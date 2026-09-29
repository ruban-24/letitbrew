import Foundation
import Testing
@testable import LetItBrewCore

@Test func piExtensionSelectsOneGlobalTarget() {
    let home = URL(fileURLWithPath: "/Users/me")
    #expect(PiExtension.extensionURL(home: home, environment: [:]).path == "/Users/me/.pi/agent/extensions/letitbrew.ts")
    #expect(PiExtension.extensionURL(home: home, environment: ["PI_CODING_AGENT_DIR": "/custom/pi"]).path == "/custom/pi/extensions/letitbrew.ts")
    #expect(PiExtension.extensionURL(home: home, environment: ["PI_CODING_AGENT_DIR": "~/custom"]).path == "/Users/me/custom/extensions/letitbrew.ts")
    #expect(PiExtension.extensionURL(home: home, environment: ["PI_CODING_AGENT_DIR": ""]).path == "/Users/me/.pi/agent/extensions/letitbrew.ts")
}

@Test func piExtensionOwnsOnlyItsExactFirstLineAndRepairsIdempotently() throws {
    let original = try PiExtension.install(into: nil, cliPath: "/old/helper")
    let repaired = try PiExtension.install(into: original, cliPath: "/new/helper")
    #expect(PiExtension.report(for: original, cliPath: "/new/helper").stale == ["extension"])
    #expect(PiExtension.report(for: repaired, cliPath: "/new/helper").isHealthy)
    #expect(try PiExtension.install(into: repaired, cliPath: "/new/helper") == repaired)
    #expect(try PiExtension.remove(from: repaired) == nil)
    for foreign in [Data(), Data("// foreign\n".utf8) + original, Data("// \(PiExtension.marker) extra\n".utf8)] {
        #expect(PiExtension.report(for: foreign, cliPath: "/new/helper").isAbsent)
        #expect(throws: PiExtension.UnownedExistingFile.self) { _ = try PiExtension.install(into: foreign, cliPath: "/new/helper") }
        #expect(throws: PiExtension.UnownedExistingFile.self) { _ = try PiExtension.remove(from: foreign) }
    }
    #expect(throws: PiExtension.RelativeCLIPath.self) { _ = try PiExtension.install(into: nil, cliPath: "helper") }
}

/// Executes the generated extension and its real child-process transport,
/// then feeds captured metadata through the production reducer and storage.
/// No hook process or test record ever touches the person's real sessions.
@Test func piExtensionRuntimeDrivesIsolatedSessionStorage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("letitbrew-pi-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = root.appendingPathComponent("helper with 'quotes\" and spaces")
    let source = root.appendingPathComponent("letitbrew.ts")
    try PiExtension.install(into: nil, cliPath: helper.path).write(to: source)
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", repo.appendingPathComponent("scripts/test-pi-extension.mjs").path, source.path, helper.path]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    struct Emission: Decodable { let event: String; let payload: HookPayload }
    let emissions = try JSONDecoder().decode([Emission].self, from: data)
    let storage = SessionStorage(directory: root.appendingPathComponent("sessions"))
    for (index, emission) in emissions.enumerated() {
        try HookSessionUpdater.apply(event: emission.event, payload: emission.payload, agent: .pi,
                                    agentPID: nil, observedAt: Date(timeIntervalSince1970: Double(index + 1)), storage: storage)
        let id = try #require(emission.payload.recordID(agent: .pi, event: emission.event))
        let record = storage.loadAll().first { $0.id == id }
        switch emission.event {
        case "SessionEnd": #expect(record == nil)
        case "UserPromptSubmit", "UserInputResolved": #expect(record?.state == .working)
        case "SessionStart", "Stop", "UserInputRequested": #expect(record?.state == .idle)
        default: Issue.record("Unexpected Pi event: \(emission.event)")
        }
    }
    #expect(storage.loadAll().isEmpty)
}
