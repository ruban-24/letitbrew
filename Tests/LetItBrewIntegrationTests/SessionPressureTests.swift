import Foundation
import LetItBrewAppCore
import LetItBrewCore
import Testing

@Test func concurrentSessionCountMatrixPreservesEveryIndependentRecord() async throws {
    for count in [1, 2, 10, 15, 50, 100] {
        let directory = pressureTempDirectory(label: "matrix-\(count)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = try await writeConcurrentSessions(
            count: count,
            cwd: "/private/tmp/pressure/shared-folder",
            directory: directory
        )

        #expect(records.count == count)
        #expect(Set(records.map(\.id)).count == count)
        #expect(Set(records.map(\.repositoryID)) == [
            "/private/tmp/pressure/shared-folder"
        ])
    }
}

@Test func pressureSnapshotPreservesAgentAndFullRepositoryAttribution() async throws {
    let directory = pressureTempDirectory(label: "attribution")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try HookSessionUpdater.apply(
                event: "UserPromptSubmit",
                payload: HookPayload(sessionId: "claude", cwd: "/private/tmp/one/app"),
                agent: .claude,
                agentPID: 101,
                observedAt: Date(timeIntervalSince1970: 101),
                storage: storage
            )
        }
        group.addTask {
            try HookSessionUpdater.apply(
                event: "PreToolUse",
                payload: HookPayload(
                    sessionId: "codex",
                    cwd: "/private/tmp/two/app",
                    toolName: "Read"
                ),
                agent: .codex,
                agentPID: 202,
                observedAt: Date(timeIntervalSince1970: 202),
                storage: storage
            )
        }
        try await group.waitForAll()
    }

    let records = storage.loadAll()
    #expect(Set(records.map(\.tool)) == ["claude", "codex"])
    #expect(Set(records.map(\.repoName)) == ["app"])
    #expect(Set(records.map(\.repositoryID)) == [
        "/private/tmp/one/app", "/private/tmp/two/app"
    ])
}

@Test func oneStoppedSessionDoesNotChangeNinetyNineWorkingSessions() async throws {
    let directory = pressureTempDirectory(label: "one-stop")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    _ = try await writeConcurrentSessions(
        count: 100,
        cwd: "/private/tmp/pressure/shared-folder",
        directory: directory
    )

    try HookSessionUpdater.apply(
        event: "Stop",
        payload: HookPayload(
            sessionId: pressureSessionID(0),
            cwd: "/private/tmp/pressure/shared-folder"
        ),
        agent: .claude,
        agentPID: 1_000,
        observedAt: Date(timeIntervalSince1970: 10_000),
        storage: storage
    )

    let records = storage.loadAll()
    #expect(records.count == 100)
    #expect(records.count { $0.state == .working } == 99)
    #expect(records.count { $0.state == .idle } == 1)
}

@Test func corruptRecordBesideOneHundredHealthyRecordsIsIsolated() async throws {
    let directory = pressureTempDirectory(label: "corrupt")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    _ = try await writeConcurrentSessions(
        count: 100,
        cwd: "/private/tmp/pressure/shared-folder",
        directory: directory
    )
    try Data("{not-json".utf8).write(
        to: directory.appendingPathComponent("corrupt.json")
    )

    let records = storage.loadAll()
    #expect(records.count == 100)
    #expect(Set(records.map(\.id)).count == 100)
}

@Test func aggregateHoldReleasesOnlyAfterTheLastWorkingSessionStops() async throws {
    let directory = pressureTempDirectory(label: "aggregate-hold")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    _ = try await writeConcurrentSessions(
        count: 100,
        cwd: "/private/tmp/pressure/shared-folder",
        directory: directory
    )
    var settings = Settings()
    settings.lidClosedFollowsSession = true
    let power = PowerState(
        onBattery: false,
        batteryPercent: 100,
        thermal: .nominal
    )

    for index in 0..<100 {
        try HookSessionUpdater.apply(
            event: "Stop",
            payload: HookPayload(
                sessionId: pressureSessionID(index),
                cwd: "/private/tmp/pressure/shared-folder"
            ),
            agent: index.isMultiple(of: 2) ? .claude : .codex,
            agentPID: Int32(index + 1),
            observedAt: Date(timeIntervalSince1970: TimeInterval(20_000 + index)),
            storage: storage
        )
        let decision = decide(
            sessions: storage.loadAll(),
            now: Date(timeIntervalSince1970: 30_000),
            settings: settings,
            power: power
        )
        #expect(decision.holdSystem == (index < 99))
        #expect(decision.holdLidClosed == (index < 99))
    }
}

@Test func oneHundredRecordWriteLoadAndPresentationReportsTiming() async throws {
    let directory = pressureTempDirectory(label: "metric")
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = ContinuousClock()
    let started = clock.now

    let records = try await writeConcurrentSessions(
        count: 100,
        cwd: "/private/tmp/pressure/shared-folder",
        directory: directory
    )
    let now = Date(timeIntervalSince1970: 5_000)
    let rows = MenuSessionPresentationPolicy.rows(
        from: records.map { record in
            SessionMenuInput(
                id: record.id,
                tool: record.tool,
                project: record.repoName,
                repositoryPath: record.repositoryID,
                state: record.state == .working ? .working : .idle,
                activeWorkingTime: record.activeWorkingTime(at: now),
                updatedAt: record.updatedAt
            )
        },
        now: now
    )
    let groups = MenuRepositoryPresentationPolicy.groups(from: rows)
    let elapsed = started.duration(to: clock.now)
    let elapsedSeconds = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000

    #expect(records.count == 100)
    #expect(rows.count == 100)
    #expect(groups.count == 1)
    print("METRIC session-pressure-100-seconds=\(elapsedSeconds)")
}

private func writeConcurrentSessions(
    count: Int,
    cwd: String,
    directory: URL
) async throws -> [SessionRecord] {
    let storage = SessionStorage(directory: directory)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<count {
            group.addTask {
                try HookSessionUpdater.apply(
                    event: index.isMultiple(of: 3) ? "PreToolUse" : "UserPromptSubmit",
                    payload: HookPayload(
                        sessionId: pressureSessionID(index),
                        cwd: cwd,
                        toolName: index.isMultiple(of: 3) ? "Read" : nil
                    ),
                    agent: index.isMultiple(of: 2) ? .claude : .codex,
                    agentPID: Int32(index + 1),
                    observedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
                    storage: storage
                )
            }
        }
        try await group.waitForAll()
    }
    return storage.loadAll()
}

private func pressureSessionID(_ index: Int) -> String {
    "pressure-session-\(index)"
}

private func pressureTempDirectory(label: String) -> URL {
    let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent(
            "letitbrew-pressure-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
