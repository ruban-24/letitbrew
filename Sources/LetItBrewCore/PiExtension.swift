import Foundation

/// Owns one global Pi extension. Requires Pi 0.87.1 or later for final
/// settlement and blocking UI prompt events. No Pi settings are rewritten.
public enum PiExtension {
    public static let marker = "__letitbrew_pi_extension"
    private static let reportKey = "extension"

    public static func extensionURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let directory: URL
        if let override = environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            if override == "~" {
                directory = home
            } else if override.hasPrefix("~/") {
                directory = home.appendingPathComponent(String(override.dropFirst(2)))
            } else {
                directory = URL(fileURLWithPath: override)
            }
        } else {
            directory = home.appendingPathComponent(".pi/agent", isDirectory: true)
        }
        return directory.appendingPathComponent("extensions/letitbrew.ts")
    }

    public struct RelativeCLIPath: Error, Equatable {
        public let cliPath: String
        public init(_ cliPath: String) { self.cliPath = cliPath }
    }

    public struct UnownedExistingFile: Error, Equatable {
        public init() {}
    }

    private static func generatedExtension(cliPath: String) throws -> Data {
        guard cliPath.hasPrefix("/") else { throw RelativeCLIPath(cliPath) }
        let pathLiteral = String(decoding: try JSONEncoder().encode(cliPath), as: UTF8.self)
        let source = """
        // \(marker)
        import { spawn } from "node:child_process"
        import { randomUUID } from "node:crypto"

        const cli = \(pathLiteral)
        const emit = (eventName, session) => new Promise(resolve => {
          if (!session) { resolve(); return }
          let child, timer
          const finish = () => { clearTimeout(timer); resolve() }
          try {
            child = spawn(cli, ["hook", "pi", eventName], { stdio: ["pipe", "ignore", "ignore"] })
            child.on("error", finish)
            child.on("close", finish)
            child.stdin.on("error", () => {})
            timer = setTimeout(() => {
              try { child.kill("SIGKILL") } catch {}
              finish()
            }, 1000)
            child.stdin.end(JSON.stringify({
              session_id: session.id,
              cwd: session.cwd,
              hook_event_name: eventName,
            }))
          } catch { finish() }
        })

        export default function letItBrew(pi) {
          let session, running = false, compacting = false, waiting = false
          // Pi does not await UI notifications. Serialize subprocess writes so
          // a slow prompt-start cannot overwrite a later prompt-end or shutdown.
          let pending = Promise.resolve()
          const send = (name, target = session) => {
            pending = pending.then(() => emit(name, target)).catch(() => {})
            return pending
          }
          const activity = () => !session ? pending : send(waiting
            ? "UserInputRequested" : running || compacting ? "UserPromptSubmit" : "Stop")

          pi.on("session_start", (_event, ctx) => {
            if (session) send("SessionEnd")
            // A resumed Pi transcript can be open in multiple processes. Each
            // loaded lifetime owns a separate record, including across /reload.
            session = { id: ctx.sessionManager.getSessionId() + ":" + randomUUID(), cwd: ctx.cwd }
            running = compacting = waiting = false
            return send("SessionStart")
          })
          pi.on("agent_start", () => { running = true; return activity() })
          // agent_end is not final: retries, compaction and queued messages may
          // continue. Only agent_settled releases a completed run.
          pi.on("agent_settled", () => { running = false; return activity() })
          pi.on("session_before_compact", () => { compacting = true; return activity() })
          const compactDone = () => { compacting = false; return activity() }
          pi.on("session_compact", compactDone)
          pi.on("session_compact_failed", compactDone)
          pi.on("ui_prompt_start", () => { waiting = true; return activity() })
          pi.on("ui_prompt_end", () => {
            waiting = false
            return session && (running || compacting) ? send("UserInputResolved") : activity()
          })
          pi.on("session_shutdown", () => {
            if (session) send("SessionEnd")
            session = undefined
            running = compacting = waiting = false
            return pending
          })
        }
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
        return try generatedExtension(cliPath: cliPath)
    }

    /// A extension target is a whole file rather than a mergeable config tree.
    /// Returning `nil` authorizes the caller to remove it, but only after its
    /// ownership has been established.
    public static func remove(from data: Data?) throws -> Data? {
        guard let data, isOwned(data) else { throw UnownedExistingFile() }
        return nil
    }

    /// A missing or foreign file is absent from Let It Brew's perspective. An
    /// owned file is healthy only when its bytes exactly match this build's
    /// generated source; all other owned content is stale. One file cannot
    /// contain duplicate or orphaned extensions, so those fields stay empty.
    public static func report(for data: Data?, cliPath: String) -> HookInstallReport {
        guard let data, isOwned(data) else { return HookInstallReport() }
        guard let expected = try? generatedExtension(cliPath: cliPath), data == expected else {
            var report = HookInstallReport()
            report.stale = [reportKey]
            return report
        }
        var report = HookInstallReport()
        report.healthy = [reportKey]
        return report
    }
}
