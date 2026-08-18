import Foundation
import Testing
@testable import LetItBrewCore

private func copilotObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func copilotTracksPermissionWaitAndResumeEdgesWithoutDecisionOutput() {
    #expect(CopilotHooks.events == [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse",
        "Notification", "ErrorOccurred", "Stop", "SessionEnd",
    ])
}

@Test func copilotHomeRelocatesTheUserHookFile() {
    let home = URL(fileURLWithPath: "/Users/me")
    #expect(CopilotHooks.hooksURL(home: home, environment: [:]).path
        == "/Users/me/.copilot/hooks/letitbrew.json")
    #expect(CopilotHooks.hooksURL(
        home: home, environment: ["COPILOT_HOME": "/custom/copilot"]
    ).path == "/custom/copilot/hooks/letitbrew.json")
}

@Test func copilotWritesPascalCaseSnakePayloadHooks() throws {
    let data = try CopilotHooks.install(into: nil, cliPath: "/opt/letitbrew")
    let root = try copilotObject(data)
    #expect(root["version"] as? Int == 1)
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect((hooks["ErrorOccurred"] as? [Any])?.count == 1)
    let stop = try #require(hooks["Stop"] as? [Any])
    try #require(stop.count == 1)
    let entry = try #require(stop[0] as? [String: Any])
    #expect(Set(entry.keys) == ["bash", "type", "timeoutSec"])
    #expect(entry["type"] as? String == "command")
    #expect(entry["timeoutSec"] as? Int == 5)
    let command = try #require(entry["bash"] as? String)
    #expect(command.contains("hook copilot Stop"))
    #expect(command.contains(">/dev/null 2>&1"))
    #expect(command.hasSuffix(HookFile.ownershipComment(marker: CopilotHooks.marker)))
}

@Test func copilotHookExecutionIsSilentAndPinsFailureToSuccess() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-copilot-hook-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let helper = directory.appendingPathComponent("failing helper")
    try "#!/bin/sh\necho helper-stdout\necho helper-stderr >&2\nexit 7\n"
        .write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", try CopilotHooks.hookCommand(event: "Stop", cliPath: helper.path)]
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    input.fileHandleForWriting.write(Data("{}\n".utf8))
    try input.fileHandleForWriting.close()

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    #expect(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
}

@Test func copilotInstallPreservesForeignKeysAndEntriesStructurally() throws {
    let foreign: [String: Any] = [
        "bash": "/usr/local/bin/agent-stop", "type": "command", "timeoutSec": 12,
        "custom": ["keep": true],
    ]
    let existing = try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "futureKey": ["opaque": 7],
        "hooks": ["agentStop": [foreign]],
    ] as [String: Any])

    let installed = try CopilotHooks.install(into: existing, cliPath: "/opt/letitbrew")
    let root = try copilotObject(installed)
    #expect((root["futureKey"] as? NSDictionary) == (["opaque": 7] as NSDictionary))
    let hooks = try #require(root["hooks"] as? [String: Any])
    let agentStop = try #require(hooks["agentStop"] as? [Any])
    #expect(agentStop.count == 1)
    #expect((agentStop[0] as? NSDictionary) == (foreign as NSDictionary))

    let removed = try CopilotHooks.remove(from: installed)
    let removedRoot = try copilotObject(removed)
    #expect((removedRoot["futureKey"] as? NSDictionary) == (["opaque": 7] as NSDictionary))
    let removedHooks = try #require(removedRoot["hooks"] as? [String: Any])
    let retained = try #require(removedHooks["agentStop"] as? [Any])
    #expect(retained.count == 1)
    #expect((retained[0] as? NSDictionary) == (foreign as NSDictionary))
}

