import CoreFoundation
import Foundation

/// Observes Cursor through its user-level `~/.cursor/hooks.json`.
///
/// Observe only: `preToolUse`, `beforeShellExecution`, and `beforeMCPExecution`
/// are skipped because each must answer with a permission decision. Cursor has
/// no other signal for a prompt on screen, so, like Codex, an approval keeps the
/// session Working and the Mac awake.
///
/// The file belongs to the user. Unknown root keys and other tools' entries are
/// kept exactly, and a malformed shape refuses the whole file.
public enum CursorHooks {
    /// Frozen ownership marker: the trailing comment of every command we write.
    public static let marker = "__letitbrew_cursor_hook"

    /// Each event to install, and the name `HookReducer` knows it by.
    public static let events = [
        "beforeSubmitPrompt": "UserPromptSubmit",
        "postToolUse": "PostToolUse",
        "stop": "Stop",
        "sessionEnd": "SessionEnd",
    ]

    public static func hooksURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    /// Cursor runs hooks in the login shell, so the command is wrapped in
    /// `/bin/sh` to stay valid under fish. `beforeSubmitPrompt` replies before
    /// the helper runs, so a missing helper can never hold up a prompt.
    public static func hookCommand(event: String, cliPath: String) throws -> String {
        guard cliPath.hasPrefix("/") else { throw ClaudeHooks.RelativeCLIPath(cliPath) }
        let reply = event == "beforeSubmitPrompt" ? "printf '{\"continue\":true}\\n'; " : ""
        let script = reply
            + "c=\(ClaudeHooks.shellSingleQuoted(cliPath)); "
            + "[ -x \"$c\" ] || c=\(ClaudeHooks.shellSingleQuoted(ClaudeHooks.fallbackCLIPath)); "
            + "\"$c\" hook cursor \(events[event] ?? event) >/dev/null 2>&1; :"
        return "/bin/sh -c \(ClaudeHooks.shellSingleQuoted(script)) # \(marker)"
    }

    private static func isOwned(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?.hasSuffix(" # \(marker)") ?? false
    }

    private static func parse(_ data: Data?) throws -> (root: [String: Any], hooks: [String: Any]) {
        let root = try ClaudeHooks.parseRoot(data)
        if let value = root["version"] {
            guard let version = value as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(),
                  version.doubleValue == 1
            else { throw ClaudeHooks.SettingsUnreadable() }
        }
        let hooks = try ClaudeHooks.hooksDictionary(root)
        try ClaudeHooks.requireEventArrays(hooks)
        return (root, hooks)
    }

    private static func sweep(_ hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks {
            guard let entries = value as? [Any] else { continue }
            let kept = entries.filter { !isOwned($0) }
            guard kept.count != entries.count else { continue }
            if kept.isEmpty { result.removeValue(forKey: event) } else { result[event] = kept }
        }
        return result
    }

    /// Sweeps our entries from every event, then appends one per event, so
    /// reinstall is idempotent and repairs a stale path or a retired event.
    public static func install(into data: Data?, cliPath: String) throws -> Data {
        let parsed = try parse(data)
        var root = parsed.root
        var hooks = sweep(parsed.hooks)
        for event in events.keys.sorted() {
            var entries = (hooks[event] as? [Any]) ?? []
            entries.append([
                "command": try hookCommand(event: event, cliPath: cliPath),
                "timeout": 5,
            ] as [String: Any])
            hooks[event] = entries
        }
        root["version"] = 1
        root["hooks"] = hooks
        return try ClaudeHooks.serialize(root)
    }

    public static func remove(from data: Data?) throws -> Data {
        let parsed = try parse(data)
        var root = parsed.root
        let hooks = sweep(parsed.hooks)
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try ClaudeHooks.serialize(root)
    }

    /// Unreadable settings report as absent, because status must always
    /// render; `install` and `remove` are the paths that refuse.
    public static func report(for data: Data?, cliPath: String) -> HookInstallReport {
        var report = HookInstallReport()
        let expected = Set(events.keys)
        guard let hooks = try? parse(data).hooks else {
            report.missing = expected
            return report
        }
        for (event, value) in hooks {
            let owned = (value as? [Any])?.filter(isOwned) ?? []
            guard !owned.isEmpty else { continue }
            guard expected.contains(event) else { report.orphaned.insert(event); continue }
            if owned.count > 1 {
                report.duplicated.insert(event)
            } else if (owned[0] as? [String: Any])?["command"] as? String
                        == (try? hookCommand(event: event, cliPath: cliPath)) {
                report.healthy.insert(event)
            } else {
                report.stale.insert(event)
            }
        }
        report.missing = expected
            .subtracting(report.healthy).subtracting(report.stale).subtracting(report.duplicated)
        return report
    }
}
