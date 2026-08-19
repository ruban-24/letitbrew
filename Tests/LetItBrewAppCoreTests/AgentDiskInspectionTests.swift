import Foundation
import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

private func diskSnapshot(_ path: String, exists: Bool = true) -> ExactFileSnapshot {
    try! ExactFileSnapshot(path: path, exists: exists, deviceID: exists ? 1 : nil, inode: exists ? 2 : nil, byteCount: exists ? 3 : nil, modificationSeconds: exists ? 4 : nil, modificationNanoseconds: exists ? 5 : nil, sha256: exists ? String(repeating: "a", count: 64) : nil)
}

private func generatedBytes(_ agent: AgentID) -> Data {
    switch agent {
    case .claude: return try! ClaudeHooks.install(into: nil, cliPath: "/letitbrew")
    case .codex: return try! CodexHooks.install(into: nil, cliPath: "/letitbrew")
    case .opencode: return try! OpenCodePlugin.install(into: nil, cliPath: "/letitbrew")
    case .copilot: return try! CopilotHooks.install(into: nil, cliPath: "/letitbrew")
    }
}

@Test(arguments: AgentID.allCases)
func diskInspectionClassifiesHealthyGeneratedBytes(agent: AgentID) {
    let target = URL(fileURLWithPath: "/a/\(agent.rawValue)")
    let result = AgentDiskInspection.inspect(agent: agent, registry: .valid(nil), defaultTarget: target, helperPath: "/letitbrew") { _, _ in
        .regular(diskSnapshot(target.path), generatedBytes(agent))
    }
    #expect(result.state == .healthyOwned)
    #expect(result.target == target)
}

@Test(arguments: AgentID.allCases)
func diskInspectionClassifiesAbsentAndUnreadableForEveryAdapter(agent: AgentID) {
    let target = URL(fileURLWithPath: "/a/\(agent.rawValue)")
    let absent = AgentDiskInspection.inspect(agent: agent, registry: .valid(nil), defaultTarget: target, helperPath: "/letitbrew") { _, _ in
        .absent(diskSnapshot(target.path, exists: false))
    }
    let unreadable = AgentDiskInspection.inspect(agent: agent, registry: .valid(nil), defaultTarget: target, helperPath: "/letitbrew") { _, _ in
        .invalid(resolvedURL: target, reason: "unreadable")
    }
    #expect(absent.state == .absent)
    #expect(unreadable.state == .invalid)
}

@Test(arguments: AgentID.allCases)
func diskInspectionClassifiesRepairableOwnedBytesForEveryAdapter(agent: AgentID) {
    let target = URL(fileURLWithPath: "/repair/\(agent.rawValue)")
    let result = AgentDiskInspection.inspect(agent: agent, registry: .valid(nil), defaultTarget: target, helperPath: "/other-letitbrew") { _, _ in
        .regular(diskSnapshot(target.path), generatedBytes(agent))
    }
    #expect(result.state == .repairableOwned)
}

@Test(arguments: [AgentID.claude, .codex, .copilot])
func diskInspectionRejectsMalformedJSONForEveryJSONAdapter(agent: AgentID) {
    let target = URL(fileURLWithPath: "/invalid/\(agent.rawValue)")
    let result = AgentDiskInspection.inspect(agent: agent, registry: .valid(nil), defaultTarget: target, helperPath: "/letitbrew") { _, _ in
        .regular(diskSnapshot(target.path), Data("not json".utf8))
    }
    #expect(result.state == .invalid)
}

@Test func diskInspectionUsesRecordedTargetOnceBeforeAmbientDefault() throws {
    let a = URL(fileURLWithPath: "/recorded/a")
    let b = URL(fileURLWithPath: "/ambient/b")
    let registry = try AgentInstallRegistry(targets: [.copilot: a.path])
    var reads: [URL] = []
    let result = AgentDiskInspection.inspect(agent: .copilot, registry: .valid(registry), defaultTarget: b, helperPath: "/letitbrew") { target, _ in
        reads.append(target)
        return .absent(diskSnapshot(target.path, exists: false))
    }
    #expect(reads == [a])
    #expect(result.usedRecordedTarget)
    #expect(result.state == .absent)
}

@Test func invalidRegistryNeverReadsATarget() {
    var reads = 0
    let result = AgentDiskInspection.inspect(agent: .claude, registry: .invalid("bad JSON"), defaultTarget: URL(fileURLWithPath: "/ambient"), helperPath: "/letitbrew") { _, _ in
        reads += 1; return .absent(diskSnapshot("/ambient", exists: false))
    }
    #expect(result.state == .invalid)
    #expect(reads == 0)
}

@Test func unownedOpenCodeFileIsInvalid() {
    let result = AgentDiskInspection.inspect(agent: .opencode, registry: .valid(nil), defaultTarget: URL(fileURLWithPath: "/plugin"), helperPath: "/letitbrew") { target, _ in
        .regular(diskSnapshot(target.path), Data("console.log('foreign')".utf8))
    }
    #expect(result.state == .invalid)
}
