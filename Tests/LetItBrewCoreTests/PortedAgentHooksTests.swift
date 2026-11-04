import Foundation
import Testing
@testable import LetItBrewCore

private let cli = "/opt/letitbrew"

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Runs a generated hook command the way the agent would.
private func run(
    _ command: String, environment: [String: String] = [:], shell: String = "/bin/sh"
) throws -> (status: Int32, stdout: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-c", command]
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (process.terminationStatus, stdout)
}

/// A helper that records each argument list, then fails. Hooks must hide both.
private func makeHelper() throws -> (url: URL, log: URL, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-ported-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let helper = directory.appendingPathComponent("helper")
    let log = directory.appendingPathComponent("log")
    try "#!/bin/sh\necho \"$@\" >> '\(log.path)'\necho noisy\nexit 7\n"
        .write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    return (helper, log, directory)
}

// MARK: - Claude-style adapters

@Test func geminiAndQwenPathsFollowTheirHomeOverrides() {
    let home = URL(fileURLWithPath: "/Users/me")
    #expect(GeminiHooks.settingsURL(home: home, environment: [:]).path == "/Users/me/.gemini/settings.json")
    #expect(GeminiHooks.settingsURL(home: home, environment: ["GEMINI_CLI_HOME": "/alt"]).path
        == "/alt/.gemini/settings.json")
    #expect(QwenHooks.settingsURL(home: home, environment: [:]).path == "/Users/me/.qwen/settings.json")
    #expect(QwenHooks.settingsURL(home: home, environment: ["QWEN_HOME": "/alt/q"]).path == "/alt/q/settings.json")
}

@Test func geminiEventsReachTheReducerUnderItsNames() throws {
    let root = try jsonObject(try GeminiHooks.adapter.install(into: nil, cliPath: cli))
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(Set(hooks.keys) == [
        "SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent", "SessionEnd",
    ])
    let groups = try #require(hooks["AfterAgent"] as? [[String: Any]])
    #expect(groups.count == 1)
    #expect(groups[0]["matcher"] == nil)
    let entry = try #require((groups[0]["hooks"] as? [[String: Any]])?.first)
    #expect(entry["timeout"] as? Int == 5_000)
    #expect(entry["name"] as? String == "Let It Brew")
    let command = try #require(entry["command"] as? String)
    #expect(command.contains("hook gemini Stop >/dev/null 2>&1"))
    #expect(command.hasSuffix(HookFile.ownershipComment(marker: GeminiHooks.marker)))
    #expect(try GeminiHooks.adapter.hookCommand(event: "BeforeAgent", cliPath: cli)
        .contains("hook gemini UserPromptSubmit "))
}

@Test func qwenInstallsNoEventThatFiresBeforeItDecides() throws {
    #expect(QwenHooks.adapter.events["PermissionRequest"] == nil)
    let root = try jsonObject(try QwenHooks.adapter.install(into: nil, cliPath: cli))
    let stop = try #require((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
    #expect((stop[0]["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == 5)
}

@Test(arguments: [GeminiHooks.adapter, QwenHooks.adapter])
func claudeStyleAdaptersKeepForeignSettingsAndRoundTrip(adapter: ClaudeStyleHooks) throws {
    let foreign = Data("""
    {"theme":"dark","hooks":{"AfterAgent":[{"hooks":[{"type":"command","command":"mine"}]}],
    "Stop":[{"hooks":[{"type":"command","command":"also mine"}]}]}}
    """.utf8)
    let once = try adapter.install(into: foreign, cliPath: cli)
    let twice = try adapter.install(into: once, cliPath: cli)
    #expect(try jsonObject(once) as NSDictionary == jsonObject(twice) as NSDictionary)
    #expect(adapter.report(for: once, cliPath: cli).isHealthy)
    #expect(!adapter.report(for: once, cliPath: "/moved/letitbrew").isHealthy)

    let removed = try adapter.remove(from: twice)
    #expect(try jsonObject(removed) as NSDictionary == jsonObject(foreign) as NSDictionary)
    #expect(adapter.report(for: removed, cliPath: cli).isAbsent)
}

