import Darwin
import Dispatch
import Foundation
import Testing
@testable import LetItBrewCore

@Test func staleSameSessionMutationCannotOverwriteNewerStop() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let payload = HookPayload(sessionId: "same", cwd: "/work/app")
    let id = hookUpdaterID("same")

    try HookSessionUpdater.apply(
        event: "Stop", payload: payload, agent: .codex, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )
    try HookSessionUpdater.apply(
        event: "PreToolUse", payload: payload, agent: .codex, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )

    #expect(storage.load(id: id)?.state == .idle)
    #expect(storage.load(id: id)?.eventObservedAt == 200)
}

@Test func lateCopilotSessionStartCannotDowngradeWorkingPrompt() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let payload = HookPayload(sessionId: "copilot-late-start", cwd: "/work/app")
    let id = hookUpdaterID("copilot-late-start", agent: .copilot)

    try HookSessionUpdater.apply(
        event: "UserPromptSubmit", payload: payload, agent: .copilot, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    try HookSessionUpdater.apply(
        event: "SessionStart", payload: payload, agent: .copilot, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )

    let record = try #require(storage.load(id: id))
    #expect(record.state == .working)
    #expect(record.lastEvent == "UserPromptSubmit")
    #expect(record.eventObservedAt == 100)
}

@Test func lateSessionStartRetainsClaudeAndCodexProductionBehavior() throws {
    for agent in [AgentID.claude, .codex] {
        let directory = hookUpdaterTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SessionStorage(directory: directory)
        let sessionID = "late-start-\(agent.rawValue)"
        let payload = HookPayload(sessionId: sessionID, cwd: "/work/app", source: "startup")
        let id = hookUpdaterID(sessionID, agent: agent)

        try HookSessionUpdater.apply(
            event: "UserPromptSubmit", payload: payload, agent: agent, agentPID: nil,
            observedAt: Date(timeIntervalSince1970: 100), storage: storage
        )
        try HookSessionUpdater.apply(
            event: "SessionStart", payload: payload, agent: agent, agentPID: nil,
            observedAt: Date(timeIntervalSince1970: 200), storage: storage
        )

        let record = try #require(storage.load(id: id))
        #expect(record.state == .idle)
        #expect(record.lastEvent == "SessionStart")
        #expect(record.eventObservedAt == 200)
    }
}

@Test func copilotPermissionAndQuestionWaitsAreWaiting() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let payload = HookPayload(sessionId: "copilot-input", cwd: "/work/app")
    let id = hookUpdaterID("copilot-input", agent: .copilot)

    try HookSessionUpdater.apply(
        event: "UserPromptSubmit", payload: payload, agent: .copilot, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    // PermissionRequest runs before allow rules decide, so it keeps Working;
    // the prompt Copilot actually shows is the wait.
    try HookSessionUpdater.apply(
        event: "PermissionRequest", payload: payload, agent: .copilot, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 150), storage: storage
    )
    #expect(storage.load(id: id)?.state == .working)
    try HookSessionUpdater.apply(
        event: "Notification",
        payload: HookPayload(
            sessionId: "copilot-input", cwd: "/work/app", notificationType: "permission_prompt"
        ),
        agent: .copilot, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )
    #expect(storage.load(id: id)?.state == .waiting)
    #expect(storage.load(id: id)?.detail == SessionWaitDetail.approval)

    try HookSessionUpdater.apply(
        event: "PostToolUse", payload: payload, agent: .copilot, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 300), storage: storage
    )
    try HookSessionUpdater.apply(
        event: "PreToolUse",
        payload: HookPayload(
            sessionId: "copilot-input", cwd: "/work/app", toolName: "ask_user"
        ),
        agent: .copilot,
        agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 400),
        storage: storage
    )

    let waiting = try #require(storage.load(id: id))
    #expect(waiting.state == .waiting)
    #expect(waiting.detail == SessionWaitDetail.question)
    #expect(waiting.lastEvent == "PreToolUse")

    try HookSessionUpdater.apply(
        event: "PostToolUse", payload: payload, agent: .copilot, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 500), storage: storage
    )
    #expect(storage.load(id: id)?.state == .working)
}

@Test func openCodeInputRequestAndReplyToggleWaitingAndWorking() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let payload = HookPayload(sessionId: "opencode-input", cwd: "/work/app")
    let id = hookUpdaterID("opencode-input", agent: .opencode)

    try HookSessionUpdater.apply(
        event: "UserPromptSubmit", payload: payload, agent: .opencode, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    try HookSessionUpdater.apply(
        event: "UserInputRequested", payload: payload, agent: .opencode, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )
    #expect(storage.load(id: id)?.state == .waiting)

    try HookSessionUpdater.apply(
        event: "UserInputResolved", payload: payload, agent: .opencode, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 300), storage: storage
    )

    let resumed = try #require(storage.load(id: id))
    #expect(resumed.state == .working)
    #expect(resumed.lastEvent == "UserInputResolved")
    #expect(resumed.eventObservedAt == 300)
}

@Test func staleWorkingEventCannotRecreateSessionAfterNewerEndAcrossStorageInstances() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = HookPayload(sessionId: "ended", cwd: "/work/app")
    let id = hookUpdaterID("ended")

    try HookSessionUpdater.apply(
        event: "UserPromptSubmit",
        payload: payload,
        agent: .codex,
        agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 50),
        storage: SessionStorage(directory: directory)
    )
    try HookSessionUpdater.apply(
        event: "SessionEnd",
        payload: payload,
        agent: .codex,
        agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 200),
        storage: SessionStorage(directory: directory)
    )
    #expect(SessionStorage(directory: directory).load(id: id) == nil)

    // A fresh storage value models another hook process starting after the
    // terminal update completed. Ordering must survive process boundaries.
    try HookSessionUpdater.apply(
        event: "PreToolUse",
        payload: payload,
        agent: .codex,
        agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 100),
        storage: SessionStorage(directory: directory)
    )

    #expect(SessionStorage(directory: directory).load(id: id) == nil)
}

@Test func terminalEventMovesOneDecodableTombstoneOutOfTheSessionScan() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let id = hookUpdaterID("terminal")

    try HookSessionUpdater.apply(
        event: "SessionEnd",
        payload: HookPayload(sessionId: "terminal", cwd: "/work/app"),
        agent: .codex,
        agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 200),
        storage: storage
    )

    let activeURL = hookUpdaterActiveURL(id: id, directory: directory)
    let tombstoneURL = hookUpdaterTombstoneURL(id: id, directory: directory)
    #expect(!FileManager.default.fileExists(atPath: activeURL.path))
    let data = try Data(contentsOf: tombstoneURL)
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["kind"] as? String == "terminal")
    #expect(object["id"] as? String == id)
    #expect(object["observed_at"] as? Double == 200)
    #expect(storage.load(id: id) == nil)
    #expect(storage.loadAll().isEmpty)

    var status = stat()
    #expect(lstat(tombstoneURL.path, &status) == 0)
    #expect(status.st_mode & S_IFMT == S_IFREG)
    #expect(status.st_mode & 0o777 == 0o600)
}

@Test func largeEndedBatchLeavesNoJSONEntriesInTheScannedSessionDirectory() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    for index in 0..<250 {
        try HookSessionUpdater.apply(
            event: "SessionEnd",
            payload: HookPayload(sessionId: "ended-\(index)", cwd: "/work/app"),
            agent: .codex,
            agentPID: nil,
            observedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
            storage: storage
        )
    }

    let scannedNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(scannedNames.filter { $0.hasSuffix(".json") }.isEmpty)
    #expect(storage.loadAll().isEmpty)
    let hiddenNames = try FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent(".locks", isDirectory: true).path
    )
    #expect(hiddenNames.filter { $0.hasSuffix(".tombstone") }.count == 250)
}

