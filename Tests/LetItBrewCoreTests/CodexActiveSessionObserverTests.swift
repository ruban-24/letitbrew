import Foundation
import Testing
@testable import LetItBrewCore

private let activeFixtureNow = Date(timeIntervalSince1970: 1_786_492_800)
private let activeFixtureCWD = "/work/letitbrew"

private func activeSessionTestHome() throws -> URL {
    let home = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("letitbrew-codex-active-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func activeSessionRolloutURL(home: URL, sessionID: String) throws -> URL {
    let directory = home
        .appendingPathComponent(".codex/sessions/2026/08/12", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(
        "rollout-2026-08-12T00-00-00-\(sessionID).jsonl"
    )
}

private func writeActiveSessionLines(_ lines: [String], to url: URL) throws {
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
}

private func activeIdleSession(
    id: String,
    edge: Date,
    eventObservedAt: TimeInterval?
) -> SessionRecord {
    SessionRecord(
        id: id,
        tool: "codex",
        state: .idle,
        detail: nil,
        cwd: "/work/old",
        pid: 77,
        updatedAt: edge,
        lastEvent: "Stop",
        startedAt: edge.addingTimeInterval(-20),
        accumulatedWorkingTime: 20,
        stateChangedAt: edge,
        stateTransitionID: "hook-stop",
        transcriptPath: nil,
        eventObservedAt: eventObservedAt
    )
}

private func activeSessionID(_ index: Int) -> String {
    String(format: "00000000-0000-0000-0000-%012d", index)
}

@discardableResult
private func writeActiveRollout(
    home: URL,
    id: String,
    cwd: String = activeFixtureCWD,
    modifiedAt: Date
) throws -> URL {
    let url = try activeSessionRolloutURL(home: home, sessionID: id)
    try writeActiveSessionLines([
        #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"#,
        #"{"timestamp":"2026-08-12T00:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#,
    ], to: url)
    try FileManager.default.setAttributes(
        [.modificationDate: modifiedAt],
        ofItemAtPath: url.path
    )
    return url
}

private func observedActiveSessions(fileCount: Int) async throws -> [SessionRecord] {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let oldestModification = activeFixtureNow.addingTimeInterval(-3_600)
    for index in 0..<fileCount {
        try writeActiveRollout(
            home: home,
            id: activeSessionID(index),
            modifiedAt: oldestModification.addingTimeInterval(TimeInterval(index))
        )
    }
    let observer = CodexActiveSessionObserver(
        homeDirectory: home,
        now: { activeFixtureNow }
    )
    return await observer.applyingFallback(to: [])
}

@Test func descriptorBoundReaderOpensAndReadsARegularRolloutUnderSessionsRoot() throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "01010101-1111-2222-3333-010101010101"
    let url = try writeActiveRollout(
        home: home,
        id: id,
        modifiedAt: activeFixtureNow.addingTimeInterval(-30)
    )
    let root = home.appendingPathComponent(".codex/sessions", isDirectory: true)

    let file = try #require(CodexRolloutFile(sessionsRoot: root, candidate: url))

    #expect(file.url == url)
    #expect(file.snapshot.size > 0)
    #expect(file.read(from: 0, upToCount: 1)?.first == UInt8(ascii: "{"))
}

@Test func discoversAnActiveCodexRolloutThatNeverEmittedHooks() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "11111111-2222-3333-4444-555555555555"
    let url = try activeSessionRolloutURL(home: home, sessionID: id)
    let lines = [
        #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"11111111-2222-3333-4444-555555555555","cwd":"/work/letitbrew"}}"#,
        #"{"timestamp":"2026-08-12T00:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#,
    ]
    try writeActiveSessionLines(lines, to: url)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:06Z"))
    let observer = CodexActiveSessionObserver(
        homeDirectory: home,
        now: { now }
    )

    let result = await observer.applyingFallback(to: [])
    let session = try #require(result.first)

    #expect(result.count == 1)
    #expect(session.id == id)
    #expect(session.tool == "codex")
    #expect(session.cwd == "/work/letitbrew")
    #expect(session.state == .working)
    #expect(session.lastEvent == "CodexTaskStarted")
    #expect(session.transcriptPath.map {
        URL(fileURLWithPath: $0).resolvingSymlinksInPath()
    } == url.resolvingSymlinksInPath())
    #expect(session.activeWorkingTime(at: now) == 5)
}