@Test(arguments: [GeminiHooks.adapter, QwenHooks.adapter])
func claudeStyleAdaptersRefuseWhatTheyCannotRoundTrip(adapter: ClaudeStyleHooks) {
    // Both CLIs accept comments in settings.json. A rewrite would lose them.
    for bytes in ["", "[]", "{\"hooks\":3}", "{\"hooks\":{\"Stop\":{}}}", "// note\n{}"] {
        #expect(throws: ClaudeHooks.SettingsUnreadable.self) {
            try adapter.install(into: Data(bytes.utf8), cliPath: cli)
        }
    }
    #expect(throws: ClaudeHooks.RelativeCLIPath.self) {
        try adapter.install(into: nil, cliPath: "relative/letitbrew")
    }
}

@Test(arguments: [GeminiHooks.adapter, QwenHooks.adapter])
func claudeStyleCommandsAreSilentAndFailOpen(adapter: ClaudeStyleHooks) throws {
    let helper = try makeHelper()
    defer { try? FileManager.default.removeItem(at: helper.directory) }
    let result = try run(try adapter.hookCommand(event: "Notification", cliPath: helper.url.path))
    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    #expect(try String(contentsOf: helper.log, encoding: .utf8)
        == "hook \(adapter.agent.rawValue) Notification\n")
}

// MARK: - Cursor

@Test func cursorSkipsEveryEventThatMustAnswerForPermission() {
    for event in ["preToolUse", "beforeShellExecution", "beforeMCPExecution"] {
        #expect(CursorHooks.events[event] == nil)
    }
    #expect(CursorHooks.hooksURL(home: URL(fileURLWithPath: "/Users/me")).path == "/Users/me/.cursor/hooks.json")
}

@Test func cursorCommandsRepliesOnlyWhereCursorExpectsOne() throws {
    let helper = try makeHelper()
    defer { try? FileManager.default.removeItem(at: helper.directory) }
    let prompt = try run(try CursorHooks.hookCommand(event: "beforeSubmitPrompt", cliPath: helper.url.path))
    #expect(prompt.status == 0)
    #expect(prompt.stdout == "{\"continue\":true}\n")
    let stop = try run(try CursorHooks.hookCommand(event: "stop", cliPath: helper.url.path))
    #expect(stop.status == 0)
    #expect(stop.stdout.isEmpty)
    #expect(try String(contentsOf: helper.log, encoding: .utf8)
        == "hook cursor UserPromptSubmit\nhook cursor Stop\n")
}

@Test func cursorPromptStillRepliesWhenTheHelperIsGone() throws {
    let result = try run(try CursorHooks.hookCommand(event: "beforeSubmitPrompt", cliPath: "/nonexistent/letitbrew"))
    #expect(result.status == 0)
    #expect(result.stdout == "{\"continue\":true}\n")
}

@Test func cursorKeepsAnotherToolsEntriesAndRoundTrips() throws {
    let orca = #"{"command":"/bin/sh -c 'orca-hook'","timeout":10}"#
    let foreign = Data("""
    {"version":1,"note":"keep","hooks":{"stop":[\(orca)],"preToolUse":[\(orca)]}}
    """.utf8)
    let once = try CursorHooks.install(into: foreign, cliPath: cli)
    let twice = try CursorHooks.install(into: once, cliPath: cli)
    #expect(try jsonObject(once) as NSDictionary == jsonObject(twice) as NSDictionary)
    let hooks = try #require(try jsonObject(once)["hooks"] as? [String: Any])
    #expect((hooks["stop"] as? [Any])?.count == 2)
    #expect((hooks["preToolUse"] as? [Any])?.count == 1)
    #expect(CursorHooks.report(for: once, cliPath: cli).isHealthy)
    #expect(!CursorHooks.report(for: once, cliPath: "/moved/letitbrew").isHealthy)

    let removed = try CursorHooks.remove(from: twice)
    #expect(try jsonObject(removed) as NSDictionary == jsonObject(foreign) as NSDictionary)
    #expect(CursorHooks.report(for: removed, cliPath: cli).isAbsent)
}

@Test func cursorRefusesAVersionOrShapeItDoesNotKnow() {
    for bytes in ["", "[]", "{\"version\":2}", "{\"version\":true}", "{\"hooks\":{\"stop\":{}}}"] {
        #expect(throws: ClaudeHooks.SettingsUnreadable.self) {
            try CursorHooks.install(into: Data(bytes.utf8), cliPath: cli)
        }
    }
}

