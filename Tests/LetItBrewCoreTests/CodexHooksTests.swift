import Testing
import Foundation
@testable import LetItBrewCore

@Test func appServerTrustEventsCoverEveryInstalledCodexHook() {
    #expect(CodexHooks.appServerEvents == Set([
        "sessionStart", "userPromptSubmit", "preToolUse", "postToolUse",
        "permissionRequest", "preCompact", "postCompact", "subagentStart",
        "subagentStop", "stop", "sessionEnd",
    ]))
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func codexOmitsTheNotificationEvent() {
    // Codex never emits Notification; installing it would be a silent no-op.
    #expect(!CodexHooks.events.contains("Notification"))
    // Codex matches event names field by field with NO error on a miss:
    // "sessionStart", "Sessionstart", and "SessionStarted" all parse
    // cleanly, register zero hooks, and warn nowhere. A capitalization-only
    // check would catch just a fraction of the ways that goes wrong; pinning
    // the exact array below — every character, every name, the count, the
    // order — is what actually encodes the edge, and needs no element
    // access at all.
    #expect(CodexHooks.events == ["SessionStart", "UserPromptSubmit", "PreToolUse",
                                  "PostToolUse", "PermissionRequest", "PreCompact",
                                  "PostCompact", "SubagentStart", "SubagentStop", "Stop",
                                  "SessionEnd"])
}

@Test func topLevelHasOnlyDescriptionAndHooks() throws {
    // Codex parses hooks.json with unknown fields denied: one stray top-level
    // key makes it reject the file and load zero hooks, the user's included.
    let root = try object(try CodexHooks.install(into: nil, cliPath: "/opt/letitbrew"))
    #expect(Set(root.keys) == ["description", "hooks"])
}

