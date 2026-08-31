import Foundation
import Testing
@testable import ChronoCore

@Suite("Persistence")
struct StorageTests {

    private func tempFileStore() throws -> FileStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chrono-fs-\(UUID().uuidString)", isDirectory: true)
        let store = FileStore(directory: dir)
        try store.ensureDirectoryExists()
        return store
    }

    @Test("Round trips a Codable value")
    func roundTrip() throws {
        let store = try tempFileStore()
        var settings = Settings()
        settings.dailyTargetHours = 6.5
        settings.siteURL = "https://acme.atlassian.net"

        try store.save(settings, to: "settings.json")
        let loaded = try #require(try store.load(Settings.self, from: "settings.json"))
        #expect(loaded.dailyTargetHours == 6.5)
        #expect(loaded.siteURL == "https://acme.atlassian.net")
    }

    @Test("A missing file yields the defaults rather than an error")
    func missingFileUsesDefaults() throws {
        let store = try tempFileStore()
        let result = store.loadMerging(defaults: Settings(), from: "nope.json")
        #expect(result.recovered == false)
        #expect(result.value == Settings())
    }

    @Test("A file from an older version still loads, with defaults for new fields")
    func forwardCompatibleLoad() throws {
        let store = try tempFileStore()
        // Simulates a file written before most settings existed.
        let legacy = """
        { "siteURL": "https://old.atlassian.net", "dailyTargetHours": 7 }
        """
        try Data(legacy.utf8).write(to: store.url(for: "settings.json"))

        let result = store.loadMerging(defaults: Settings(), from: "settings.json")
        #expect(result.value.siteURL == "https://old.atlassian.net", "stored values win")
        #expect(result.value.dailyTargetHours == 7)
        #expect(result.value.idleThresholdSeconds == Settings().idleThresholdSeconds, "new fields fall back")
        #expect(result.value.roundingMode == .nearest)
    }

    @Test("Unknown fields from a newer version are ignored, not fatal")
    func unknownFieldsIgnored() throws {
        let store = try tempFileStore()
        let futuristic = """
        { "dailyTargetHours": 9, "teleportationEnabled": true }
        """
        try Data(futuristic.utf8).write(to: store.url(for: "settings.json"))

        let result = store.loadMerging(defaults: Settings(), from: "settings.json")
        #expect(result.value.dailyTargetHours == 9)
    }

    @Test("A corrupt file is quarantined rather than deleted, and defaults are used")
    func corruptFileQuarantined() throws {
        let store = try tempFileStore()
        try Data("this is not json {{{".utf8).write(to: store.url(for: "state.json"))

        let result = store.loadMerging(defaults: PersistedState(), from: "state.json")
        #expect(result.recovered)
        #expect(result.value.segments.isEmpty)
        #expect(store.exists("state.json") == false)
        let quarantined = store.listFiles(withPrefix: "state.json.corrupt-")
        #expect(quarantined.count == 1, "the user's unreadable data must still be on disk")
    }

    @Test("Segments older than the hot window are archived and removed from state")
    func archivingOldSegments() throws {
        let fileStore = try tempFileStore()
        let store = StateStore(fileStore: fileStore, debounce: 0)
        let now = Fixture.referenceDate

        var state = PersistedState()
        let recent = Fixture.segment(Fixture.issue("CYM-1"), from: now.addingTimeInterval(-3600), minutes: 30)
        let ancient = Fixture.segment(
            Fixture.issue("CYM-OLD"),
            from: now.addingTimeInterval(-90 * 86_400),
            minutes: 60
        )
        state.segments = [ancient, recent]

        let trimmed = store.retireOldSegments(in: state, asOf: now)

        #expect(trimmed.segments.count == 1)
        #expect(trimmed.segments[0].target.issueKey == "CYM-1")

        let month = SegmentArchive.monthKey(for: ancient.start)
        #expect(store.loadArchive(month: month).count == 1)

        // Running it again must not duplicate the archived entry.
        _ = store.retireOldSegments(in: trimmed, asOf: now)
        #expect(store.loadArchive(month: month).count == 1)
    }

    @Test("Reading a date range pulls archived months back in")
    func rangeQuerySpansArchives() throws {
        let fileStore = try tempFileStore()
        let store = StateStore(fileStore: fileStore, debounce: 0)
        let now = Fixture.referenceDate

        var state = PersistedState()
        let ancient = Fixture.segment(
            Fixture.issue("CYM-OLD"), from: now.addingTimeInterval(-90 * 86_400), minutes: 60
        )
        state.segments = [ancient]
        let trimmed = store.retireOldSegments(in: state, asOf: now)

        let range = DateInterval(start: ancient.start.addingTimeInterval(-86_400), end: now)
        let found = store.segments(covering: range, hotSegments: trimmed.segments)
        #expect(found.contains { $0.target.issueKey == "CYM-OLD" })
    }

    @Test("An incoherent running state is repaired to idle on load")
    func sanitizesImpossibleState() throws {
        let fileStore = try tempFileStore()
        let store = StateStore(fileStore: fileStore, debounce: 0)

        // runningSince set but no target or segment id — cannot be interpreted.
        let broken = """
        { "runningSince": "2026-03-10T09:00:00Z", "schemaVersion": 1 }
        """
        try Data(broken.utf8).write(to: fileStore.url(for: "state.json"))

        let loaded = store.loadState()
        #expect(loaded.state.isRunning == false)
        #expect(loaded.state.isIdle)
    }
}

