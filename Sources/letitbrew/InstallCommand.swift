import Darwin
import Foundation
import LetItBrewCore

private struct DanglingSymlink: Error { let path: String }
private struct UnsafeTarget: Error { let path: String }
private struct TestFault: Error { let name: String }

/// Fault injection is deliberately unavailable outside an explicitly anchored
/// test home.  It lets the shell contract exercise the actual command ordering
/// without adding a production mutation path.
private func hasTestFault(_ name: String, filesystem: CommandFilesystem) -> Bool {
    filesystem.testHome != nil && ProcessInfo.processInfo.environment["LETITBREW_TEST_FAULT"] == name
}

private func throwTestFault(_ name: String, filesystem: CommandFilesystem) throws {
    if hasTestFault(name, filesystem: filesystem) { throw TestFault(name: name) }
}

private enum Operation { case install, uninstall, doctor }

func resolvedCLIPath() -> String {
    var size: UInt32 = 0; _NSGetExecutablePath(nil, &size)
    var buffer = [Int8](repeating: 0, count: Int(size)); _NSGetExecutablePath(&buffer, &size)
    let resolved = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath().standardizedFileURL.path
    // Foundation's URL normalization does not consistently collapse the
    // Darwin `/tmp` alias. Persistent hooks must embed the same canonical
    // executable identity an external process receives through realpath(3).
    if let canonical = realpath(resolved, nil) {
        defer { free(canonical) }
        return String(cString: canonical)
    }
    return resolved
}

/// One command owns the test-home directory descriptor.  The environment is
/// read once here; selected test targets retain this anchor instead of being
/// checked by path and reopened later.
private final class CommandFilesystem {
    let anchor: DirectoryAnchor
    let testHome: DirectoryAnchor?
    let homeURL: URL
    let adapterEnvironment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let raw = environment["LETITBREW_TEST_HOME"] {
            guard !raw.isEmpty, raw.hasPrefix("/") else { throw UnsafeTarget(path: "LETITBREW_TEST_HOME must be an absolute path") }
            let anchor = try DirectoryAnchor.openNoFollow(at: URL(fileURLWithPath: raw).standardizedFileURL)
            self.anchor = anchor; testHome = anchor; homeURL = anchor.displayURL; adapterEnvironment = [:]
        } else {
            anchor = try DirectoryAnchor.openNoFollow(at: URL(fileURLWithPath: "/"))
            testHome = nil; homeURL = FileManager.default.homeDirectoryForCurrentUser; adapterEnvironment = environment
        }
    }

    func target(at url: URL, resolvingParentSymlinks: Bool = false) throws -> ExactFileTarget {
        let target = resolvingParentSymlinks && testHome == nil
            ? url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
            : url
        return try anchor.target(atAbsoluteURL: target)
    }

    func registryTarget() throws -> ExactFileTarget {
        try target(at: homeURL.appendingPathComponent("Library/Application Support/LetItBrew/agent-hook-targets.json"), resolvingParentSymlinks: true)
    }

    func recordedTarget(_ path: String) throws -> ExactFileTarget {
        try target(at: URL(fileURLWithPath: path))
    }

    func configuredTarget(for agent: AgentID) throws -> ExactFileTarget {
        let url: URL
        switch agent {
        case .claude: url = ClaudeHooks.settingsURL(home: homeURL)
        case .codex: url = CodexHooks.hooksURL(home: homeURL, environment: adapterEnvironment)
        case .opencode: url = OpenCodePlugin.pluginURL(home: homeURL, environment: adapterEnvironment)
        case .copilot: url = CopilotHooks.hooksURL(home: homeURL, environment: adapterEnvironment)
        }
        return try target(at: url, resolvingParentSymlinks: true)
    }
}

private struct LoadedRegistry { var value: AgentInstallRegistry; var capture: CapturedExactFile }

