import Testing
import Foundation
@testable import LetItBrewCore

@Test func sessionsUseTheCanonicalLetItBrewApplicationSupportDirectory() {
    #expect(SessionStorage.applicationSupportDirectory.lastPathComponent == "LetItBrew")
    #expect(SessionStorage.sessionsDirectory.deletingLastPathComponent()
            == SessionStorage.applicationSupportDirectory)
}

@Test func canonicalUserDataDirectoryIsDerivedFromAResolvedApplicationSupportBase() {
    let base = URL(
        fileURLWithPath: "/Users/example/Library/Application Support",
        isDirectory: true
    )

    #expect(
        SessionStorage.applicationSupportDirectory(in: base)
            == base.appendingPathComponent("LetItBrew", isDirectory: true)
    )
}

@Test func recentPreToolUseIsPresentedAsAnActiveToolCall() {
    let now = Date(timeIntervalSince1970: 1_000)
    let record = SessionRecord(
        id: "active", tool: "claude", state: .working, detail: "running-command",
        cwd: "/tmp", pid: 1, updatedAt: now.addingTimeInterval(-30), lastEvent: "PreToolUse"
    )

    #expect(record.workingActivity(at: now, silentAfter: 120) == .activeToolCall)
}

@Test func oldPreToolUseIsPresentedAsSilentWithoutReleasingTheSession() {
    let now = Date(timeIntervalSince1970: 1_000)
    let record = SessionRecord(
        id: "stuck", tool: "codex", state: .working, detail: "running-command",
        cwd: "/tmp", pid: 1, updatedAt: now.addingTimeInterval(-1_200), lastEvent: "PreToolUse"
    )

    #expect(record.workingActivity(at: now, silentAfter: 120) == .silent)
    #expect(record.state == .working)
}

@Test func workingWithoutAToolEventIsSilentEvenWhenRecent() {
    let now = Date(timeIntervalSince1970: 1_000)
    let record = SessionRecord(
        id: "thinking", tool: "claude", state: .working, detail: nil,
        cwd: "/tmp", pid: 1, updatedAt: now.addingTimeInterval(-5), lastEvent: "UserPromptSubmit"
    )

    #expect(record.workingActivity(at: now, silentAfter: 120) == .silent)
}

@Test func idleSessionsHaveNoWorkingActivity() {
    let now = Date(timeIntervalSince1970: 1_000)
    let record = SessionRecord(
        id: "idle", tool: "codex", state: .idle, detail: nil,
        cwd: "/tmp", pid: 1, updatedAt: now, lastEvent: "Stop"
    )

    #expect(record.workingActivity(at: now, silentAfter: 120) == nil)
}

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func roundTripsARecord() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    let record = SessionRecord(
        id: "abc-123", tool: "claude", state: .working, detail: "running-command",
        cwd: "/Users/me/code/letitbrew", pid: 4821, updatedAt: Date(timeIntervalSince1970: 1_000_000),
        startedAt: Date(timeIntervalSince1970: 998_000),
        stateChangedAt: Date(timeIntervalSince1970: 999_000), stateTransitionID: "edge-1",
        eventObservedAt: 1_000_000.625
    )
    try storage.write(record)

    let loaded = storage.loadAll()
    #expect(loaded.count == 1)
    #expect(loaded.first == record)
}

@Test func oldRecordWithTranscriptPathStillDecodesAsACompatibilityFixture() throws {
    let json = #"{"id":"legacy","tool":"codex","state":"working","cwd":"/tmp","updated_at":"1970-01-01T00:16:40Z","transcript_path":"/Users/me/.codex/sessions/legacy.jsonl"}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let record = try decoder.decode(SessionRecord.self, from: Data(json.utf8))

    #expect(record.id == "legacy")
    #expect(record.tool == "codex")
}

