import Foundation
import Testing
@testable import LetItBrewCore

private func cursorObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func cursorContractIsExactAndFailOpen() throws {
    #expect(CursorHooks.eventMap == [
        "sessionStart": "SessionStart",
        "beforeSubmitPrompt": "UserPromptSubmit",
        "preToolUse": "PreToolUse",
        "postToolUse": "PostToolUse",
        "subagentStart": "SubagentStart",
        "subagentStop": "SubagentStop",
        "stop": "Stop",
        "sessionEnd": "SessionEnd",
    ])
    #expect(CursorHooks.settingsURL(home: URL(fileURLWithPath: "/Users/me")).path
        == "/Users/me/.cursor/hooks.json")

    let command = try CursorHooks.hookCommand(
        sourceEvent: "beforeSubmitPrompt", cliPath: "/opt/letitbrew"
    )
    #expect(command.contains("hook cursor UserPromptSubmit"))
    #expect(command.contains(">/dev/null 2>&1"))
    #expect(command.hasSuffix(HookFile.ownershipComment(marker: CursorHooks.marker)))
    #expect(!command.contains("failClosed"))
}

@Test func cursorInstallPreservesForeignKeysAndHooksExactly() throws {
    let foreign: [String: Any] = ["command": "/usr/bin/true", "custom": ["keep": true]]
    let existing = try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "futureKey": ["opaque": 7],
        "hooks": ["stop": [foreign]],
    ] as [String: Any])
    let twice = try CursorHooks.install(
        into: CursorHooks.install(into: existing, cliPath: "/opt/letitbrew"),
        cliPath: "/opt/letitbrew"
    )
    let root = try cursorObject(twice)
    #expect((root["futureKey"] as? NSDictionary) == (["opaque": 7] as NSDictionary))
    #expect(root["version"] as? Int == 1)
    let hooks = try #require(root["hooks"] as? [String: Any])
    let stop = try #require(hooks["stop"] as? [Any])
    #expect(stop.count == 2)
    #expect((stop[0] as? NSDictionary) == (foreign as NSDictionary))
    #expect(CursorHooks.report(for: twice, cliPath: "/opt/letitbrew").isHealthy)
}

@Test func cursorInstallWritesOneFlatOwnedEntryPerMappedEventWithoutFailClosed() throws {
    let root = try cursorObject(try CursorHooks.install(into: nil, cliPath: "/opt/letitbrew"))
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(Set(hooks.keys) == Set(CursorHooks.eventMap.keys))

    for (sourceEvent, mappedEvent) in CursorHooks.eventMap {
        let entries = try #require(hooks[sourceEvent] as? [Any])
        try #require(entries.count == 1)
        let entry = try #require(entries.first as? [String: Any])
        #expect(Set(entry.keys) == ["command", "timeout"])
        #expect(entry["timeout"] as? Int == 5)
        #expect(entry["failClosed"] == nil)
        let command = try #require(entry["command"] as? String)
        #expect(command.contains("hook cursor \(mappedEvent)"))
        #expect(HookFile.isOurs(entry, marker: CursorHooks.marker))
    }
}

@Test func cursorInstallRejectsRelativePathsAndQuotesTheEmbeddedHelperPath() throws {
    #expect(throws: CursorHooks.RelativeCLIPath.self) {
        _ = try CursorHooks.hookCommand(sourceEvent: "stop", cliPath: "relative/letitbrew")
    }
    #expect(throws: CursorHooks.RelativeCLIPath.self) {
        _ = try CursorHooks.install(into: nil, cliPath: "relative/letitbrew")
    }

    let command = try CursorHooks.hookCommand(
        sourceEvent: "stop", cliPath: "/Applications/Let It Brew.app/Contents/Helpers/letitbrew"
    )
    #expect(command.contains(ClaudeHooks.shellSingleQuoted(
        "/Applications/Let It Brew.app/Contents/Helpers/letitbrew"
    )))
    #expect(command.contains(ClaudeHooks.shellSingleQuoted(ClaudeHooks.fallbackCLIPath)))
    #expect(!command.contains("command -v"))
}

