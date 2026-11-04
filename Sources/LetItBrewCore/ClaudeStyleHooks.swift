import Foundation

/// Hooks in a JSON settings file shaped like Claude Code's: `event -> [group]`,
/// where each group holds `command` entries. Gemini CLI and Qwen Code share
/// this shape and differ only in their event names, timeout unit, and path.
///
/// It follows `ClaudeHooks`'s rules for a file the user owns: every foreign
/// key survives, and a value of an unexpected shape refuses the whole file.
public struct ClaudeStyleHooks: Sendable {
    public let agent: AgentID
    /// Frozen: released versions must recognize each other's entries.
    public let marker: String
    public let timeout: Int
    /// Each event to install, and the name `HookReducer` knows it by.
    public let events: [String: String]

    /// The fail-open command for one vendor event. Output is discarded and the
    /// trailing `:` pins exit 0, so it can never answer or block the agent.
    public func hookCommand(event: String, cliPath: String) throws -> String {
        guard cliPath.hasPrefix("/") else { throw ClaudeHooks.RelativeCLIPath(cliPath) }
        return "c=\(ClaudeHooks.shellSingleQuoted(cliPath)); "
            + "[ -x \"$c\" ] || c=\(ClaudeHooks.shellSingleQuoted(ClaudeHooks.fallbackCLIPath)); "
            + "\"$c\" hook \(agent.rawValue) \(events[event] ?? event) >/dev/null 2>&1; "
            + HookFile.ownershipComment(marker: marker)
    }

    /// Sweeps our entries from every event, then appends one per event, so
    /// reinstall is idempotent and repairs a stale path or a retired event.
    public func install(into data: Data?, cliPath: String) throws -> Data {
        var root = try ClaudeHooks.parseRoot(data)
        let existing = try ClaudeHooks.hooksDictionary(root)
        try ClaudeHooks.requireEventArrays(existing)
        var hooks = HookFile.sweep(existing, marker: marker)
        for event in events.keys.sorted() {
            var groups = (hooks[event] as? [Any]) ?? []
            // Gemini shows this name while a hook runs, instead of the command.
            groups.append(["hooks": [[
                "type": "command",
                "command": try hookCommand(event: event, cliPath: cliPath),
                "timeout": timeout,
                "name": "Let It Brew",
            ] as [String: Any]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try ClaudeHooks.serialize(root)
    }

    /// Removes only our entries, dropping `hooks` if nothing survives.
    public func remove(from data: Data?) throws -> Data {
        var root = try ClaudeHooks.parseRoot(data)
        let existing = try ClaudeHooks.hooksDictionary(root)
        try ClaudeHooks.requireEventArrays(existing)
        let hooks = HookFile.sweep(existing, marker: marker)
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try ClaudeHooks.serialize(root)
    }

    /// Unreadable settings report as absent, because status must always
    /// render; `install` and `remove` are the paths that refuse.
    public func report(for data: Data?, cliPath: String) -> HookInstallReport {
        let hooks: [String: Any]? = try? {
            let hooks = try ClaudeHooks.hooksDictionary(try ClaudeHooks.parseRoot(data))
            try ClaudeHooks.requireEventArrays(hooks)
            return hooks
        }()
        return HookFile.report(
            hooks: hooks,
            events: Array(events.keys),
            marker: marker,
            expectedCommand: { (try? hookCommand(event: $0, cliPath: cliPath)) ?? "" }
        )
    }
}

/// Gemini CLI's user settings. Its approval prompt sends a `ToolPermission`
/// notification after `BeforeTool`, and approving it sends no hook until
/// `AfterTool`, so local input latches the answer, as with Claude.
public enum GeminiHooks {
    public static let marker = "__letitbrew_gemini_hook"

    public static let adapter = ClaudeStyleHooks(
        agent: .gemini,
        marker: marker,
        // Gemini reads hook timeouts in milliseconds.
        timeout: 5_000,
        events: [
            "SessionStart": "SessionStart",
            "BeforeAgent": "UserPromptSubmit",
            "BeforeTool": "PreToolUse",
            "AfterTool": "PostToolUse",
            "Notification": "Notification",
            "AfterAgent": "Stop",
            "SessionEnd": "SessionEnd",
        ]
    )

    public static func settingsURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let root = environment["GEMINI_CLI_HOME"].map(URL.init(fileURLWithPath:)) ?? home
        return root.appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}

/// Qwen Code's user settings. Its approval prompt sends `permission_prompt`
/// after `PreToolUse`, and approving it sends no hook until `PostToolUse`, so
/// local input latches the answer, as with Claude. `PermissionRequest` runs
/// before Qwen decides, so it is not installed. Esc fires no `Stop`: it sends
/// `idle_prompt`, or `PostToolUseFailure` with `is_interrupt` during a tool.
public enum QwenHooks {
    public static let marker = "__letitbrew_qwen_hook"

    public static let adapter = ClaudeStyleHooks(
        agent: .qwen,
        marker: marker,
        timeout: 5,
        events: Dictionary(uniqueKeysWithValues: [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd",
        ].map { ($0, $0) })
    )

    public static func settingsURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let root = environment["QWEN_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".qwen", isDirectory: true)
        return root.appendingPathComponent("settings.json")
    }
}
