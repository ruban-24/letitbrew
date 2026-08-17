import Foundation
import LetItBrewAppCore
import LetItBrewCore
import Testing

@Test func concurrentSessionCountMatrixPreservesEveryIndependentRecord() async throws {
    for count in pressureCounts() {
        let directory = try pressureTempDirectory(label: "matrix-\(count)")
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

@Test func directPressureFixtureUsesItsOwnValidatedPrivateRoot() throws {
    let directory = try pressureTempDirectory(label: "direct-root")
    defer { try? FileManager.default.removeItem(at: directory) }

    let root = directory.path
    #expect(root.hasPrefix("/private/tmp/letitbrew-session-pressure."))
}

@Test func suppliedPressureRootContainsEveryFixtureDirectory() throws {
    let root = try pressureTempDirectory(label: "supplied-root")
    defer { try? FileManager.default.removeItem(at: root) }
    let child = try pressureTempDirectory(label: "records", suppliedRoot: root.path)

    #expect(child.path.hasPrefix(root.path + "/"))
    #expect(child.path.contains("/records-records-"))
}

@Test func hundredConcurrentSessionsRoundRobinEverySupportedAgentAndHoldTheSystem() async throws {
    let directory = try pressureTempDirectory(label: "five-agent-hundred")
    defer { try? FileManager.default.removeItem(at: directory) }

    let records = try await writeConcurrentSessions(
        count: 100,
        cwd: "/private/tmp/pressure/shared-folder",
        directory: directory
    )

    #expect(records.count == 100)
    #expect(Set(records.map(\.tool)) == Set(AgentID.allCases.map(\.rawValue)))
    #expect(Dictionary(grouping: records, by: \.tool).values.allSatisfy { $0.count == 20 })
    let decision = decide(
        sessions: records,
        now: Date(timeIntervalSince1970: 2_000),
        settings: Settings(),
        power: PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
    )
    #expect(decision.holdSystem)
}

@Test func pressureSnapshotPreservesAgentAndFullRepositoryAttribution() async throws {
    let directory = try pressureTempDirectory(label: "attribution")
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
    let directory = try pressureTempDirectory(label: "one-stop")
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
        agent: pressureAgent(0),
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
    let directory = try pressureTempDirectory(label: "corrupt")
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
    let directory = try pressureTempDirectory(label: "aggregate-hold")
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
            agent: pressureAgent(index),
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

@Test func newerIdleEventWinsOverAnOlderWorkingEventForEveryAgent() throws {
    let directory = try pressureTempDirectory(label: "event-race")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)

    for (index, agent) in AgentID.allCases.enumerated() {
        let sessionID = "race-\(agent.rawValue)"
        try HookSessionUpdater.apply(
            event: "UserPromptSubmit",
            payload: HookPayload(sessionId: sessionID, cwd: "/private/tmp/pressure/race"),
            agent: agent,
            agentPID: Int32(index + 1),
            observedAt: Date(timeIntervalSince1970: 100),
            storage: storage
        )
        try HookSessionUpdater.apply(
            event: "Stop",
            payload: HookPayload(sessionId: sessionID, cwd: "/private/tmp/pressure/race"),
            agent: agent,
            agentPID: Int32(index + 1),
            observedAt: Date(timeIntervalSince1970: 200),
            storage: storage
        )
        try HookSessionUpdater.apply(
            event: "PreToolUse",
            payload: HookPayload(sessionId: sessionID, cwd: "/private/tmp/pressure/race", toolName: "Read"),
            agent: agent,
            agentPID: Int32(index + 1),
            observedAt: Date(timeIntervalSince1970: 150),
            storage: storage
        )
    }

    #expect(storage.loadAll().count == AgentID.allCases.count)
    #expect(storage.loadAll().allSatisfy { $0.state == .idle })
}

@Test func disconnectedFifthAgentStaysStoredButCannotHoldTheSystem() async throws {
    let directory = try pressureTempDirectory(label: "visibility")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = SessionStorage(directory: directory)
    let records = try await writeConcurrentSessions(
        count: AgentID.allCases.count,
        cwd: "/private/tmp/pressure/shared-folder",
        directory: directory
    )
    let disconnected = AgentID.allCases.last!

    for (index, agent) in AgentID.allCases.dropLast().enumerated() {
        try HookSessionUpdater.apply(
            event: "Stop",
            payload: HookPayload(sessionId: pressureSessionID(index), cwd: "/private/tmp/pressure/shared-folder"),
            agent: agent,
            agentPID: Int32(index + 1),
            observedAt: Date(timeIntervalSince1970: 10_000),
            storage: storage
        )
    }

    let application = AgentSessionVisibilityPipeline.apply(
        sessions: storage.loadAll(),
        connectedAgentIDs: Set(AgentID.allCases.dropLast().map(\.rawValue)),
        suppressions: []
    )
    #expect(records.contains { $0.tool == disconnected.rawValue && $0.state == .working })
    #expect(storage.loadAll().contains { $0.tool == disconnected.rawValue && $0.state == .working })
    #expect(application.sessions.contains { $0.tool == disconnected.rawValue } == false)
    let decision = decide(
        sessions: application.sessions,
        now: Date(timeIntervalSince1970: 11_000),
        settings: Settings(),
        power: PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
    )
    #expect(!decision.holdSystem)
    #expect(!decision.holdLidClosed)
}

@Test func childSessionsRemainIndependentOfSiblingAndParentStops() throws {
    for (agentIndex, agent) in [AgentID.claude, .codex, .cursor].enumerated() {
        let directory = try pressureTempDirectory(label: "children-\(agent.rawValue)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SessionStorage(directory: directory)
        let parent = "parent-\(agent.rawValue)"
        let childA = HookRecordID(agent: agent, parentID: parent, childID: "child-a")!.encoded
        let childB = HookRecordID(agent: agent, parentID: parent, childID: "child-b")!.encoded
        let parentID = HookRecordID(agent: agent, parentID: parent)!.encoded
        for child in ["child-a", "child-b"] {
            let payload = agent == .cursor
                ? HookPayload(sessionId: parent, parentConversationId: parent, subagentId: child, cwd: "/private/tmp/pressure/children")
                : HookPayload(sessionId: parent, agentId: child, cwd: "/private/tmp/pressure/children")
            try HookSessionUpdater.apply(
                event: "SubagentStart",
                payload: payload,
                agent: agent,
                agentPID: Int32(agentIndex + 1),
                observedAt: Date(timeIntervalSince1970: 100),
                storage: storage
            )
        }

        let stoppedChild = agent == .cursor
            ? HookPayload(sessionId: parent, parentConversationId: parent, subagentId: "child-a", cwd: "/private/tmp/pressure/children")
            : HookPayload(sessionId: parent, agentId: "child-a", cwd: "/private/tmp/pressure/children")
        try HookSessionUpdater.apply(
            event: "SubagentStop",
            payload: stoppedChild,
            agent: agent,
            agentPID: Int32(agentIndex + 1),
            observedAt: Date(timeIntervalSince1970: 200),
            storage: storage
        )
        #expect(Set(storage.loadAll().map(\.id)) == [childB])
        #expect(storage.load(id: childA) == nil)
        #expect(storage.load(id: childB)?.state == .working)
        #expect(storage.load(id: parentID) == nil)
        let childOnlyDecision = decide(
            sessions: storage.loadAll(),
            now: Date(timeIntervalSince1970: 250),
            settings: Settings(),
            power: PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
        )
        #expect(childOnlyDecision.holdSystem)
        #expect(childOnlyDecision.holdLidClosed)
        try HookSessionUpdater.apply(
            event: "Stop",
            payload: HookPayload(sessionId: parent, cwd: "/private/tmp/pressure/children"),
            agent: agent,
            agentPID: Int32(agentIndex + 1),
            observedAt: Date(timeIntervalSince1970: 300),
            storage: storage
        )
        #expect(Set(storage.loadAll().map(\.id)) == [childB, parentID])
        #expect(storage.load(id: childA) == nil)
        #expect(storage.load(id: childB)?.state == .working)
        #expect(storage.load(id: parentID)?.state == .idle)
        let parentStopDecision = decide(
            sessions: storage.loadAll(),
            now: Date(timeIntervalSince1970: 350),
            settings: Settings(),
            power: PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
        )
        #expect(parentStopDecision.holdSystem)
        #expect(parentStopDecision.holdLidClosed)
    }
}

@Test func oneHundredRecordWriteLoadAndPresentationReportsTiming() async throws {
    let directory = try pressureTempDirectory(label: "metric")
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
                    agent: pressureAgent(index),
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

private func pressureAgent(_ index: Int) -> AgentID {
    let agents = pressureAgents()
    return agents[index % agents.count]
}

private func pressureCounts() -> [Int] {
    let configured = ProcessInfo.processInfo.environment["LETITBREW_SESSION_PRESSURE_COUNTS"]
    let counts = configured?
        .split(separator: ",")
        .compactMap { Int($0) }
    return (counts?.isEmpty == false ? counts! : [1, 10, 15, 50, 100])
}

private func pressureAgents() -> [AgentID] {
    let configured = ProcessInfo.processInfo.environment["LETITBREW_SESSION_PRESSURE_AGENTS"]
    let agents = configured?
        .split(separator: ",")
        .compactMap { AgentID(rawValue: String($0)) }
    return Set(agents ?? []) == Set(AgentID.allCases) ? agents! : AgentID.allCases
}

private enum PressureFixtureError: Error {
    case invalidRoot(String)
}

private func pressureTempDirectory(
    label: String,
    suppliedRoot: String? = ProcessInfo.processInfo.environment["LETITBREW_SESSION_PRESSURE_ROOT"]
) throws -> URL {
    if let suppliedRoot {
        let root = try validatedPressureRoot(URL(fileURLWithPath: suppliedRoot, isDirectory: true))
        let directory = root.appendingPathComponent("records-\(label)-\(UUID().uuidString)", isDirectory: true)
        guard directory.path.hasPrefix(root.path + "/") else {
            throw PressureFixtureError.invalidRoot(directory.path)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent(
            "letitbrew-session-pressure.\(label).\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return try validatedPressureRoot(directory)
}

private func validatedPressureRoot(_ candidate: URL) throws -> URL {
    guard candidate.path.hasPrefix("/private/tmp/letitbrew-session-pressure.") else {
        throw PressureFixtureError.invalidRoot(candidate.path)
    }
    let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw PressureFixtureError.invalidRoot(candidate.path)
    }
    return candidate
}