@Test func hiddenTombstonePersistsAcrossFreshStorageAndBlocksStaleWork() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let parentID = "durable-terminal"
    let id = hookUpdaterID(parentID)
    let payload = HookPayload(sessionId: parentID, cwd: "/work/app")

    try HookSessionUpdater.apply(
        event: "SessionEnd", payload: payload, agent: .codex, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 200),
        storage: SessionStorage(directory: directory)
    )

    let tombstoneURL = hookUpdaterTombstoneURL(id: id, directory: directory)
    let committed = try Data(contentsOf: tombstoneURL)
    #expect(!FileManager.default.fileExists(
        atPath: hookUpdaterActiveURL(id: id, directory: directory).path
    ))

    try HookSessionUpdater.apply(
        event: "PreToolUse", payload: payload, agent: .codex, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 100),
        storage: SessionStorage(directory: directory)
    )

    #expect(SessionStorage(directory: directory).load(id: id) == nil)
    #expect(try Data(contentsOf: tombstoneURL) == committed)
    #expect(!FileManager.default.fileExists(
        atPath: hookUpdaterActiveURL(id: id, directory: directory).path
    ))
    let data = try Data(contentsOf: tombstoneURL)
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["kind"] as? String == "terminal")
    #expect(object["observed_at"] as? Double == 200)
}

@Test func crashIntermediateAtActivePathIsInvisibleAndRetainsEqualArrivalRule() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let parentID = "crash-intermediate"
    let id = hookUpdaterID(parentID)
    let payload = HookPayload(sessionId: parentID, cwd: "/work/app")
    let activeURL = hookUpdaterActiveURL(id: id, directory: directory)
    let staged = try JSONSerialization.data(withJSONObject: [
        "kind": "terminal", "id": id, "observed_at": 200,
    ])
    try staged.write(to: activeURL, options: .atomic)

    let storage = SessionStorage(directory: directory)
    #expect(storage.load(id: id) == nil)
    #expect(storage.loadAll().isEmpty)
    try HookSessionUpdater.apply(
        event: "PreToolUse", payload: payload, agent: .codex, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    #expect(try Data(contentsOf: activeURL) == staged)

    try HookSessionUpdater.apply(
        event: "SessionStart", payload: payload, agent: .codex, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )
    #expect(storage.load(id: id)?.eventObservedAt == 200)
    #expect(!FileManager.default.fileExists(
        atPath: hookUpdaterTombstoneURL(id: id, directory: directory).path
    ))
}

@Test func corruptHiddenTombstoneFailsClosedWithoutAffectingPublicLoadAll() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = "corrupt-hidden"
    let storage = SessionStorage(directory: directory)
    try storage.mutate(id: id) { _ in .keep }
    let tombstoneURL = hookUpdaterTombstoneURL(id: id, directory: directory)
    let corrupt = Data("not a tombstone".utf8)
    try corrupt.write(to: tombstoneURL, options: .atomic)
    #expect(chmod(tombstoneURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    var transformCalled = false

    #expect(storage.loadAll().isEmpty)
    #expect(storage.load(id: id) == nil)
    #expect(throws: SessionStorageMutationError.self) {
        try storage.mutate(id: id, observedAt: 300) { _ in
            transformCalled = true
            return .replace(hookUpdaterRecord(id: id, observedAt: 300))
        }
    }
    #expect(transformCalled == false)
    #expect(try Data(contentsOf: tombstoneURL) == corrupt)
}

@Test func equalOrNewerLifecycleEventReplacesTerminalAndCleansHiddenTombstone() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = HookPayload(sessionId: "reused", cwd: "/work/app")
    let storage = SessionStorage(directory: directory)
    let id = hookUpdaterID("reused")

    try HookSessionUpdater.apply(
        event: "SessionEnd", payload: payload, agent: .codex, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )
    let tombstoneURL = hookUpdaterTombstoneURL(id: id, directory: directory)
    #expect(FileManager.default.fileExists(atPath: tombstoneURL.path))
    try HookSessionUpdater.apply(
        event: "SessionStart", payload: payload, agent: .codex, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )
    #expect(storage.load(id: id)?.eventObservedAt == 200)
    #expect(!FileManager.default.fileExists(atPath: tombstoneURL.path))
    let equalEntry = try hookUpdaterEntryObject(id: id, directory: directory)
    var entry = try #require(equalEntry)
    #expect(entry["kind"] as? String == "active")

    try HookSessionUpdater.apply(
        event: "UserPromptSubmit", payload: payload, agent: .codex, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 201), storage: storage
    )
    #expect(storage.load(id: id)?.state == .working)
    #expect(storage.load(id: id)?.eventObservedAt == 201)
    let newerEntry = try hookUpdaterEntryObject(id: id, directory: directory)
    entry = try #require(newerEntry)
    #expect(entry["kind"] as? String == "active")
    let active = try #require(entry["record"] as? [String: Any])
    #expect(active["event_observed_at"] as? Double == 201)
    #expect(active["prompt_observed_at"] as? Double == 201)
    #expect(!FileManager.default.fileExists(atPath: tombstoneURL.path))
}

@Test func directLegacySessionRecordJSONRemainsReadable() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let record = hookUpdaterRecord(id: "legacy-direct", observedAt: 123)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(
        to: directory.appendingPathComponent(SessionStorage.safeFilename(for: record.id)),
        options: .atomic
    )

    let storage = SessionStorage(directory: directory)
    #expect(storage.load(id: record.id) == record)
    #expect(storage.loadAll() == [record])
}

@Test func malformedTombstoneFailsClosedBeforeOrderedTransform() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = "malformed-terminal"
    let entryURL = directory.appendingPathComponent(SessionStorage.safeFilename(for: id))
    // This deliberately also contains every required direct-record field. A
    // decoder that merely falls back after a malformed tagged entry would
    // misclassify it as active and discard the tombstone's fail-closed intent.
    let malformed = Data(
        #"{"kind":"terminal","id":"malformed-terminal","tool":"codex","state":"working","cwd":"/work/app","updated_at":"1970-01-01T00:01:40Z"}"#.utf8
    )
    try malformed.write(to: entryURL, options: .atomic)
    let storage = SessionStorage(directory: directory)
    var transformCalled = false

    #expect(throws: SessionStorageMutationError.self) {
        try storage.mutate(id: id, observedAt: 300) { _ in
            transformCalled = true
            return .replace(hookUpdaterRecord(id: id, observedAt: 300))
        }
    }

    #expect(transformCalled == false)
    #expect(try Data(contentsOf: entryURL) == malformed)
    #expect(storage.load(id: id) == nil)
}

@Test func nonFiniteObservationFailsBeforeTransformOrStorageSideEffects() throws {
    let root = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    for (index, observedAt) in [TimeInterval.nan, .infinity, -.infinity].enumerated() {
        let directory = root.appendingPathComponent("case-\(index)", isDirectory: true)
        let storage = SessionStorage(directory: directory)
        var transformCalled = false

        #expect(throws: SessionStorageMutationError.self) {
            try storage.mutate(id: "nonfinite", observedAt: observedAt) { _ in
                transformCalled = true
                return .delete
            }
        }
        #expect(transformCalled == false)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

@Test func concurrentMixedEventsKeepTheGreatestObservationForOneSession() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let queue = DispatchQueue(label: "HookSessionUpdaterTests.mixed", attributes: .concurrent)
    let group = DispatchGroup()
    let failures = LockedErrors()

    for index in 1...80 {
        group.enter()
        queue.async {
            defer { group.leave() }
            let event: String
            switch index % 4 {
            case 0: event = "Stop"
            case 1: event = "PreToolUse"
            case 2: event = "UserPromptSubmit"
            default: event = "PermissionRequest"
            }
            do {
                try HookSessionUpdater.apply(
                    event: event,
                    payload: HookPayload(
                        sessionId: "mixed",
                        cwd: "/work/app",
                        toolName: event == "PreToolUse" ? "Bash" : nil
                    ),
                    agent: .codex,
                    agentPID: Int32(index),
                    observedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    storage: storage
                )
            } catch {
                failures.append(error)
            }
        }
    }

    group.wait()
    #expect(failures.values.isEmpty)
    let id = hookUpdaterID("mixed")
    let record = try #require(storage.load(id: id))
    #expect(record.eventObservedAt == 80)
    #expect(record.state == .idle)
    #expect(record.lastEvent == "Stop")
    let data = try Data(contentsOf: directory.appendingPathComponent(
        SessionStorage.safeFilename(for: id)
    ))
    #expect(throws: Never.self) {
        try JSONSerialization.jsonObject(with: data)
    }
}