@Test func installIntoAnExistingFileWithNoDescriptionDoesNotAddOne() throws {
    // A stray "description" our own default text is metadata pollution the
    // same way an extra hook entry would be: fine for a file we create from
    // nothing, wrong to silently add to one that already existed without it.
    let existing = Data(#"{"hooks":{}}"#.utf8)
    let root = try object(try CodexHooks.install(into: existing, cliPath: "/opt/letitbrew"))
    #expect(root["description"] == nil)
}

@Test func uninstallPreservesAGenuineUserDescriptionVerbatim() throws {
    // description is opaque data to remove: whatever the file carried comes
    // back unchanged, whatever it says.
    let existing = Data(#"{"description":"my own hooks config","hooks":{}}"#.utf8)
    let installed = try CodexHooks.install(into: existing, cliPath: "/opt/letitbrew")
    let root = try object(try CodexHooks.remove(from: installed))
    let description = try #require(root["description"] as? String)
    #expect(description == "my own hooks config")
}

@Test func uninstallOnAFileWithNoDescriptionProducesNoDescriptionKey() throws {
    // No description in means none out — remove must never synthesize one.
    let existing = Data(#"{"hooks":{}}"#.utf8)
    let installed = try CodexHooks.install(into: existing, cliPath: "/opt/letitbrew")
    let root = try object(try CodexHooks.remove(from: installed))
    #expect(root["description"] == nil)
    #expect(Set(root.keys) == ["hooks"])
}

@Test func uninstallDoesNotDeleteADescriptionThatCoincidentallyMatchesOurDefault() throws {
    // Overturned from an earlier version that compared the description
    // against our own default text and dropped it on a match, reasoning
    // that meant Let It Brew had created the file wholesale. A string match is
    // not a provenance signal: a user whose own description happened to
    // read the same way would have silently lost it. remove must not guess
    // at authorship from content — see the type-level docs on `remove`.
    let installed = try CodexHooks.install(into: nil, cliPath: "/opt/letitbrew")
    let root = try object(try CodexHooks.remove(from: installed))
    let description = try #require(root["description"] as? String)
    #expect(description == "Let It Brew keep-awake hooks")
}

@Test func unknownTopLevelKeyThrowsRatherThanBeingSilentlyDropped() {
    // Overturned from an earlier "drop it" policy: a future Codex version
    // could legitimately accept a new top-level field. Dropping it here
    // would silently delete valid user configuration on every install and
    // remove, with no way for the user to know it happened. Refusing is
    // recoverable; deleting is not.
    let existing = Data(#"{"description":"mine","hooks":{},"somethingElse":1}"#.utf8)
    #expect(throws: CodexHooks.HooksUnreadable(key: "somethingElse", reason: .invalidTopLevelKey)) {
        _ = try CodexHooks.install(into: existing, cliPath: "/opt/letitbrew")
    }
    #expect(throws: CodexHooks.HooksUnreadable(key: "somethingElse", reason: .invalidTopLevelKey)) {
        _ = try CodexHooks.remove(from: existing)
    }
}

@Test func wrongTypedDescriptionThrowsRatherThanBeingCoerced() {
    let existing = Data(#"{"description":42,"hooks":{}}"#.utf8)
    #expect(throws: CodexHooks.HooksUnreadable(key: "description", reason: .invalidTopLevelKey)) {
        _ = try CodexHooks.install(into: existing, cliPath: "/opt/letitbrew")
    }
}

@Test func preservesTheUsersOwnCodexHooks() throws {
    let existing = Data("""
    {"description":"mine",
     "hooks":{"Stop":[{"hooks":[{"type":"command","command":"my own thing"}]}]}}
    """.utf8)
    let root = try object(try CodexHooks.install(into: existing, cliPath: "/opt/letitbrew"))
    let hooks = try #require(root["hooks"] as? [String: Any])
    let groups = try #require(hooks["Stop"] as? [Any])
    // Exact count pinned with try #require before any element is touched:
    // the foreign group, untouched, plus our own newly-appended group.
    try #require(groups.count == 2)

    let foreignGroup = try #require(groups[0] as? [String: Any])
    let foreignEntries = try #require(foreignGroup["hooks"] as? [Any])
    try #require(foreignEntries.count == 1)
    let foreignEntry = try #require(foreignEntries.first as? [String: Any])
    let foreignCommand = try #require(foreignEntry["command"] as? String)
    #expect(foreignCommand == "my own thing")

    let ourGroup = try #require(groups[1] as? [String: Any])
    let ourEntries = try #require(ourGroup["hooks"] as? [Any])
    try #require(ourEntries.count == 1)
    let ourEntry = try #require(ourEntries.first as? [String: Any])
    #expect(HookFile.isOurs(ourEntry, marker: CodexHooks.marker))
}

@Test func codexMarkerIsDistinctFromClaudes() {
    // Removing one integration must never strip the other's entries.
    #expect(CodexHooks.marker != ClaudeHooks.marker)
    #expect(!CodexHooks.marker.contains(ClaudeHooks.marker))
    #expect(!ClaudeHooks.marker.contains(CodexHooks.marker))
}

@Test func hookCommandUsesTheCodexMarkerAndPinsExitZero() throws {
    let command = try CodexHooks.hookCommand(event: "Stop", cliPath: "/opt/letitbrew")
    #expect(command.contains(CodexHooks.marker))
    #expect(!command.contains(ClaudeHooks.marker))
    #expect(command.contains("hook codex Stop"))
    #expect(command.contains(">/dev/null 2>&1"))
    #expect(command.contains(": #"))
}

@Test func codexHookCommandRejectsARelativeCLIPath() {
    // Same PATH-hijack risk ClaudeHooks.hookCommand guards against: a hook
    // installed with a relative path would fall back to a PATH lookup, and
    // a hook outlives the app that installed it.
    #expect(throws: CodexHooks.RelativeCLIPath.self) {
        _ = try CodexHooks.hookCommand(event: "PreToolUse", cliPath: "relative/letitbrew")
    }
    #expect(throws: CodexHooks.RelativeCLIPath.self) {
        _ = try CodexHooks.install(into: nil, cliPath: "relative/letitbrew")
    }
}

@Test func honoursCodexHomeEnvironmentVariable() {
    let home = URL(fileURLWithPath: "/Users/me")
    #expect(CodexHooks.hooksURL(home: home, environment: [:]).path
            == "/Users/me/.codex/hooks.json")
    #expect(CodexHooks.hooksURL(home: home, environment: ["CODEX_HOME": "/elsewhere/cdx"]).path
            == "/elsewhere/cdx/hooks.json")
}

@Test func reinstallIsIdempotent() throws {
    let once = try CodexHooks.install(into: nil, cliPath: "/opt/letitbrew")
    let twice = try CodexHooks.install(into: once, cliPath: "/opt/letitbrew")
    #expect(CodexHooks.report(for: twice, cliPath: "/opt/letitbrew").isHealthy)
}

@Test func removeStripsOnlyOurs() throws {
    let existing = Data("""
    {"description":"mine","hooks":{"Stop":[{"hooks":[{"type":"command","command":"my own thing"}]}]}}
    """.utf8)
    let installed = try CodexHooks.install(into: existing, cliPath: "/opt/letitbrew")
    let root = try object(try CodexHooks.remove(from: installed))
    let hooks = try #require(root["hooks"] as? [String: Any])
    // Every event we install into was fully ours and gets swept out
    // entirely; Stop keeps only the foreign group.
    #expect(Set(hooks.keys) == ["Stop"])
    let groups = try #require(hooks["Stop"] as? [Any])
    try #require(groups.count == 1)
    let group = try #require(groups.first as? [String: Any])
    let entries = try #require(group["hooks"] as? [Any])
    try #require(entries.count == 1)
    let entry = try #require(entries.first as? [String: Any])
    let command = try #require(entry["command"] as? String)
    #expect(command == "my own thing")
    #expect(!HookFile.isOurs(entry, marker: CodexHooks.marker))
}