@Test func claudeHooksStandDownOnlyWhenConnectedCursorReplaysThem() throws {
    let helper = try makeHelper()
    defer { try? FileManager.default.removeItem(at: helper.directory) }
    let command = try ClaudeHooks.hookCommand(event: "Stop", cliPath: helper.url.path)
    let cursor = helper.directory.appendingPathComponent(".cursor", isDirectory: true)
    try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
    let replay = [
        "HOME": helper.directory.path, "CURSOR_VERSION": "1", "CURSOR_PROJECT_DIR": "/p",
    ]
    func calls() throws -> Int {
        guard FileManager.default.fileExists(atPath: helper.log.path) else { return 0 }
        return try String(contentsOf: helper.log, encoding: .utf8)
            .components(separatedBy: "hook claude Stop\n").count - 1
    }

    // Cursor is not connected, with no file or only another tool's hooks: the
    // replay is that session's only hold, so it still reports.
    #expect(try run(command, environment: replay).status == 0)
    #expect(try calls() == 1)
    try #"{"version":1,"hooks":{"stop":[{"command":"other"}]}}"#
        .write(to: cursor.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
    #expect(try run(command, environment: replay).status == 0)
    #expect(try calls() == 2)

    // Cursor is connected: its own hooks report the session.
    try CursorHooks.install(into: nil, cliPath: cli)
        .write(to: cursor.appendingPathComponent("hooks.json"))
    #expect(try run(command, environment: replay).status == 0)
    #expect(try calls() == 2)

    // Without both variables this is a real Claude session, even in Cursor's terminal.
    for missing in ["CURSOR_VERSION", "CURSOR_PROJECT_DIR"] {
        var environment = replay
        environment[missing] = nil
        #expect(try run(command, environment: environment).status == 0)
    }
    #expect(try calls() == 4)
}

// MARK: - Kimi

private func kimiText(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

@Test func kimiPathFollowsItsHomeOverride() {
    let home = URL(fileURLWithPath: "/Users/me")
    #expect(KimiHooks.configURL(home: home, environment: [:]).path == "/Users/me/.kimi-code/config.toml")
    #expect(KimiHooks.configURL(home: home, environment: ["KIMI_CODE_HOME": "/alt"]).path == "/alt/config.toml")
}

@Test func kimiWritesOnlyTheKeysItsSchemaAccepts() throws {
    let text = kimiText(try KimiHooks.install(into: nil, cliPath: cli))
    let keys = Set(text.split(separator: "\n").filter { !$0.hasPrefix("[") }
        .compactMap { $0.split(separator: " ").first.map(String.init) })
    #expect(keys == ["event", "command", "timeout"])
    #expect(text.components(separatedBy: "[[hooks]]").count - 1 == KimiHooks.events.count)
    #expect(text.contains("event = \"Interrupt\""))
    #expect(text.contains(#"hook kimi UserInputResolved >/dev/null 2>&1"#))
    // The shell's own double quotes must be escaped inside the TOML string.
    #expect(text.contains(#"[ -x \"$c\" ]"#))
}

@Test func kimiPreservesTheUsersBytesAndRoundTrips() throws {
    let original = """
    # my settings
    default_model = "kimi"

    [[hooks]]
    event = "Stop"
    command = "notify-send done"

    [loop_control]
    max_steps = 10\n
    """
    let once = try KimiHooks.install(into: Data(original.utf8), cliPath: cli)
    let text = kimiText(once)
    #expect(text.hasPrefix(original.trimmingCharacters(in: .newlines)))
    #expect(text.contains("command = \"notify-send done\""))
    #expect(try KimiHooks.install(into: once, cliPath: cli) == once)
    #expect(KimiHooks.report(for: once, cliPath: cli).isHealthy)
    #expect(kimiText(try KimiHooks.remove(from: once)) == original)
}

@Test func kimiFindsItsTablesAfterKimiRewritesTheFile() throws {
    // A rewrite drops comments and may move or re-quote what it keeps.
    let command = "c='/opt/letitbrew'; \"$c\" hook kimi Stop; \(HookFile.ownershipComment(marker: KimiHooks.marker))"
    let rewritten = """
    [[hooks]]
    timeout = 5
    command = '\(command.replacingOccurrences(of: "'", with: ""))'
    event = 'Stop'

    [[hooks]]
    command = "mine"
    event = "Stop"\n
    """
    let data = Data(rewritten.utf8)
    #expect(KimiHooks.report(for: data, cliPath: cli).stale == ["Stop"])
    let repaired = kimiText(try KimiHooks.install(into: data, cliPath: cli))
    #expect(repaired.hasPrefix("[[hooks]]\ncommand = \"mine\""))
    #expect(repaired.components(separatedBy: "[[hooks]]").count - 1 == KimiHooks.events.count + 1)
}

@Test func kimiKeepsWindowsLineEndingsInAUsersFile() throws {
    let original = "default_model = \"kimi\"\r\n"
    let once = try KimiHooks.install(into: Data(original.utf8), cliPath: cli)
    let bytes = Array(once)
    for (index, byte) in bytes.enumerated() where byte == 0x0A {
        #expect(index > 0 && bytes[index - 1] == 0x0D)
    }
    #expect(KimiHooks.report(for: once, cliPath: cli).isHealthy)
    #expect(kimiText(try KimiHooks.remove(from: once)) == original)
}

@Test func kimiIgnoresTableTextInsideAMultilineString() throws {
    let original = "notes = \"\"\"\n[[hooks]]\ncommand = \"\(HookFile.ownershipComment(marker: KimiHooks.marker))\"\n\"\"\"\n"
    let report = KimiHooks.report(for: Data(original.utf8), cliPath: cli)
    #expect(report.isAbsent)
    #expect(try KimiHooks.remove(from: Data(original.utf8)) == Data(original.utf8))
}

@Test func kimiRefusesAConfigWhereAppendingWouldBreakIt() {
    for bytes in [
        "hooks = []\n",
        "\"hooks\" = []\n",
        "[hooks]\nevent = \"Stop\"\n",
        "[hooks.extra]\nkey = 1\n",
        "notes = \"\"\"\nnever closed\n",
    ] {
        #expect(throws: KimiHooks.ConfigUnreadable.self) {
            try KimiHooks.install(into: Data(bytes.utf8), cliPath: cli)
        }
        #expect(KimiHooks.report(for: Data(bytes.utf8), cliPath: cli).isAbsent)
    }
    #expect(throws: KimiHooks.ConfigUnreadable.self) {
        try KimiHooks.install(into: Data([0xFF, 0xFE]), cliPath: cli)
    }
    // A key named `hooks` inside another table cannot collide.
    #expect(throws: Never.self) {
        try KimiHooks.install(into: Data("[other]\nhooks = 1\n".utf8), cliPath: cli)
    }
}