@Test func reducerNoOpDoesNotCreateStorageOrLockDirectories() throws {
    let root = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("never-created", isDirectory: true)

    try HookSessionUpdater.apply(
        event: "SomeFutureEvent",
        payload: HookPayload(sessionId: "no-op", cwd: "/work/app"),
        agent: .codex,
        agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 100),
        storage: SessionStorage(directory: sessions)
    )

    #expect(!FileManager.default.fileExists(atPath: sessions.path))
}

@Test func serializedMutationCannotOverwriteANewerCompletedMutation() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let staleTransformEntered = DispatchSemaphore(value: 0)
    let releaseStaleTransform = DispatchSemaphore(value: 0)
    let staleDone = DispatchGroup()
    let failures = LockedErrors()

    staleDone.enter()
    DispatchQueue.global().async {
        defer { staleDone.leave() }
        do {
            try storage.mutate(id: "ordered") { _ in
                staleTransformEntered.signal()
                releaseStaleTransform.wait()
                return .replace(hookUpdaterRecord(id: "ordered", observedAt: 100))
            }
        } catch {
            failures.append(error)
        }
    }

    staleTransformEntered.wait()
    do {
        try storage.mutate(id: "ordered", timeout: 0.01) { _ in
            .replace(hookUpdaterRecord(id: "ordered", observedAt: 200))
        }
        // An unlocked implementation reaches this branch. Releasing the stale
        // transform only after the newer write completes deterministically
        // exposes the stale-overwrite race at the final assertion.
        releaseStaleTransform.signal()
        staleDone.wait()
    } catch SessionStorageMutationError.lockTimedOut {
        // A per-session transaction bounds the competing attempt. Complete
        // the stale transaction, then retry the newer observation.
        releaseStaleTransform.signal()
        staleDone.wait()
        try storage.mutate(id: "ordered") { _ in
            .replace(hookUpdaterRecord(id: "ordered", observedAt: 200))
        }
    }

    #expect(failures.values.isEmpty)
    #expect(storage.load(id: "ordered")?.eventObservedAt == 200)
}

@Test func sameSessionLockTimesOutWithinItsBoundAndLeavesValidJSON() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    try storage.write(hookUpdaterRecord(id: "blocked", observedAt: 1))
    let transformEntered = DispatchSemaphore(value: 0)
    let releaseTransform = DispatchSemaphore(value: 0)
    let holderDone = DispatchGroup()
    let failures = LockedErrors()

    holderDone.enter()
    DispatchQueue.global().async {
        defer { holderDone.leave() }
        do {
            try storage.mutate(id: "blocked") { previous in
                transformEntered.signal()
                releaseTransform.wait()
                return .replace(hookUpdaterRecord(
                    id: "blocked",
                    observedAt: (previous?.eventObservedAt ?? 0) + 1
                ))
            }
        } catch {
            failures.append(error)
        }
    }
    defer {
        releaseTransform.signal()
        holderDone.wait()
    }

    transformEntered.wait()
    let clock = ContinuousClock()
    let started = clock.now
    do {
        try storage.mutate(id: "blocked", timeout: 0.01) { _ in .keep }
        Issue.record("expected a typed lock timeout")
    } catch let error as SessionStorageMutationError {
        #expect(error == .lockTimedOut)
    }
    let elapsed = started.duration(to: clock.now)
    #expect(elapsed >= .milliseconds(5))
    // The holder remains blocked until after this assertion, so returning at
    // all proves the lock wait is bounded. The generous wall-clock ceiling
    // tolerates scheduler starvation when the full test process runs hundreds
    // of unrelated blocking tests concurrently.
    #expect(elapsed < .seconds(30))

    releaseTransform.signal()
    holderDone.wait()
    #expect(failures.values.isEmpty)
    let record = try #require(storage.load(id: "blocked"))
    #expect(record.eventObservedAt == 2)
    let data = try Data(contentsOf: directory.appendingPathComponent("blocked.json"))
    #expect(throws: Never.self) {
        try JSONSerialization.jsonObject(with: data)
    }
}

@Test func lockDirectoryAndStableLockFileUsePrivateModes() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    try storage.mutate(id: "mode/check") { _ in .keep }

    let locks = directory.appendingPathComponent(".locks", isDirectory: true)
    let lock = locks.appendingPathComponent(
        SessionStorage.safeFilename(for: "mode/check") + ".lock"
    )
    var directoryStatus = stat()
    var lockStatus = stat()
    #expect(lstat(locks.path, &directoryStatus) == 0)
    #expect(lstat(lock.path, &lockStatus) == 0)
    #expect(directoryStatus.st_mode & S_IFMT == S_IFDIR)
    #expect(lockStatus.st_mode & S_IFMT == S_IFREG)
    #expect(directoryStatus.st_mode & 0o777 == 0o700)
    #expect(lockStatus.st_mode & 0o777 == 0o600)
}

@Test func symlinkedLockDirectoryIsRefusedWithoutTouchingItsTarget() throws {
    let root = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: sessions.appendingPathComponent(".locks"),
        withDestinationURL: outside
    )

    #expect(throws: SessionStorageMutationError.self) {
        try SessionStorage(directory: sessions).mutate(id: "escape") { _ in .keep }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

@Test func unsafeIDsUseIndependentLockFilesDuringConcurrentMutation() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let firstTransformEntered = DispatchSemaphore(value: 0)
    let releaseFirstTransform = DispatchSemaphore(value: 0)
    let firstDone = DispatchGroup()
    let failures = LockedErrors()

    firstDone.enter()
    DispatchQueue.global().async {
        defer { firstDone.leave() }
        do {
            try storage.mutate(id: "a/b") { _ in
                firstTransformEntered.signal()
                releaseFirstTransform.wait()
                return .replace(hookUpdaterRecord(id: "a/b", observedAt: 100))
            }
        } catch {
            failures.append(error)
        }
    }
    defer {
        releaseFirstTransform.signal()
        firstDone.wait()
    }

    firstTransformEntered.wait()
    try storage.mutate(id: "a?b", timeout: 0.01) { _ in
        .replace(hookUpdaterRecord(id: "a?b", observedAt: 200))
    }

    releaseFirstTransform.signal()
    firstDone.wait()
    #expect(failures.values.isEmpty)
    #expect(Set(storage.loadAll().map(\.id)) == ["a/b", "a?b"])

    let locks = directory.appendingPathComponent(".locks", isDirectory: true)
    let lockNames = try FileManager.default.contentsOfDirectory(atPath: locks.path)
    #expect(lockNames.count == 2)
    #expect(Set(lockNames).count == 2)
}

@Test func mutationDeleteSurfacesFilesystemFailure() throws {
    let root = hookUpdaterTempDirectory()
    let directory = root.appendingPathComponent("sessions", isDirectory: true)
    defer {
        chmod(directory.path, mode_t(S_IRWXU))
        try? FileManager.default.removeItem(at: root)
    }
    let storage = SessionStorage(directory: directory)
    let record = hookUpdaterRecord(id: "cannot-delete", observedAt: 100)
    try storage.write(record)
    let outsideSentinel = root.appendingPathComponent("outside-sentinel")
    try Data("outside-state-must-survive".utf8).write(to: outsideSentinel)
    // Create/open the lock infrastructure before making the parent session
    // directory read-only. Existing lock files remain usable, while unlinking
    // the visible record from its parent must fail with EACCES/EPERM.
    try storage.mutate(id: record.id) { _ in .keep }
    #expect(chmod(directory.path, mode_t(S_IRUSR | S_IXUSR)) == 0)

    #expect(throws: SessionStorageMutationError.self) {
        try storage.mutate(id: record.id) { _ in .delete }
    }
    #expect(storage.load(id: record.id) == record)
    #expect(try String(contentsOf: outsideSentinel, encoding: .utf8)
            == "outside-state-must-survive")
}

