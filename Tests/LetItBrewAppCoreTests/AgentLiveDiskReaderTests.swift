import Foundation
import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

@Test func liveReaderRefusesRegistryAndRecordedSymlinksButResolvesConfiguredJSONOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = root.appendingPathComponent("registry.json")
    let registryReal = root.appendingPathComponent("registry-real.json")
    try Data("{}".utf8).write(to: registryReal)
    try FileManager.default.createSymbolicLink(at: registry, withDestinationURL: registryReal)
    let configured = root.appendingPathComponent("configured.json")
    let final = root.appendingPathComponent("final.json")
    try Data("{}".utf8).write(to: final)
    try FileManager.default.createSymbolicLink(at: configured, withDestinationURL: final)
    let invalidRegistry = AgentLiveDiskReader.inspect(agent: .claude, registryURL: registry, defaultTarget: configured, helperPath: "/letitbrew")
    #expect(invalidRegistry.state == .invalid)

    try FileManager.default.removeItem(at: registry)
    let cleanRegistry = try AgentInstallRegistry(targets: [:])
    try JSONEncoder().encode(cleanRegistry).write(to: registry)
    let configuredResult = AgentLiveDiskReader.inspect(agent: .claude, registryURL: registry, defaultTarget: configured, helperPath: "/letitbrew")
    #expect(configuredResult.target == final)

    let recordedLink = root.appendingPathComponent("recorded-link.json")
    try FileManager.default.createSymbolicLink(at: recordedLink, withDestinationURL: final)
    let recordedRegistry = try AgentInstallRegistry(targets: [.claude: recordedLink.path])
    try JSONEncoder().encode(recordedRegistry).write(to: registry)
    let recorded = AgentLiveDiskReader.inspect(agent: .claude, registryURL: registry, defaultTarget: configured, helperPath: "/letitbrew")
    #expect(recorded.state == .invalid)

    let openCode = root.appendingPathComponent("letitbrew.js")
    try FileManager.default.createSymbolicLink(at: openCode, withDestinationURL: final)
    let openCodeResult = AgentLiveDiskReader.inspect(agent: .opencode, registryURL: root.appendingPathComponent("absent-registry"), defaultTarget: openCode, helperPath: "/letitbrew")
    #expect(openCodeResult.state == .invalid)

    let dangling = root.appendingPathComponent("dangling.json")
    try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing.json"))
    let danglingResult = AgentLiveDiskReader.inspect(agent: .claude, registryURL: root.appendingPathComponent("absent-registry"), defaultTarget: dangling, helperPath: "/letitbrew")
    #expect(danglingResult.state == .invalid)
}

@Test func liveReaderResolvesOpenCodeParentSymlinksWithoutFollowingThePluginLeaf() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let actualPlugins = root.appendingPathComponent("actual/plugins")
    try FileManager.default.createDirectory(at: actualPlugins, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let configuredRoot = root.appendingPathComponent("configured")
    try FileManager.default.createSymbolicLink(
        at: configuredRoot,
        withDestinationURL: root.appendingPathComponent("actual")
    )
    let configuredPlugin = configuredRoot.appendingPathComponent("plugins/letitbrew.js")
    let actualPlugin = actualPlugins.appendingPathComponent("letitbrew.js")
    try OpenCodePlugin.install(into: nil, cliPath: "/letitbrew").write(to: actualPlugin)

    let result = AgentLiveDiskReader.inspect(
        agent: .opencode,
        registryURL: root.appendingPathComponent("missing-registry.json"),
        defaultTarget: configuredPlugin,
        helperPath: "/letitbrew"
    )

    #expect(result.state == .healthyOwned)
    #expect(result.target == actualPlugin.standardizedFileURL)
    #expect(result.snapshot?.path == actualPlugin.standardizedFileURL.path)
}

@Test func liveReaderInjectsExactlyOneSelectedCaptureAndNeverAnAlternate() throws {
    let selected = URL(fileURLWithPath: "/recorded/A.json")
    let ambient = URL(fileURLWithPath: "/ambient/B.json")
    let registry = try AgentInstallRegistry(targets: [.copilot: selected.path])
    var calls: [(URL, Bool, AgentID)] = []
    let result = AgentLiveDiskReader.inspect(
        agent: .copilot, registry: .valid(registry), defaultTarget: ambient,
        helperPath: "/letitbrew",
        readExactTarget: { target, recorded, agent in
            calls.append((target, recorded, agent))
            return .absent(try! ExactFileSnapshot(path: target.path, exists: false))
        }
    )
    #expect(calls.count == 1)
    #expect(calls[0].0 == selected && calls[0].1 && calls[0].2 == .copilot)
    #expect(result.target == selected)
}

@Test func liveReaderUsesOneInjectedRegistryAndSelectedCaptureForRecordedAndConfiguredProvenance() throws {
    let registryURL = URL(fileURLWithPath: "/registry/targets.json")
    let recorded = URL(fileURLWithPath: "/recorded/A.json")
    let configured = URL(fileURLWithPath: "/configured/B.json")
    let absentRecorded = try ExactFileSnapshot(path: recorded.path, exists: false)
    let absentConfigured = try ExactFileSnapshot(path: configured.path, exists: false)
    for (agent, registry, target, expectedRecorded, snapshot) in [
        (AgentID.claude, AgentDiskRegistry.valid(try .init(targets: [.claude: recorded.path])), recorded, true, absentRecorded),
        (AgentID.copilot, AgentDiskRegistry.valid(nil), configured, false, absentConfigured),
    ] {
        var registryReads = 0
        var targetReads: [(URL, Bool, AgentID)] = []
        let result = AgentLiveDiskReader.inspect(
            agent: agent,
            registryURL: registryURL,
            defaultTarget: configured,
            helperPath: "/letitbrew",
            registryReader: { url in
                registryReads += 1
                #expect(url == registryURL)
                return registry
            },
            readExactTarget: { url, recorded, agent in
                targetReads.append((url, recorded, agent))
                return .absent(snapshot)
            }
        )
        #expect(registryReads == 1)
        #expect(targetReads.count == 1)
        #expect(targetReads.first?.0 == target)
        #expect(targetReads.first?.1 == expectedRecorded)
        #expect(targetReads.first?.2 == agent)
        #expect(result.target == target)
    }
}

