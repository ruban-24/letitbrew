import Foundation
import Testing
@testable import LetItBrewCore
@Test func registryRejectsRelativeTarget() { #expect(throws: AgentInstallRegistryError.self) { _ = try AgentInstallRegistry(targets: [.copilot: "relative.json"]) } }
@Test func registryRoundTripsKnownAgentsOnly() throws { let registry = try AgentInstallRegistry(targets: [.opencode: "/tmp/plugin.js"]); #expect(try JSONDecoder().decode(AgentInstallRegistry.self, from: JSONEncoder().encode(registry)) == registry) }