@Test func completedCodexRolloutIsNotSynthesizedAsActive() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let url = try activeSessionRolloutURL(home: home, sessionID: id)
    try writeActiveSessionLines([
        #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/work/letitbrew"}}"#,
        #"{"timestamp":"2026-08-12T00:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"timestamp":"2026-08-12T00:00:04Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
    ], to: url)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:06Z"))
    let observer = CodexActiveSessionObserver(homeDirectory: home, now: { now })

    #expect(await observer.applyingFallback(to: []).isEmpty)
}

@Test func structuralTaskStartOverridesAnOlderIdleHookSnapshot() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "99999999-8888-7777-6666-555555555555"
    let url = try activeSessionRolloutURL(home: home, sessionID: id)
    try writeActiveSessionLines([
        #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"99999999-8888-7777-6666-555555555555","cwd":"/work/letitbrew"}}"#,
        #"{"timestamp":"2026-08-12T00:00:03Z","type":"event_msg","payload":{"type":"task_started"}}"#,
    ], to: url)
    let idleAt = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:01Z"))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:06Z"))
    let idle = SessionRecord(
        id: id,
        tool: "codex",
        state: .idle,
        detail: nil,
        cwd: "/work/letitbrew",
        pid: 77,
        updatedAt: idleAt,
        lastEvent: "Stop",
        startedAt: idleAt.addingTimeInterval(-20),
        accumulatedWorkingTime: 20,
        eventObservedAt: idleAt.timeIntervalSince1970
    )
    let observer = CodexActiveSessionObserver(homeDirectory: home, now: { now })

    let result = await observer.applyingFallback(to: [idle])
    let session = try #require(result.first)

    #expect(session.state == .working)
    #expect(session.lastEvent == "CodexTaskStarted")
    #expect(session.accumulatedWorkingTime == 20)
    #expect(session.activeWorkingTime(at: now) == 23)
}

@Test func newerStructuralStartAdvancesWorkingWatermarkBeforeTerminalFallback() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "98989898-8787-7676-6565-545454545454"
    let url = try activeSessionRolloutURL(home: home, sessionID: id)
    try writeActiveSessionLines([
        #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/refreshed"}}"#,
        #"{"timestamp":"2026-08-12T00:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        #"{"timestamp":"2026-08-12T00:00:10Z","type":"event_msg","payload":{"type":"task_started"}}"#,
    ], to: url)
    let t0 = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:00Z"))
    let t10 = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:10Z"))
    let original = SessionRecord(
        id: id,
        tool: "codex",
        state: .working,
        detail: "hook-command",
        cwd: "/work/original",
        pid: 77,
        updatedAt: t0,
        lastEvent: "PreToolUse",
        startedAt: t0.addingTimeInterval(-60),
        accumulatedWorkingTime: 7,
        stateChangedAt: t0,
        stateTransitionID: "hook-working",
        transcriptPath: nil,
        eventObservedAt: t0.timeIntervalSince1970
    )
    let activeObserver = CodexActiveSessionObserver(homeDirectory: home, now: { activeFixtureNow })
    let terminalObserver = CodexTerminalSessionObserver(homeDirectory: home, now: { activeFixtureNow })
    let later = t10.addingTimeInterval(13)
    let originalActiveTimeAtT10 = original.activeWorkingTime(at: t10)

    let afterActive = try #require(
        await activeObserver.applyingFallback(to: [original]).first
    )
    let final = try #require(
        await terminalObserver.applyingFallback(to: [afterActive]).first
    )

    #expect(afterActive.state == .working)
    #expect(afterActive.updatedAt == t10)
    #expect(afterActive.eventObservedAt == t10.timeIntervalSince1970)
    #expect(afterActive.lastEvent == "PreToolUse")
    #expect(afterActive.stateChangedAt == t0)
    #expect(afterActive.stateTransitionID == "hook-working")
    #expect(originalActiveTimeAtT10 == 17)
    #expect(afterActive.accumulatedWorkingTime == 17)
    #expect(afterActive.activeWorkingTime(at: t10) == originalActiveTimeAtT10)
    #expect(afterActive.activeWorkingTime(at: later) == original.activeWorkingTime(at: later))
    #expect(afterActive.detail == "hook-command")
    #expect(afterActive.cwd == "/work/refreshed")
    #expect(afterActive.transcriptPath == url.path)
    #expect(final == afterActive)
}

