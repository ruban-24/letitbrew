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
        event: "PermissionRequest",
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

@Test func compactSessionLifecycleStaysWorkingThroughStorage() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let timestamp = Date(timeIntervalSince1970: 100)

    try applyDecodedHook(
        event: "SessionStart",
        json: #"{"session_id":"compact-parent","cwd":"/work/app","source":"compact"}"#,
        agent: .claude,
        observedAt: timestamp,
        storage: storage
    )
    let id = try #require(HookPayload(sessionId: "compact-parent")
        .recordID(agent: .claude, event: "SessionStart"))
    let transitionID = try #require(storage.load(id: id)?.stateTransitionID)

    try applyDecodedHook(
        event: "PreCompact",
        json: #"{"session_id":"compact-parent","cwd":"/work/app"}"#,
        agent: .claude,
        observedAt: timestamp.addingTimeInterval(1),
        storage: storage
    )
    try applyDecodedHook(
        event: "PostCompact",
        json: #"{"session_id":"compact-parent","cwd":"/work/app"}"#,
        agent: .claude,
        observedAt: timestamp.addingTimeInterval(2),
        storage: storage
    )

    let record = try #require(storage.load(id: id))
    #expect(record.state == .working)
    #expect(record.lastEvent == "PostCompact")
    #expect(record.stateTransitionID == transitionID)
    #expect(storage.loadAll().count == 1)
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

@Test func stopFailureBecomesIdleThroughStorage() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    try applyDecodedHook(
        event: "StopFailure",
        json: #"{"session_id":"failed-stop","cwd":"/work/app"}"#,
        agent: .claude,
        observedAt: Date(timeIntervalSince1970: 100),
        storage: storage
    )

    let id = try #require(HookPayload(sessionId: "failed-stop")
        .recordID(agent: .claude, event: "StopFailure"))
    #expect(storage.load(id: id)?.state == .idle)
    #expect(storage.load(id: id)?.lastEvent == "StopFailure")
}

@Test func subagentStopRemovesOnlyTheAddressedChildRecord() throws {
    let directory = hookUpdaterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

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
    #expect(Set(storage.loadAll().map(\.id)) == [firstID, secondID])

    try applyDecodedHook(
        event: "SubagentStop",
        json: #"{"session_id":"parent","agent_id":"child-a"}"#,
        agent: .claude,
        observedAt: Date(timeIntervalSince1970: 102),
        storage: storage
    )

    #expect(storage.load(id: firstID) == nil)
    #expect(storage.load(id: secondID)?.state == .working)
    #expect(storage.loadAll().map(\.id) == [secondID])
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