@Test func reportsFreshInstallAsHealthyAndAbsentAsMissing() throws {
    let data = try CodexHooks.install(into: nil, cliPath: "/opt/letitbrew")
    #expect(CodexHooks.report(for: data, cliPath: "/opt/letitbrew").healthy == Set(CodexHooks.events))
    #expect(CodexHooks.report(for: nil, cliPath: "/opt/letitbrew").missing == Set(CodexHooks.events))
}

// MARK: - Drift, through CodexHooks.report (Codex has its own marker/events;
// only ClaudeHooksReportTests exercised the shared classifier this
// thoroughly before now)

@Test func codexReportsADriftedPathAsStale() throws {
    let data = try CodexHooks.install(into: nil, cliPath: "/old/letitbrew")
    let report = CodexHooks.report(for: data, cliPath: "/new/letitbrew")
    #expect(report.stale == Set(CodexHooks.events))
    #expect(report.healthy.isEmpty)
    #expect(report.duplicated.isEmpty)
    #expect(report.orphaned.isEmpty)
    #expect(report.missing.isEmpty)
    #expect(!report.isHealthy)
    #expect(!report.isAbsent)
}

@Test func codexReportsADoubledEntryAsDuplicated() throws {
    let data = Data("""
    {"hooks":{"Stop":[
      {"hooks":[{"type":"command","command":"a; : # \(CodexHooks.marker)"}]},
      {"hooks":[{"type":"command","command":"b; : # \(CodexHooks.marker)"}]}]}}
    """.utf8)
    let report = CodexHooks.report(for: data, cliPath: "/opt/letitbrew")
    #expect(report.duplicated == ["Stop"])
    #expect(report.healthy.isEmpty)
    #expect(report.stale.isEmpty)
    #expect(report.orphaned.isEmpty)
    #expect(report.missing == Set(CodexHooks.events).subtracting(["Stop"]))
    #expect(!report.isHealthy)
    #expect(!report.isAbsent)
}

@Test func codexReportsAnEntryUnderARetiredEventAsOrphaned() {
    let data = Data("""
    {"hooks":{"LegacyEvent":[{"hooks":[{"type":"command","command":"x; : # \(CodexHooks.marker)"}]}]}}
    """.utf8)
    let report = CodexHooks.report(for: data, cliPath: "/opt/letitbrew")
    #expect(report.orphaned == ["LegacyEvent"])
    #expect(report.missing == Set(CodexHooks.events))
    #expect(report.healthy.isEmpty)
    #expect(report.stale.isEmpty)
    #expect(report.duplicated.isEmpty)
    #expect(!report.isHealthy)
    #expect(!report.isAbsent)
}

@Test func codexReinstallReplacesAStalePath() throws {
    let old = try CodexHooks.install(into: nil, cliPath: "/old/letitbrew")
    let new = try CodexHooks.install(into: old, cliPath: "/new/letitbrew")
    let root = try object(new)
    let hooks = try #require(root["hooks"] as? [String: Any])
    let groups = try #require(hooks["PreToolUse"] as? [Any])
    try #require(groups.count == 1)
    let group = try #require(groups.first as? [String: Any])
    let entries = try #require(group["hooks"] as? [Any])
    try #require(entries.count == 1)
    let entry = try #require(entries.first as? [String: Any])
    let command = try #require(entry["command"] as? String)
    #expect(command.contains("/new/letitbrew"))
    #expect(!command.contains("/old/letitbrew"))
}

// MARK: - Data-loss hardening

/// Requires exactly one group under `event` and exactly one entry inside it,
/// and that the entry is ours. Cardinality pinned with `try #require` before
/// any element is touched, so a wrong count aborts right there instead of
/// `.first` silently reading past a shape that doesn't match what was claimed.
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
    #expect(HookFile.isOurs(entry, marker: CodexHooks.marker))
    return (group, entry)
}

@Test func everyEventGetsExactlyOneOwnedEntryAcrossInstallAndReinstallNoMatcher() throws {
    let once = try CodexHooks.install(into: nil, cliPath: "/opt/letitbrew")
    let twice = try CodexHooks.install(into: once, cliPath: "/opt/letitbrew")
    for pass in [once, twice] {
        let root = try object(pass)
        for event in CodexHooks.events {
            let (group, entry) = try requireSoleOwnedEntry(root, event: event)
            // Codex rejects a matcher on every event: none of ours ever carries one.
            #expect(group["matcher"] == nil)
            let timeout = try #require(entry["timeout"] as? Int)
            #expect(timeout == 5)
        }
    }
}

