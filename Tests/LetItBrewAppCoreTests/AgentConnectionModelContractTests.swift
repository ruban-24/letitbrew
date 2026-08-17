import Foundation
import Testing

private func sourceFile(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(path))
}

private func methodBody(_ source: String, named name: String) -> String {
    guard let start = source.range(of: "func \(name)")?.lowerBound,
          let firstBrace = source[start...].firstIndex(of: "{")
    else { return "" }
    var depth = 0
    for index in source[firstBrace...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" {
            depth -= 1
            if depth == 0 { return String(source[start...index]) }
        }
    }
    return ""
}

@Test func modelUsesExplicitFiveAgentConnectionOrchestration() throws {
    let source = try sourceFile("Sources/LetItBrewApp/LetItBrewAppModel.swift")
    #expect(source.contains("connectedAgentIDsV2"))
    #expect(source.contains("AgentID.allCases.map"))
    #expect(source.contains("AgentConnectionMigration.migrate"))
    #expect(source.contains("AgentConnectionActionCoordinator.perform"))
    #expect(source.contains("AgentLiveDiskReader.inspect"))
    #expect(source.contains("AgentLaunchPreparationRunner.run"))
    #expect(source.contains("persistConnectedAgentIDs(next)"))
    #expect(source.contains("reapplyLatestSnapshot(connectedAgentIDs: next)"))
    #expect(!source.contains(#"intersection(["claude", "codex"])"#))
    let connect = methodBody(source, named: "connectAgent")
    let disconnect = methodBody(source, named: "disconnectAgent")
    #expect(connect.contains("persistConnectedAgentIDs(next)"))
    #expect(connect.contains("reapplyLatestSnapshot(connectedAgentIDs: next)"))
    #expect(disconnect.contains("persistConnectedAgentIDs(next)"))
    #expect(disconnect.contains("reapplyLatestSnapshot(connectedAgentIDs: next)"))
}