@Test func olderAndEqualStructuralStartsDoNotAdvanceWorkingWatermark() async throws {
    let edge = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:05Z"))
    let updatedAt = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:00Z"))
    for (index, timestamp) in [
        "2026-08-12T00:00:04Z",
        "2026-08-12T00:00:05Z",
    ].enumerated() {
        let home = try activeSessionTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "97979797-8787-7676-6565-54545454545\(index)"
        let url = try activeSessionRolloutURL(home: home, sessionID: id)
        try writeActiveSessionLines([
            #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/refreshed"}}"#,
            #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"task_started"}}"#,
        ], to: url)
        let original = SessionRecord(
            id: id,
            tool: "codex",
            state: .working,
            detail: "hook-command",
            cwd: "/work/original",
            pid: 77,
            updatedAt: updatedAt,
            lastEvent: "PreToolUse",
            startedAt: updatedAt.addingTimeInterval(-60),
            accumulatedWorkingTime: 7,
            stateChangedAt: updatedAt,
            stateTransitionID: "hook-working",
            transcriptPath: nil,
            eventObservedAt: edge.timeIntervalSince1970
        )
        let observer = CodexActiveSessionObserver(homeDirectory: home, now: { activeFixtureNow })

        let result = try #require(await observer.applyingFallback(to: [original]).first)

        #expect(result.updatedAt == updatedAt)
        #expect(result.eventObservedAt == edge.timeIntervalSince1970)
        #expect(result.lastEvent == "PreToolUse")
        #expect(result.stateChangedAt == updatedAt)
        #expect(result.stateTransitionID == "hook-working")
        #expect(result.accumulatedWorkingTime == 7)
        #expect(result.cwd == "/work/refreshed")
        #expect(result.transcriptPath == url.path)
    }
}

@Test func olderStructuralTaskStartRefreshesMetadataWithoutResurrectingIdleHook() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "abababab-1111-2222-3333-444444444444"
    let url = try activeSessionRolloutURL(home: home, sessionID: id)
    try writeActiveSessionLines([
        #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/refreshed"}}"#,
        #"{"timestamp":"2026-08-12T00:00:03Z","type":"event_msg","payload":{"type":"task_started"}}"#,
    ], to: url)
    let edge = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:05Z"))
    let original = activeIdleSession(id: id, edge: edge, eventObservedAt: nil)
    let observer = CodexActiveSessionObserver(homeDirectory: home, now: { activeFixtureNow })

    let result = try #require(await observer.applyingFallback(to: [original]).first)

    #expect(result.state == .idle)
    #expect(result.lastEvent == "Stop")
    #expect(result.updatedAt == edge)
    #expect(result.eventObservedAt == nil)
    #expect(result.cwd == "/work/refreshed")
    #expect(result.transcriptPath == url.path)
}

@Test func equalStructuralTaskStartRefreshesMetadataWithoutResurrectingIdleHook() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "bcbcbcbc-1111-2222-3333-555555555555"
    let url = try activeSessionRolloutURL(home: home, sessionID: id)
    try writeActiveSessionLines([
        #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/refreshed"}}"#,
        #"{"timestamp":"2026-08-12T00:00:05Z","type":"event_msg","payload":{"type":"task_started"}}"#,
    ], to: url)
    let edge = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:05Z"))
    let original = activeIdleSession(
        id: id,
        edge: edge.addingTimeInterval(-30),
        eventObservedAt: edge.timeIntervalSince1970
    )
    let observer = CodexActiveSessionObserver(homeDirectory: home, now: { activeFixtureNow })

    let result = try #require(await observer.applyingFallback(to: [original]).first)

    #expect(result.state == .idle)
    #expect(result.lastEvent == "Stop")
    #expect(result.updatedAt == edge.addingTimeInterval(-30))
    #expect(result.eventObservedAt == edge.timeIntervalSince1970)
    #expect(result.cwd == "/work/refreshed")
    #expect(result.transcriptPath == url.path)
}

