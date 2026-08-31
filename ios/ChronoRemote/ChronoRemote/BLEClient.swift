import Foundation
import CoreBluetooth

/// Bluetooth LE client that talks to Chrono on the Mac.
///
/// The point of BLE over the LAN remote: it keeps working when you walk out of Wi-Fi range,
/// which is exactly the moment you are most likely to want to pause a timer.
@MainActor
@Observable
final class BLEClient: NSObject {

    enum Connection: Equatable {
        case idle
        case unauthorized
        case poweredOff
        case unsupported
        case scanning
        case connecting(String)
        case connected(String)
        case lost

        var isConnected: Bool { if case .connected = self { return true }; return false }

        var description: String {
            switch self {
            case .idle: return "Not searching"
            case .unauthorized: return "Bluetooth access denied"
            case .poweredOff: return "Bluetooth is off"
            case .unsupported: return "Bluetooth unavailable"
            case .scanning: return "Looking for your Mac…"
            case .connecting(let name): return "Connecting to \(name)…"
            case .connected(let name): return name
            case .lost: return "Disconnected — retrying"
            }
        }
    }

    private(set) var connection: Connection = .idle
    private(set) var snapshot: RemoteSnapshot?
    private(set) var info: RemoteInfo?
    private(set) var lastMessage: String?
    /// Locally-ticked elapsed value, so the timer counts smoothly between notifications.
    private(set) var displayElapsed: Int = 0

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var stateCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var tickTimer: Timer?

    private let store: PairingStore

    private let serviceUUID = CBUUID(string: ChronoRemote.BLE.serviceUUID)
    private let stateUUID = CBUUID(string: ChronoRemote.BLE.stateCharacteristicUUID)
    private let commandUUID = CBUUID(string: ChronoRemote.BLE.commandCharacteristicUUID)
    private let infoUUID = CBUUID(string: ChronoRemote.BLE.infoCharacteristicUUID)

    init(store: PairingStore) {
        self.store = store
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScan()
        }
        startTicking()
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        connection = .idle
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }
        // Filtering by service UUID is both faster and kinder to the battery than scanning
        // everything and inspecting advertisements.
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
        connection = .scanning
    }

    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let snapshot = self.snapshot, snapshot.status == .running else { return }
                self.displayElapsed += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: - Commands

    func send(_ command: RemoteCommand) {
        guard let peripheral, let characteristic = commandCharacteristic else {
            lastMessage = "Not connected"
            return
        }
        guard let secret = store.secret else {
            lastMessage = "Not paired"
            return
        }

        do {
            let envelope = try SignedEnvelope.make(
                command: command,
                counter: store.nextCounter(),
                deviceID: store.deviceID,
                secret: secret
            )
            let data = try JSONEncoder().encode(envelope)
            // `withResponse` so a failure is visible rather than silently dropped.
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        } catch {
            lastMessage = "Could not send that command"
        }
    }

    /// Optimistically reflects a command locally so the button feels instant; the Mac's next
    /// notification is authoritative.
    func optimistically(apply command: RemoteCommand) {
        guard var current = snapshot else { return }
        switch command {
        case .pause:
            current.status = .paused
        case .resume, .resumeLast:
            current.status = .running
        case .stop:
            current.status = .idle
            current.elapsed = 0
            displayElapsed = 0
        default:
            return
        }
        snapshot = current
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEClient: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: beginScan()
            case .unauthorized: connection = .unauthorized
            case .poweredOff: connection = .poweredOff
            case .unsupported: connection = .unsupported
            default: connection = .idle
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            guard self.peripheral == nil else { return }
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
                ?? peripheral.name
                ?? "Mac"
            self.peripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            connection = .connecting(name)
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            self.peripheral = nil
            beginScan()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            self.peripheral = nil
            stateCharacteristic = nil
            commandCharacteristic = nil
            connection = .lost
            // The Mac may simply have slept; keep looking rather than giving up.
            beginScan()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEClient: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else { return }
            peripheral.discoverCharacteristics([stateUUID, commandUUID, infoUUID], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case stateUUID:
                    stateCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                    peripheral.readValue(for: characteristic)
                case commandUUID:
                    commandCharacteristic = characteristic
                case infoUUID:
                    peripheral.readValue(for: characteristic)
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard let data = characteristic.value else { return }

            if characteristic.uuid == stateUUID {
                guard let incoming = try? JSONDecoder().decode(RemoteSnapshot.self, from: data) else { return }
                // Out-of-order BLE notifications are normal; ignore anything older than what we
                // already have.
                if let current = snapshot, incoming.revision < current.revision { return }
                snapshot = incoming
                displayElapsed = incoming.elapsed
                if case .connecting(let name) = connection { connection = .connected(name) }
                else if !connection.isConnected { connection = .connected(info?.deviceName ?? "Mac") }
            } else if characteristic.uuid == infoUUID {
                info = try? JSONDecoder().decode(RemoteInfo.self, from: data)
                if let name = info?.deviceName { connection = .connected(name) }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let error {
                lastMessage = "The Mac refused that: \(error.localizedDescription)"
            } else {
                // The Mac pushes a fresh snapshot right after acting, so nothing to do here.
                lastMessage = nil
            }
        }
    }
}
