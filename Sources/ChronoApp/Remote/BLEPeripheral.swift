import Foundation
import CoreBluetooth
import ChronoCore

/// Advertises Chrono as a Bluetooth LE peripheral so the iPhone app can control the timer with
/// no network at all.
///
/// This is the part Electron could not have done, and it matters for the actual use case: you
/// walk out of the room to take a call, off the office Wi-Fi, and still want to hit pause.
/// BLE reaches roughly across a floor and needs no infrastructure whatsoever.
///
/// Three characteristics: read/notify state, write command, and an unauthenticated info read so
/// the phone can identify which Mac it has found before pairing.
@MainActor
final class BLEPeripheral: NSObject, CBPeripheralManagerDelegate {

    enum Status: Equatable {
        case stopped
        case unauthorized
        case poweredOff
        case unsupported
        case advertising(subscribers: Int)

        var description: String {
            switch self {
            case .stopped: return "Off"
            case .unauthorized: return "Bluetooth permission denied"
            case .poweredOff: return "Bluetooth is turned off"
            case .unsupported: return "This Mac does not support Bluetooth LE"
            case .advertising(let count):
                return count == 0 ? "Advertising — no phone connected" : "Connected to \(count) device\(count == 1 ? "" : "s")"
            }
        }

        var isHealthy: Bool { if case .advertising = self { return true }; return false }
    }

    private(set) var status: Status = .stopped
    var onStatusChange: ((Status) -> Void)?

    /// Produces the current snapshot as JSON, kept small enough for one notification.
    var stateProvider: (() -> Data)?
    /// Produces the info blob, readable before pairing.
    var infoProvider: (() -> Data)?
    /// Handles a signed command; returns the response JSON.
    var commandHandler: ((Data) async -> Data)?

    private var manager: CBPeripheralManager?
    private var stateCharacteristic: CBMutableCharacteristic?
    private var subscribers: Set<UUID> = []
    /// Reassembly buffer per central, in case a command exceeds one write.
    private var partialWrites: [UUID: Data] = [:]

    private let serviceUUID = CBUUID(string: ChronoRemote.BLE.serviceUUID)
    private let stateUUID = CBUUID(string: ChronoRemote.BLE.stateCharacteristicUUID)
    private let commandUUID = CBUUID(string: ChronoRemote.BLE.commandCharacteristicUUID)
    private let infoUUID = CBUUID(string: ChronoRemote.BLE.infoCharacteristicUUID)

    private var deviceName: String

    init(deviceName: String) {
        self.deviceName = deviceName
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard manager == nil else { return }
        // Creating the manager is what triggers the Bluetooth permission prompt, so it happens
        // only when the user has actually enabled the remote.
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager = nil
        stateCharacteristic = nil
        subscribers.removeAll()
        set(status: .stopped)
    }

    var isRunning: Bool { manager != nil }

    /// Pushes a new snapshot to every subscribed phone.
    func publishState() {
        guard let manager, let characteristic = stateCharacteristic, !subscribers.isEmpty,
              let data = stateProvider?() else { return }
        // A false return means the transmit queue is full; CoreBluetooth will call
        // `peripheralManagerIsReady` and we simply publish on the next state change.
        _ = manager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
    }

    private func set(status newValue: Status) {
        guard status != newValue else { return }
        status = newValue
        onStatusChange?(newValue)
    }

    // MARK: - CBPeripheralManagerDelegate

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        // Delivered on the main queue (the manager was created with `queue: .main`).
        MainActor.assumeIsolated {
            switch peripheral.state {
            case .poweredOn:
                publishService(on: peripheral)
            case .unauthorized:
                set(status: .unauthorized)
            case .poweredOff:
                set(status: .poweredOff)
            case .unsupported:
                set(status: .unsupported)
            default:
                set(status: .stopped)
            }
        }
    }

    private func publishService(on peripheral: CBPeripheralManager) {
        let state = CBMutableCharacteristic(
            type: stateUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        let command = CBMutableCharacteristic(
            type: commandUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        // A fixed value, so it needs no read callback and is cheap to fetch.
        let info = CBMutableCharacteristic(
            type: infoUUID,
            properties: [.read],
            value: infoProvider?(),
            permissions: [.readable]
        )

        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [state, command, info]

        peripheral.removeAllServices()
        peripheral.add(service)
        stateCharacteristic = state

        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            // The advertised name is truncated hard by BLE; keep it short and recognisable.
            CBAdvertisementDataLocalNameKey: String("\(ChronoRemote.BLE.advertisedNamePrefix) \(deviceName)".prefix(18)),
        ])
        set(status: .advertising(subscribers: subscribers.count))
        ChronoLog.remote.info("BLE peripheral advertising")
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        // Delivered on the main queue (the manager was created with `queue: .main`).
        MainActor.assumeIsolated {
            let data: Data?
            if request.characteristic.uuid == stateUUID {
                data = stateProvider?()
            } else if request.characteristic.uuid == infoUUID {
                data = infoProvider?()
            } else {
                peripheral.respond(to: request, withResult: .attributeNotFound)
                return
            }

            guard let data else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                return
            }
            guard request.offset <= data.count else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }
            request.value = data.subdata(in: request.offset..<data.count)
            peripheral.respond(to: request, withResult: .success)
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        // Delivered on the main queue (the manager was created with `queue: .main`).
        MainActor.assumeIsolated {
            for request in requests {
                guard request.characteristic.uuid == commandUUID, let value = request.value else {
                    peripheral.respond(to: request, withResult: .writeNotPermitted)
                    return
                }

                let centralID = request.central.identifier
                var accumulated = partialWrites[centralID] ?? Data()
                accumulated.append(value)

                // A complete command is valid JSON; anything else is a partial write to buffer.
                if (try? JSONSerialization.jsonObject(with: accumulated)) != nil {
                    partialWrites[centralID] = nil
                    Task { [weak self] in
                        _ = await self?.commandHandler?(accumulated)
                        self?.publishState()
                    }
                } else if accumulated.count < 4096 {
                    partialWrites[centralID] = accumulated
                } else {
                    // Give up rather than buffer unboundedly on malformed input.
                    partialWrites[centralID] = nil
                }
            }
            // Respond to the first request only, as CoreBluetooth requires.
            if let first = requests.first {
                peripheral.respond(to: first, withResult: .success)
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        // Delivered on the main queue (the manager was created with `queue: .main`).
        MainActor.assumeIsolated {
            subscribers.insert(central.identifier)
            set(status: .advertising(subscribers: subscribers.count))
            publishState()
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        // Delivered on the main queue (the manager was created with `queue: .main`).
        MainActor.assumeIsolated {
            subscribers.remove(central.identifier)
            partialWrites[central.identifier] = nil
            set(status: .advertising(subscribers: subscribers.count))
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Delivered on the main queue (the manager was created with `queue: .main`).
        MainActor.assumeIsolated {
            publishState()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        // Delivered on the main queue (the manager was created with `queue: .main`).
        MainActor.assumeIsolated {
            if let error {
                ChronoLog.remote.error("Could not publish BLE service: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