@Test func activeLifecycleAtExactOneMiBTailBoundaryIsObserved() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "cdcdcdcd-1111-2222-3333-666666666666"
    let url = try activeSessionRolloutURL(home: home, sessionID: id)
    let metadata = #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/boundary"}}"# + "\n"
    let lifecycle = #"{"timestamp":"2026-08-12T00:00:05Z","type":"event_msg","payload":{"type":"task_started"}}"# + "\n"
    var prefix = Data(metadata.utf8)
    prefix.append(Data(repeating: 0x78, count: 1_048_577 - prefix.count - 1))
    prefix.append(0x0A)
    var tail = Data(lifecycle.utf8)
    tail.append(Data(repeating: 0x79, count: 1_048_576 - tail.count - 1))
    tail.append(0x0A)
    prefix.append(tail)
    try prefix.write(to: url)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:06Z"))
    let observer = CodexActiveSessionObserver(homeDirectory: home, now: { now })

    let result = await observer.applyingFallback(to: [])

    #expect(result.first?.id == id)
    #expect(result.first?.state == .working)
}

@Test func incompleteActiveLifecycleLineIsIgnoredUntilItsNewlineArrives() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "cececece-1111-2222-3333-676767676767"
    let url = try activeSessionRolloutURL(home: home, sessionID: id)
    let metadata = #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/incomplete"}}"#
    let lifecycle = #"{"timestamp":"2026-08-12T00:00:05Z","type":"event_msg","payload":{"type":"task_started"}}"#
    try Data((metadata + "\n" + lifecycle).utf8).write(to: url)
    let observer = CodexActiveSessionObserver(homeDirectory: home, now: { activeFixtureNow })

    #expect(await observer.applyingFallback(to: []).isEmpty)

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n".utf8))
    try handle.close()

    #expect(await observer.applyingFallback(to: []).first?.id == id)
}

@Test func laterTerminalLineWinsEqualTimestampAcrossOverlappingActiveScans() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "dededede-1111-2222-3333-777777777777"
    let url = try activeSessionRolloutURL(home: home, sessionID: id)
    let metadata = #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/tie"}}"#
    let start = #"{"timestamp":"2026-08-12T00:00:05Z","type":"event_msg","payload":{"type":"task_started"}}"#
    let terminal = #"{"timestamp":"2026-08-12T00:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}"#
    var data = Data((metadata + "\n" + start + "\n").utf8)
    data.append(Data(repeating: 0x78, count: 1_048_400))
    data.append(Data(("\n" + terminal + "\n").utf8))
    try data.write(to: url)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-12T00:00:06Z"))
    let observer = CodexActiveSessionObserver(homeDirectory: home, now: { now })

    #expect(await observer.applyingFallback(to: []).isEmpty)
}

@Test func samePathActiveRolloutReplacementWithPreservedSizeAndMTimeIsRescanned() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "efefefef-1111-2222-3333-888888888888"
    let url = try activeSessionRolloutURL(home: home, sessionID: id)
    let metadata = #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/replaced"}}"#
    let active = #"{"timestamp":"2026-08-12T00:00:05Z","type":"event_msg","payload":{"type":"task_started"}}"#
    let ended = #"{"timestamp":"2026-08-12T00:00:05Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#
    #expect(active.utf8.count == ended.utf8.count)
    let modifiedAt = activeFixtureNow.addingTimeInterval(-30)
    try writeActiveSessionLines([metadata, active], to: url)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    let observer = CodexActiveSessionObserver(homeDirectory: home, now: { activeFixtureNow })
    #expect(await observer.applyingFallback(to: []).first?.state == .working)

    let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.jsonl")
    try writeActiveSessionLines([metadata, ended], to: replacement)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: replacement.path)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)

    #expect(await observer.applyingFallback(to: []).isEmpty)
}

@Test func finalSymlinkedActiveRolloutIsRejected() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "f1f1f1f1-1111-2222-3333-999999999999"
    let candidate = try activeSessionRolloutURL(home: home, sessionID: id)
    let outside = home.appendingPathComponent("outside-active.jsonl")
    try writeActiveSessionLines([
        #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/outside"}}"#,
        #"{"timestamp":"2026-08-12T00:00:05Z","type":"event_msg","payload":{"type":"task_started"}}"#,
    ], to: outside)
    try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: outside)
    let observer = CodexActiveSessionObserver(homeDirectory: home, now: { activeFixtureNow })

    #expect(await observer.applyingFallback(to: []).isEmpty)
}