@Test func canonicalUpdatedAtRejectsNullOrWrongTypeEvenWithLegacyTimestamp() {
    let invalidCanonicalValues = ["null", #""not-a-date""#]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    for canonical in invalidCanonicalValues {
        let json = #"{"id":"legacy","tool":"claude","state":"working","cwd":"/tmp","updated_at":\#(canonical),"updatedAt":1000}"#
        #expect(throws: DecodingError.self) {
            try decoder.decode(SessionRecord.self, from: Data(json.utf8))
        }
    }
}

@Test func canonicalUpdatedAtWinsWhenBothTimestampKeysAreValid() throws {
    let json = #"{"id":"legacy","tool":"claude","state":"working","cwd":"/tmp","updated_at":2000,"updatedAt":1000}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let record = try decoder.decode(SessionRecord.self, from: Data(json.utf8))

    #expect(record.updatedAt == Date(timeIntervalSince1970: 2_000))
}

@Test func legacyUpdatedAtAloneStillDecodes() throws {
    let json = #"{"id":"legacy","tool":"claude","state":"working","cwd":"/tmp","updatedAt":1000}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let record = try decoder.decode(SessionRecord.self, from: Data(json.utf8))

    #expect(record.updatedAt == Date(timeIntervalSince1970: 1_000))
}

@Test func oldRecordWithoutStartedAtDecodesAndUsesItsEarliestKnownTimestamp() throws {
    let json = #"{"id":"legacy","tool":"codex","state":"working","cwd":"/tmp","updated_at":"1970-01-01T00:20:00Z","state_changed_at":"1970-01-01T00:16:40Z"}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let record = try decoder.decode(SessionRecord.self, from: Data(json.utf8))

    #expect(record.startedAt == nil)
    #expect(record.effectiveStartedAt == Date(timeIntervalSince1970: 1_000))
}

@Test func explicitStartedAtWinsOverLaterActivityAndStateTimestamps() {
    let record = SessionRecord(
        id: "session", tool: "claude", state: .idle, detail: nil,
        cwd: "/tmp", pid: 1, updatedAt: Date(timeIntervalSince1970: 1_200),
        startedAt: Date(timeIntervalSince1970: 800),
        stateChangedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(record.effectiveStartedAt == Date(timeIntervalSince1970: 800))
}

@Test func hookUpdatesPreserveTheEarliestKnownSessionStart() {
    let previous = SessionRecord(
        id: "session", tool: "codex", state: .working, detail: nil,
        cwd: "/tmp", pid: 1, updatedAt: Date(timeIntervalSince1970: 1_100),
        startedAt: Date(timeIntervalSince1970: 800),
        stateChangedAt: Date(timeIntervalSince1970: 1_000)
    )
    let now = Date(timeIntervalSince1970: 1_200)

    #expect(SessionTimeline.startedAt(previous: previous, now: now)
            == Date(timeIntervalSince1970: 800))
    #expect(SessionTimeline.startedAt(previous: nil, now: now) == now)
}

@Test func hookUpdatesAccumulateOnlyThePreviousWorkingInterval() {
    let working = SessionRecord(
        id: "working", tool: "codex", state: .working, detail: nil,
        cwd: "/tmp", pid: 1, updatedAt: Date(timeIntervalSince1970: 1_000),
        accumulatedWorkingTime: 120
    )
    let idle = SessionRecord(
        id: "idle", tool: "claude", state: .idle, detail: nil,
        cwd: "/tmp", pid: 2, updatedAt: Date(timeIntervalSince1970: 1_000),
        accumulatedWorkingTime: 120
    )
    let now = Date(timeIntervalSince1970: 1_030)

    #expect(SessionTimeline.accumulatedWorkingTime(previous: working, now: now) == 150)
    #expect(SessionTimeline.accumulatedWorkingTime(previous: idle, now: now) == 120)
    #expect(SessionTimeline.accumulatedWorkingTime(previous: nil, now: now) == 0)
}

