import Testing
import Foundation
@testable import LetItBrewCore

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Requires exactly one group under `event` and exactly one entry inside it,
/// and that the entry is ours. Cardinality is pinned with `try #require`
/// (not `#expect`) before any element is touched, so a wrong count aborts
/// right there instead of letting `.first` read from a container that
/// doesn't have the shape just claimed of it — an extra or malformed
/// survivor cannot vanish silently or slip past as a masked crash.
private func requireSoleOwnedEntry(
    _ root: [String: Any], event: String
) throws -> (group: [String: Any], entry: [String: Any]) {
    let hooks = try #require(root["hooks"] as? [String: Any])
    let groups = try #require(hooks[event] as? [Any])
    try #require(groups.count == 1)
    let group = try #require(groups.first as? [String: Any])
    let entries = try #require(group["hooks"] as? [Any])
    try #require(entries.count == 1)
    let entry = try #require(entries.first as? [String: Any])
    #expect(HookFile.isOurs(entry, marker: ClaudeHooks.marker))
    return (group, entry)
}

@Test func singleQuotesPathsSafely() {
    #expect(ClaudeHooks.shellSingleQuoted("/Applications/Let It Brew.app") == "'/Applications/Let It Brew.app'")
    #expect(ClaudeHooks.shellSingleQuoted("/Users/o'brien/app") == #"'/Users/o'\''brien/app'"#)
    #expect(ClaudeHooks.shellSingleQuoted("/a b/c") == "'/a b/c'")
}

@Test func hookCommandPinsExitZeroAndCarriesTheMarker() throws {
    let command = try ClaudeHooks.hookCommand(event: "PreToolUse", cliPath: "/opt/letitbrew")
    #expect(command.contains("hook claude PreToolUse"))
    #expect(command.contains(">/dev/null 2>&1"))
    // Anchored exactly at the end, matching how HookFile.isOurs matches
    // ownership with hasSuffix: text appended after the sentinel is the exact
    // thing that would make a live hook unrecognizable to uninstall.
    #expect(command.hasSuffix(HookFile.ownershipComment(marker: ClaudeHooks.marker)))
    #expect(command.contains(ClaudeHooks.shellSingleQuoted("/opt/letitbrew")))
    #expect(command.contains(ClaudeHooks.shellSingleQuoted(ClaudeHooks.fallbackCLIPath)))
    // No PATH lookup: a stale hook left after the app is deleted must not let
    // an unrelated binary named letitbrew run on every tool call.
    #expect(!command.contains("command -v"))
    #expect(!command.contains("which "))
}

@Test func hookCommandRejectsARelativeCLIPath() {
    #expect(throws: ClaudeHooks.RelativeCLIPath.self) {
        _ = try ClaudeHooks.hookCommand(event: "PreToolUse", cliPath: "relative/letitbrew")
    }
}

@Test func installsIntoAnAbsentFile() throws {
    let root = try object(ClaudeHooks.install(into: nil, cliPath: "/opt/letitbrew"))
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(Set(hooks.keys) == Set(ClaudeHooks.events))
    _ = try requireSoleOwnedEntry(root, event: "Stop")
}