@Test func claudeIdleCompactionLeavesTheSessionIdle() throws {
    // The hook sequence of an idle auto-compaction, and of /compact at the
    // prompt: no Stop follows, so nothing else would release the hold.
    for (trigger, order) in [("auto", ["SessionStart", "PostCompact"]),
                             ("manual", ["PostCompact", "SessionStart"])] {
        let directory = hookUpdaterTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SessionStorage(directory: directory)
        let id = try #require(HookPayload(sessionId: "idle-compact")
            .recordID(agent: .claude, event: "Stop"))

        try applyClaudeCompactHooks(
            ["UserPromptSubmit", "Stop", "PreCompact"] + order,
            sessionID: "idle-compact", trigger: trigger, from: 100, storage: storage
        )

        let record = try #require(storage.load(id: id))
        #expect(record.state == .idle)
        #expect(record.lastEvent == (trigger == "manual" ? "PostCompact" : "Stop"))
        #expect(storage.loadAll().count == 1)
    }
}

@Test func claudeAbortedCompactionLeavesTheSessionIdle() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let id = try #require(HookPayload(sessionId: "aborted-compact")
        .recordID(agent: .claude, event: "Stop"))

    try applyClaudeCompactHooks(
        ["UserPromptSubmit", "Stop", "PreCompact"],
        sessionID: "aborted-compact", trigger: "manual", from: 100, storage: storage
    )

    #expect(storage.load(id: id)?.state == .idle)
    #expect(storage.load(id: id)?.lastEvent == "Stop")
}

@Test func claudeCompactionInsideATurnStaysWorkingUntilStop() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let id = try #require(HookPayload(sessionId: "turn-compact")
        .recordID(agent: .claude, event: "Stop"))

    try applyClaudeCompactHooks(
        ["UserPromptSubmit"], sessionID: "turn-compact", trigger: "auto", from: 100,
        storage: storage
    )
    let transitionID = try #require(storage.load(id: id)?.stateTransitionID)
    try applyClaudeCompactHooks(
        ["PreCompact", "SessionStart", "PostCompact"],
        sessionID: "turn-compact", trigger: "auto", from: 101, storage: storage
    )

    let compacted = try #require(storage.load(id: id))
    #expect(compacted.state == .working)
    #expect(compacted.lastEvent == "UserPromptSubmit")
    #expect(compacted.stateTransitionID == transitionID)

    try applyClaudeCompactHooks(
        ["Stop"], sessionID: "turn-compact", trigger: "auto", from: 104, storage: storage
    )
    #expect(storage.load(id: id)?.state == .idle)
}

@Test func codexCompactionKeepsTheTurnsStateThroughStorage() throws {
    for (lead, expected) in [("Stop", SessionState.idle), ("PreToolUse", .working)] {
        let directory = hookUpdaterTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SessionStorage(directory: directory)

        try applyHooks(
            [("UserPromptSubmit", ""), (lead, "")] + compactionHooks(trigger: "manual"),
            agent: .codex, sessionID: "codex-compact", from: 100, storage: storage
        )

        let record = try #require(storage.load(id: hookUpdaterID("codex-compact")))
        #expect(record.state == expected)
        #expect(record.lastEvent == lead)
    }
}

@Test func claudeManualCompactClearsATurnAnInterruptLeftWorking() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    // Claude sends no hook when Esc cancels a turn, so PreToolUse is its last.
    try applyHooks(
        [("UserPromptSubmit", ""), ("PreToolUse", #","tool_name":"Bash""#)]
            + compactionHooks(trigger: "manual"),
        sessionID: "interrupted", from: 100, storage: storage
    )

    let record = try #require(storage.load(id: hookUpdaterID("interrupted", agent: .claude)))
    #expect(record.state == .idle)
    #expect(record.lastEvent == "PostCompact")
}

@Test func claudeManualCompactKeepsAStoppedTurnsBackgroundWork() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    try applyHooks(
        [("UserPromptSubmit", ""),
         ("Stop", #","background_tasks":[{"type":"shell","status":"running"}]"#)]
            + compactionHooks(trigger: "manual"),
        sessionID: "background", from: 100, storage: storage
    )

    let record = try #require(storage.load(id: hookUpdaterID("background", agent: .claude)))
    #expect(record.state == .working)
    #expect(record.lastEvent == "Stop")
}

@Test func claudeSessionStartFromAnUnknownSourceKeepsTheTurnWorking() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    try applyHooks(
        [("UserPromptSubmit", ""), ("SessionStart", #","source":"some-future-source""#)],
        sessionID: "future-source", from: 100, storage: storage
    )

    let record = try #require(storage.load(id: hookUpdaterID("future-source", agent: .claude)))
    #expect(record.state == .working)
    #expect(record.lastEvent == "UserPromptSubmit")
}

@Test func codexInterruptReleasesTheCancelledTurn() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    try applyHooks(
        [("UserPromptSubmit", ""), ("PreToolUse", #","tool_name":"Bash""#),
         ("Interrupt", #","turn_id":"turn-1""#)],
        agent: .codex, sessionID: "codex-esc", from: 100, storage: storage
    )

    let record = try #require(storage.load(id: hookUpdaterID("codex-esc")))
    #expect(record.state == .idle)
    #expect(record.lastEvent == "Interrupt")
}

@Test func codexStopClearsChildrenSilentForTheParentsWholeTurn() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let early = hookUpdaterID("codex-family", childID: "early")
    let late = hookUpdaterID("codex-family", childID: "late")

    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-family",
                   from: 100, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"early""#)], agent: .codex,
                   sessionID: "codex-family", from: 101, storage: storage)
    try applyHooks([("Stop", "")], agent: .codex, sessionID: "codex-family",
                   from: 102, storage: storage)
    // Heard during the turn that just stopped: it may still be running.
    #expect(storage.load(id: early)?.state == .working)

    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-family",
                   from: 200, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"late""#)], agent: .codex,
                   sessionID: "codex-family", from: 250, storage: storage)
    try applyHooks([("Stop", "")], agent: .codex, sessionID: "codex-family",
                   from: 300, storage: storage)

    #expect(storage.load(id: early) == nil)
    #expect(storage.load(id: late)?.state == .working)
    #expect(storage.load(id: hookUpdaterID("codex-family"))?.state == .idle)
}

@Test func codexStopMeasuresTheTurnFromThePromptsExactTime() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    try applyHooks([("UserPromptSubmit", ""), ("Stop", "")], agent: .codex,
                   sessionID: "codex-second", from: 100, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"before""#)], agent: .codex,
                   sessionID: "codex-second", from: 200.1, storage: storage)
    // The turn starts at 200.3, within the same whole second as both children.
    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-second",
                   from: 200.3, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"after""#)], agent: .codex,
                   sessionID: "codex-second", from: 200.6, storage: storage)
    try applyHooks([("Stop", "")], agent: .codex, sessionID: "codex-second",
                   from: 300, storage: storage)

    #expect(storage.load(id: hookUpdaterID("codex-second", childID: "before")) == nil)
    #expect(storage.load(id: hookUpdaterID("codex-second", childID: "after"))?.state == .working)
}

@Test func codexStopClearsChildrenOfATurnThatEndedWithoutAHook() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    // Esc on a Codex without the Interrupt hook leaves the parent Working, so
    // the next prompt does not change its state.
    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-esc-child",
                   from: 100, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"cancelled""#)], agent: .codex,
                   sessionID: "codex-esc-child", from: 101, storage: storage)
    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-esc-child",
                   from: 200, storage: storage)
    try applyHooks([("Stop", "")], agent: .codex, sessionID: "codex-esc-child",
                   from: 300, storage: storage)

    #expect(storage.load(id: hookUpdaterID("codex-esc-child", childID: "cancelled")) == nil)
    #expect(storage.load(id: hookUpdaterID("codex-esc-child"))?.state == .idle)
}