@Test func copilotReinstallRepairsDriftDuplicatesAndOrphans() throws {
    let stale = try CopilotHooks.install(into: nil, cliPath: "/old/letitbrew")
    #expect(CopilotHooks.report(for: stale, cliPath: "/new/letitbrew").stale
        == Set(CopilotHooks.events))

    var root = try copilotObject(stale)
    var hooks = try #require(root["hooks"] as? [String: Any])
    let duplicate = try #require(hooks["Stop"] as? [Any]).first!
    hooks["Stop"] = (hooks["Stop"] as? [Any] ?? []) + [duplicate]
    hooks["LegacyEvent"] = [[
        "bash": "old hook; \(HookFile.ownershipComment(marker: CopilotHooks.marker))",
        "type": "command", "timeoutSec": 5,
    ]]
    root["hooks"] = hooks
    let damaged = try JSONSerialization.data(withJSONObject: root)

    let report = CopilotHooks.report(for: damaged, cliPath: "/new/letitbrew")
    #expect(report.stale == Set(CopilotHooks.events).subtracting(["Stop"]))
    #expect(report.duplicated == ["Stop"])
    #expect(report.orphaned == ["LegacyEvent"])
    #expect(report.missing.isEmpty)

    let repaired = try CopilotHooks.install(into: damaged, cliPath: "/new/letitbrew")
    #expect(CopilotHooks.report(for: repaired, cliPath: "/new/letitbrew").isHealthy)
    let repairedHooks = try #require(copilotObject(repaired)["hooks"] as? [String: Any])
    #expect(repairedHooks["LegacyEvent"] == nil)
    #expect((repairedHooks["Stop"] as? [Any])?.count == 1)
}

@Test func copilotRemovalIsMarkerScopedAndIdempotent() throws {
    let foreignMarkerMention = "echo \(CopilotHooks.marker) anywhere"
    let existing = try JSONSerialization.data(withJSONObject: [
        "hooks": ["Stop": [["bash": foreignMarkerMention, "type": "command"]]],
    ] as [String: Any])
    let installed = try CopilotHooks.install(into: existing, cliPath: "/opt/letitbrew")
    let removedOnce = try CopilotHooks.remove(from: installed)
    let removedTwice = try CopilotHooks.remove(from: removedOnce)
    #expect(removedOnce == removedTwice)
    let root = try copilotObject(removedTwice)
    let hooks = try #require(root["hooks"] as? [String: Any])
    let stop = try #require(hooks["Stop"] as? [Any])
    #expect(stop.count == 1)
    #expect((stop[0] as? [String: Any])?["bash"] as? String == foreignMarkerMention)
    #expect(CopilotHooks.report(for: removedTwice, cliPath: "/opt/letitbrew").isAbsent)
}

@Test func copilotReinstallIsIdempotentAndRejectsMalformedShapes() throws {
    let once = try CopilotHooks.install(into: nil, cliPath: "/opt/letitbrew")
    let twice = try CopilotHooks.install(into: once, cliPath: "/opt/letitbrew")
    #expect(once == twice)
    #expect(CopilotHooks.report(for: twice, cliPath: "/opt/letitbrew").isHealthy)

    let malformed: [Data] = [
        Data(),
        Data("not json".utf8),
        Data("[1,2,3]".utf8),
        Data(#"{"version":"1"}"#.utf8),
        Data(#"{"version":2}"#.utf8),
        Data(#"{"version":true}"#.utf8),
        Data(#"{"hooks":[]}"#.utf8),
        Data(#"{"hooks":{"Stop":"not an array"}}"#.utf8),
    ]
    for data in malformed {
        #expect(throws: CopilotHooks.SettingsUnreadable.self) {
            _ = try CopilotHooks.install(into: data, cliPath: "/opt/letitbrew")
        }
        #expect(throws: CopilotHooks.SettingsUnreadable.self) {
            _ = try CopilotHooks.remove(from: data)
        }
        let report = CopilotHooks.report(for: data, cliPath: "/opt/letitbrew")
        #expect(report.missing == Set(CopilotHooks.events))
        #expect(report.isAbsent)
    }
}

@Test func copilotRejectsRelativeHelperPaths() {
    #expect(throws: CopilotHooks.RelativeCLIPath.self) {
        _ = try CopilotHooks.hookCommand(event: "Stop", cliPath: "relative/letitbrew")
    }
    #expect(throws: CopilotHooks.RelativeCLIPath.self) {
        _ = try CopilotHooks.install(into: nil, cliPath: "relative/letitbrew")
    }
}
