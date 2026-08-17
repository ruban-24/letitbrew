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

@Test func registryRejectsAnyTopLevelSchemaDeviationBeforeTypedDecode() {
    let invalidDocuments = [
        "{\"version\":1,\"targets\":{},\"extra\":true}",
        "{\"version\":1}",
        "{\"targets\":{}}",
        "{\"version\":\"1\",\"targets\":{}}",
        "{\"version\":1,\"targets\":[]}",
    ]
    for document in invalidDocuments {
        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(AgentInstallRegistry.self, from: Data(document.utf8))
        }
    }
}

@Test func registryRejectsUnsupportedVersionUnknownAgentAndInvalidTargetPath() {
    #expect(throws: AgentInstallRegistryError.unsupportedVersion) {
        _ = try JSONDecoder().decode(AgentInstallRegistry.self, from: Data("{\"version\":2,\"targets\":{}}".utf8))
    }
    #expect(throws: AgentInstallRegistryError.invalidAgent("unknown")) {
        _ = try JSONDecoder().decode(AgentInstallRegistry.self, from: Data("{\"version\":1,\"targets\":{\"unknown\":\"/tmp/x\"}}".utf8))
    }
    #expect(throws: AgentInstallRegistryError.invalidPath("relative.json")) {
        _ = try JSONDecoder().decode(AgentInstallRegistry.self, from: Data("{\"version\":1,\"targets\":{\"claude\":\"relative.json\"}}".utf8))
    }
}

private func registryFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("registry-exact-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("agent-hook-targets.json")
}

@Test func registryPrivatePublicationAndSuccessiveBaselines() throws {
    let url = try registryFile(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var capture = try ExactFileCapture.capture(at: url)
    var registry = try AgentInstallRegistry(targets: [.claude: "/tmp/claude.json"])
    try AtomicFile.write(try JSONEncoder().encode(registry), to: url, ifUnchangedFrom: capture, privateMode: true)
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    capture = try ExactFileCapture.capture(at: url)
    registry.targets[.copilot] = "/tmp/copilot.json"
    try AtomicFile.write(try JSONEncoder().encode(registry), to: url, ifUnchangedFrom: capture, privateMode: true)
    let decoded = try JSONDecoder().decode(AgentInstallRegistry.self, from: Data(contentsOf: url))
    #expect(decoded.targets == registry.targets)
}

@Test func registryCaptureRefusesContentAndInodeReplacement() throws {
    let url = try registryFile(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try Data("first".utf8).write(to: url)
    let contentCapture = try ExactFileCapture.capture(at: url)
    try Data("other".utf8).write(to: url)
    #expect(throws: ConcurrentModification.self) { try AtomicFile.write(Data("new".utf8), to: url, ifUnchangedFrom: contentCapture, privateMode: true) }
    try Data("same".utf8).write(to: url)
    let inodeCapture = try ExactFileCapture.capture(at: url)
    let moved = url.appendingPathExtension("old")
    try FileManager.default.moveItem(at: url, to: moved)
    try Data("same".utf8).write(to: url)
    #expect(throws: ConcurrentModification.self) { try AtomicFile.write(Data("new".utf8), to: url, ifUnchangedFrom: inodeCapture, privateMode: true) }
}

@Test func registryFinalAndParentSymlinksAreRefused() throws {
    let url = try registryFile(); let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target")
    try Data("registry".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    #expect(throws: ExactFileSnapshotError.self) { try ExactFileCapture.capture(at: url) }
    let linkedParent = directory.appendingPathComponent("linked-parent")
    try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: directory)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: linkedParent.path)) != nil)
}
