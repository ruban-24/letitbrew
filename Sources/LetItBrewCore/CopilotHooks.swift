import CoreFoundation
import Foundation

/// Installs Let It Brew's observational lifecycle hooks in GitHub Copilot
/// CLI's user-level hook file.
///
/// This adapter deliberately installs only `SessionStart`,
/// `UserPromptSubmit`, `PostToolUse`, `Stop`, and `SessionEnd`. In particular,
/// it never installs `PreToolUse`, `PermissionRequest`, or `ErrorOccurred`:
/// v0.6.0 must not block a tool, influence an approval, or add context to a
/// Copilot turn. An error path that emits neither `Stop` nor `SessionEnd`
/// therefore relies on Let It Brew's 12-hour stale-record backstop or the
/// user's Stop Tracking action.
///
/// `letitbrew.json` belongs to the user. All operations retain unknown root
/// keys and foreign flat entries exactly, and refuse malformed shapes rather
/// than replacing configuration they cannot safely understand.
public enum CopilotHooks {
    /// Frozen ownership marker for commands in `~/.copilot/hooks/letitbrew.json`.
    public static let marker = "__letitbrew_copilot_hook"

    /// The complete v0.6.0 Copilot lifecycle surface. These are intentionally
    /// PascalCase because they are Copilot CLI's source event names.
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd",
    ]

    /// Persistent hooks embed an absolute fallback rather than using PATH, so
    /// moving or deleting the app cannot run an unrelated helper named
    /// `letitbrew` later.
    public static let fallbackCLIPath = ClaudeHooks.fallbackCLIPath

    /// `~/.copilot/hooks/letitbrew.json`, unless Copilot's user home has been
    /// relocated with `COPILOT_HOME`. Project, team, and enterprise scopes are
    /// intentionally not touched.
    public static func hooksURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let copilotHome = environment["COPILOT_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".copilot", isDirectory: true)
        return copilotHome
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("letitbrew.json")
    }

    /// Thrown rather than creating a persistent hook with a relative helper
    /// path, which would otherwise turn into a PATH lookup at execution time.
    public struct RelativeCLIPath: Error, Equatable {
        public let cliPath: String
        public init(_ cliPath: String) { self.cliPath = cliPath }
    }

    /// Existing bytes whose root, version, hooks object, or event arrays are
    /// not safe to preserve through a JSON round trip.
    public struct SettingsUnreadable: Error, Equatable {
        public init() {}
    }

    /// The fail-open command run by one Copilot event. The helper's output is
    /// discarded, and the trailing `:` means a missing or failing helper
    /// cannot block the user's session. The ownership comment must be the
    /// exact suffix so marker-scoped removal can recognize it later.
    public static func hookCommand(event: String, cliPath: String) throws -> String {
        guard cliPath.hasPrefix("/") else { throw RelativeCLIPath(cliPath) }
        return "c=\(ClaudeHooks.shellSingleQuoted(cliPath)); "
            + "[ -x \"$c\" ] || c=\(ClaudeHooks.shellSingleQuoted(fallbackCLIPath)); "
            + "\"$c\" hook copilot \(event) >/dev/null 2>&1; "
            + HookFile.ownershipComment(marker: marker)
    }

    /// `nil` means there is no file yet. Present bytes — including an empty
    /// file — must parse as an object before a mutation is permitted.
    static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard !data.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: data),
              let root = value as? [String: Any] else {
            throw SettingsUnreadable()
        }
        return root
    }

    /// Copilot's supported schema is numeric version 1. JSON booleans bridge
    /// to `NSNumber`, so rule them out before accepting the numeric value.
    static func requireSupportedVersion(_ root: [String: Any]) throws {
        guard let value = root["version"] else { return }
        guard let version = value as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 1 else {
            throw SettingsUnreadable()
        }
    }

    /// Every existing event must be an array. Otherwise an owned command could
    /// be hidden in data neither sweep nor removal can inspect safely.
    static func hooksDictionary(_ root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw SettingsUnreadable() }
        for value in hooks.values where !(value is [Any]) {
            throw SettingsUnreadable()
        }
        return hooks
    }

    static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Sweeps our marker from every event (including retired events), then
    /// appends exactly one current flat entry per event. Reinstall is therefore
    /// idempotent and repairs stale paths, duplicate entries, and orphans.
    public static func install(into data: Data?, cliPath: String) throws -> Data {
        var root = try parseRoot(data)
        try requireSupportedVersion(root)
        let existingHooks = try hooksDictionary(root)
        var hooks = FlatHookFile.sweep(
            existingHooks, marker: marker, commandKey: "bash"
        )

        for event in events {
            var entries = (hooks[event] as? [Any]) ?? []
            entries.append([
                "bash": try hookCommand(event: event, cliPath: cliPath),
                "type": "command",
                "timeoutSec": 5,
            ])
            hooks[event] = entries
        }

        root["version"] = 1
        root["hooks"] = hooks
        return try serialize(root)
    }

    /// Removes only flat commands with this adapter's exact trailing marker.
    /// The `hooks` key is pruned only when it becomes empty; version 1 remains
    /// explicit because this adapter serializes the supported schema.
    public static func remove(from data: Data?) throws -> Data {
        var root = try parseRoot(data)
        try requireSupportedVersion(root)
        let existingHooks = try hooksDictionary(root)
        let hooks = FlatHookFile.sweep(
            existingHooks, marker: marker, commandKey: "bash"
        )

        root["version"] = 1
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try serialize(root)
    }

    /// Reports healthy, missing, stale, duplicated, and orphaned owned
    /// entries. Invalid data reports absent so status rendering stays safe;
    /// install/remove remain fail-closed and throw instead.
    public static func report(for data: Data?, cliPath: String) -> HookInstallReport {
        let hooks: [String: Any]? = try? {
            let root = try parseRoot(data)
            try requireSupportedVersion(root)
            return try hooksDictionary(root)
        }()

        return FlatHookFile.report(
            hooks: hooks,
            events: events,
            marker: marker,
            commandKey: "bash",
            expectedCommand: { event in
                (try? hookCommand(event: event, cliPath: cliPath)) ?? ""
            }
        )
    }
}