@Test func rootLevelMalformationsThrowThroughInstallRemoveAndAreAbsentInReport() {
    // Treating a read failure, or a file
    // that exists but isn't the shape expected, as "no file yet" and
    // atomically replacing the user's file with a hooks-only object. An
    // empty file is frequently a partial/interrupted write, exactly the
    // moment it must not be clobbered.
    let malformed: [Data] = [
        Data(),                        // exists but empty: not "no file yet"
        Data("not json".utf8),         // malformed JSON
        Data("[1,2,3]".utf8),          // valid JSON, but not an object
    ]
    for data in malformed {
        #expect(throws: CodexHooks.HooksUnreadable.self) {
            _ = try CodexHooks.install(into: data, cliPath: "/opt/letitbrew")
        }
        #expect(throws: CodexHooks.HooksUnreadable.self) {
            _ = try CodexHooks.remove(from: data)
        }
        let report = CodexHooks.report(for: data, cliPath: "/opt/letitbrew")
        #expect(report.missing == Set(CodexHooks.events))
        #expect(report.healthy.isEmpty)
        #expect(report.stale.isEmpty)
        #expect(report.duplicated.isEmpty)
        #expect(report.orphaned.isEmpty)
        #expect(report.isAbsent)
        #expect(!report.isHealthy)
    }
}

@Test func malformedHooksShapesThrowThroughInstallAndRemove() {
    let malformed: [Data] = [
        Data(#"{"hooks":[1,2,3]}"#.utf8),                       // hooks present but not a dictionary
        Data(#"{"hooks":{"PreToolUse":"not an array"}}"#.utf8), // an event present but not an array
    ]
    for data in malformed {
        #expect(throws: CodexHooks.HooksUnreadable.self) {
            _ = try CodexHooks.install(into: data, cliPath: "/opt/letitbrew")
        }
        #expect(throws: CodexHooks.HooksUnreadable.self) {
            _ = try CodexHooks.remove(from: data)
        }
    }
}

@Test func codexMalformedEventValueNamesTheOffendingEventInTheError() {
    // A bare refusal with no way to know which key is malformed isn't good
    // enough for a file the user has to go fix by hand.
    let data = Data(#"{"hooks":{"PreToolUse":"not an array"}}"#.utf8)
    let expected = CodexHooks.HooksUnreadable(key: "PreToolUse", reason: .malformedEventValue)
    #expect(throws: expected) {
        _ = try CodexHooks.install(into: data, cliPath: "/opt/letitbrew")
    }
    #expect(throws: expected) {
        _ = try CodexHooks.remove(from: data)
    }
}

@Test func mixedMalformedEventBesideAHealthyOneReportsAsFullyAbsentNotPartial() throws {
    // Without validating every event's shape the same way install/remove do,
    // HookFile.report would classify Stop on its own and report it healthy
    // while install/remove would refuse to touch the whole file. A status
    // display saying "connected" while the installer won't go near the file
    // is exactly the misleading state this guards against.
    let realStopCommand = try CodexHooks.hookCommand(event: "Stop", cliPath: "/opt/letitbrew")
    let data = Data("""
    {"hooks":{"PreToolUse":"not an array",
               "Stop":[{"hooks":[{"type":"command","command":"\(realStopCommand)"}]}]}}
    """.utf8)
    let report = CodexHooks.report(for: data, cliPath: "/opt/letitbrew")
    #expect(report.missing == Set(CodexHooks.events))
    #expect(report.healthy.isEmpty)
    #expect(report.stale.isEmpty)
    #expect(report.duplicated.isEmpty)
    #expect(report.orphaned.isEmpty)
    #expect(report.isAbsent)
    #expect(!report.isHealthy)
}

@Test func healthyHooksPlusAStrayTopLevelKeyReportsAsAbsentNotHealthy() throws {
    // A file can look perfectly installed by the `hooks` subtree alone while
    // a stray top-level key makes Codex reject the entire thing — real
    // Codex loads ZERO hooks from a file like this. `report` must reflect
    // that, not just what `hooks` looks like in isolation.
    let installed = try CodexHooks.install(into: nil, cliPath: "/opt/letitbrew")
    var root = try object(installed)
    root["somethingElse"] = 1
    let tampered = try JSONSerialization.data(withJSONObject: root)

    let report = CodexHooks.report(for: tampered, cliPath: "/opt/letitbrew")
    #expect(report.missing == Set(CodexHooks.events))
    #expect(report.healthy.isEmpty)
    #expect(report.stale.isEmpty)
    #expect(report.duplicated.isEmpty)
    #expect(report.orphaned.isEmpty)
    #expect(report.isAbsent)
    #expect(!report.isHealthy)
}
