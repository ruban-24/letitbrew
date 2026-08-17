import Darwin
import Foundation
import LetItBrewCore

private struct DanglingSymlink: Error { let path: String }
private struct UnsafeTarget: Error { let path: String }

private enum Operation { case install, uninstall, doctor }

func resolvedCLIPath() -> String {
    var size: UInt32 = 0; _NSGetExecutablePath(nil, &size)
    var buffer = [Int8](repeating: 0, count: Int(size)); _NSGetExecutablePath(&buffer, &size)
    let resolved = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().standardizedFileURL.path
    // Foundation's URL normalization does not consistently collapse the
    // Darwin `/tmp` alias. Persistent hooks must embed the same canonical
    // executable identity an external process receives through realpath(3).
    if let canonical = realpath(resolved, nil) {
        defer { free(canonical) }
        return String(cString: canonical)
    }
    return resolved
}

private func testHome() throws -> URL? {
    guard let value = ProcessInfo.processInfo.environment["LETITBREW_TEST_HOME"] else { return nil }
    guard !value.isEmpty, value.hasPrefix("/") else { throw UnsafeTarget(path: "LETITBREW_TEST_HOME must be an absolute path") }
    let url = URL(fileURLWithPath: value).standardizedFileURL
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { throw UnsafeTarget(path: url.path) }
    return url
}

private func isWithinTestHome(_ url: URL) throws {
    guard let root = try testHome() else { return }
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard url.standardizedFileURL.path.hasPrefix(rootPath) else { throw UnsafeTarget(path: url.path) }
    var current = root
    for part in url.standardizedFileURL.path.dropFirst(rootPath.count).split(separator: "/") {
        current.appendPathComponent(String(part))
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil { throw UnsafeTarget(path: current.path) }
    }
}

private func home() throws -> URL { try testHome() ?? FileManager.default.homeDirectoryForCurrentUser }
private func isolatedEnvironment() throws -> [String: String] { try testHome() == nil ? ProcessInfo.processInfo.environment : [:] }

private func registryURL() throws -> URL {
    if let root = try testHome() { return root.appendingPathComponent("Library/Application Support/LetItBrew/agent-hook-targets.json") }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LetItBrew/agent-hook-targets.json")
}

private func rejectSymlink(_ url: URL) throws {
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { throw UnsafeTarget(path: url.path) }
}

private struct LoadedRegistry { var value: AgentInstallRegistry; var capture: ExactFileCapture }

private func loadRegistry() throws -> LoadedRegistry {
    let url = try registryURL(); try isWithinTestHome(url); try rejectSymlink(url)
    let capture = try ExactFileCapture.capture(at: url)
    guard let data = capture.data else { return LoadedRegistry(value: try AgentInstallRegistry(), capture: capture) }
    let registry = try JSONDecoder().decode(AgentInstallRegistry.self, from: data)
    for target in registry.targets.values { try isWithinTestHome(URL(fileURLWithPath: target)) }
    return LoadedRegistry(value: registry, capture: capture)
}

private func saveRegistry(_ registry: AgentInstallRegistry, basedOn capture: ExactFileCapture) throws -> ExactFileCapture {
    let url = try registryURL(); try isWithinTestHome(url); try rejectSymlink(url)
    let data = try JSONEncoder().encode(registry)
    try AtomicFile.write(data, to: url, ifUnchangedFrom: capture, privateMode: true)
    return try ExactFileCapture.capture(at: url)
}

/// Follow a user-owned JSON symlink exactly once at Connect, then record the
/// final file.  A dangling link is not treated as an absent configuration.
private func resolveJSONTarget(_ configured: URL) throws -> URL {
    var current = configured.standardizedFileURL; var hops = 0
    while let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) {
        hops += 1; guard hops <= 32 else { throw DanglingSymlink(path: configured.path) }
        current = URL(fileURLWithPath: destination, relativeTo: current.deletingLastPathComponent()).standardizedFileURL
    }
    if hops > 0 && !FileManager.default.fileExists(atPath: current.path) { throw DanglingSymlink(path: configured.path) }
    current = current.resolvingSymlinksInPath().standardizedFileURL
    try isWithinTestHome(current)
    return current
}

