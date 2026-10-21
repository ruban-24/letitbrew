import AppKit
import LetItBrewCore

/// Brings forward the app that hosts an agent session: the terminal, editor,
/// or agent app among the agent's ancestors. App-level only; it never asks
/// for Accessibility or Automation access to pick a window or tab.
@MainActor
enum SessionHostActivator {
    /// Terminal servers that run from outside their app's bundle, so neither
    /// their parent nor their executable names the app. Prefixes, because the
    /// kernel's command name is truncated and versioned.
    private static let detachedServers: [(prefix: String, bundleID: String)] = [
        ("iTermServer", "com.googlecode.iterm2"),
    ]

    /// Returns false when no hosting app could be found, for example under
    /// tmux or screen, or when the agent has already exited.
    @discardableResult
    static func activate(agentPID: Int32) -> Bool {
        guard let app = hostApp(of: agentPID) else { return false }
        // Cooperative activation: the menu-bar popover makes Let It Brew the
        // active app, which may hand activation to the session's app.
        NSApp.yieldActivation(to: app)
        return app.activate()
    }

    /// The nearest regular app among the agent's ancestors, or the app that
    /// owns the detached host at the root of the agent's lineage.
    static func hostApp(of agentPID: Int32) -> NSRunningApplication? {
        let lineage = ProcessAncestry.lineage(of: agentPID)
        for process in lineage {
            guard let app = NSRunningApplication(processIdentifier: process.pid),
                  isCandidate(app)
            else { continue }
            return app
        }
        // Some terminal hosts run detached, so launchd rather than their app
        // is their parent: Orca's terminal host, iTerm2's server, or a helper
        // its app left behind. They are not registered apps, but the bundle
        // holding the executable names the app, by location or identifier.
        // Only that root process is consulted: an agent or tool below it may
        // itself ship inside another app's bundle, such as the Codex CLI in
        // the ChatGPT app, and under tmux the root names no app at all.
        guard let root = lineage.last, root.parentPID == 1 else { return nil }
        if let path = ProcessAncestry.executablePath(of: root.pid),
           let bundle = ProcessAncestry.outermostAppBundle(containing: path),
           let app = runningApp(forBundleAt: bundle) {
            return app
        }
        guard let server = detachedServers.first(where: { root.name.hasPrefix($0.prefix) })
        else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: server.bundleID)
            .first(where: isCandidate)
    }

    private static func runningApp(forBundleAt path: String) -> NSRunningApplication? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let running = NSWorkspace.shared.runningApplications.filter(isCandidate)
        if let app = running.first(where: { $0.bundleURL?.standardizedFileURL == url }) {
            return app
        }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        return running.first { $0.bundleIdentifier == bundleID }
    }

    private static func isCandidate(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app != NSRunningApplication.current
    }
}