@Suite("Remote authentication")
struct RemoteAuthTests {

    @Test("A correctly signed command is accepted")
    func acceptsValidCommand() async throws {
        let secret = KeychainStore.randomSecret()
        let clock = MutableClock(Fixture.referenceDate)
        let verifier = RemoteCommandVerifier(secret: secret, clock: clock)

        let envelope = try SignedEnvelope.make(
            command: .pause, counter: 1, deviceID: "iphone", secret: secret, now: clock.now
        )
        let command = try await verifier.verify(envelope)
        #expect(command == .pause)
    }

    @Test("A tampered payload is rejected")
    func rejectsTamperedPayload() async throws {
        let secret = KeychainStore.randomSecret()
        let clock = MutableClock(Fixture.referenceDate)
        let verifier = RemoteCommandVerifier(secret: secret, clock: clock)

        var envelope = try SignedEnvelope.make(
            command: .pause, counter: 1, deviceID: "iphone", secret: secret, now: clock.now
        )
        // Swap the command for a destructive one, keeping the original signature.
        envelope.payload = try JSONEncoder().encode(RemoteCommand.stop)

        await #expect(throws: RemoteCommandVerifier.Rejection.badSignature) {
            _ = try await verifier.verify(envelope)
        }
    }

    @Test("The wrong secret is rejected")
    func rejectsWrongSecret() async throws {
        let clock = MutableClock(Fixture.referenceDate)
        let verifier = RemoteCommandVerifier(secret: KeychainStore.randomSecret(), clock: clock)

        let envelope = try SignedEnvelope.make(
            command: .pause, counter: 1, deviceID: "iphone", secret: "someone-elses-secret", now: clock.now
        )
        await #expect(throws: RemoteCommandVerifier.Rejection.badSignature) {
            _ = try await verifier.verify(envelope)
        }
    }

    @Test("A replayed counter is rejected")
    func rejectsReplay() async throws {
        let secret = KeychainStore.randomSecret()
        let clock = MutableClock(Fixture.referenceDate)
        let verifier = RemoteCommandVerifier(secret: secret, clock: clock)

        let envelope = try SignedEnvelope.make(
            command: .pause, counter: 5, deviceID: "iphone", secret: secret, now: clock.now
        )
        _ = try await verifier.verify(envelope)

        await #expect(throws: RemoteCommandVerifier.Rejection.self) {
            _ = try await verifier.verify(envelope)
        }
    }

    @Test("A stale command is rejected even with a fresh counter, covering the post-restart replay gap")
    func rejectsStaleTimestamp() async throws {
        let secret = KeychainStore.randomSecret()
        let clock = MutableClock(Fixture.referenceDate)
        let verifier = RemoteCommandVerifier(secret: secret, clock: clock)

        let envelope = try SignedEnvelope.make(
            command: .stop, counter: 99, deviceID: "iphone", secret: secret, now: clock.now
        )
        // The Mac restarts (counters forgotten) and an hour passes.
        clock.advance(by: 3600)

        await #expect(throws: RemoteCommandVerifier.Rejection.self) {
            _ = try await verifier.verify(envelope)
        }
    }

    @Test("Commands are refused entirely when no secret is set")
    func refusesWhenUnpaired() async throws {
        let verifier = RemoteCommandVerifier(secret: nil, clock: MutableClock(Fixture.referenceDate))
        let envelope = try SignedEnvelope.make(
            command: .pause, counter: 1, deviceID: "iphone", secret: "x", now: Fixture.referenceDate
        )
        await #expect(throws: RemoteCommandVerifier.Rejection.notPaired) {
            _ = try await verifier.verify(envelope)
        }
    }

    @Test("Rotating the secret unpairs existing devices")
    func rotationUnpairs() async throws {
        let original = KeychainStore.randomSecret()
        let clock = MutableClock(Fixture.referenceDate)
        let verifier = RemoteCommandVerifier(secret: original, clock: clock)

        await verifier.updateSecret(KeychainStore.randomSecret())
        let envelope = try SignedEnvelope.make(
            command: .pause, counter: 1, deviceID: "iphone", secret: original, now: clock.now
        )
        await #expect(throws: RemoteCommandVerifier.Rejection.badSignature) {
            _ = try await verifier.verify(envelope)
        }
    }

    @Test("The pairing secret is not embedded in the query string of the pairing URL")
    func pairingURLKeepsSecretInFragment() throws {
        let payload = PairingPayload(host: "192.168.1.20", port: 8765, secret: "s3cr3t", deviceName: "Mac")
        let url = try #require(payload.pairingURL())

        #expect(url.query == nil, "a query string would be logged by any proxy in between")
        #expect(url.fragment?.contains("s=s3cr3t") == true, "fragments are never sent to the server")
    }

    @Test("Every command round trips through its compact encoding")
    func commandCodingRoundTrip() throws {
        let commands: [RemoteCommand] = [
            .pause, .resume, .stop, .resumeLast, .switchToMeeting, .refresh,
            .startIssue("CYM-123"), .snooze(minutes: 15), .note("on a call"),
        ]
        for command in commands {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(RemoteCommand.self, from: data) == command)
        }
    }

    @Test("A state snapshot fits inside one BLE notification")
    func snapshotFitsBLEPacket() throws {
        let snapshot = RemoteSnapshot(
            status: .running,
            label: "CYM-12345 a fairly long issue summary that should be truncated",
            elapsed: 359_999,
            todaySeconds: 86_399,
            targetSeconds: 8 * 3600,
            pendingDrafts: 99,
            unfiledSeconds: 12_345,
            inMeeting: true,
            revision: 999_999
        )
        let data = try JSONEncoder().encode(snapshot)
        // 185 bytes is a typical negotiated ATT MTU; staying under it avoids a chunking layer.
        #expect(data.count <= 185, "snapshot was \(data.count) bytes")
    }
}

