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