@Test func displayedActiveWorkingTimeTicksOnlyWhileTheSessionIsWorking() {
    let working = SessionRecord(
        id: "working", tool: "codex", state: .working, detail: nil,
        cwd: "/tmp", pid: 1, updatedAt: Date(timeIntervalSince1970: 1_000),
        accumulatedWorkingTime: 120
    )
    let idle = SessionRecord(
        id: "idle", tool: "claude", state: .idle, detail: nil,
        cwd: "/tmp", pid: 2, updatedAt: Date(timeIntervalSince1970: 1_000),
        accumulatedWorkingTime: 120
    )
    let now = Date(timeIntervalSince1970: 1_030)

    #expect(working.activeWorkingTime(at: now) == 150)
    #expect(idle.activeWorkingTime(at: now) == 120)
}

@Test func loadsOneRecordByExactUnsanitizedID() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let record = SessionRecord(id: "../edge", tool: "codex", state: .idle, detail: nil,
                               cwd: "/tmp", pid: nil, updatedAt: Date(timeIntervalSince1970: 1_000))
    try storage.write(record)

    #expect(storage.load(id: "../edge") == record)
    #expect(storage.load(id: "___edge") == nil)
}

@Test func repeatedStateRetainsItsTransitionIdentity() {
    let firstTime = Date(timeIntervalSince1970: 1_000)
    let previous = SessionRecord(
        id: "session", tool: "codex", state: .idle, detail: nil,
        cwd: "/tmp", pid: 1, updatedAt: firstTime,
        stateChangedAt: firstTime, stateTransitionID: "idle-edge"
    )

    let transition = SessionStateTransition.resolve(
        previous: previous,
        newState: .idle,
        now: firstTime.addingTimeInterval(30),
        makeID: { "must-not-be-used" }
    )

    #expect(transition.changedAt == firstTime)
    #expect(transition.id == "idle-edge")
}

@Test func leavingAndReenteringCreatesANewTransitionIdentity() {
    let previous = SessionRecord(
        id: "session", tool: "codex", state: .working, detail: nil,
        cwd: "/tmp", pid: 1, updatedAt: Date(timeIntervalSince1970: 1_000),
        stateChangedAt: Date(timeIntervalSince1970: 900), stateTransitionID: "working-edge"
    )

    let transition = SessionStateTransition.resolve(
        previous: previous,
        newState: .idle,
        now: Date(timeIntervalSince1970: 1_100),
        makeID: { "new-idle-edge" }
    )

    #expect(transition.changedAt == Date(timeIntervalSince1970: 1_100))
    #expect(transition.id == "new-idle-edge")
}

@Test func oldRecordWithoutTransitionMetadataIsUpgradedWithoutMovingItsEdgeTime() {
    let previous = SessionRecord(
        id: "legacy", tool: "claude", state: .idle, detail: nil,
        cwd: "/tmp", pid: nil, updatedAt: Date(timeIntervalSince1970: 1_000)
    )

    let transition = SessionStateTransition.resolve(
        previous: previous,
        newState: .idle,
        now: Date(timeIntervalSince1970: 1_200),
        makeID: { "upgraded-edge" }
    )

    #expect(transition.changedAt == previous.updatedAt)
    #expect(transition.id == "upgraded-edge")
}

@Test func deletesARecord() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    try storage.write(SessionRecord(id: "gone", tool: "claude", state: .idle, detail: nil,
                                    cwd: "/tmp", pid: nil, updatedAt: Date()))
    #expect(storage.loadAll().count == 1)
    storage.delete(id: "gone")
    #expect(storage.loadAll().isEmpty)
}

@Test func skipsCorruptFilesInsteadOfFailing() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    try storage.write(SessionRecord(id: "good", tool: "claude", state: .idle, detail: nil,
                                    cwd: "/tmp", pid: nil, updatedAt: Date()))
    try Data("not json".utf8).write(to: directory.appendingPathComponent("bad.json"))

    let loaded = storage.loadAll()
    #expect(loaded.count == 1)
    #expect(loaded.first?.id == "good")
}