private func configuredURL(for agent: AgentID) throws -> URL {
    let h = try home(); let environment = try isolatedEnvironment()
    let url: URL
    switch agent {
    case .claude: url = ClaudeHooks.settingsURL(home: h)
    case .codex: url = CodexHooks.hooksURL(home: h, environment: environment)
    case .cursor: url = CursorHooks.settingsURL(home: h)
    case .opencode: url = OpenCodePlugin.pluginURL(home: h, environment: environment)
    case .copilot: url = CopilotHooks.hooksURL(home: h, environment: environment)
    }
    try isWithinTestHome(url); return url.standardizedFileURL
}

private func selectedTarget(_ agent: AgentID, registry: AgentInstallRegistry, connect: Bool) throws -> URL {
    if let recorded = registry.targets[agent] { let url = URL(fileURLWithPath: recorded); try isWithinTestHome(url); return url }
    let configured = try configuredURL(for: agent)
    return connect && agent != .opencode ? try resolveJSONTarget(configured) : configured
}

private func readTarget(_ target: URL, opencode: Bool = false) throws -> Data? {
    try rejectSymlink(target)
    return try ExactFileCapture.capture(at: target).data
}

private func replacement(agent: AgentID, data: Data?, cli: String, removing: Bool) throws -> Data? {
    switch agent {
    case .claude: return removing ? try ClaudeHooks.remove(from: data) : try ClaudeHooks.install(into: data, cliPath: cli)
    case .codex: return removing ? try CodexHooks.remove(from: data) : try CodexHooks.install(into: data, cliPath: cli)
    case .cursor: return removing ? try CursorHooks.remove(from: data) : try CursorHooks.install(into: data, cliPath: cli)
    case .copilot: return removing ? try CopilotHooks.remove(from: data) : try CopilotHooks.install(into: data, cliPath: cli)
    case .opencode: return removing ? try OpenCodePlugin.remove(from: data) : try OpenCodePlugin.install(into: data, cliPath: cli)
    }
}

private func report(agent: AgentID, data: Data?, cli: String) -> HookInstallReport {
    switch agent {
    case .claude: ClaudeHooks.report(for: data, cliPath: cli)
    case .codex: CodexHooks.report(for: data, cliPath: cli)
    case .cursor: CursorHooks.report(for: data, cliPath: cli)
    case .copilot: CopilotHooks.report(for: data, cliPath: cli)
    case .opencode: OpenCodePlugin.report(for: data, cliPath: cli)
    }
}

private func validate(agent: AgentID, data: Data?, cli: String) throws -> HookInstallReport {
    _ = try replacement(agent: agent, data: data, cli: cli, removing: false)
    return report(agent: agent, data: data, cli: cli)
}

private func failure(_ agent: AgentID, _ target: URL, _ error: Error, _ operation: Operation) {
    let verb = operation == .install ? "installed" : operation == .uninstall ? "removed" : "inspected"
    FileHandle.standardError.write(Data("\(agent.displayName): could not be \(verb) at \(target.path); file was left unchanged (\(error)).\n".utf8))
}

private struct Prepared { let target: URL; let capture: ExactFileCapture; let replacement: Data }

