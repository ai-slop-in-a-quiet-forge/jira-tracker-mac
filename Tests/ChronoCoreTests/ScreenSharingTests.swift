import Foundation
import Testing
@testable import ChronoCore

@Suite("Screen sharing as a meeting signal")
struct ScreenSharingTests {

    private let zoomHost = "us.zoom.CptHost"

    private func snapshot(
        sharing: Set<String> = [],
        mic: Bool = false,
        camera: Bool = false,
        runningApps: Set<String> = [],
        frontmost: String? = nil
    ) -> ActivitySnapshot {
        ActivitySnapshot(
            timestamp: Fixture.referenceDate,
            microphoneInUse: mic,
            cameraInUse: camera,
            frontmostBundleID: frontmost,
            runningMeetingApps: runningApps,
            screenSharingHosts: sharing
        )
    }

    @Test("Sharing the screen is certain on its own")
    func sharingIsCertain() {
        let signal = snapshot(sharing: [zoomHost]).meetingSignal(settings: Settings())
        #expect(signal?.confidence == .certain)
        #expect(signal?.reason == "you are sharing your screen")
    }

    @Test("Presenting while muted with the camera off is caught")
    func presentingWhileMuted() {
        // The entire point of the issue: mic and camera signals both miss this.
        let muted = snapshot(sharing: [zoomHost], mic: false, camera: false)
        #expect(muted.meetingSignal(settings: Settings())?.confidence == .certain)

        // Without the sharing signal the same snapshot reads as nothing at all.
        let withoutSharing = snapshot(mic: false, camera: false)
        #expect(withoutSharing.meetingSignal(settings: Settings()) == nil)
    }

    @Test("The warning names the app, not the helper process")
    func namesTheOwningApp() {
        let signal = snapshot(sharing: [zoomHost]).meetingSignal(settings: Settings())
        #expect(signal?.appName == "Zoom")
    }

    @Test("Turning the setting off ignores sharing entirely")
    func respectsTheSetting() {
        var settings = Settings()
        settings.detectViaScreenSharing = false
        #expect(snapshot(sharing: [zoomHost]).meetingSignal(settings: settings) == nil)
    }

    @Test("Sharing is on by default")
    func onByDefault() {
        #expect(Settings().detectViaScreenSharing)
    }

    @Test("Sharing outranks a mere frontmost app")
    func outranksWeakSignals() {
        var settings = Settings()
        settings.detectViaFrontmostApp = true
        let signal = snapshot(sharing: [zoomHost], frontmost: "com.microsoft.teams2")
            .meetingSignal(settings: settings)
        // Actually capturing beats merely having a window in front.
        #expect(signal?.confidence == .certain)
        #expect(signal?.reason == "you are sharing your screen")
    }

    @Test("A locked screen or sleeping machine still reports nothing")
    func respectsLockAndSleep() {
        var locked = snapshot(sharing: [zoomHost])
        locked.screenLocked = true
        #expect(locked.meetingSignal(settings: Settings()) == nil)

        var asleep = snapshot(sharing: [zoomHost])
        asleep.systemAsleep = true
        #expect(asleep.meetingSignal(settings: Settings()) == nil)
    }

    @Test("Meeting detection off disables it like every other signal")
    func respectsMasterSwitch() {
        var settings = Settings()
        settings.meetingDetectionEnabled = false
        #expect(snapshot(sharing: [zoomHost]).meetingSignal(settings: settings) == nil)
    }

    @Test("No sharing host means no sharing signal")
    func emptyIsQuiet() {
        #expect(snapshot(sharing: []).meetingSignal(settings: Settings()) == nil)
    }

    @Test("The catalogue only holds processes that exist solely while sharing")
    func catalogueExcludesAlwaysRunningHelpers() {
        // Electron helpers run the whole time their app does, so including one would report a
        // meeting for as long as Teams was open. This pins that decision.
        let catalogue = MeetingAppCatalog.screenSharingHostBundleIDs
        #expect(catalogue.contains("us.zoom.CptHost"))
        #expect(catalogue.contains("com.microsoft.teams2.helper") == false)
        #expect(catalogue.contains("com.microsoft.teams2.modulehost") == false)
        #expect(catalogue.contains("com.tinyspeck.slackmacgap") == false)
    }

    @Test("Every catalogued host maps to a nameable app")
    func hostsHaveOwners() {
        for host in MeetingAppCatalog.screenSharingHostBundleIDs {
            let owner = MeetingAppCatalog.appOwningSharingHost(host)
            #expect(owner != nil, "\(host) has no owning app")
            if let owner {
                #expect(MeetingAppCatalog.displayName(forBundleID: owner) != owner)
            }
        }
    }
}