private func loadRegistry(_ filesystem: CommandFilesystem) throws -> LoadedRegistry {
    let capture = try filesystem.registryTarget().capture()
    guard let data = capture.data else { return LoadedRegistry(value: try AgentInstallRegistry(), capture: capture) }
    let registry = try JSONDecoder().decode(AgentInstallRegistry.self, from: data)
    for target in registry.targets.values { _ = try filesystem.recordedTarget(target) }
    return LoadedRegistry(value: registry, capture: capture)
}

private func saveRegistry(_ registry: AgentInstallRegistry, basedOn capture: CapturedExactFile) throws -> CapturedExactFile {
    let data = try JSONEncoder().encode(registry)
    // The returned still-bound capture is the only baseline for a later save
    // in this command.  Do not reconstruct the registry URL or reopen it.
    return try AtomicFile.write(data, replacing: capture, permissions: .exact(0o600))
}

/// Follow a user-owned JSON symlink exactly once at Connect, then record the
/// final file.  A dangling link is not treated as an absent configuration.
private func resolveJSONTarget(_ configured: ExactFileTarget, filesystem: CommandFilesystem) throws -> ExactFileTarget {
    do { return try configured.resolvingAnchoredFinalSymlink() }
    catch { throw DanglingSymlink(path: configured.displayPath) }
}

private func selectedTarget(_ agent: AgentID, registry: AgentInstallRegistry, connect: Bool, filesystem: CommandFilesystem) throws -> ExactFileTarget {
    if let recorded = registry.targets[agent] { return try filesystem.recordedTarget(recorded) }
    let configured = try filesystem.configuredTarget(for: agent)
    return connect && agent != .opencode ? try resolveJSONTarget(configured, filesystem: filesystem) : configured
}

private func replacement(agent: AgentID, data: Data?, cli: String, removing: Bool) throws -> Data? {
    switch agent {
    case .claude: return removing ? try ClaudeHooks.remove(from: data) : try ClaudeHooks.install(into: data, cliPath: cli)
    case .codex: return removing ? try CodexHooks.remove(from: data) : try CodexHooks.install(into: data, cliPath: cli)
    case .copilot: return removing ? try CopilotHooks.remove(from: data) : try CopilotHooks.install(into: data, cliPath: cli)
    case .opencode: return removing ? try OpenCodePlugin.remove(from: data) : try OpenCodePlugin.install(into: data, cliPath: cli)
    }
}

private func report(agent: AgentID, data: Data?, cli: String) -> HookInstallReport {
    switch agent {
    case .claude: ClaudeHooks.report(for: data, cliPath: cli)
    case .codex: CodexHooks.report(for: data, cliPath: cli)
    case .copilot: CopilotHooks.report(for: data, cliPath: cli)
    case .opencode: OpenCodePlugin.report(for: data, cliPath: cli)
    }
}

private func validate(agent: AgentID, data: Data?, cli: String) throws -> HookInstallReport {
    _ = try replacement(agent: agent, data: data, cli: cli, removing: false)
    return report(agent: agent, data: data, cli: cli)
}

private func failure(_ agent: AgentID, _ target: ExactFileTarget, _ error: Error, _ operation: Operation) {
    let verb = operation == .install ? "installed" : operation == .uninstall ? "removed" : "inspected"
    FileHandle.standardError.write(Data("\(agent.displayName): could not be \(verb) at \(target.displayPath); file was left unchanged (\(error)).\n".utf8))
}

/// Keeps the one descriptor capture that supplied the adapter's input alive
/// across registry persistence and into the vendor commit.
private struct Prepared { let observed: CapturedExactFile; let replacement: Data }

