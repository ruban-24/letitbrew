import Foundation

/// Installs and removes Let It Brew's lifecycle hooks in Claude Code's user
/// settings.
///
/// This edits a file the user owns and cannot afford to lose, so two rules
/// are absolute:
///
/// 1. `JSONSerialization`, never `Codable`. A typed struct silently drops keys
///    it does not model, which would delete the user's configuration on a
///    round trip.
/// 2. "No file yet" and "could not read the file" are different outcomes.
///    Conflating them lets a transient IO error replace a full settings file
///    with a hooks-only object. The same rule extends to any value that is
///    present but not the shape expected — an empty file, a `hooks` value
///    that isn't a dictionary, an event value that isn't an array: refuse
///    rather than guess.
public enum ClaudeHooks {
    /// Ownership marker. Frozen: released versions must recognize each
    /// other's entries, so changing this orphans every existing install.
    public static let marker = "__letitbrew_hook"

    /// Exactly the events `HookReducer` maps. Nothing speculative.
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Notification", "PreCompact", "PostCompact",
        "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd",
    ]

    /// Events whose settings entry takes a tool matcher; the others reject one.
    static let matcherEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    /// Where the CLI lives in a normal install, used as the fallback when the
    /// baked path stops resolving.
    public static let fallbackCLIPath = "/Applications/Let It Brew.app/Contents/Helpers/letitbrew"

    public static func settingsURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// POSIX single-quoting: everything inside is literal, an embedded quote
    /// becomes `'\''`. The app can be installed anywhere, and a quote or
    /// backtick in the path would be an `sh -c` syntax error, exiting 2 before
    /// the trailing `:` can pin exit 0. Claude Code reads that as a blocking
    /// hook failure on every tool call.
    public static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Thrown when `cliPath` is not absolute. A relative path would fall back
    /// to a PATH lookup inside the generated command — exactly the hijack the
    /// absolute-path rule exists to prevent — so this is refused at the
    /// boundary rather than ever reaching `shellSingleQuoted`.
    public struct RelativeCLIPath: Error, Equatable {
        public let cliPath: String
        public init(_ cliPath: String) { self.cliPath = cliPath }
    }

    /// The shell command an installed hook runs.
    ///
    /// Hooks execute under a non-interactive `sh -c` whose PATH can be
    /// launchd-minimal, so both candidate paths are absolute. A PATH lookup is
    /// deliberately avoided: a stale hook left behind after the app is deleted
    /// would otherwise let any `letitbrew` on PATH run on every tool call. The
    /// trailing `:` pins exit 0, so a missing CLI never disturbs a session.
    /// The sentinel is built by ``HookFile/ownershipComment(marker:)`` and must
    /// be the exact end of the string. Ownership is matched with `hasSuffix`,
    /// so a trailing space, newline, or semicolon after it would make the
    /// command unrecognizable to uninstall — orphaning a hook that still fires.
    public static func hookCommand(event: String, cliPath: String) throws -> String {
        guard cliPath.hasPrefix("/") else { throw RelativeCLIPath(cliPath) }
        return "c=\(shellSingleQuoted(cliPath)); [ -x \"$c\" ] || c=\(shellSingleQuoted(fallbackCLIPath)); "
            + "\"$c\" hook claude \(event) >/dev/null 2>&1; \(HookFile.ownershipComment(marker: marker))"
    }

    public struct SettingsUnreadable: Error, Equatable {
        /// The event whose value tripped validation, when the failure can be
        /// pinned to one. `nil` for failures with no specific event to name —
        /// an unreadable file, a non-object root, a `hooks` value that isn't
        /// a dictionary at all. Naming the event is what makes the
        /// fail-closed policy in `requireEventArrays` tolerable: a bare
        /// refusal gives the user no way to know which key to fix.
        public let event: String?
        public init(event: String? = nil) { self.event = event }
    }

    /// Distinguishes "no file yet" (nil, safe to start from an empty object)
    /// from "exists but unreadable" (throws).
    public static func read(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw SettingsUnreadable()
        }
    }

    /// `nil` means "no file yet" and starts from `{}`. Any non-nil `Data` —
    /// including empty `Data`, which is not valid JSON — means a file exists
    /// and must parse cleanly or throw. An empty file is not "no file yet":
    /// it is often a partial or interrupted write by another process, which
    /// is precisely the moment we must not clobber it.
    static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any] else {
            throw SettingsUnreadable()
        }
        return root
    }

    /// The "hooks" value from a parsed root: `[:]` if absent, the dictionary
    /// if present with the expected shape, or a throw if present as anything
    /// else. A `hooks` value that is there but not a dictionary — a hand
    /// edit, a corruption — must never be silently discarded and overwritten
    /// with our own object; that is unrecoverable for the user.
    static func hooksDictionary(_ root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let dict = value as? [String: Any] else { throw SettingsUnreadable() }
        return dict
    }

    /// Every event's value inside a hooks dictionary must be a group array.
    /// `HookFile.sweep` leaves a shape it doesn't recognize completely
    /// untouched by design, which is safe for values we merely pass through —
    /// but a value this malformed makes it impossible to tell whether one of
    /// our own entries is hiding inside it, so install and remove both refuse
    /// the whole file rather than silently leaving, or overwriting, something
    /// they cannot verify.
    static func requireEventArrays(_ hooks: [String: Any]) throws {
        for (event, value) in hooks where !(value is [Any]) {
            throw SettingsUnreadable(event: event)
        }
    }

    static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Merges one entry per mapped event, preserving every foreign key and
    /// other tools' hooks verbatim.
    ///
    /// Our entries are swept out of *every* event first, not only the ones
    /// about to be rewritten: an entry left under an event an older version
    /// installed is still ours and still fires, and repair is just a
    /// reinstall. That also makes reinstall idempotent and self-healing for a
    /// baked path that no longer resolves.
    public static func install(into data: Data?, cliPath: String) throws -> Data {
        var root = try parseRoot(data)
        let existingHooks = try hooksDictionary(root)
        try requireEventArrays(existingHooks)
        // Sweep ours out of EVERY event first, not only the ones about to be
        // rewritten: an entry left under an event an older version installed
        // still fires, and repair is implemented as a plain reinstall.
        var hooks = HookFile.sweep(existingHooks, marker: marker)

        for event in events {
            // Safe to force this shape now: requireEventArrays already
            // guaranteed every existing event value is `[Any]`, and sweep
            // never introduces a differently-typed value for a key it kept.
            var groups = (hooks[event] as? [Any]) ?? []
            // The CLI answers in milliseconds; a tight timeout means even a
            // wedged disk cannot stall a turn.
            groups.append(HookFile.entry(
                command: try hookCommand(event: event, cliPath: cliPath),
                timeout: 5,
                matcher: matcherEvents.contains(event) ? "*" : nil
            ))
            hooks[event] = groups
        }

        root["hooks"] = hooks
        return try serialize(root)
    }

    /// Removes exactly the entries carrying our marker, pruning only what our
    /// removal emptied and dropping the `hooks` key if nothing survives.
    /// Everything else is untouched.
    public static func remove(from data: Data?) throws -> Data {
        var root = try parseRoot(data)
        let existingHooks = try hooksDictionary(root)
        try requireEventArrays(existingHooks)

        let hooks = HookFile.sweep(existingHooks, marker: marker)
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try serialize(root)
    }

    /// Classifies the current install, event by event. Repair is a reinstall.
    ///
    /// Unreadable settings report as fully missing rather than throwing: this
    /// drives a status display that must always render something, whereas
    /// `install` is the path that genuinely has to refuse rather than risk
    /// overwriting. The same validation chain `install`/`remove` use —
    /// `parseRoot`, `hooksDictionary`, `requireEventArrays` — runs here too,
    /// so a shape neither of them would accept (a non-dictionary `hooks`, an
    /// event value that isn't an array) reports as all-missing rather than
    /// letting `HookFile.report` silently skip just that event and report a
    /// partial install `install`/`remove` would actually refuse to touch.
    ///
    /// `hookCommand` throws for a relative `cliPath`. When it does, `try?`
    /// substitutes an empty string, which can never equal a real command
    /// (every real command ends with the non-empty ownership sentinel), so
    /// affected entries conservatively land in `stale` — not because the
    /// install has actually drifted, but because the query itself is
    /// malformed and `stale` is the closer of the two available answers to
    /// "not verifiably healthy". Callers are required to pass an absolute
    /// `cliPath`, same as `install`.
    public static func report(for data: Data?, cliPath: String) -> HookInstallReport {
        let hooks: [String: Any]? = try? {
            let hooks = try hooksDictionary(try parseRoot(data))
            try requireEventArrays(hooks)
            return hooks
        }()
        return HookFile.report(
            hooks: hooks,
            events: events,
            marker: marker,
            expectedCommand: { (try? hookCommand(event: $0, cliPath: cliPath)) ?? "" }
        )
    }
}