@Suite("Jira plumbing")
struct JiraPlumbingTests {

    @Test("Site URL normalisation", arguments: [
        ("acme", "https://acme.atlassian.net"),
        ("acme.atlassian.net", "https://acme.atlassian.net"),
        ("https://acme.atlassian.net", "https://acme.atlassian.net"),
        ("https://acme.atlassian.net/", "https://acme.atlassian.net"),
        ("http://acme.atlassian.net/jira/software/projects/CYM/boards/1", "https://acme.atlassian.net"),
        ("  ACME.Atlassian.NET  ", "https://acme.atlassian.net"),
        ("jira.mycompany.com", "https://jira.mycompany.com"),
    ])
    func siteNormalisation(input: String, expected: String) throws {
        let url = try #require(JiraCredentials.normalizeSite(input))
        #expect(url.absoluteString == expected)
    }

    @Test("Empty or nonsense site input is rejected")
    func rejectsBadSite() {
        #expect(JiraCredentials.normalizeSite("") == nil)
        #expect(JiraCredentials.normalizeSite("   ") == nil)
    }

    @Test("Credentials are rejected unless all three parts are present")
    func credentialValidation() {
        #expect(JiraCredentials(rawSite: "acme", email: "", apiToken: "t") == nil)
        #expect(JiraCredentials(rawSite: "acme", email: "a@b.com", apiToken: "  ") == nil)
        #expect(JiraCredentials(rawSite: "acme", email: "a@b.com", apiToken: "token") != nil)
    }