@Test func kimiRemovalLeavesAFileWithoutOurTablesUntouched() throws {
    #expect(try KimiHooks.remove(from: nil).isEmpty)
    let unusual = Data("a = 1   \n\n\n".utf8)
    #expect(try KimiHooks.remove(from: unusual) == unusual)
}

// MARK: - Payloads

@Test func cursorPayloadNamesItsSessionAndProject() throws {
    let payload = try JSONDecoder().decode(HookPayload.self, from: Data("""
    {"conversation_id":"c1","workspace_roots":["/work/app","/work/lib"],"cwd":"/tmp/tool","status":"aborted"}
    """.utf8))
    #expect(payload.sessionId == "c1")
    #expect(payload.cwd == "/work/app")
    let oddRoots = try JSONDecoder().decode(HookPayload.self, from: Data("""
    {"conversation_id":"c1","workspace_roots":"/work/app","cwd":"/tmp/tool"}
    """.utf8))
    #expect(oddRoots.cwd == "/tmp/tool")
}

@Test(arguments: [AgentID.qwen, .kimi])
func taggedHooksCountTowardTheParentTurn(agent: AgentID) {
    let payload = HookPayload(sessionId: "s1", agentId: "main")
    #expect(payload.recordID(agent: agent, event: "PreToolUse")
        == HookRecordID(agent: agent, parentID: "s1")?.encoded)
}

@Test func otherAgentsKeepChildRecords() {
    let payload = HookPayload(sessionId: "s1", agentId: "child")
    #expect(HookRecordID(encoded: payload.recordID(agent: .claude, event: "PreToolUse") ?? "")?.childID == "child")
}

// MARK: - Replayed turns

private final class Replay {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-replay-\(UUID().uuidString)", isDirectory: true)
    let storage: SessionStorage
    let agent: AgentID
    private var clock: TimeInterval = 1_000

