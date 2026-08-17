import Foundation
import Testing
@testable import LetItBrewCore
@Test func registryRejectsRelativeTarget() { #expect(throws: AgentInstallRegistryError.self) { _ = try AgentInstallRegistry(targets: [.copilot: "relative.json"]) } }
@Test func registryRoundTripsKnownAgentsOnly() throws { let registry = try AgentInstallRegistry(targets: [.opencode: "/tmp/plugin.js"]); #expect(try JSONDecoder().decode(AgentInstallRegistry.self, from: JSONEncoder().encode(registry)) == registry) }
@Test func registryUsesStrictTargetsObject() throws {
    let data = try JSONEncoder().encode(AgentInstallRegistry(targets: [.cursor: "/tmp/hooks.json"]))
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let targets = try #require(root["targets"] as? [String: String])
    #expect(targets == ["cursor": "/tmp/hooks.json"])
    #expect(throws: Error.self) { _ = try JSONDecoder().decode(AgentInstallRegistry.self, from: Data("{\"version\":1,\"targets\":{\"unknown\":\"/tmp/x\"}}".utf8)) }
}