@Test func codexStopFallsBackToTheStateEdgeForALegacyParent() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let parent = hookUpdaterID("codex-legacy")

    try applyHooks([("SubagentStart", #","agent_id":"silent""#)], agent: .codex,
                   sessionID: "codex-legacy", from: 150, storage: storage)
    // Written before prompts were recorded: no promptObservedAt.
    var legacy = hookUpdaterRecord(id: parent, observedAt: 200)
    legacy.state = .working
    legacy.lastEvent = "UserPromptSubmit"
    legacy.stateChangedAt = Date(timeIntervalSince1970: 200)
    try storage.mutate(id: parent, observedAt: 200) { _ in .replace(legacy) }
    try applyHooks([("SubagentStart", #","agent_id":"heard""#)], agent: .codex,
                   sessionID: "codex-legacy", from: 250, storage: storage)
    try applyHooks([("Stop", "")], agent: .codex, sessionID: "codex-legacy",
                   from: 300, storage: storage)

    #expect(storage.load(id: hookUpdaterID("codex-legacy", childID: "silent")) == nil)
    #expect(storage.load(id: hookUpdaterID("codex-legacy", childID: "heard"))?.state == .working)
}

@Test func codexSessionEndClearsItsChildren() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-end",
                   from: 100, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"child""#)], agent: .codex,
                   sessionID: "codex-end", from: 101, storage: storage)
    try applyHooks([("SessionEnd", "")], agent: .codex, sessionID: "codex-end",
                   from: 102, storage: storage)

    #expect(storage.loadAll().isEmpty)
}

@Test func codexStopCutoffHidesChildrenItsCleanupMissed() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let parent = hookUpdaterID("codex-cutoff")
    let child = hookUpdaterID("codex-cutoff", childID: "child")

    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-cutoff",
                   from: 100, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"child""#)], agent: .codex,
                   sessionID: "codex-cutoff", from: 101, storage: storage)
    try applyHooks([("Stop", ""), ("UserPromptSubmit", "")], agent: .codex,
                   sessionID: "codex-cutoff", from: 102, storage: storage)
    // Hold the real child lock while the next Stop commits the parent and
    // attempts its bounded cleanup. No production fault-injection seam.
    try storage.mutate(id: child) { _ in
        #expect(throws: SessionStorageMutationError.lockTimedOut) {
            try applyHooks([("Stop", "")], agent: .codex, sessionID: "codex-cutoff",
                           from: 300, storage: storage)
        }
        return .keep
    }

    #expect(storage.load(id: parent)?.state == .idle)
    let entry = try #require(try hookUpdaterEntryObject(id: parent, directory: directory))
    let record = try #require(entry["record"] as? [String: Any])
    #expect(record["stale_child_cutoff"] as? Double == 103)
    #expect(storage.load(id: child) != nil)
    #expect(storage.loadAll().map(\.id) == [parent])
    #expect(!decide(
        sessions: storage.loadAll(), now: Date(timeIntervalSince1970: 301), settings: Settings(),
        power: PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
    ).holdSystem)

    // A late hook observed before the cutoff cannot revive the child; one
    // observed after it proves the child is still running.
    try applyHooks([("PostToolUse", #","agent_id":"child""#)], agent: .codex,
                   sessionID: "codex-cutoff", from: 102.5, storage: storage)
    #expect(storage.load(id: child)?.eventObservedAt == 101)
    #expect(storage.loadAll().map(\.id) == [parent])
    try applyHooks([("PostToolUse", #","agent_id":"child""#)], agent: .codex,
                   sessionID: "codex-cutoff", from: 301, storage: storage)
    #expect(storage.loadAll().count == 2)
}

@Test func codexChildHookObservedBeforeTheStopButAppliedAfterItSurvives() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let child = hookUpdaterID("codex-race", childID: "child")

    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-race",
                   from: 50, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"child""#)], agent: .codex,
                   sessionID: "codex-race", from: 90, storage: storage)
    try applyHooks([("Stop", "")], agent: .codex, sessionID: "codex-race",
                   from: 95, storage: storage)
    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-race",
                   from: 100, storage: storage)
    // The child's hook is observed first but loses the family lock to the Stop.
    try applyHooks([("Stop", "")], agent: .codex, sessionID: "codex-race",
                   from: 150.001, storage: storage)
    #expect(storage.load(id: child) == nil)
    try applyHooks([("PreToolUse", #","agent_id":"child","tool_name":"Bash""#)],
                   agent: .codex, sessionID: "codex-race", from: 150, storage: storage)

    #expect(storage.load(id: child)?.state == .working)
    #expect(storage.loadAll().contains { $0.id == child })
}

@Test func codexInterruptClearsChildrenSilentForTheCancelledTurn() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-esc-sweep",
                   from: 100, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"silent""#)], agent: .codex,
                   sessionID: "codex-esc-sweep", from: 101, storage: storage)
    try applyHooks([("Stop", ""), ("UserPromptSubmit", "")], agent: .codex,
                   sessionID: "codex-esc-sweep", from: 102, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"heard""#)], agent: .codex,
                   sessionID: "codex-esc-sweep", from: 150, storage: storage)
    try applyHooks([("Interrupt", #","turn_id":"turn-2""#)], agent: .codex,
                   sessionID: "codex-esc-sweep", from: 200, storage: storage)

    #expect(storage.load(id: hookUpdaterID("codex-esc-sweep"))?.state == .idle)
    #expect(storage.load(id: hookUpdaterID("codex-esc-sweep", childID: "silent")) == nil)
    #expect(storage.load(id: hookUpdaterID("codex-esc-sweep", childID: "heard"))?.state == .working)
}

@Test func codexInterruptedCleanupCannotKeepEndedFamilyAwake() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let parent = hookUpdaterID("codex-sweep")
    let child = hookUpdaterID("codex-sweep", childID: "child")

    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-sweep",
                   from: 10, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"child""#)], agent: .codex,
                   sessionID: "codex-sweep", from: 20, storage: storage)
    // Model a SessionEnd hook that exits after committing the parent terminal,
    // before deleting any children. Later child hooks are rejected, so reads
    // must treat the terminal as authoritative.
    try storage.mutate(id: parent, observedAt: 30) { _ in .delete }
    #expect(storage.load(id: child) != nil)
    #expect(storage.loadAll().isEmpty)
    #expect(!decide(
        sessions: storage.loadAll(), now: Date(timeIntervalSince1970: 31), settings: Settings(),
        power: PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
    ).holdSystem)

    try applyHooks([("SessionStart", "")], agent: .codex, sessionID: "codex-sweep",
                   from: 50.8, storage: storage)
    #expect(storage.loadAll().map(\.id) == [parent])
    try applyHooks([("SubagentStart", #","agent_id":"new-child""#)], agent: .codex,
                   sessionID: "codex-sweep", from: 51, storage: storage)
    #expect(storage.loadAll().count == 2)
}

@Test func claudeParentStopLeavesChildrenToTheirOwnCompletion() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let child = hookUpdaterID("claude-family", agent: .claude, childID: "child")

    try applyHooks([("UserPromptSubmit", "")], sessionID: "claude-family", from: 100,
                   storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"child""#)], sessionID: "claude-family",
                   from: 101, storage: storage)
    try applyHooks([("Stop", ""), ("UserPromptSubmit", ""), ("Stop", "")],
                   sessionID: "claude-family", from: 200, storage: storage)

    #expect(storage.load(id: child)?.state == .working)
}

@Test func claudeBackgroundTasksAndSessionCronsDriveStopStructurally() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let id = try #require(HookPayload(sessionId: "claude-parent")
        .recordID(agent: .claude, event: "Stop"))

    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"claude-parent","background_tasks":[{"description":"ignored"}]}"#,
        agent: .claude,
        observedAt: Date(timeIntervalSince1970: 100),
        storage: storage
    )
    #expect(storage.load(id: id)?.state == .working)

    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"claude-parent","background_tasks":[]}"#,
        agent: .claude,
        observedAt: Date(timeIntervalSince1970: 101),
        storage: storage
    )
    #expect(storage.load(id: id)?.state == .idle)

    try applyDecodedHook(
        event: "UserPromptSubmit",
        json: #"{"session_id":"claude-parent"}"#,
        agent: .claude,
        observedAt: Date(timeIntervalSince1970: 102),
        storage: storage
    )
    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"claude-parent","session_crons":[{"id":"cron"}]}"#,
        agent: .claude,
        observedAt: Date(timeIntervalSince1970: 103),
        storage: storage
    )
    #expect(storage.load(id: id)?.state == .idle)
}