@Test func candidateReplacedByFinalSymlinkImmediatelyBeforeDescriptorOpenIsRejected() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "f2f2f2f2-1111-2222-3333-101010101010"
    let candidate = try writeActiveRollout(
        home: home,
        id: id,
        modifiedAt: activeFixtureNow.addingTimeInterval(-30)
    )
    let outside = home.appendingPathComponent("outside-active.jsonl")
    try writeActiveSessionLines([
        #"{"timestamp":"2026-08-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/outside"}}"#,
        #"{"timestamp":"2026-08-12T00:00:05Z","type":"event_msg","payload":{"type":"task_started"}}"#,
    ], to: outside)
    let observer = CodexActiveSessionObserver(
        homeDirectory: home,
        now: { activeFixtureNow },
        beforeOpeningRollout: { url in
            guard url == candidate else { return }
            try? FileManager.default.removeItem(at: candidate)
            try? FileManager.default.createSymbolicLink(
                at: candidate,
                withDestinationURL: outside
            )
        }
    )

    #expect(await observer.applyingFallback(to: []).isEmpty)
}

@Test func observesAll127NewestCandidateFiles() async throws {
    let sessions = try await observedActiveSessions(fileCount: 127)

    #expect(sessions.count == 127)
    #expect(Set(sessions.map(\.id)) == Set((0..<127).map(activeSessionID)))
}

@Test func observesAll128NewestCandidateFiles() async throws {
    let sessions = try await observedActiveSessions(fileCount: 128)

    #expect(sessions.count == 128)
    #expect(Set(sessions.map(\.id)) == Set((0..<128).map(activeSessionID)))
}

@Test func observesOnlyThe128NewestOf129CandidateFiles() async throws {
    let sessions = try await observedActiveSessions(fileCount: 129)
    let observedIDs = Set(sessions.map(\.id))

    #expect(sessions.count == 128)
    #expect(observedIDs == Set((1..<129).map(activeSessionID)))
    #expect(!observedIDs.contains(activeSessionID(0)))
}

@Test func oneHundredActiveRolloutsKeepExactIndependentIdentitiesInOneCWD() async throws {
    let sessions = try await observedActiveSessions(fileCount: 100)
    let expectedIDs = Set((0..<100).map(activeSessionID))

    #expect(sessions.count == 100)
    #expect(Set(sessions.map(\.id)) == expectedIDs)
    #expect(Set(sessions.map(\.cwd)) == Set([activeFixtureCWD]))
    #expect(Dictionary(grouping: sessions, by: \.cwd)[activeFixtureCWD]?.count == 100)
}

@Test func sameCWDParentContinuationAndSubagentRolloutsRemainIndependent() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let ids = [
        "10000000-0000-0000-0000-000000000001",
        "20000000-0000-0000-0000-000000000002",
        "30000000-0000-0000-0000-000000000003",
    ]
    for (index, id) in ids.enumerated() {
        try writeActiveRollout(
            home: home,
            id: id,
            cwd: "/work/shared-repository",
            modifiedAt: activeFixtureNow.addingTimeInterval(TimeInterval(index - 60))
        )
    }
    let observer = CodexActiveSessionObserver(
        homeDirectory: home,
        now: { activeFixtureNow }
    )

    let sessions = await observer.applyingFallback(to: [])

    #expect(sessions.count == 3)
    #expect(Set(sessions.map(\.id)) == Set(ids))
    #expect(Set(sessions.map(\.cwd)) == Set(["/work/shared-repository"]))
    #expect(sessions.allSatisfy { $0.state == .working })
}

@Test func rolloutAtTheTwelveHourAgeBoundaryIsExcluded() async throws {
    let home = try activeSessionTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let includedID = "40000000-0000-0000-0000-000000000004"
    let excludedID = "50000000-0000-0000-0000-000000000005"
    try writeActiveRollout(
        home: home,
        id: includedID,
        modifiedAt: activeFixtureNow.addingTimeInterval(-(12 * 3_600) + 1)
    )
    try writeActiveRollout(
        home: home,
        id: excludedID,
        modifiedAt: activeFixtureNow.addingTimeInterval(-(12 * 3_600))
    )
    let observer = CodexActiveSessionObserver(
        homeDirectory: home,
        now: { activeFixtureNow }
    )

    let sessions = await observer.applyingFallback(to: [])

    #expect(sessions.map(\.id) == [includedID])
    #expect(!sessions.map(\.id).contains(excludedID))
}