func runInstall(agents: Set<AgentID> = Set(AgentID.allCases)) -> Int32 {
    let cli = resolvedCLIPath(); var failures = 0
    do {
        var loadedRegistry = try loadRegistry(); var registry = loadedRegistry.value
        for agent in AgentID.allCases where agents.contains(agent) {
            let target = try selectedTarget(agent, registry: registry, connect: true)
            do {
                try AgentInstallTransaction.install(preflightPureTransform: {
                    let capture = try ExactFileCapture.capture(at: target)
                    let existing = capture.data
                    let bytes = try replacement(agent: agent, data: existing, cli: cli, removing: false)
                    return Prepared(target: target, capture: capture, replacement: bytes!)
                }, persistExactTarget: { prepared in
                    registry.targets[agent] = prepared.target.path; loadedRegistry.capture = try saveRegistry(registry, basedOn: loadedRegistry.capture)
                }, commitVendorMutation: { prepared in
                    try AtomicFile.write(prepared.replacement, to: prepared.target, ifUnchangedFrom: prepared.capture)
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
        var loadedRegistry = try loadRegistry(); var registry = loadedRegistry.value
        for agent in AgentID.allCases where agents.contains(agent) {
            let target = try selectedTarget(agent, registry: registry, connect: false)
            do {
                try AgentInstallTransaction.uninstall(removeOwnedOrProveAbsent: {
                    let existing = try readTarget(target, opencode: agent == .opencode)
                    guard let existing else { return }
                    if agent == .opencode {
                        guard try replacement(agent: agent, data: existing, cli: cli, removing: true) == nil else { throw UnsafeTarget(path: target.path) }
                        try AtomicFile.remove(target, ifUnchangedFrom: existing)
                    } else if (try validate(agent: agent, data: existing, cli: cli)).isAbsent {
                        // A stale registry retry only clears its record; it
                        // never reformats a clean/foreign JSON replacement.
                        return
                    } else {
                        let output = try replacement(agent: agent, data: existing, cli: cli, removing: true)!
                        let capture = try ExactFileCapture.capture(at: target)
                        guard capture.data == existing else { throw ConcurrentModification(path: target.path) }
                        try AtomicFile.write(output, to: target, ifUnchangedFrom: capture)
                    }
                }, clearExactTarget: {
                    registry.targets.removeValue(forKey: agent); loadedRegistry.capture = try saveRegistry(registry, basedOn: loadedRegistry.capture)
                })
                print("\(agent.displayName): hooks removed")
            } catch { failure(agent, target, error, .uninstall); failures += 1 }
        }
    } catch { FileHandle.standardError.write(Data("Let It Brew: registry refused before configuration mutation (\(error)).\n".utf8)); return 1 }
    return failures == 0 ? 0 : 1
}

private func doctorAgent(_ agent: AgentID, registry: AgentInstallRegistry, cli: String) -> Bool {
    do {
        let target = try selectedTarget(agent, registry: registry, connect: false)
        let data = try readTarget(target, opencode: agent == .opencode)
        guard data != nil else { print("\(agent.displayName): not installed"); return false }
        let state = try validate(agent: agent, data: data, cli: cli)
        if state.isHealthy { print("\(agent.displayName): healthy"); return true }
        if state.isAbsent { print("\(agent.displayName): not installed"); return false }
        print("\(agent.displayName): needs repair"); return false
    } catch { print("\(agent.displayName): configuration invalid"); return false }
}

func runDoctor(agents: Set<AgentID> = Set(AgentID.allCases)) -> Int32 {
    let loadedRegistry = try? loadRegistry(); let cli = resolvedCLIPath()
    let agentsHealthy: Bool
    if let registry = loadedRegistry?.value {
        agentsHealthy = AgentID.allCases.filter { agents.contains($0) }.map { doctorAgent($0, registry: registry, cli: cli) }.allSatisfy { $0 }
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
        let target = URL(fileURLWithPath: preparation.snapshot.path); try isWithinTestHome(target)
        var loadedRegistry = try loadRegistry(); var registry = loadedRegistry.value
        if let other = registry.targets[agent], other != target.path { throw UnsafeTarget(path: other) }
        let capture = try ExactFileCapture.capture(at: target)
        guard capture.snapshot == preparation.snapshot else { throw UnsafeTarget(path: target.path) }
        let cli = resolvedCLIPath(); let current = capture.data
        let currentReport = try validate(agent: agent, data: current, cli: cli)
        let observed: ExactTargetExpectedState = current == nil ? .absent : currentReport.isHealthy ? .healthyOwned : currentReport.isAbsent ? .absent : .repairableOwned
        guard observed == preparation.expectedState else { throw UnsafeTarget(path: target.path) }
        if observed == .healthyOwned { registry.targets[agent] = target.path; _ = try saveRegistry(registry, basedOn: loadedRegistry.capture); return 0 }
        let bytes = try replacement(agent: agent, data: current, cli: cli, removing: false)!
        try AgentInstallTransaction.install(preflightPureTransform: { Prepared(target: target, capture: capture, replacement: bytes) }, persistExactTarget: { prepared in registry.targets[agent] = prepared.target.path; loadedRegistry.capture = try saveRegistry(registry, basedOn: loadedRegistry.capture) }, commitVendorMutation: { prepared in try AtomicFile.write(prepared.replacement, to: prepared.target, ifUnchangedFrom: prepared.capture) })
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