@Test func subagentStopRemovesOnlyTheAddressedChildRecord() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    try applyDecodedHook(
        event: "UserPromptSubmit",
        json: #"{"session_id":"parent","cwd":"/work/app"}"#,
        agent: .claude,
        observedAt: Date(timeIntervalSince1970: 99),
        storage: storage
    )

    for (index, child) in ["child-a", "child-b"].enumerated() {
        try applyDecodedHook(
            event: "SubagentStart",
            json: #"{"session_id":"parent","agent_id":"\#(child)","cwd":"/work/app"}"#,
            agent: .claude,
            observedAt: Date(timeIntervalSince1970: TimeInterval(100 + index)),
            storage: storage
        )
    }

    let firstID = try #require(HookPayload(sessionId: "parent", agentId: "child-a")
        .recordID(agent: .claude, event: "SubagentStart"))
    let secondID = try #require(HookPayload(sessionId: "parent", agentId: "child-b")
        .recordID(agent: .claude, event: "SubagentStart"))
    let parentID = try #require(HookPayload(sessionId: "parent")
        .recordID(agent: .claude, event: "UserPromptSubmit"))
    #expect(Set(storage.loadAll().map(\.id)) == [parentID, firstID, secondID])

    try applyDecodedHook(
        event: "SubagentStop",
        json: #"{"session_id":"parent"}"#,
        agent: .claude,
        observedAt: Date(timeIntervalSince1970: 102),
        storage: storage
    )
    try applyDecodedHook(
        event: "SubagentStop",
        json: #"{"session_id":"parent","agent_id":""}"#,
        agent: .claude,
        observedAt: Date(timeIntervalSince1970: 103),
        storage: storage
    )
    #expect(Set(storage.loadAll().map(\.id)) == [parentID, firstID, secondID])

    try applyDecodedHook(
        event: "SubagentStop",
        json: #"{"session_id":"parent","agent_id":"child-a"}"#,
        agent: .claude,
        observedAt: Date(timeIntervalSince1970: 104),
        storage: storage
    )

    #expect(storage.load(id: firstID) == nil)
    #expect(storage.load(id: parentID)?.state == .working)
    #expect(storage.load(id: secondID)?.state == .working)
    #expect(Set(storage.loadAll().map(\.id)) == [parentID, secondID])
}

@Test func equalRawSessionIDsFromDifferentVendorsStayDistinctInStorage() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    for agent in [AgentID.claude, .codex] {
        try applyDecodedHook(
            event: "Stop",
            json: #"{"session_id":"same","cwd":"/work/app"}"#,
            agent: agent,
            observedAt: Date(timeIntervalSince1970: 100),
            storage: storage
        )
    }

    let records = storage.loadAll()
    #expect(Set(records.map(\.id)).count == 2)
    #expect(Set(records.map(\.tool)) == ["claude", "codex"])
}

@Test func equalTimestampOpenCodeStopEdgesRemainOneIdleTransition() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let timestamp = Date(timeIntervalSince1970: 100)

    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"open-code","cwd":"/work/app"}"#,
        agent: .opencode,
        observedAt: timestamp,
        storage: storage
    )
    let first = try #require(storage.loadAll().first)
    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"open-code","cwd":"/work/app"}"#,
        agent: .opencode,
        observedAt: timestamp,
        storage: storage
    )

    let records = storage.loadAll()
    try #require(records.count == 1)
    #expect(records[0].state == .idle)
    #expect(records[0].stateTransitionID == first.stateTransitionID)
    #expect(records[0].stateChangedAt == first.stateChangedAt)
}

@Test func claudeStopWithFinishedBackgroundTasksReleasesWorkingSession() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let id = hookUpdaterID("parent", agent: .claude)

    try applyDecodedHook(
        event: "UserPromptSubmit", json: #"{"session_id":"parent","cwd":"/work/app"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"parent","cwd":"/work/app","background_tasks":[{"id":"a","status":"completed"},{"id":"b","status":"failed"},{"id":"c","status":"killed"},{"id":"d","status":"cancelled"},{"id":"e","status":"canceled"},{"id":"f","status":"idle"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )

    let record = try #require(storage.load(id: id))
    #expect(record.state == .idle)
    #expect(record.lastEvent == "Stop")
    #expect(record.accumulatedWorkingTime == 100)
}

@Test func claudeStopPreservesRunningOrUnrecognizedBackgroundWork() throws {
    for task in [#"{"status":"running"}"#, #"{"status":"pending"}"#,
                 #"{"status":"future-status"}"#, "{}", #"{"status":null}"#,
                 #"{"status":42}"#] {
        let directory = hookUpdaterTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SessionStorage(directory: directory)
        try applyDecodedHook(
            event: "Stop",
            json: "{\"session_id\":\"parent\",\"background_tasks\":[{\"status\":\"completed\"},\(task)]}",
            agent: .claude, observedAt: Date(timeIntervalSince1970: 100), storage: storage
        )
        #expect(storage.load(id: hookUpdaterID("parent", agent: .claude))?.state == .working)
    }
}


// MARK: - Claude background work: shell-only holds, inventories, and child pruning

@Test func claudeStopWithOnlyShellsHoldsAsABoundedBackgroundShell() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let id = hookUpdaterID("parent", agent: .claude)

    try applyDecodedHook(
        event: "UserPromptSubmit", json: #"{"session_id":"parent","cwd":"/work/app"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    // Captured shape: a shell a subagent started outlives that subagent.
    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"parent","cwd":"/work/app","background_tasks":[{"id":"beyuypx27","type":"shell","status":"running","command":"private"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )
    var record = try #require(storage.load(id: id))
    #expect(record.state == .working)
    #expect(record.detail == SessionWorkDetail.backgroundShell)
    #expect(record.updatedAt == Date(timeIntervalSince1970: 200))

    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"parent","cwd":"/work/app","background_tasks":[{"id":"a1","type":"subagent","status":"running"},{"id":"beyuypx27","type":"shell","status":"running"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 201), storage: storage
    )
    record = try #require(storage.load(id: id))
    #expect(record.state == .working)
    #expect(record.detail == SessionWorkDetail.backgroundAgent)

    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"parent","cwd":"/work/app","background_tasks":[{"id":"beyuypx27","type":"shell","status":"killed"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 202), storage: storage
    )
    #expect(storage.load(id: id)?.state == .idle)
}

@Test func claudeStopInventoryPrunesChildrenItNoLongerLists() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let parentID = hookUpdaterID("parent", agent: .claude)
    let keptID = hookUpdaterID("parent", agent: .claude, childID: "child-a", event: "SubagentStart")
    let orphanID = hookUpdaterID("parent", agent: .claude, childID: "child-b", event: "SubagentStart")

    try applyDecodedHook(
        event: "UserPromptSubmit", json: #"{"session_id":"parent","cwd":"/work/app"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    for (index, child) in ["child-a", "child-b"].enumerated() {
        try applyDecodedHook(
            event: "SubagentStart",
            json: #"{"session_id":"parent","agent_id":"\#(child)","cwd":"/work/app"}"#,
            agent: .claude, observedAt: Date(timeIntervalSince1970: TimeInterval(101 + index)),
            storage: storage
        )
    }
    // child-b never sends SubagentStop, as observed for killed or handed-back agents.
    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"parent","cwd":"/work/app","background_tasks":[{"id":"child-a","type":"subagent","status":"running","agent_type":"general-purpose"},{"id":"sh","type":"shell","status":"running"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )
    #expect(storage.load(id: keptID)?.state == .working)
    #expect(storage.load(id: orphanID) == nil)
    #expect(storage.load(id: parentID)?.detail == SessionWorkDetail.backgroundAgent)

    // An empty inventory at Stop means every child has finished.
    try applyDecodedHook(
        event: "Stop", json: #"{"session_id":"parent","cwd":"/work/app","background_tasks":[]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 300), storage: storage
    )
    #expect(storage.load(id: keptID) == nil)
    #expect(storage.load(id: parentID)?.state == .idle)
    #expect(Set(storage.loadAll().map(\.id)) == [parentID])
}

@Test func claudeStopWithAnUnidentifiedEntryOrNoSnapshotKeepsChildren() throws {
    for stop in [#"{"session_id":"parent","cwd":"/work/app"}"#,
                 #"{"session_id":"parent","cwd":"/work/app","background_tasks":[{"type":"subagent","status":"running"}]}"#,
                 #"{"session_id":"parent","cwd":"/work/app","background_tasks":[{"id":"","type":"shell","status":"running"}]}"#] {
        let directory = hookUpdaterTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SessionStorage(directory: directory)
        let childID = hookUpdaterID("parent", agent: .claude, childID: "child", event: "SubagentStart")

        try applyDecodedHook(
            event: "UserPromptSubmit", json: #"{"session_id":"parent","cwd":"/work/app"}"#,
            agent: .claude, observedAt: Date(timeIntervalSince1970: 100), storage: storage
        )
        try applyDecodedHook(
            event: "SubagentStart", json: #"{"session_id":"parent","agent_id":"child","cwd":"/work/app"}"#,
            agent: .claude, observedAt: Date(timeIntervalSince1970: 101), storage: storage
        )
        try applyDecodedHook(
            event: "Stop", json: stop,
            agent: .claude, observedAt: Date(timeIntervalSince1970: 200), storage: storage
        )
        #expect(storage.load(id: childID)?.state == .working, "stop: \(stop)")
    }
}

@Test func aStaleClaudeStopCannotPruneAChildHeardAfterIt() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let childID = hookUpdaterID("parent", agent: .claude, childID: "child", event: "SubagentStart")

    try applyDecodedHook(
        event: "UserPromptSubmit", json: #"{"session_id":"parent","cwd":"/work/app"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    try applyDecodedHook(
        event: "SubagentStart", json: #"{"session_id":"parent","agent_id":"child","cwd":"/work/app"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 101), storage: storage
    )
    try applyDecodedHook(
        event: "PreToolUse",
        json: #"{"session_id":"parent","agent_id":"child","cwd":"/work/app","tool_name":"Read"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 300), storage: storage
    )
    // The Stop was observed before the child's tool call but applied after it.
    try applyDecodedHook(
        event: "Stop", json: #"{"session_id":"parent","cwd":"/work/app","background_tasks":[]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 250), storage: storage
    )
    #expect(storage.load(id: childID)?.state == .working)
}

