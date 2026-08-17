import Foundation

/// Installs and removes Let It Brew's lifecycle hooks in Codex.
///
/// Codex models its hooks on Claude Code's closely enough that the event
/// names and payload fields match, so `HookPayload` and `HookReducer` serve
/// both. Only the config file differs, and it has three sharp edges:
///
/// 1. **A stray top-level key destroys the file.** `hooks.json` is parsed
///    with unknown fields denied and accepts only `description` and `hooks`.
///    One unrecognized key makes Codex reject the whole file and load *none*
///    of its hooks, the user's included. So we write those two keys and
///    nothing else, ever — see ``serialize(description:hooks:)``.
/// 2. **Event names are not validated.** Names under `hooks` are matched
///    field by field with no error on a miss, so `sessionStart` parses
///    cleanly, registers zero hooks, and warns nowhere. ``events`` is their
///    single definition site.
/// 3. **Installed is not running.** Every hook starts untrusted and an
///    untrusted hook never executes and says nothing about it. Codex asks the
///    user to review it. We deliberately do not write the trust state: that
///    table is the point of the review gate, and granting ourselves
///    permission would defeat a security decision belonging to the person at
///    the keyboard. ``needsUserApprovalNote`` is what we surface instead.
///
/// `config.toml` also accepts a `[hooks]` table, but writing there would mean
/// sharing a file with the user's own settings, including the single-valued
/// `notify` key many people already point at their own program.
///
/// ## Fail closed everywhere, but say why
///
/// Every malformed shape refuses rather than guesses — both at the top level
/// and inside `hooks`. That was not always the plan here: an earlier version
/// treated the top level differently, silently dropping an unrecognized key
/// or coercing a wrong-typed `description`, on the theory that Codex already
/// refuses to load *any* hooks from a file shaped that way, so nothing
/// usable was being thrown away. That reasoning does not survive contact
/// with time: a *future* Codex version could legitimately accept a new
/// top-level field, and at that moment an older Let It Brew would silently
/// delete valid user configuration on every install and every uninstall,
/// with no way for the user to know it happened. "Codex ignores it today" is
/// not the same claim as "it is disposable" — refusing is recoverable (the
/// user can go look and fix it), deleting is not. It also brings Codex in
/// line with the policy `ClaudeHooks` already uses: validate, and fail
/// closed on anything unverified, rather than pass an uninspectable value
/// through.
///
/// The *reason* attached to a thrown ``HooksUnreadable`` still depends on
/// where the malformation sits, because the two locations carry different
/// weight for the message a user needs:
/// - **Top level** (an unrecognized key, or `description`/`hooks` present
///   with the wrong type): Codex's parser denies unknown fields, so a file
///   in this shape is *already* rejected by Codex in its entirety — none of
///   its hooks load, ours or the user's own — independent of anything
///   Let It Brew does. The error names the exact key so the user knows what to
///   go remove or fix right now.
/// - **Inside `hooks`** (an event value that exists but isn't a group
///   array): Codex's own per-event matching is lenient (edge 2 above) in a
///   way its top-level parsing is not, so a malformed event value does not
///   carry the same "Codex already gave up on this file" guarantee. It
///   could still be a shape that loads fine for events Let It Brew doesn't
///   touch, holding genuine automation the user set up themselves. Refusing
///   here is "we can't verify what's inside, so we won't guess," not "this
///   key is already dead weight."
public enum CodexHooks {
    /// Distinct from Claude Code's marker so removing one integration can
    /// never strip the other's entries. Frozen, like the other marker.
    public static let marker = "__letitbrew_codex_hook"

