import Foundation

/// The single file Let It Brew owns in OpenCode's plugin discovery path.
///
/// OpenCode loads the standard global and project plugin locations in addition
/// to an `OPENCODE_CONFIG_DIR` location. This adapter deliberately installs at
/// only one of those locations and never searches for, alters, or removes
/// files from the others.
public enum OpenCodePlugin {
    /// Frozen, exact first-line marker for `letitbrew.js` ownership.
    public static let marker = "__letitbrew_opencode_plugin"

    private static let reportKey = "plugin"

    /// `~/.config/opencode/plugins/letitbrew.js`, or the one explicit
    /// additional config target requested through `OPENCODE_CONFIG_DIR`.
    public static func pluginURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let configDirectory = environment["OPENCODE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".config/opencode", isDirectory: true)
        return configDirectory
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("letitbrew.js")
    }

    /// Persistent plugins must not depend on a later PATH lookup.
    public struct RelativeCLIPath: Error, Equatable {
        public let cliPath: String
        public init(_ cliPath: String) { self.cliPath = cliPath }
    }

    /// The same-name file belongs to somebody else and must stay byte-for-byte
    /// untouched. Ownership is intentionally only the exact first line.
    public struct UnownedExistingFile: Error, Equatable {
        public init() {}
    }

    /// Generates the dependency-free ESM plugin. The helper path is encoded as
    /// a JSON string, which is also a valid JavaScript string literal. Tagged
    /// OpenCode v1 exposes permission and question request/reply events. A
    /// request becomes Idle; every reply resumes Working because control has
    /// returned to the agent, regardless of the person's answer.
    private static func generatedPlugin(cliPath: String) throws -> Data {
        guard cliPath.hasPrefix("/") else { throw RelativeCLIPath(cliPath) }
        let encodedPath = try JSONEncoder().encode(cliPath)
        let pathLiteral = String(decoding: encodedPath, as: UTF8.self)
        let source = """
        // \(marker)
        const cli = \(pathLiteral)

        const emit = async (eventName, sessionID, cwd) => {
          if (!sessionID) return
          try {
            const child = Bun.spawn([cli, "hook", "opencode", eventName], {
              stdin: "pipe",
              stdout: "ignore",
              stderr: "ignore",
            })
            child.stdin.write(JSON.stringify({
              session_id: sessionID,
              cwd,
              hook_event_name: eventName,
            }))
            child.stdin.end()
            const timeout = setTimeout(() => child.kill(), 1000)
            try {
              await child.exited
            } finally {
              clearTimeout(timeout)
            }
          } catch {}
        }

        export const LetItBrew = async ({ directory }) => ({
          event: async ({ event }) => {
            try {
              const properties = event?.properties ?? {}
              const info = properties.info ?? {}
              const sessionID = properties.sessionID ?? properties.sessionId ?? info.id
              const cwd = info.directory ?? directory
              if (event?.type === "session.created") await emit("SessionStart", sessionID, cwd)
              if (event?.type === "session.status") {
                const status = properties.status?.type ?? properties.status
                if (status === "busy" || status === "retry") {
                  await emit("UserPromptSubmit", sessionID, cwd)
                }
                if (status === "idle") await emit("Stop", sessionID, cwd)
              }
              if (event?.type === "session.idle") await emit("Stop", sessionID, cwd)
              if (event?.type === "session.deleted") await emit("SessionEnd", sessionID, cwd)
              if (
                event?.type === "permission.updated" ||
                event?.type === "permission.asked" ||
                event?.type === "permission.v2.asked"
              ) {
                await emit("PermissionRequest", sessionID, cwd)
              }
              if (
                event?.type === "permission.replied" ||
                event?.type === "permission.v2.replied"
              ) {
                await emit("UserInputResolved", sessionID, cwd)
              }
              if (event?.type === "question.asked") {
                await emit("UserInputRequested", sessionID, cwd)
              }
              if (
                event?.type === "question.replied" ||
                event?.type === "question.rejected"
              ) {
                await emit("UserInputResolved", sessionID, cwd)
              }
            } catch {}
          },
        })
        """
        return Data(source.utf8)
    }

    /// An owned file starts with exactly the marker line, rather than merely
    /// mentioning the marker somewhere in its contents.
    private static func isOwned(_ data: Data) -> Bool {
        guard let source = String(data: data, encoding: .utf8) else { return false }
        let firstLine: Substring
        if let newline = source.firstIndex(of: "\n") {
            firstLine = source[..<newline]
        } else {
            firstLine = source[...]
        }
        return firstLine == "// \(marker)"
    }

    /// `nil` means the target does not yet exist. A present file must carry
    /// the exact first-line marker before it can be replaced.
    public static func install(into data: Data?, cliPath: String) throws -> Data {
        if let data, !isOwned(data) { throw UnownedExistingFile() }
        return try generatedPlugin(cliPath: cliPath)
    }

    /// A plugin target is a whole file rather than a mergeable config tree.
    /// Returning `nil` authorizes the caller to remove it, but only after its
    /// ownership has been established.
    public static func remove(from data: Data?) throws -> Data? {
        guard let data, isOwned(data) else { throw UnownedExistingFile() }
        return nil
    }

    /// A missing or foreign file is absent from Let It Brew's perspective. An
    /// owned file is healthy only when its bytes exactly match this build's
    /// generated source; all other owned content is stale. One file cannot
    /// contain duplicate or orphaned adapters, so those fields stay empty.
    public static func report(for data: Data?, cliPath: String) -> HookInstallReport {
        guard let data, isOwned(data) else { return HookInstallReport() }
        guard let expected = try? generatedPlugin(cliPath: cliPath), data == expected else {
            var report = HookInstallReport()
            report.stale = [reportKey]
            return report
        }
        var report = HookInstallReport()
        report.healthy = [reportKey]
        return report
    }
}