@Test func cursorReinstallRepairsDriftDuplicatesAndLegacyOrphans() throws {
    let stale = try CursorHooks.install(into: nil, cliPath: "/old/letitbrew")
    #expect(CursorHooks.report(for: stale, cliPath: "/new/letitbrew").stale
        == Set(CursorHooks.eventMap.keys))

    var root = try cursorObject(stale)
    var hooks = try #require(root["hooks"] as? [String: Any])
    let duplicate = try #require(hooks["stop"] as? [Any]).first!
    hooks["stop"] = (hooks["stop"] as? [Any] ?? []) + [duplicate]
    hooks["legacy"] = [[
        "command": "old hook; \(HookFile.ownershipComment(marker: CursorHooks.marker))",
        "timeout": 5,
    ]]
    root["hooks"] = hooks
    let damaged = try JSONSerialization.data(withJSONObject: root)

    let report = CursorHooks.report(for: damaged, cliPath: "/new/letitbrew")
    #expect(report.stale == Set(CursorHooks.eventMap.keys).subtracting(["stop"]))
    #expect(report.duplicated == ["stop"])
    #expect(report.orphaned == ["legacy"])
    #expect(report.missing.isEmpty)

    let repaired = try CursorHooks.install(into: damaged, cliPath: "/new/letitbrew")
    #expect(CursorHooks.report(for: repaired, cliPath: "/new/letitbrew").isHealthy)
    let repairedHooks = try #require(cursorObject(repaired)["hooks"] as? [String: Any])
    #expect(repairedHooks["legacy"] == nil)
    #expect((repairedHooks["stop"] as? [Any])?.count == 1)
}

@Test func cursorRemovalIsMarkerScopedAndDoesNotClaimMarkerTextInForeignCommands() throws {
    let foreignSuffixText = "echo \(CursorHooks.marker)"
    let foreignOtherMarker = "x; \(HookFile.ownershipComment(marker: ClaudeHooks.marker))"
    let existing = try JSONSerialization.data(withJSONObject: [
        "futureKey": ["preserve": true],
        "hooks": [
            "stop": [
                ["command": foreignSuffixText, "metadata": ["keep": 1]],
                ["command": foreignOtherMarker],
            ],
        ],
    ] as [String: Any])
    let installed = try CursorHooks.install(into: existing, cliPath: "/opt/letitbrew")
    let removed = try CursorHooks.remove(from: installed)
    let root = try cursorObject(removed)
    #expect((root["futureKey"] as? NSDictionary) == (["preserve": true] as NSDictionary))
    let hooks = try #require(root["hooks"] as? [String: Any])
    let stop = try #require(hooks["stop"] as? [Any])
    #expect(stop.count == 2)
    #expect((stop[0] as? NSDictionary) == (["command": foreignSuffixText, "metadata": ["keep": 1]] as NSDictionary))
    #expect((stop[1] as? [String: Any])?["command"] as? String == foreignOtherMarker)
    #expect(CursorHooks.report(for: removed, cliPath: "/opt/letitbrew").isAbsent)
}

@Test func cursorInstallAndRemoveRejectEveryMalformedShape() {
    let malformed: [Data] = [
        Data(),
        Data("not json".utf8),
        Data("[1,2,3]".utf8),
        Data(#"{"version":"1"}"#.utf8),
        Data(#"{"version":2}"#.utf8),
        Data(#"{"version":true}"#.utf8),
        Data(#"{"hooks":[]}"#.utf8),
        Data(#"{"hooks":{"stop":"not an array"}}"#.utf8),
    ]

    for data in malformed {
        #expect(throws: CursorHooks.SettingsUnreadable.self) {
            _ = try CursorHooks.install(into: data, cliPath: "/opt/letitbrew")
        }
        #expect(throws: CursorHooks.SettingsUnreadable.self) {
            _ = try CursorHooks.remove(from: data)
        }
        let report = CursorHooks.report(for: data, cliPath: "/opt/letitbrew")
        #expect(report.missing == Set(CursorHooks.eventMap.keys))
        #expect(report.isAbsent)
    }
}

@Test func cursorPayloadUsesConversationAndSubagentAliases() throws {
    let payload = try JSONDecoder().decode(HookPayload.self, from: Data(
        #"{"parent_conversation_id":"parent","subagent_id":"child"}"#.utf8
    ))
    #expect(payload.recordID(agent: .cursor, event: "SubagentStart")
        == "v1|6:cursor|6:parent|5:child")
}
