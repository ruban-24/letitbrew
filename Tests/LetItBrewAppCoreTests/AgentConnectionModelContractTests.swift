import Foundation
import Testing

private func sourceFile(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(path))
}

@Test func modelUsesExplicitFiveAgentConnectionOrchestration() throws {
    let source = try sourceFile("Sources/LetItBrewApp/LetItBrewAppModel.swift")
    #expect(source.contains("connectedAgentIDsV2"))
    #expect(source.contains("AgentID.allCases.map"))
    #expect(source.contains("AgentLaunchConnectionPolicy.decision"))
    #expect(source.contains("AgentConnectionActionCoordinator.perform"))
    #expect(source.contains("AgentDiskInspection.inspect"))
    #expect(source.contains("AgentLaunchPreparationRunner.run"))
    #expect(source.contains("persistConnectedAgentIDs(next)"))
    #expect(source.contains("reapplyLatestSnapshot(connectedAgentIDs: next)"))
    #expect(!source.contains(#"intersection(["claude", "codex"])"#))
}
