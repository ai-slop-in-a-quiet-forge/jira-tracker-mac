import AppKit
import Foundation
import CoreAudio
import CoreMediaIO
import ChronoCore

/// Detects whether the microphone or camera is currently in use by anything on the system.
///
/// This is the signal that makes meeting detection actually work. Watching which app is
/// frontmost is hopeless — Teams is always open — whereas "the microphone is live" tracks the
/// thing we care about: you are talking to someone.
///
/// Both checks read a "is running somewhere" device property, so they see capture started by
/// *any* process and require no permissions of their own. Chrono never opens the microphone or
/// camera itself, and so never appears in the orange-dot privacy indicator.
public struct MediaSensor: Sendable {

    public init() {}

    // MARK: - Microphone

    public func microphoneInUse() -> Bool {
        for device in audioDevices() where hasInputStreams(device) {
            if isRunningSomewhere(device) { return true }
        }
        return false
    }

    private func audioDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return [] }
        return devices
    }

    /// Only input-capable devices matter; otherwise every playing speaker reads as a "live mic".
    private func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    // MARK: - Camera

    public func cameraInUse() -> Bool {
        for device in videoDevices() where isVideoDeviceRunning(device) {
            return true
        }
        return false
    }

    private func videoDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices
        ) == noErr else { return [] }
        return devices
    }

    private func isVideoDeviceRunning(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var running: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running
        ) == noErr else { return false }
        return running != 0
    }
}

// MARK: - Screen sharing

public extension MediaSensor {

    /// Sharing-host processes currently running.
    ///
    /// Deliberately a process check rather than asking the system whether the screen is being
    /// captured: every API that answers that directly needs Screen Recording permission, and
    /// Chrono's sensors require none. See `MeetingAppCatalog.screenSharingHostBundleIDs` for
    /// what may go in the catalogue and why most meeting apps cannot.
    ///
    /// `runningApplications` is permission-free and does include helper bundles, which is what
    /// makes this work at all.
    func screenSharingHosts() -> Set<String> {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return running.intersection(MeetingAppCatalog.screenSharingHostBundleIDs)
    }
}