func runInstall(agents: Set<AgentID> = Set(AgentID.allCases)) -> Int32 {
    let cli = resolvedCLIPath(); var failures = 0
    do {
        let filesystem = try CommandFilesystem(); var loadedRegistry = try loadRegistry(filesystem); var registry = loadedRegistry.value
        for agent in AgentID.allCases where agents.contains(agent) {
            let target = try selectedTarget(agent, registry: registry, connect: true, filesystem: filesystem)
            do {
                try AgentInstallTransaction.install(preflightPureTransform: {
                    let observed = try target.capture()
                    let existing = observed.data
                    let bytes = try replacement(agent: agent, data: existing, cli: cli, removing: false)
                    return Prepared(observed: observed, replacement: bytes!)
                }, persistExactTarget: { prepared in
                    try throwTestFault("registry-persist", filesystem: filesystem)
                    registry.targets[agent] = prepared.observed.target.displayPath; loadedRegistry.capture = try saveRegistry(registry, basedOn: loadedRegistry.capture)
                }, commitVendorMutation: { prepared in
                    try throwTestFault("vendor-commit", filesystem: filesystem)
                    _ = try AtomicFile.write(prepared.replacement, replacing: prepared.observed)
                })
                print("\(agent.displayName): installed")
            } catch { failure(agent, target, error, .install); failures += 1 }
        }
    } catch { FileHandle.standardError.write(Data("Let It Brew: registry refused before configuration mutation (\(error)).\n".utf8)); return 1 }
    return failures == 0 ? 0 : 1
}

func runUninstall(agents: Set<AgentID> = Set(AgentID.allCases)) -> Int32 {
    let cli = resolvedCLIPath(); var failures = 0
    do {
        let filesystem = try CommandFilesystem(); var loadedRegistry = try loadRegistry(filesystem); var registry = loadedRegistry.value
        for agent in AgentID.allCases where agents.contains(agent) {
            let target = try selectedTarget(agent, registry: registry, connect: false, filesystem: filesystem)
            do {
                try AgentInstallTransaction.uninstall(removeOwnedOrProveAbsent: {
                    let observed = try target.capture()
                    let existing = observed.data
                    guard let existing else { return }
                    if agent == .opencode {
                        guard try replacement(agent: agent, data: existing, cli: cli, removing: true) == nil else { throw UnsafeTarget(path: target.displayPath) }
                        try throwTestFault("vendor-remove", filesystem: filesystem)
                        let hooks = hasTestFault("active-replacement", filesystem: filesystem)
                            ? AtomicFile.RaceHooks(afterQuarantineValidationBeforePublish: {
                                try AtomicFile.testOnlyPublishActiveReplacement(observed, data: Data("foreign replacement after quarantine".utf8))
                            })
                            : AtomicFile.RaceHooks()
                        try AtomicFile.remove(observed, expectedData: existing, hooks: hooks)
                    } else if (try validate(agent: agent, data: existing, cli: cli)).isAbsent {
                        // A stale registry retry only clears its record; it
                        // never reformats a clean/foreign JSON replacement.
                        return
                    } else {
                        try throwTestFault("vendor-remove", filesystem: filesystem)
                        let output = try replacement(agent: agent, data: existing, cli: cli, removing: true)!
                        _ = try AtomicFile.write(output, replacing: observed)
                    }
                }, clearExactTarget: {
                    try throwTestFault("registry-clear", filesystem: filesystem)
                    registry.targets.removeValue(forKey: agent); loadedRegistry.capture = try saveRegistry(registry, basedOn: loadedRegistry.capture)
                })
                print("\(agent.displayName): hooks removed")
            } catch { failure(agent, target, error, .uninstall); failures += 1 }
        }
    } catch { FileHandle.standardError.write(Data("Let It Brew: registry refused before configuration mutation (\(error)).\n".utf8)); return 1 }
    return failures == 0 ? 0 : 1
}

