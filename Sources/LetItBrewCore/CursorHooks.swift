import CoreFoundation
import Foundation

/// Installs Let It Brew's lifecycle hooks in Cursor's user-scoped hook file.
///
/// Cursor's hook file is a flat `event -> [entry]` JSON object. It is owned by
/// the person using Cursor, so this adapter only changes entries whose command
/// ends in its exact ownership marker. Unknown root data, foreign events, and
/// foreign entries all pass through unchanged.
public enum CursorHooks {
    /// Frozen ownership marker for entries in `~/.cursor/hooks.json`.
    public static let marker = "__letitbrew_cursor_hook"

    /// Cursor's source event names mapped onto Let It Brew's lifecycle names.
    public static let eventMap = [
        "sessionStart": "SessionStart",
        "beforeSubmitPrompt": "UserPromptSubmit",
        "preToolUse": "PreToolUse",
        "postToolUse": "PostToolUse",
        "subagentStart": "SubagentStart",
        "subagentStop": "SubagentStop",
        "stop": "Stop",
        "sessionEnd": "SessionEnd",
    ]

    private static let sourceEvents = [
        "sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse",
        "subagentStart", "subagentStop", "stop", "sessionEnd",
    ]

    /// Cursor hooks persist after the app moves, so retain the same safe
    /// fallback as the other local integrations rather than searching PATH.
    public static let fallbackCLIPath = ClaudeHooks.fallbackCLIPath

    /// `~/.cursor/hooks.json`. Project, team, and enterprise hook scopes are
    /// intentionally not touched.
    public static func settingsURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    /// A hook must embed an absolute helper path. Otherwise a persistent hook
    /// could execute an unrelated `letitbrew` found on PATH after the app is
    /// moved or removed.
    public struct RelativeCLIPath: Error, Equatable {
        public let cliPath: String
        public init(_ cliPath: String) { self.cliPath = cliPath }
    }

    /// Keeps a public command constructor from creating a hook that Cursor
    /// accepts but Let It Brew cannot associate with a lifecycle transition.
    public struct UnsupportedSourceEvent: Error, Equatable {
        public let sourceEvent: String
        public init(_ sourceEvent: String) { self.sourceEvent = sourceEvent }
    }

    /// Existing bytes that cannot be safely interpreted. Install and remove
    /// throw this before constructing replacement JSON, leaving the caller's
    /// file untouched.
    public struct SettingsUnreadable: Error, Equatable {
        public init() {}
    }

    /// The fail-open command Cursor executes for one source event. Redirecting
    /// all output and ending with `:` means a missing or failed helper cannot
    /// block the user's Cursor interaction; the exact trailing marker is how
    /// future install/remove/report operations recognize this entry.
    public static func hookCommand(sourceEvent: String, cliPath: String) throws -> String {
        guard cliPath.hasPrefix("/") else { throw RelativeCLIPath(cliPath) }
        guard let mappedEvent = eventMap[sourceEvent] else {
            throw UnsupportedSourceEvent(sourceEvent)
        }

        return "c=\(ClaudeHooks.shellSingleQuoted(cliPath)); "
            + "[ -x \"$c\" ] || c=\(ClaudeHooks.shellSingleQuoted(fallbackCLIPath)); "
            + "\"$c\" hook cursor \(mappedEvent) >/dev/null 2>&1; "
            + HookFile.ownershipComment(marker: marker)
    }

    /// `nil` is an absent file and starts from an empty object. Non-nil bytes,
    /// including an empty file, must form a JSON object before we will touch
    /// them.
    static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard !data.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: data),
              let root = value as? [String: Any] else {
            throw SettingsUnreadable()
        }
        return root
    }

    /// Cursor currently accepts version 1. Preserve an absent version and an
    /// existing numeric `1`, but never normalize a version we do not know how
    /// to preserve safely. JSON booleans bridge to NSNumber, so explicitly
    /// exclude them before comparing the numeric value.
    static func requireSupportedVersion(_ root: [String: Any]) throws {
        guard let value = root["version"] else { return }
        guard let version = value as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 1 else {
            throw SettingsUnreadable()
        }
    }

    /// Returns an absent `hooks` object as empty, and rejects every other
    /// present shape. Every present event must itself be an array so no owned
    /// entry can be hidden inside data we would otherwise overwrite or leave
    /// behind.
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

    /// Removes all prior owned entries, including ones an older version left
    /// under a retired source event, then appends exactly one current flat
    /// entry per event. Cursor's default behavior stays fail-open: no
    /// `failClosed` setting is written.
    public static func install(into data: Data?, cliPath: String) throws -> Data {
        var root = try parseRoot(data)
        try requireSupportedVersion(root)
        let existingHooks = try hooksDictionary(root)
        var hooks = FlatHookFile.sweep(
            existingHooks, marker: marker, commandKey: "command"
        )

        for sourceEvent in sourceEvents {
            var entries = (hooks[sourceEvent] as? [Any]) ?? []
            entries.append(FlatHookFile.entry(
                command: try hookCommand(sourceEvent: sourceEvent, cliPath: cliPath),
                commandKey: "command",
                timeoutKey: "timeout",
                timeout: 5
            ))
            hooks[sourceEvent] = entries
        }

        root["hooks"] = hooks
        return try serialize(root)
    }

    /// Removes only commands carrying this adapter's exact trailing marker.
    /// A `hooks` key is removed only if sweeping our entries left it empty;
    /// every unknown root key and foreign entry stays intact.
    public static func remove(from data: Data?) throws -> Data {
        var root = try parseRoot(data)
        try requireSupportedVersion(root)
        let existingHooks = try hooksDictionary(root)
        let hooks = FlatHookFile.sweep(
            existingHooks, marker: marker, commandKey: "command"
        )

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try serialize(root)
    }

    /// Reports each expected source event as healthy, missing, stale, or
    /// duplicated, and reports owned entries under all other source events as
    /// orphaned. Unreadable data reports fully absent so status UI can render
    /// without risking a mutation.
    public static func report(for data: Data?, cliPath: String) -> HookInstallReport {
        let hooks: [String: Any]? = try? {
            let root = try parseRoot(data)
            try requireSupportedVersion(root)
            return try hooksDictionary(root)
        }()

        return FlatHookFile.report(
            hooks: hooks,
            events: sourceEvents,
            marker: marker,
            commandKey: "command",
            expectedCommand: { sourceEvent in
                (try? hookCommand(sourceEvent: sourceEvent, cliPath: cliPath)) ?? ""
            }
        )
    }
}