    init(_ agent: AgentID) {
        self.agent = agent
        storage = SessionStorage(directory: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var record: SessionRecord? {
        storage.load(id: HookRecordID(agent: agent, parentID: "s1")!.encoded)
    }

    /// Applies one vendor event through the name its adapter installs it under.
    func send(
        _ event: String, tool: String? = nil, notification: String? = nil, source: String? = nil,
        agentId: String? = nil, isInterrupt: Bool = false, observedEarlierBy: TimeInterval = 0
    ) throws {
        let canonical: String
        switch agent {
        case .cursor: canonical = CursorHooks.events[event] ?? event
        case .gemini: canonical = GeminiHooks.adapter.events[event] ?? event
        case .qwen: canonical = QwenHooks.adapter.events[event] ?? event
        case .kimi: canonical = KimiHooks.events[event] ?? event
        default: canonical = event
        }
        clock += 1
        try HookSessionUpdater.apply(
            event: canonical,
            payload: HookPayload(
                sessionId: "s1", agentId: agentId, cwd: "/work", source: source,
                toolName: tool, notificationType: notification, isInterrupt: isInterrupt
            ),
            agent: agent, agentPID: nil,
            observedAt: Date(timeIntervalSince1970: clock - observedEarlierBy), storage: storage
        )
    }

    /// Whether the Mac holds, with local input this long after the latest hook.
    func holds(lastInput: TimeInterval?) throws -> Bool {
        let record = try #require(record)
        let latch = WaitAnswerLatch.observing(
            [record], input: lastInput.map { .lastInput(at: Date(timeIntervalSince1970: clock + $0)) } ?? .none
        )
        return decide(
            sessions: [record], now: Date(timeIntervalSince1970: clock + 2), settings: Settings(),
            power: PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal),
            waitAnswers: latch
        ).holdLidClosed
    }
}

@Test func cursorTurnWorksThroughAnApprovalAndEndsOnStop() throws {
    let replay = Replay(.cursor)
    try replay.send("beforeSubmitPrompt")
    // An approval prompt sends nothing Cursor's adapter installs, as with Codex.
    #expect(replay.record?.state == .working)
    #expect(try replay.holds(lastInput: 1))
    try replay.send("postToolUse", tool: "Shell")
    #expect(replay.record?.state == .working)
    try replay.send("stop")
    #expect(replay.record?.state == .idle)
    // A tool edge that lands after the turn ended cannot reopen it.
    try replay.send("postToolUse", tool: "Shell")
    #expect(replay.record?.state == .idle)
    try replay.send("beforeSubmitPrompt")
    #expect(replay.record?.state == .working)
    try replay.send("sessionEnd")
    #expect(replay.record == nil)
}

// These follow the hook order the real CLIs produced: Gemini 0.66.0, Qwen 0.26.7,
// and Kimi 2.4.1 against a local fake model.

@Test func geminiApprovalReleasesUntilInputSuggestsAnAnswer() throws {
    let replay = Replay(.gemini)
    try replay.send("SessionStart", source: "startup")
    #expect(replay.record?.state == .idle)
    try replay.send("BeforeAgent")
    #expect(replay.record?.state == .working)
    try replay.send("SessionStart", source: "resume")
    #expect(replay.record?.state == .working)
    try replay.send("BeforeTool", tool: "run_shell_command")
    #expect(replay.record?.state == .working)
    try replay.send("Notification", notification: "ToolPermission")
    #expect(replay.record?.state == .waiting)
    #expect(try !replay.holds(lastInput: nil))
    // Approving sends nothing until AfterTool, so the tool holds on input alone.
    #expect(try replay.holds(lastInput: 1))
    try replay.send("AfterTool", tool: "run_shell_command")
    #expect(replay.record?.state == .working)
    try replay.send("AfterAgent")
    #expect(replay.record?.state == .idle)
    try replay.send("SessionEnd")
    #expect(replay.record == nil)
}

@Test func geminiQuestionToolWaitsWithoutTheApprovalLatch() throws {
    let replay = Replay(.gemini)
    try replay.send("BeforeAgent")
    try replay.send("BeforeTool", tool: "ask_user")
    try replay.send("Notification", notification: "ToolPermission")
    #expect(replay.record?.detail == SessionWaitDetail.question)
    #expect(try !replay.holds(lastInput: 1))
    try replay.send("AfterTool", tool: "ask_user")
    #expect(replay.record?.state == .working)
}

@Test func qwenIdlePromptDoesNotEndATurnWhileAToolRuns() throws {
    let replay = Replay(.qwen)
    try replay.send("UserPromptSubmit")
    try replay.send("PreToolUse", tool: "run_shell_command")
    try replay.send("Notification", notification: "idle_prompt")
    #expect(replay.record?.state == .working)
    #expect(try replay.holds(lastInput: nil))
    try replay.send("PostToolUse", tool: "run_shell_command")
    try replay.send("Stop")
    #expect(replay.record?.state == .idle)
}

@Test func qwenPreToolUseStillAppliesWhenIdlePromptLandsFirst() throws {
    let replay = Replay(.qwen)
    try replay.send("UserPromptSubmit")
    try replay.send("Notification", notification: "idle_prompt")
    #expect(replay.record?.state == .idle)
    try replay.send("PreToolUse", tool: "run_shell_command", observedEarlierBy: 1.5)
    #expect(replay.record?.state == .idle)
    try replay.send("Notification", notification: "idle_prompt")
    try replay.send("PreToolUse", tool: "run_shell_command", observedEarlierBy: 0.5)
    #expect(replay.record?.state == .working)
}

@Test func qwenApprovalReleasesUntilInputSuggestsAnAnswer() throws {
    let replay = Replay(.qwen)
    try replay.send("UserPromptSubmit")
    try replay.send("PreToolUse", tool: "run_shell_command")
    try replay.send("Notification", notification: "idle_prompt")
    try replay.send("Notification", notification: "permission_prompt")
    #expect(replay.record?.state == .waiting)
    #expect(try !replay.holds(lastInput: nil))
    #expect(try replay.holds(lastInput: 1))
    try replay.send("PostToolUse", tool: "run_shell_command")
    #expect(replay.record?.state == .working)
}

@Test func qwenEscEndsTheTurnEverywhere() throws {
    // While text streams.
    var replay = Replay(.qwen)
    try replay.send("UserPromptSubmit")
    try replay.send("Notification", notification: "idle_prompt")
    #expect(replay.record?.state == .idle)
    // At an approval prompt.
    replay = Replay(.qwen)
    try replay.send("UserPromptSubmit")
    try replay.send("PreToolUse", tool: "run_shell_command")
    try replay.send("Notification", notification: "permission_prompt")
    try replay.send("Notification", notification: "idle_prompt")
    #expect(replay.record?.state == .idle)
    // While a tool runs, whichever hook lands first.
    replay = Replay(.qwen)
    try replay.send("UserPromptSubmit")
    try replay.send("PreToolUse", tool: "run_shell_command")
    try replay.send("Notification", notification: "idle_prompt")
    try replay.send("PostToolUseFailure", tool: "run_shell_command", isInterrupt: true)
    #expect(replay.record?.state == .idle)
    try replay.send("Notification", notification: "auth_success")
    #expect(replay.record?.state == .idle)
}

@Test func qwenFailedToolContinuesTheTurn() throws {
    let replay = Replay(.qwen)
    try replay.send("UserPromptSubmit")
    try replay.send("PreToolUse", tool: "run_shell_command")
    try replay.send("PostToolUseFailure", tool: "run_shell_command")
    #expect(replay.record?.state == .working)
}

@Test func kimiApprovalAndEscAreReportedByTheirOwnHooks() throws {
    let replay = Replay(.kimi)
    try replay.send("UserPromptSubmit")
    try replay.send("SessionStart", source: "startup")
    #expect(replay.record?.state == .working)
    try replay.send("PermissionRequest", tool: "Bash", agentId: "main")
    #expect(replay.record?.state == .waiting)
    // The answer has its own hook, so input means nothing here.
    #expect(try !replay.holds(lastInput: 1))
    try replay.send("PermissionResult", tool: "Bash", agentId: "main")
    #expect(replay.record?.state == .working)
    try replay.send("PreToolUse", tool: "AskUserQuestion")
    #expect(replay.record?.detail == SessionWaitDetail.question)
    try replay.send("PostToolUse", tool: "AskUserQuestion")
    try replay.send("PermissionRequest", tool: "Bash", agentId: "main")
    try replay.send("Interrupt")
    #expect(replay.record?.state == .idle)
    // The answer's edge can race Interrupt and must not reopen the turn.
    try replay.send("PermissionResult", tool: "Bash", agentId: "main")
    #expect(replay.record?.state == .idle)
    // No second record is left holding the Mac.
    #expect(replay.storage.loadAll().count == 1)
}