private func doctorAgent(_ agent: AgentID, registry: AgentInstallRegistry, cli: String, filesystem: CommandFilesystem) -> Bool {
    do {
        let target = try selectedTarget(agent, registry: registry, connect: false, filesystem: filesystem)
        let data = try target.capture().data
        guard data != nil else { print("\(agent.displayName): not installed"); return false }
        let state = try validate(agent: agent, data: data, cli: cli)
        if state.isHealthy { print("\(agent.displayName): healthy"); return true }
        if state.isAbsent { print("\(agent.displayName): not installed"); return false }
        print("\(agent.displayName): needs repair"); return false
    } catch { print("\(agent.displayName): configuration invalid"); return false }
}

func runDoctor(agents: Set<AgentID> = Set(AgentID.allCases)) -> Int32 {
    let filesystem = try? CommandFilesystem()
    let loadedRegistry = filesystem.flatMap { try? loadRegistry($0) }; let cli = resolvedCLIPath()
    let agentsHealthy: Bool
    if let registry = loadedRegistry?.value, let filesystem {
        agentsHealthy = AgentID.allCases.filter { agents.contains($0) }.map { doctorAgent($0, registry: registry, cli: cli, filesystem: filesystem) }.allSatisfy { $0 }
    } else {
        for agent in AgentID.allCases where agents.contains(agent) { print("\(agent.displayName): configuration invalid") }
        agentsHealthy = false
    }
    let leaseHealthy = doctorLease()
    return agentsHealthy && leaseHealthy ? 0 : 1
}

/// Hidden handoff used by the app.  It verifies the inspection snapshot and
/// repeats pure validation before any registry or vendor change.
func runPrepareExact(agent: AgentID, input: Data) -> Int32 {
    do {
        let preparation = try JSONDecoder().decode(ExactTargetPreparation.self, from: input)
        guard preparation.agent == agent else { throw UnsafeTarget(path: "agent mismatch") }
        let filesystem = try CommandFilesystem()
        let target = try filesystem.target(at: URL(fileURLWithPath: preparation.snapshot.path))
        var loadedRegistry = try loadRegistry(filesystem); var registry = loadedRegistry.value
        if let other = registry.targets[agent], other != target.displayPath { throw UnsafeTarget(path: other) }
        let capture = try target.capture()
        guard capture.snapshot == preparation.snapshot else { throw UnsafeTarget(path: target.displayPath) }
        let cli = resolvedCLIPath(); let current = capture.data
        let currentReport = try validate(agent: agent, data: current, cli: cli)
        let observed: ExactTargetExpectedState = current == nil ? .absent : currentReport.isHealthy ? .healthyOwned : currentReport.isAbsent ? .absent : .repairableOwned
        guard observed == preparation.expectedState else { throw UnsafeTarget(path: target.displayPath) }
        if observed == .healthyOwned { registry.targets[agent] = target.displayPath; _ = try saveRegistry(registry, basedOn: loadedRegistry.capture); return 0 }
        let bytes = try replacement(agent: agent, data: current, cli: cli, removing: false)!
        try AgentInstallTransaction.install(preflightPureTransform: { Prepared(observed: capture, replacement: bytes) }, persistExactTarget: { prepared in registry.targets[agent] = prepared.observed.target.displayPath; loadedRegistry.capture = try saveRegistry(registry, basedOn: loadedRegistry.capture) }, commitVendorMutation: { prepared in _ = try AtomicFile.write(prepared.replacement, replacing: prepared.observed) })
        return 0
    } catch { FileHandle.standardError.write(Data("prepare-exact refused: \(error)\n".utf8)); return 1 }
}

private func doctorLease() -> Bool {
    switch SleepWatchdogDebtCheck.status(at: OsascriptSleepWatchdog.defaultLeaseURL) {
    case .none: print("Lid-closed watchdog: no active lease"); return true
    case .held(let debt): print("Lid-closed watchdog: held (watchdog pid \(debt.watchdogPID), armed by app pid \(debt.appPID))"); return true
    case .orphaned: print("Lid-closed watchdog: ORPHANED — run `letitbrew repair` to fix."); return false
    case .unreadable: print("Lid-closed watchdog: UNREADABLE lease — run `letitbrew repair`."); return false
    }
}