@Test func loadAllSkipsUnsupportedLegacyStateWithoutMigratingOtherRecords() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let valid = SessionRecord(
        id: "working", tool: "claude", state: .working, detail: nil,
        cwd: "/tmp", pid: nil, updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    try storage.write(valid)
    let legacy = #"{"id":"waiting","tool":"codex","state":"waiting","cwd":"/tmp","updated_at":"1970-01-01T00:16:40Z"}"#
    try Data(legacy.utf8).write(
        to: directory.appendingPathComponent(SessionStorage.safeFilename(for: "waiting"))
    )

    #expect(storage.loadAll() == [valid])
}

@Test func loadingAMissingDirectoryIsEmptyNotAnError() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-absent-\(UUID().uuidString)", isDirectory: true)
    #expect(SessionStorage(directory: directory).loadAll().isEmpty)
}

@Test func sanitizesSessionIdsIntoSafeFilenames() {
    // session_id arrives from an external tool: it is untrusted input and
    // must never escape the sessions directory.
    #expect(SessionStorage.safeFilename(for: "../../etc/passwd")
            == "______etc_passwd-2bef2c0bbbdefdfa.json")
    #expect(SessionStorage.safeFilename(for: "a/b")
            == "a_b-e620c3190468cf61.json")
    #expect(SessionStorage.safeFilename(for: "9f2c-4d1a") == "9f2c-4d1a.json")
}

@Test func traversalIdStaysInsideTheDirectory() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    try storage.write(SessionRecord(id: "../escape", tool: "claude", state: .idle, detail: nil,
                                    cwd: "/tmp", pid: nil, updatedAt: Date()))

    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(contents.count == 1)
    #expect(!FileManager.default.fileExists(
        atPath: directory.deletingLastPathComponent().appendingPathComponent("escape.json").path))
}

@Test func repoNameIsTheLastPathComponent() {
    let record = SessionRecord(id: "x", tool: "claude", state: .idle, detail: nil,
                               cwd: "/Users/me/code/letitbrew", pid: nil, updatedAt: Date())
    #expect(record.repoName == "letitbrew")
}

@Test func repositoryIDUsesTheFullStandardizedWorkingDirectory() {
    let record = SessionRecord(id: "x", tool: "codex", state: .working, detail: nil,
                               cwd: "/Users/me/code/../code/letitbrew/.",
                               pid: nil, updatedAt: Date())

    #expect(record.repositoryID == "/Users/me/code/letitbrew")
}

@Test func encodesOnlyTheCanonicalUpdatedAtKey() throws {
    // A round-trip test alone would pass even if CodingKeys used the wrong
    // string on both the encode and decode side. Assert the wire format
    // directly: `updated_at` is a contract other tools (the hook CLI, the
    // watcher, potentially other-language tooling) depend on literally.
    let record = SessionRecord(id: "x", tool: "claude", state: .idle, detail: nil,
                               cwd: "/tmp", pid: nil, updatedAt: Date(timeIntervalSince1970: 0))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(record)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["updated_at"] != nil)
    #expect(json?["updatedAt"] == nil)
    #expect(json?["started_at"] == nil)
    #expect(json?["state_changed_at"] == nil)
    #expect(json?["state_transition_id"] == nil)
    #expect(json?["event_observed_at"] == nil)
}

// Table-driven: session_id is untrusted input from another tool. Each row
// is a distinct way a hostile or merely weird id could try to produce an
// unsafe, colliding, or filesystem-meaningful filename.
@Test func safeFilenameNeutralizesAdversarialIds() {
    let cases: [(id: String, expected: String, why: String)] = [
        ("", "unnamed-cbf29ce484222325.json", "empty id uses a digested unnamed sentinel"),
        (".", "_-af63a34c86018bb1.json", "single disallowed char is replaced and disambiguated"),
        ("/etc/passwd", "_etc_passwd-8cd5faba57335497.json", "absolute path is defanged and disambiguated"),
        ("abc\u{0}def", "abc_def-e34a003877932188.json", "embedded NUL is replaced and disambiguated"),
        ("\u{0430}dmin", "_dmin-33ca5f6608953cfd.json", "Unicode homoglyph is neutralized and disambiguated"),
    ]
    for testCase in cases {
        let filename = SessionStorage.safeFilename(for: testCase.id)
        #expect(filename == testCase.expected, Comment(rawValue: testCase.why))
    }
}