@Test func liveReaderMakesUnreadableAndNonregularReadsInvalidWithoutFallback() throws {
    let target = URL(fileURLWithPath: "/selected/target")
    let registry = AgentDiskRegistry.valid(nil)
    for reason in ["unreadable", "not a regular file"] {
        var calls = 0
        let result = AgentLiveDiskReader.inspect(
            agent: .opencode,
            registry: registry,
            defaultTarget: target,
            helperPath: "/letitbrew",
            readExactTarget: { url, recorded, _ in
                calls += 1
                #expect(url == target)
                #expect(!recorded)
                return .invalid(resolvedURL: target, reason: reason)
            }
        )
        #expect(calls == 1)
        #expect(result.state == .invalid)
    }
}

@Test func liveReaderRefusesActualUnreadableAndNonregularTargets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = root.appendingPathComponent("missing-registry.json")
    let directory = root.appendingPathComponent("directory-target")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(AgentLiveDiskReader.inspect(agent: .opencode, registryURL: registry, defaultTarget: directory, helperPath: "/letitbrew").state == .invalid)

    let unreadable = root.appendingPathComponent("unreadable.js")
    try Data("{}".utf8).write(to: unreadable)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
    #expect(AgentLiveDiskReader.inspect(agent: .opencode, registryURL: registry, defaultTarget: unreadable, helperPath: "/letitbrew").state == .invalid)
}

@Test func liveReaderClassifiesPinnedACaptureAfterRecordedAndConfiguredComponentReplacement() throws {
    for recorded in [true, false] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let component = root.appendingPathComponent("component")
        let selected = component.appendingPathComponent("A.json")
        let ambientB = root.appendingPathComponent("ambient-B.json")
        try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ClaudeHooks.install(into: nil, cliPath: "/letitbrew").write(to: selected)
        try Data("foreign B".utf8).write(to: ambientB)
        let bBefore = try Data(contentsOf: ambientB)
        let bAttributes = try FileManager.default.attributesOfItem(atPath: ambientB.path)
        let registry: AgentDiskRegistry = recorded
            ? .valid(try AgentInstallRegistry(targets: [.claude: selected.path]))
            : .valid(nil)
        var captures: [(URL, Bool, AgentID)] = []
        let result = AgentLiveDiskReader.inspect(
            agent: .claude,
            registry: registry,
            defaultTarget: selected,
            helperPath: "/letitbrew",
            hooks: .init(afterExactCapture: { target, usedRecorded, agent, capture in
                captures.append((target, usedRecorded, agent))
                #expect(capture.snapshot.path == selected.path)
                #expect(capture.data != nil)
                let retired = root.appendingPathComponent("retired")
                try FileManager.default.moveItem(at: component, to: retired)
                try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
                try Data("replacement not A".utf8).write(to: selected)
            })
        )
        #expect(result.state == .healthyOwned)
        #expect(captures.count == 1)
        #expect(captures.first?.0 == selected)
        #expect(captures.first?.1 == recorded)
        #expect(captures.first?.2 == .claude)
        #expect(try Data(contentsOf: ambientB) == bBefore)
        let bAfter = try FileManager.default.attributesOfItem(atPath: ambientB.path)
        #expect(bAfter[.systemFileNumber] as? NSNumber == bAttributes[.systemFileNumber] as? NSNumber)
        #expect(bAfter[.modificationDate] as? Date == bAttributes[.modificationDate] as? Date)
    }
}

@Test func liveReaderUsesCapturedRegistryBytesWhenRegistryNameIsReplaced() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registryURL = root.appendingPathComponent("registry.json")
    let selected = root.appendingPathComponent("recorded-A.json")
    let ambientB = root.appendingPathComponent("ambient-B.json")
    try Data("{}".utf8).write(to: selected)
    try Data("foreign B".utf8).write(to: ambientB)
    try JSONEncoder().encode(try AgentInstallRegistry(targets: [.claude: selected.path])).write(to: registryURL)
    var targetCaptures: [URL] = []
    let result = AgentLiveDiskReader.inspect(
        agent: .claude, registryURL: registryURL, defaultTarget: ambientB, helperPath: "/letitbrew",
        readExactTarget: { target, _, _ in
            targetCaptures.append(target)
            return .absent(try! ExactFileSnapshot(path: target.path, exists: false))
        },
        registryHooks: .init(afterExactCapture: { _ in
            let replacement = root.appendingPathComponent("replacement.json")
            try? Data("not registry JSON".utf8).write(to: replacement)
            try? FileManager.default.removeItem(at: registryURL)
            try? FileManager.default.moveItem(at: replacement, to: registryURL)
        })
    )
    #expect(targetCaptures == [selected])
    #expect(result.target == selected)
}