@Test func subagentStopJudgesTheParentWithoutTheChildThatIsStopping() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let parentID = hookUpdaterID("parent", agent: .claude)
    let childID = hookUpdaterID("parent", agent: .claude, childID: "a1ae869a95e1a9a18", event: "SubagentStart")

    try applyDecodedHook(
        event: "UserPromptSubmit", json: #"{"session_id":"parent","cwd":"/work/app"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    try applyDecodedHook(
        event: "SubagentStart",
        json: #"{"session_id":"parent","agent_id":"a1ae869a95e1a9a18","cwd":"/work/app"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 101), storage: storage
    )
    // Captured sequence: the parent stops while its backgrounded subagent and
    // that subagent's shell run, then the subagent stops and still lists itself.
    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"parent","cwd":"/work/app","background_tasks":[{"id":"a1ae869a95e1a9a18","type":"subagent","status":"running"},{"id":"beyuypx27","type":"shell","status":"running"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )
    #expect(storage.load(id: parentID)?.detail == SessionWorkDetail.backgroundAgent)

    try applyDecodedHook(
        event: "SubagentStop",
        json: #"{"session_id":"parent","agent_id":"a1ae869a95e1a9a18","cwd":"/work/app","background_tasks":[{"id":"a1ae869a95e1a9a18","type":"subagent","status":"running"},{"id":"beyuypx27","type":"shell","status":"running"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 260), storage: storage
    )
    #expect(storage.load(id: childID) == nil)
    let downgraded = try #require(storage.load(id: parentID))
    #expect(downgraded.state == .working)
    #expect(downgraded.detail == SessionWorkDetail.backgroundShell)
    #expect(downgraded.lastEvent == "SubagentStop")
    #expect(downgraded.updatedAt == Date(timeIntervalSince1970: 260))

    // A manual compact at that prompt keeps the bounded hold, as it does for Stop.
    try applyDecodedHook(
        event: "PostCompact", json: #"{"session_id":"parent","cwd":"/work/app","trigger":"manual"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 270), storage: storage
    )
    #expect(storage.load(id: parentID)?.detail == SessionWorkDetail.backgroundShell)
}

@Test func subagentStopWithOnlyItselfListedMakesTheParentIdle() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let parentID = hookUpdaterID("parent", agent: .claude)

    try applyDecodedHook(
        event: "UserPromptSubmit", json: #"{"session_id":"parent","cwd":"/work/app"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    try applyDecodedHook(
        event: "SubagentStart", json: #"{"session_id":"parent","agent_id":"child","cwd":"/work/app"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 101), storage: storage
    )
    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"parent","cwd":"/work/app","background_tasks":[{"id":"child","type":"subagent","status":"running"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )
    try applyDecodedHook(
        event: "SubagentStop",
        json: #"{"session_id":"parent","agent_id":"child","cwd":"/work/app","background_tasks":[{"id":"child","type":"subagent","status":"running"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 260), storage: storage
    )
    let parent = try #require(storage.load(id: parentID))
    #expect(parent.state == .idle)
    #expect(parent.lastEvent == "SubagentStop")
    #expect(Set(storage.loadAll().map(\.id)) == [parentID])
}

@Test func subagentStopKeepsAParentWithOtherAgentWorkOrAnExistingShellHold() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let parentID = hookUpdaterID("parent", agent: .claude)

    try applyDecodedHook(
        event: "UserPromptSubmit", json: #"{"session_id":"parent","cwd":"/work/app"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    for child in ["child-a", "child-b"] {
        try applyDecodedHook(
            event: "SubagentStart", json: #"{"session_id":"parent","agent_id":"\#(child)","cwd":"/work/app"}"#,
            agent: .claude, observedAt: Date(timeIntervalSince1970: 101), storage: storage
        )
    }
    try applyDecodedHook(
        event: "Stop",
        json: #"{"session_id":"parent","cwd":"/work/app","background_tasks":[{"id":"child-a","type":"subagent","status":"running"},{"id":"child-b","type":"subagent","status":"running"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 200), storage: storage
    )
    try applyDecodedHook(
        event: "SubagentStop",
        json: #"{"session_id":"parent","agent_id":"child-a","cwd":"/work/app","background_tasks":[{"id":"child-a","type":"subagent","status":"running"},{"id":"child-b","type":"subagent","status":"running"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 260), storage: storage
    )
    #expect(storage.load(id: parentID)?.detail == SessionWorkDetail.backgroundAgent)

    // The second child leaves a shell behind: a bounded hold starts at 300.
    try applyDecodedHook(
        event: "SubagentStop",
        json: #"{"session_id":"parent","agent_id":"child-b","cwd":"/work/app","background_tasks":[{"id":"sh","type":"shell","status":"running"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 300), storage: storage
    )
    var parent = try #require(storage.load(id: parentID))
    #expect(parent.detail == SessionWorkDetail.backgroundShell)
    #expect(parent.updatedAt == Date(timeIntervalSince1970: 300))

    // A later shell-only snapshot does not restart that hold.
    try applyDecodedHook(
        event: "SubagentStart", json: #"{"session_id":"parent","agent_id":"child-c","cwd":"/work/app"}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 350), storage: storage
    )
    try applyDecodedHook(
        event: "SubagentStop",
        json: #"{"session_id":"parent","agent_id":"child-c","cwd":"/work/app","background_tasks":[{"id":"sh","type":"shell","status":"running"}]}"#,
        agent: .claude, observedAt: Date(timeIntervalSince1970: 400), storage: storage
    )
    parent = try #require(storage.load(id: parentID))
    #expect(parent.detail == SessionWorkDetail.backgroundShell)
    #expect(parent.updatedAt == Date(timeIntervalSince1970: 300))
}

/// Applies `(event, extra payload fields)` pairs one second apart.
private func applyHooks(
    _ events: [(String, String)],
    agent: AgentID = .claude,
    sessionID: String,
    from start: TimeInterval,
    storage: SessionStorage
) throws {
    for (offset, (event, extra)) in events.enumerated() {
        try applyDecodedHook(
            event: event,
            json: #"{"session_id":"\#(sessionID)","cwd":"/work/app","hook_event_name":"\#(event)"\#(extra)}"#,
            agent: agent,
            observedAt: Date(timeIntervalSince1970: start + TimeInterval(offset)),
            storage: storage
        )
    }
}