@Test func installPreservesForeignHookSubtreesStructurallyEqual() throws {
    // Both an rtk-shaped and a terminal-notifier-shaped foreign entry, one
    // carrying an unknown extra field, prove install preserves complete
    // foreign subtrees — structurally equal via NSDictionary, not merely
    // matching command strings.
    let rtkEntry: [String: Any] = [
        "type": "command", "command": "rtk hook claude", "timeout": 10, "customField": "keep-me",
    ]
    let rtkGroup: [String: Any] = ["matcher": "Bash", "hooks": [rtkEntry]]
    let notifierEntry: [String: Any] = ["type": "command", "command": "terminal-notifier -message hi"]
    let notifierGroup: [String: Any] = ["hooks": [notifierEntry]]
    let permissions: [String: Any] = ["allow": ["Bash"]]
    let existing = try JSONSerialization.data(withJSONObject: [
        "model": "opus",
        "permissions": permissions,
        "hooks": ["PreToolUse": [rtkGroup, notifierGroup]],
    ] as [String: Any])

    let root = try object(try ClaudeHooks.install(into: existing, cliPath: "/opt/letitbrew"))
    let model = try #require(root["model"] as? String)
    #expect(model == "opus")
    let installedPermissions = try #require(root["permissions"] as? NSDictionary)
    #expect(installedPermissions == (permissions as NSDictionary))

    let hooks = try #require(root["hooks"] as? [String: Any])
    let groups = try #require(hooks["PreToolUse"] as? [Any])
    try #require(groups.count == 3)
    let firstGroup = try #require(groups[0] as? NSDictionary)
    #expect(firstGroup == (rtkGroup as NSDictionary))
    let secondGroup = try #require(groups[1] as? NSDictionary)
    #expect(secondGroup == (notifierGroup as NSDictionary))

    let ours = try #require(groups[2] as? [String: Any])
    let matcher = try #require(ours["matcher"] as? String)
    #expect(matcher == "*")
    let oursEntries = try #require(ours["hooks"] as? [Any])
    try #require(oursEntries.count == 1)
    let oursEntry = try #require(oursEntries.first as? [String: Any])
    #expect(HookFile.isOurs(oursEntry, marker: ClaudeHooks.marker))
}

@Test func everyEventGetsExactlyOneOwnedEntryAcrossInstallAndReinstall() throws {
    let once = try ClaudeHooks.install(into: nil, cliPath: "/opt/letitbrew")
    let twice = try ClaudeHooks.install(into: once, cliPath: "/opt/letitbrew")

    for pass in [once, twice] {
        let root = try object(pass)
        for event in ClaudeHooks.events {
            let (group, entry) = try requireSoleOwnedEntry(root, event: event)
            let command = try #require(entry["command"] as? String)
            #expect(command.hasSuffix(HookFile.ownershipComment(marker: ClaudeHooks.marker)))
            #expect(command.contains("/opt/letitbrew"))
            let timeout = try #require(entry["timeout"] as? Int)
            #expect(timeout == 5)
            if ClaudeHooks.matcherEvents.contains(event) {
                let matcher = try #require(group["matcher"] as? String)
                #expect(matcher == "*")
            } else {
                #expect(group["matcher"] == nil)
            }
        }
    }
}

@Test func reinstallReplacesAStalePath() throws {
    let old = try ClaudeHooks.install(into: nil, cliPath: "/old/letitbrew")
    let new = try ClaudeHooks.install(into: old, cliPath: "/new/letitbrew")
    let root = try object(new)
    let (_, entry) = try requireSoleOwnedEntry(root, event: "PreToolUse")
    let command = try #require(entry["command"] as? String)
    #expect(command.contains("/new/letitbrew"))
    #expect(!command.contains("/old/letitbrew"))
}

@Test func installSweepsOursOutOfEventsWeNoLongerUse() throws {
    let orphan = Data("""
    {"hooks":{"LegacyEvent":[{"hooks":[{"type":"command","command":"x; : # __letitbrew_hook"}]}]}}
    """.utf8)
    let root = try object(try ClaudeHooks.install(into: orphan, cliPath: "/opt/letitbrew"))
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(hooks["LegacyEvent"] == nil)
}