    /// Spelled exactly as Codex matches them. Load-bearing strings: a
    /// lowercase letter here disables the integration with no error anywhere.
    /// Codex has no `Notification` event.
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "PermissionRequest", "PreCompact", "PostCompact",
        "SubagentStart", "SubagentStop", "Stop", "SessionEnd",
    ]

    public static let fallbackCLIPath = ClaudeHooks.fallbackCLIPath

    /// Shown in the UI after installing: hooks are inert until approved.
    public static let needsUserApprovalNote =
        "Codex installs new hooks untrusted. Approve Let It Brew's hooks in Codex to activate them."

    /// Used only by `install` when it is creating `hooks.json` from nothing.
    /// An existing file's missing `description` is left missing — see
    /// ``install(into:cliPath:)``.
    private static let defaultDescription = "Let It Brew keep-awake hooks"

    /// `~/.codex/hooks.json`. `CODEX_HOME` relocates the whole directory.
    public static func hooksURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return base.appendingPathComponent("hooks.json")
    }

    /// Thrown when `cliPath` is not absolute. A relative path would fall
    /// back to a PATH lookup inside the generated command — exactly the
    /// hijack the absolute-path rule exists to prevent. A hook lives on in
    /// `hooks.json` long after the app that installed it might be gone, so a
    /// relative lookup at that point would let any binary named `letitbrew`
    /// somewhere on PATH run on every tool call. Refused at the boundary
    /// rather than ever reaching `ClaudeHooks.shellSingleQuoted`, mirroring
    /// `ClaudeHooks.RelativeCLIPath`.
    public struct RelativeCLIPath: Error, Equatable {
        public let cliPath: String
        public init(_ cliPath: String) { self.cliPath = cliPath }
    }

    /// Codex fails open: a hook that writes nothing or exits non-zero lets
    /// the action proceed, so the same inert command shape works for both
    /// tools. Same sentinel discipline as
    /// ``ClaudeHooks/hookCommand(event:cliPath:)``: built by
    /// ``HookFile/ownershipComment(marker:)`` and required to be the exact
    /// end of the string, since ownership is matched with `hasSuffix`.
    public static func hookCommand(event: String, cliPath: String) throws -> String {
        guard cliPath.hasPrefix("/") else { throw RelativeCLIPath(cliPath) }
        return "c=\(ClaudeHooks.shellSingleQuoted(cliPath)); "
            + "[ -x \"$c\" ] || c=\(ClaudeHooks.shellSingleQuoted(fallbackCLIPath)); "
            + "\"$c\" hook codex \(event) >/dev/null 2>&1; \(HookFile.ownershipComment(marker: marker))"
    }

    /// Thrown for `hooks.json` content that exists but cannot be safely
    /// interpreted. `key` names the offending key when the failure can be
    /// pinned to one, so a refusal leaves the user somewhere to start fixing
    /// the file by hand rather than a bare "can't read it". `reason`
    /// distinguishes *why*, because the two classes of failure carry
    /// different weight — see the type-level doc.
    public struct HooksUnreadable: Error, Equatable {
        public enum Reason: Equatable, Sendable {
            /// The bytes themselves are present but empty, not JSON, or not
            /// a JSON object. There is no single key to point at.
            case unparseable
            /// The file could not even be read — permissions, a directory
            /// where a file was expected, or any other I/O failure short of
            /// "no such file" (which is not an error at all: see `read`).
            /// Kept distinct from `.unparseable` so the message does not
            /// send the user hunting for a JSON syntax error that isn't
            /// there. Carries the underlying error's description.
            case ioFailure(description: String)
            /// A top-level key is either unrecognized, or a recognized key
            /// (`description`, `hooks`) is present with the wrong type.
            /// Codex's unknown-fields-denied top-level parser means the
            /// entire file is already rejected while this key is present in
            /// this shape — nothing loads, ours or the user's own.
            case invalidTopLevelKey
            /// An event's value inside `hooks` exists but isn't a group
            /// array. Unlike a top-level violation, this does not
            /// necessarily break the rest of the file, but it does make it
            /// impossible to verify whether one of our own entries is
            /// hiding inside it.
            case malformedEventValue
        }

        public let key: String?
        public let reason: Reason
        public init(key: String? = nil, reason: Reason) {
            self.key = key
            self.reason = reason
        }
    }

    /// Distinguishes "no file yet" (nil, safe to start from an empty
    /// object) from "exists but unreadable" (throws) — same contract as
    /// `ClaudeHooks.read(at:)`, and the caller `install`/`uninstall` need:
    /// a plain `try? Data(contentsOf:)` would conflate a missing file with,
    /// say, a permissions error, silently treating "cannot read it" as
    /// "safe to overwrite from empty."
    public static func read(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw HooksUnreadable(reason: .ioFailure(description: "\(error)"))
        }
    }

    /// `nil` means "no file yet" and starts from `{}`. Any non-nil `Data` —
    /// including empty `Data`, which is not valid JSON — means a file exists
    /// and must parse cleanly or throw. An empty file is not "no file yet":
    /// it is often a partial or interrupted write by another process, which
    /// is precisely the moment we must not clobber it.
    static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any] else {
            throw HooksUnreadable(reason: .unparseable)
        }
        return root
    }

    /// Validates the top-level shape strictly and extracts both fields in
    /// one pass: only `description` (String, optional) and `hooks`
    /// (dictionary, optional) are permitted at the top level. A *missing*
    /// known key defaults safely — there is nothing to lose in that case.
    /// Anything else — an unrecognized key, or `description`/`hooks`
    /// present with the wrong type — throws ``HooksUnreadable`` naming the
    /// key, per the type-level fail-closed policy. This governs only the
    /// top level; what's inside `hooks` is validated separately by
    /// ``requireEventArrays(_:)``.
    static func validateTopLevel(_ root: [String: Any]) throws -> (description: String?, hooks: [String: Any]) {
        for key in root.keys where key != "description" && key != "hooks" {
            throw HooksUnreadable(key: key, reason: .invalidTopLevelKey)
        }

        let description: String?
        if let value = root["description"] {
            guard let string = value as? String else {
                throw HooksUnreadable(key: "description", reason: .invalidTopLevelKey)
            }
            description = string
        } else {
            description = nil
        }

        let hooks: [String: Any]
        if let value = root["hooks"] {
            guard let dict = value as? [String: Any] else {
                throw HooksUnreadable(key: "hooks", reason: .invalidTopLevelKey)
            }
            hooks = dict
        } else {
            hooks = [:]
        }

        return (description, hooks)
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
            throw HooksUnreadable(key: event, reason: .malformedEventValue)
        }
    }

    /// Writes `description` — omitted entirely when `nil`, never defaulted
    /// here — and `hooks`, and nothing else. Whether a missing description
    /// becomes our default text or stays missing is `install`/`remove`'s
    /// call: hardcoding a default in this function was the bug that let
    /// installing into an existing description-less file silently add one.
    static func serialize(description: String?, hooks: [String: Any]) throws -> Data {
        var root: [String: Any] = ["hooks": hooks]
        if let description { root["description"] = description }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Merges one entry per mapped event. Our entries are swept out of
    /// *every* event first, not only the ones about to be rewritten: an
    /// entry left under an event an older version installed is still ours
    /// and still fires, and repair is just a reinstall.
    public static func install(into data: Data?, cliPath: String) throws -> Data {
        let root = try parseRoot(data)
        let (description, existingHooks) = try validateTopLevel(root)
        try requireEventArrays(existingHooks)
        var hooks = HookFile.sweep(existingHooks, marker: marker)

        for event in events {
            // Safe to force this shape now: requireEventArrays already
            // guaranteed every existing event value is `[Any]`, and sweep
            // never introduces a differently-typed value for a key it kept.
            var groups = (hooks[event] as? [Any]) ?? []
            // No matcher: Codex rejects one on every event.
            groups.append(HookFile.entry(
                command: try hookCommand(event: event, cliPath: cliPath),
                timeout: 5,
                matcher: nil
            ))
            hooks[event] = groups
        }

        // Only a file we are creating from nothing gets our default
        // description. An existing file that never had one keeps not
        // having one — adding metadata to a file we did not create is not
        // ours to do, the same principle that keeps install from touching
        // any other key it does not own.
        let resolvedDescription = data == nil ? defaultDescription : description
        return try serialize(description: resolvedDescription, hooks: hooks)
    }

    /// Removes exactly the entries carrying our marker, pruning only what our
    /// removal emptied. Everything else — including the user's own entries
    /// under events we also use — is untouched.
    ///
    /// `description` is opaque data here: whatever the input carried —
    /// present or absent, the user's own or a value that happens to read
    /// exactly like our own default text — passes through completely
    /// unchanged. An earlier version of this function compared it against
    /// `defaultDescription` and dropped it on a match, reasoning that a file
    /// left with only that exact text and no hooks was one Let It Brew had
    /// created wholesale. That reasoning does not hold: a string match is
    /// not a provenance signal, and a user whose own description happened to
    /// read the same way would have silently lost it. There is no reliable
    /// way to know whether Let It Brew created a given file without actually
    /// tracking that, which is out of scope here.
    ///
    /// One consequence: uninstalling a file Let It Brew created entirely from
    /// nothing leaves `{"description": "…", "hooks": {}}` behind rather than
    /// true absence — a deliberate choice, not an oversight. Deleting a
    /// user-visible config file outright is a bigger risk than leaving an
    /// inert, harmless object in its place, and doing it right requires the
    /// provenance tracking above. An empty, harmless leftover is the safe
    /// failure mode; a wrongly deleted file is not.
    public static func remove(from data: Data?) throws -> Data {
        let root = try parseRoot(data)
        let (description, existingHooks) = try validateTopLevel(root)
        try requireEventArrays(existingHooks)
        let hooks = HookFile.sweep(existingHooks, marker: marker)
        return try serialize(description: description, hooks: hooks)
    }

    /// Classifies the current install, event by event. Repair is a reinstall.
    ///
    /// Unreadable hooks.json reports as fully missing rather than throwing:
    /// this drives a status display that must always render something,
    /// whereas `install`/`remove` are the paths that genuinely have to
    /// refuse rather than risk overwriting. The same validation chain they
    /// use — `parseRoot`, `validateTopLevel`, `requireEventArrays` — runs
    /// here too, so a shape none of them would accept reports as all-missing
    /// rather than letting `HookFile.report` silently classify the `hooks`
    /// subtree as healthy while a stray top-level key means real Codex
    /// loads zero hooks from the file.
    ///
    /// `hookCommand` throws for a relative `cliPath`. When it does, `try?`
    /// substitutes `""`, which can never equal a real command (every real
    /// command ends with the non-empty ownership sentinel), so affected
    /// entries conservatively land in `stale` — the closer of the two
    /// available answers to "not verifiably healthy" when the query itself
    /// is malformed. Callers are required to pass an absolute `cliPath`,
    /// same as `install`.
    public static func report(for data: Data?, cliPath: String) -> HookInstallReport {
        let hooks: [String: Any]? = try? {
            let root = try parseRoot(data)
            let (_, hooks) = try validateTopLevel(root)
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