private func compactionHooks(trigger: String) -> [(String, String)] {
    [("PreCompact", #","trigger":"\#(trigger)","custom_instructions":null"#),
     ("SessionStart", #","source":"compact""#),
     ("PostCompact", #","trigger":"\#(trigger)","compact_summary":"summary""#)]
}

/// Applies Claude events one second apart, with the payload fields Claude Code
/// sends for each compaction edge.
private func applyClaudeCompactHooks(
    _ events: [String],
    sessionID: String,
    trigger: String,
    from start: TimeInterval,
    storage: SessionStorage
) throws {
    for (offset, event) in events.enumerated() {
        let extra = switch event {
        case "PreCompact": #","trigger":"\#(trigger)","custom_instructions":null"#
        case "PostCompact": #","trigger":"\#(trigger)","compact_summary":"summary""#
        case "SessionStart": #","source":"compact""#
        default: ""
        }
        try applyDecodedHook(
            event: event,
            json: #"{"session_id":"\#(sessionID)","cwd":"/work/app","hook_event_name":"\#(event)"\#(extra)}"#,
            agent: .claude,
            observedAt: Date(timeIntervalSince1970: start + TimeInterval(offset)),
            storage: storage
        )
    }
}

private func applyDecodedHook(
    event: String,
    json: String,
    agent: AgentID,
    observedAt: Date,
    storage: SessionStorage
) throws {
    let payload = try JSONDecoder().decode(HookPayload.self, from: Data(json.utf8))
    try HookSessionUpdater.apply(
        event: event,
        payload: payload,
        agent: agent,
        agentPID: nil,
        observedAt: observedAt,
        storage: storage
    )
}

private func hookUpdaterTempDirectory() -> URL {
    let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("letitbrew-hook-updater-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func hookUpdaterID(
    _ parentID: String,
    agent: AgentID = .codex,
    childID: String? = nil,
    event: String = "Stop"
) -> String {
    guard let id = HookPayload(sessionId: parentID, agentId: childID)
        .recordID(agent: agent, event: event)
    else { preconditionFailure("test hook identity must be valid") }
    return id
}

private func hookUpdaterRecord(id: String, observedAt: TimeInterval) -> SessionRecord {
    SessionRecord(
        id: id,
        tool: "codex",
        state: .idle,
        detail: nil,
        cwd: "/work/app",
        pid: nil,
        updatedAt: Date(timeIntervalSince1970: observedAt),
        eventObservedAt: observedAt
    )
}

private func hookUpdaterEntryObject(
    id: String,
    directory: URL
) throws -> [String: Any]? {
    let data = try Data(contentsOf: directory.appendingPathComponent(
        SessionStorage.safeFilename(for: id)
    ))
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func hookUpdaterActiveURL(id: String, directory: URL) -> URL {
    directory.appendingPathComponent(SessionStorage.safeFilename(for: id))
}

private func hookUpdaterTombstoneURL(id: String, directory: URL) -> URL {
    directory
        .appendingPathComponent(".locks", isDirectory: true)
        .appendingPathComponent(SessionStorage.safeFilename(for: id) + ".tombstone")
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [any Error] = []

    var values: [any Error] {
        lock.withLock { storage }
    }

    func append(_ error: any Error) {
        lock.withLock { storage.append(error) }
    }
}

@Test func codexStopDuringAQuestionStillClearsSilentChildren() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let parent = hookUpdaterID("codex-question")
    let child = hookUpdaterID("codex-question", childID: "silent")

    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-question",
                   from: 100, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"silent""#)], agent: .codex,
                   sessionID: "codex-question", from: 50, storage: storage)
    try applyHooks([("PreToolUse", #","tool_name":"request_user_input""#)], agent: .codex,
                   sessionID: "codex-question", from: 110, storage: storage)
    #expect(storage.load(id: parent)?.state == .waiting)

    // A question the turn abandons ends with Stop while the parent waits.
    try applyHooks([("Stop", "")], agent: .codex, sessionID: "codex-question",
                   from: 120, storage: storage)
    #expect(storage.load(id: parent)?.state == .idle)
    #expect(storage.load(id: child) == nil)
}

@Test func aDelayedCopilotSessionStartCannotEndAWait() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let id = hookUpdaterID("copilot-late-start", agent: .copilot)

    try applyHooks([
        ("UserPromptSubmit", ""), ("Notification", #","notification_type":"permission_prompt""#),
    ], agent: .copilot, sessionID: "copilot-late-start", from: 100, storage: storage)
    try applyHooks([("SessionStart", "")], agent: .copilot,
                   sessionID: "copilot-late-start", from: 102, storage: storage)
    #expect(storage.load(id: id)?.state == .waiting)
}

@Test func aHookWithoutAnAgentPIDKeepsTheKnownOne() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let payload = HookPayload(sessionId: "pid-keep", cwd: "/work/app")
    let id = hookUpdaterID("pid-keep", agent: .claude)

    try HookSessionUpdater.apply(
        event: "UserPromptSubmit", payload: payload, agent: .claude, agentPID: 4_321,
        observedAt: Date(timeIntervalSince1970: 100), storage: storage
    )
    try HookSessionUpdater.apply(
        event: "PreToolUse", payload: payload, agent: .claude, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: 101), storage: storage
    )
    #expect(storage.load(id: id)?.pid == 4_321)

    try HookSessionUpdater.apply(
        event: "PostToolUse", payload: payload, agent: .claude, agentPID: 9_876,
        observedAt: Date(timeIntervalSince1970: 102), storage: storage
    )
    #expect(storage.load(id: id)?.pid == 9_876)
}

@Test func claudeWaitsFollowTheShownPromptAndTheAnswer() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let id = hookUpdaterID("claude-wait", agent: .claude)

    try applyHooks([("UserPromptSubmit", ""), ("PermissionRequest", #","tool_name":"Bash""#)],
                   sessionID: "claude-wait", from: 100, storage: storage)
    // The request alone may be settled by another hook or auto mode.
    #expect(storage.load(id: id)?.state == .working)

    try applyHooks([("Notification", #","notification_type":"permission_prompt""#)],
                   sessionID: "claude-wait", from: 107, storage: storage)
    let waiting = try #require(storage.load(id: id))
    #expect(waiting.state == .waiting)
    #expect(waiting.detail == SessionWaitDetail.approval)

    try applyHooks([("PostToolUse", #","tool_name":"Bash""#)],
                   sessionID: "claude-wait", from: 400, storage: storage)
    #expect(storage.load(id: id)?.state == .working)

    try applyHooks([("PreToolUse", #","tool_name":"AskUserQuestion""#)],
                   sessionID: "claude-wait", from: 500, storage: storage)
    #expect(storage.load(id: id)?.detail == SessionWaitDetail.question)
    try applyHooks([("PostToolUse", #","tool_name":"AskUserQuestion""#)],
                   sessionID: "claude-wait", from: 520, storage: storage)
    #expect(storage.load(id: id)?.state == .working)
}

@Test func aCodexChildHeardBeforeAnAnsweredQuestionSurvivesTheTurnEnd() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let child = hookUpdaterID("codex-answered", childID: "heard")

    try applyHooks([("UserPromptSubmit", "")], agent: .codex, sessionID: "codex-answered",
                   from: 100, storage: storage)
    try applyHooks([("SubagentStart", #","agent_id":"heard""#)], agent: .codex,
                   sessionID: "codex-answered", from: 105, storage: storage)
    try applyHooks([
        ("PreToolUse", #","tool_name":"request_user_input""#),
        ("PostToolUse", #","tool_name":"request_user_input""#),
    ], agent: .codex, sessionID: "codex-answered", from: 110, storage: storage)
    try applyHooks([("Stop", "")], agent: .codex, sessionID: "codex-answered",
                   from: 200, storage: storage)

    // Heard during the turn, so it may still be running.
    #expect(storage.load(id: child)?.state == .working)
}