@Test func distinctUnsafeIDsRoundTripAndDeleteIndependently() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let first = SessionRecord(
        id: "a/b", tool: "claude", state: .working, detail: nil,
        cwd: "/tmp/one", pid: nil, updatedAt: Date(timeIntervalSince1970: 100)
    )
    let second = SessionRecord(
        id: "a?b", tool: "codex", state: .idle, detail: nil,
        cwd: "/tmp/two", pid: nil, updatedAt: Date(timeIntervalSince1970: 200)
    )

    #expect(SessionStorage.safeFilename(for: first.id) != SessionStorage.safeFilename(for: second.id))
    try storage.write(first)
    try storage.write(second)
    #expect(storage.load(id: first.id) == first)
    #expect(storage.load(id: second.id) == second)
    #expect(Set(storage.loadAll().map(\.id)) == [first.id, second.id])

    storage.delete(id: first.id)
    #expect(storage.load(id: first.id) == nil)
    #expect(storage.load(id: second.id) == second)
}

@Test func sharedPrefixIdsBeyondTheBoundGetDifferentFilenames() {
    // Two ids that agree on their first 128 characters and only diverge
    // after that must not truncate down to the same file: one write must
    // never silently overwrite or delete the other's session.
    let idA = String(repeating: "a", count: 128) + "X"
    let idB = String(repeating: "a", count: 128) + "Y"

    let filenameA = SessionStorage.safeFilename(for: idA)
    let filenameB = SessionStorage.safeFilename(for: idB)

    #expect(filenameA != filenameB)
    #expect(filenameA.hasSuffix(".json"))
    #expect(filenameB.hasSuffix(".json"))
    #expect(filenameA.count <= 128 + ".json".count)
    #expect(filenameB.count <= 128 + ".json".count)
}

@Test func hostileDeleteCannotTouchAnUnrelatedSession() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    try storage.write(SessionRecord(id: "victim", tool: "claude", state: .idle, detail: nil,
                                    cwd: "/tmp", pid: nil, updatedAt: Date()))

    storage.delete(id: "../victim")

    let loaded = storage.loadAll()
    #expect(loaded.count == 1)
    #expect(loaded.first?.id == "victim")
}

@Test func loadAllSkipsAFileWhoseNameDoesNotMatchItsRecordId() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    try storage.write(SessionRecord(id: "legit", tool: "claude", state: .idle, detail: nil,
                                    cwd: "/tmp", pid: nil, updatedAt: Date()))

    // Simulate a tampered or hand-planted file: valid JSON, valid grammar,
    // but its embedded id sanitizes to a different filename than the one
    // it's sitting under.
    let spoofed = SessionRecord(id: "not-spoof", tool: "claude", state: .idle, detail: nil,
                                cwd: "/tmp", pid: nil, updatedAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(spoofed).write(to: directory.appendingPathComponent("spoof.json"))

    let loaded = storage.loadAll()
    #expect(loaded.count == 1)
    #expect(loaded.first?.id == "legit")
}

@Test func loadAllSkipsSymlinksInsteadOfFollowingThem() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    // A real, validly-named record living outside the sessions directory.
    let outside = tempDirectory()
    defer { try? FileManager.default.removeItem(at: outside) }
    let target = SessionRecord(id: "sneaky", tool: "claude", state: .idle, detail: nil,
                               cwd: "/tmp", pid: nil, updatedAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let targetURL = outside.appendingPathComponent("sneaky.json")
    try encoder.encode(target).write(to: targetURL)

    // A symlink inside the sessions directory, named exactly as
    // safeFilename would generate for "sneaky", pointing at that file.
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent(SessionStorage.safeFilename(for: "sneaky")),
        withDestinationURL: targetURL)

    #expect(storage.loadAll().isEmpty)
}