    @Test("Basic auth header is correctly encoded")
    func basicAuthHeader() throws {
        let credentials = try #require(
            JiraCredentials(rawSite: "acme", email: "user@example.com", apiToken: "abc123")
        )
        #expect(credentials.basicAuthHeader == "Basic dXNlckBleGFtcGxlLmNvbTphYmMxMjM=")
    }

    @Test("The redacted description never contains the whole token")
    func redactionHidesToken() throws {
        let credentials = try #require(
            JiraCredentials(rawSite: "acme", email: "user@example.com", apiToken: "supersecrettoken9999")
        )
        let described = credentials.redactedDescription
        #expect(described.contains("supersecrettoken") == false)
        #expect(described.contains("9999"))
    }

    @Test("Jira timestamps use a colon-less offset, which ISO8601DateFormatter cannot produce")
    func jiraTimestampFormat() {
        let stamp = Fixture.referenceDate.jiraTimestamp
        // e.g. 2026-03-10T09:00:00.000+0530
        #expect(stamp.contains("T"))
        #expect(stamp.contains("."))
        let offset = String(stamp.suffix(5))
        #expect(offset.contains(":") == false, "Jira rejects +05:30")
        #expect(JiraClient.parseJiraDate(stamp) != nil, "and we must be able to read it back")
    }

    @Test("Jira error bodies are turned into something readable")
    func errorMessageExtraction() {
        let body = Data(#"{"errorMessages":["Issue does not exist"],"errors":{}}"#.utf8)
        #expect(JiraClient.extractMessage(from: body) == "Issue does not exist")

        let fieldErrors = Data(#"{"errorMessages":[],"errors":{"timeSpentSeconds":"must be positive"}}"#.utf8)
        #expect(JiraClient.extractMessage(from: fieldErrors).contains("must be positive"))
    }

    @Test("HTTP status codes map onto the right retry behaviour", arguments: [
        (401, FailureKind.authentication, false),
        (403, FailureKind.authentication, false),
        (404, FailureKind.issueNotFound, false),
        (400, FailureKind.rejected, false),
        (429, FailureKind.rateLimited, true),
        (503, FailureKind.serverError, true),
    ])
    func statusMapping(status: Int, kind: FailureKind, retryable: Bool) {
        let error = JiraError.http(status: status, message: "")
        #expect(error.failureKind == kind)
        #expect(error.failureKind.isRetryable == retryable)
    }

    @Test("Ids arrive as strings or numbers and decode either way")
    func flexibleIDDecoding() throws {
        struct Holder: Codable { let id: FlexibleID }
        let asString = try JSONDecoder().decode(Holder.self, from: Data(#"{"id":"10042"}"#.utf8))
        let asNumber = try JSONDecoder().decode(Holder.self, from: Data(#"{"id":10042}"#.utf8))
        #expect(asString.id.value == "10042")
        #expect(asNumber.id.value == "10042")
    }

    @Test("Plain text becomes a valid ADF document, one paragraph per line")
    func adfGeneration() throws {
        let document = try #require(ADF.document(from: "First line\nSecond line"))
        #expect(document["type"] as? String == "doc")
        #expect(document["version"] as? Int == 1)
        let content = try #require(document["content"] as? [[String: Any]])
        #expect(content.count == 2)
    }

    @Test("Empty comments produce no ADF at all, so the field can be omitted")
    func adfSkipsEmpty() {
        #expect(ADF.document(from: nil) == nil)
        #expect(ADF.document(from: "   \n  ") == nil)
    }

    @Test("ADF from Jira flattens back to readable text")
    func adfFlattening() {
        let document: [String: Any] = [
            "type": "doc",
            "version": 1,
            "content": [
                ["type": "paragraph", "content": [["type": "text", "text": "Reviewed the PR"]]],
                ["type": "paragraph", "content": [["type": "text", "text": "Then deployed"]]],
            ],
        ]
        let text = ADF.plainText(from: document)
        #expect(text.contains("Reviewed the PR"))
        #expect(text.contains("Then deployed"))
    }
}

@Suite("Rollups and formatting")
struct RollupTests {

    @Test("Daily totals group by target and separate breaks from work")
    func dailyTotals() {
        let now = Fixture.referenceDate
        let segments = [
            Fixture.segment(Fixture.issue("CYM-1"), from: now, minutes: 60),
            Fixture.segment(Fixture.issue("CYM-1"), from: now.addingTimeInterval(7200), minutes: 30),
            Fixture.segment(Fixture.issue("CYM-2"), from: now.addingTimeInterval(3600), minutes: 45),
            Fixture.segment(Fixture.adhoc(.breakTime), from: now.addingTimeInterval(10_800), minutes: 20),
        ]

        let rollup = DayRollup.build(segments: segments, day: now, asOf: now.addingTimeInterval(20_000))

        #expect(rollup.workSeconds == (60 + 30 + 45) * 60)
        #expect(rollup.breakSeconds == 20 * 60)
        #expect(rollup.totals.count == 3)
        #expect(rollup.totals.first { $0.target.issueKey == "CYM-1" }?.seconds == 5400)
    }

    @Test("Unfiled ad-hoc work is reported separately from loggable work")
    func unloggableTracked() {
        let now = Fixture.referenceDate
        let segments = [
            Fixture.segment(Fixture.issue("CYM-1"), from: now, minutes: 60),
            Fixture.segment(Fixture.adhoc(.interruption), from: now.addingTimeInterval(3600), minutes: 25),
        ]
        let rollup = DayRollup.build(segments: segments, day: now, asOf: now.addingTimeInterval(9000))

        #expect(rollup.workSeconds == 85 * 60)
        #expect(rollup.unloggableSeconds == 25 * 60, "the interruption still needs a ticket")
    }

    @Test("Pause and resume on one task is not counted as a context switch")
    func contextSwitchCounting() {
        let now = Fixture.referenceDate
        let segments = [
            Fixture.segment(Fixture.issue("CYM-1"), from: now, minutes: 20),
            Fixture.segment(Fixture.issue("CYM-1"), from: now.addingTimeInterval(1800), minutes: 20),
            Fixture.segment(Fixture.issue("CYM-2"), from: now.addingTimeInterval(4000), minutes: 20),
            Fixture.segment(Fixture.issue("CYM-1"), from: now.addingTimeInterval(6000), minutes: 20),
        ]
        let rollup = DayRollup.build(segments: segments, day: now, asOf: now.addingTimeInterval(9000))
        #expect(rollup.contextSwitches == 2)
    }

    @Test("Untracked time inside the working span is surfaced")
    func untrackedGap() {
        let now = Fixture.referenceDate
        let segments = [
            Fixture.segment(Fixture.issue("CYM-1"), from: now, minutes: 60),
            // A three-hour hole, then more work.
            Fixture.segment(Fixture.issue("CYM-1"), from: now.addingTimeInterval(4 * 3600), minutes: 60),
        ]
        let rollup = DayRollup.build(segments: segments, day: now, asOf: now.addingTimeInterval(6 * 3600))

        #expect(rollup.totalSeconds == 7200)
        #expect(rollup.spanSeconds == 5 * 3600)
        #expect(rollup.untrackedWithinSpanSeconds == 3 * 3600)
    }

    @Test("Progress toward the daily target is clamped to 1")
    func progressClamped() {
        let now = Fixture.referenceDate
        let rollup = DayRollup.build(
            segments: [Fixture.segment(Fixture.issue("CYM-1"), from: now, minutes: 600)],
            day: now,
            asOf: now.addingTimeInterval(40_000)
        )
        #expect(rollup.progress(towardHours: 8) == 1)
    }

    @Test("Duration formatting", arguments: [
        (0.0, "0:00", "0s"),
        (59.0, "0:00", "59s"),
        (60.0, "0:01", "1m"),
        (3600.0, "1:00", "1h"),
        (8100.0, "2:15", "2h 15m"),
        (86_399.0, "23:59", "23h 59m"),
    ])
    func formatting(seconds: Double, compact: String, humane: String) {
        #expect(DurationFormat.compact(seconds) == compact)
        #expect(DurationFormat.humane(seconds) == humane)
    }

    @Test("The menu bar string keeps a fixed width so the bar does not jitter")
    func compactFormatIsStable() {
        // Within an hour bucket the width must not change as seconds tick past.
        let widths = Set((0..<60).map { DurationFormat.compact(3600 + Double($0)).count })
        #expect(widths.count == 1)
    }

    @Test("Jira shorthand matches what Jira itself displays", arguments: [
        (0.0, "0m"), (60.0, "1m"), (3600.0, "1h"), (8100.0, "2h 15m"), (5400.0, "1h 30m"),
    ])
    func jiraShorthand(seconds: Double, expected: String) {
        #expect(DurationFormat.jira(seconds) == expected)
    }
}

@Suite("Segment arithmetic")
struct SegmentTests {

    @Test("A segment spanning midnight splits into one piece per day")
    func splitAcrossMidnight() {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: Fixture.referenceDate)!
        let segment = Fixture.segment(Fixture.issue("CYM-1"), from: start, minutes: 240) // 22:00 -> 02:00

        let pieces = segment.splitAcrossDays(asOf: start.addingTimeInterval(14_400))
        #expect(pieces.count == 2)
        #expect(pieces[0].closedDuration == 2 * 3600)
        #expect(pieces[1].closedDuration == 2 * 3600)
        #expect(pieces.allSatisfy { $0.id == segment.id }, "pieces keep the parent id so draft coverage still works")
    }

    @Test("A segment inside one day is returned unchanged")
    func noSplitNeeded() {
        let segment = Fixture.segment(Fixture.issue("CYM-1"), from: Fixture.referenceDate, minutes: 60)
        #expect(segment.splitAcrossDays(asOf: Fixture.referenceDate.addingTimeInterval(3600)).count == 1)
    }

    @Test("Closing at an earlier time than the start clamps instead of going negative")
    func closingClamps() {
        let segment = WorkSegment(target: Fixture.issue("CYM-1"), start: Fixture.referenceDate)
        let closed = segment.closing(at: Fixture.referenceDate.addingTimeInterval(-500))
        #expect(closed.closedDuration == 0)
    }

    @Test("Trimming the tail records how much idle time was removed")
    func trimmingRecordsIdle() {
        let segment = Fixture.segment(Fixture.issue("CYM-1"), from: Fixture.referenceDate, minutes: 30)
        let trimmed = segment.trimmingTail(by: 600, at: Fixture.referenceDate.addingTimeInterval(1800))
        #expect(trimmed.closedDuration == 1200)
        #expect(trimmed.trimmedIdle == 600)
    }

    @Test("An open segment measures against now")
    func openSegmentDuration() {
        let segment = WorkSegment(target: Fixture.issue("CYM-1"), start: Fixture.referenceDate)
        #expect(segment.isOpen)
        #expect(segment.duration(asOf: Fixture.referenceDate.addingTimeInterval(120)) == 120)
    }
}

@Suite("Cross-language signing contract")
struct SigningContractTests {

    /// Pins the exact bytes both the Swift side and the phone remote's JavaScript sign.
    ///
    /// The web remote cannot use WebCrypto (`crypto.subtle` requires a secure context, and the
    /// remote is plain HTTP on a LAN address), so it ships its own SHA-256/HMAC. This vector is
    /// what stops the two implementations from silently drifting apart: the expected value was
    /// produced by the JavaScript in `RemoteWebAssets`, verified against Node's crypto module.
    @Test("Swift and the phone remote's JavaScript produce identical signatures")
    func signatureMatchesJavaScriptImplementation() {
        let secret = "testsecret"
        let counter: UInt64 = 7
        let timestamp: Int64 = 1_700_000_000
        let payload = Data(#"{"c":"pause"}"#.utf8)

        let mac = RemoteAuth.sign(
            payload: payload,
            counter: counter,
            timestamp: timestamp,
            secret: secret
        )

        #expect(mac.base64EncodedString() == "ppiicj+70jVkXceqVTWXcEKZAfwv+MBexuBJF5YNCJI=")
    }

    @Test("The signed input is exactly counter.timestamp.payload")
    func signingInputShape() throws {
        let input = RemoteAuth.signingInput(
            counter: 42,
            timestamp: 1_700_000_000,
            payload: Data("hello".utf8)
        )
        #expect(String(decoding: input, as: UTF8.self) == "42.1700000000.hello")
    }
}

@Suite("HTTP request parsing")
struct HTTPRequestTests {

    private func raw(_ text: String) -> Data { Data(text.utf8) }

    @Test("Parses a simple GET")
    func simpleGet() throws {
        let request = try #require(HTTPRequest(raw: raw(
            "GET /state HTTP/1.1\r\nHost: 192.168.1.20:8765\r\nX-Chrono-Counter: 7\r\n\r\n"
        )))
        #expect(request.method == "GET")
        #expect(request.path == "/state")
        #expect(request.headers["x-chrono-counter"] == "7")
        #expect(request.body.isEmpty)
    }

    @Test("Header names are matched case-insensitively, since clients vary")
    func headerCaseInsensitivity() throws {
        let request = try #require(HTTPRequest(raw: raw(
            "GET / HTTP/1.1\r\nX-CHRONO-MAC: abc\r\nx-chrono-device: phone-1\r\n\r\n"
        )))
        #expect(request.headers["x-chrono-mac"] == "abc")
        #expect(request.headers["x-chrono-device"] == "phone-1")
    }

    @Test("A query string is stripped from the path")
    func queryStringStripped() throws {
        let request = try #require(HTTPRequest(raw: raw("GET /state?cache=0 HTTP/1.1\r\n\r\n")))
        #expect(request.path == "/state")
    }

    @Test("Returns nil until the headers are complete, so the caller keeps reading")
    func incompleteHeaders() {
        #expect(HTTPRequest(raw: raw("POST /command HTTP/1.1\r\nContent-Length: 5\r\n")) == nil)
        #expect(HTTPRequest(raw: raw("POST /comm")) == nil)
    }

    @Test("Returns nil until the whole body has arrived")
    func incompleteBody() throws {
        let head = "POST /command HTTP/1.1\r\nContent-Length: 13\r\n\r\n"
        #expect(HTTPRequest(raw: raw(head + "{\"c\":\"pau")) == nil, "body is short, keep reading")

        let complete = try #require(HTTPRequest(raw: raw(head + #"{"c":"pause"}"#)))
        #expect(String(decoding: complete.body, as: UTF8.self) == #"{"c":"pause"}"#)
    }

    @Test("Extra bytes past Content-Length are not swallowed into the body")
    func bodyRespectsContentLength() throws {
        let request = try #require(HTTPRequest(raw: raw(
            "POST /command HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcdEXTRA"
        )))
        #expect(String(decoding: request.body, as: UTF8.self) == "abcd")
    }

    @Test("A body with no Content-Length is treated as empty rather than guessed at")
    func missingContentLength() throws {
        let request = try #require(HTTPRequest(raw: raw("POST /command HTTP/1.1\r\n\r\nignored")))
        #expect(request.body.isEmpty)
    }

    @Test("Malformed request lines are rejected")
    func malformedRequestLine() {
        #expect(HTTPRequest(raw: raw("NONSENSE\r\n\r\n")) == nil)
    }

    @Test("The method is normalised to upper case")
    func methodNormalised() throws {
        let request = try #require(HTTPRequest(raw: raw("get / HTTP/1.1\r\n\r\n")))
        #expect(request.method == "GET")
    }
}