@Test func removeStripsOnlyOursAndPrunesEmptied() throws {
    let rtkEntry: [String: Any] = [
        "type": "command", "command": "rtk hook claude", "timeout": 10, "customField": "keep-me",
    ]
    let rtkGroup: [String: Any] = ["matcher": "Bash", "hooks": [rtkEntry]]
    let notifierEntry: [String: Any] = ["type": "command", "command": "terminal-notifier -message hi"]
    let notifierGroup: [String: Any] = ["hooks": [notifierEntry]]
    let existing = try JSONSerialization.data(withJSONObject: [
        "model": "opus",
        "hooks": ["PreToolUse": [rtkGroup, notifierGroup]],
    ] as [String: Any])

    let installed = try ClaudeHooks.install(into: existing, cliPath: "/opt/letitbrew")
    let root = try object(try ClaudeHooks.remove(from: installed))

    let model = try #require(root["model"] as? String)
    #expect(model == "opus")
    let hooks = try #require(root["hooks"] as? [String: Any])
    let groups = try #require(hooks["PreToolUse"] as? [Any])
    try #require(groups.count == 2)
    let firstGroup = try #require(groups[0] as? NSDictionary)
    #expect(firstGroup == (rtkGroup as NSDictionary))
    let secondGroup = try #require(groups[1] as? NSDictionary)
    #expect(secondGroup == (notifierGroup as NSDictionary))
    #expect(hooks["Stop"] == nil)
    #expect(hooks["SessionStart"] == nil)
}

@Test func removeDropsTheHooksKeyWhenNothingElseRemains() throws {
    let installed = try ClaudeHooks.install(into: Data(#"{"model":"opus"}"#.utf8),
                                            cliPath: "/opt/letitbrew")
    let root = try object(try ClaudeHooks.remove(from: installed))
    #expect(root["hooks"] == nil)
    let model = try #require(root["model"] as? String)
    #expect(model == "opus")
}

@Test func rootLevelMalformationsThrowThroughBothInstallAndRemove() {
    // The worst possible bug: treating a read failure — or a file that is
    // there but not what we expect — as "no file yet" and atomically
    // replacing a full settings.json with a hooks-only object.
    let malformed: [Data] = [
        Data(),                          // exists but is empty: not "no file yet"
        Data("this is not json".utf8),   // malformed JSON
        Data("[1,2,3]".utf8),            // valid JSON, but not an object
    ]
    for data in malformed {
        #expect(throws: ClaudeHooks.SettingsUnreadable.self) {
            _ = try ClaudeHooks.install(into: data, cliPath: "/opt/letitbrew")
        }
        #expect(throws: ClaudeHooks.SettingsUnreadable.self) {
            _ = try ClaudeHooks.remove(from: data)
        }
    }
}

@Test func malformedHooksShapesThrowThroughBothInstallAndRemove() {
    let malformed: [Data] = [
        Data(#"{"hooks":[1,2,3]}"#.utf8),                       // hooks present but not a dictionary
        Data(#"{"hooks":{"PreToolUse":"not an array"}}"#.utf8), // an event present but not an array
    ]
    for data in malformed {
        #expect(throws: ClaudeHooks.SettingsUnreadable.self) {
            _ = try ClaudeHooks.install(into: data, cliPath: "/opt/letitbrew")
        }
        #expect(throws: ClaudeHooks.SettingsUnreadable.self) {
            _ = try ClaudeHooks.remove(from: data)
        }
    }
}

@Test func malformedEventValueNamesTheOffendingEventInTheError() {
    // The mitigation that makes the fail-closed policy in requireEventArrays
    // tolerable: a bare refusal with no way to know which key is malformed
    // is not good enough for a file the user has to go fix by hand.
    let data = Data(#"{"hooks":{"PreToolUse":"not an array"}}"#.utf8)
    #expect(throws: ClaudeHooks.SettingsUnreadable(event: "PreToolUse")) {
        _ = try ClaudeHooks.install(into: data, cliPath: "/opt/letitbrew")
    }
    #expect(throws: ClaudeHooks.SettingsUnreadable(event: "PreToolUse")) {
        _ = try ClaudeHooks.remove(from: data)
    }
}

@Test func missingFileReadsAsNilAndUnreadableThrows() throws {
    let absent = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-absent-\(UUID().uuidString).json")
    #expect(try ClaudeHooks.read(at: absent) == nil)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-dir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: ClaudeHooks.SettingsUnreadable.self) { _ = try ClaudeHooks.read(at: directory) }
}
