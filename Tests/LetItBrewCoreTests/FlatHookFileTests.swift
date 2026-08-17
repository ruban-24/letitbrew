import Foundation
import Testing
@testable import LetItBrewCore

private let flatMarker = "__letitbrew_cursor_hook"
private let flatOwnershipComment = HookFile.ownershipComment(marker: flatMarker)

private func flatJSON(_ value: Any) throws -> Data {
    // The outer array permits scalars as well as arrays and dictionaries while
    // preserving the exact JSON value we are comparing.
    try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
}

@Test func flatSweepRemovesOnlyExactOwnedEntries() throws {
    let foreign: [String: Any] = ["command": "notify --text __letitbrew_cursor_hook"]
    let ours: [String: Any] = ["command": "run; : # __letitbrew_cursor_hook"]
    let hooks: [String: Any] = ["stop": [foreign, ours]]

    let swept = FlatHookFile.sweep(
        hooks, marker: flatMarker, commandKey: "command"
    )

    let kept = try #require(swept["stop"] as? [Any])
    #expect(kept.count == 1)
    #expect(try flatJSON(kept[0]) == flatJSON(foreign))
}

@Test func flatOwnershipUsesOnlyTheSpecifiedCommandKeyAndExactTrailingComment() {
    #expect(FlatHookFile.isOurs(
        ["run": "execute\(flatOwnershipComment)"], marker: flatMarker, commandKey: "run"
    ))
    #expect(!FlatHookFile.isOurs(
        ["command": "execute\(flatOwnershipComment)"], marker: flatMarker, commandKey: "run"
    ))
    #expect(!FlatHookFile.isOurs(
        ["run": "execute\(flatOwnershipComment) trailing"], marker: flatMarker, commandKey: "run"
    ))
    #expect(!FlatHookFile.isOurs(
        ["run": "execute; : # __letitbrew_cursor_hook_v2"], marker: flatMarker, commandKey: "run"
    ))
}

@Test func flatSweepPreservesForeignAndUnknownJSONStructuresExactly() throws {
    let foreignEntry: [String: Any] = [
        "command": "foreign command",
        "metadata": ["nested": [1, true, NSNull()]],
    ]
    let untouchedArray: [Any] = [foreignEntry, "unknown entry", 42, NSNull()]
    let hooks: [String: Any] = [
        "foreign": untouchedArray,
        "empty": [],
        "unknown-object": ["anything": ["deep": false]],
        "unknown-scalar": "leave me alone",
        "mixed": [
            ["command": "remove\(flatOwnershipComment)", "extra": ["x": 1]],
            foreignEntry,
            ["run": "different key\(flatOwnershipComment)"],
        ],
    ]

    let swept = FlatHookFile.sweep(hooks, marker: flatMarker, commandKey: "command")

    #expect(Set(swept.keys) == Set(hooks.keys))
    let foreign = try #require(swept["foreign"])
    let empty = try #require(swept["empty"])
    let unknownObject = try #require(swept["unknown-object"])
    let originalUnknownObject = try #require(hooks["unknown-object"])
    let unknownScalar = try #require(swept["unknown-scalar"])
    let originalUnknownScalar = try #require(hooks["unknown-scalar"])
    #expect(try flatJSON(foreign) == flatJSON(untouchedArray))
    #expect(try flatJSON(empty) == flatJSON([]))
    #expect(try flatJSON(unknownObject) == flatJSON(originalUnknownObject))
    #expect(try flatJSON(unknownScalar) == flatJSON(originalUnknownScalar))

    let mixed = try #require(swept["mixed"] as? [Any])
    #expect(mixed.count == 2)
    #expect(try flatJSON(mixed) == flatJSON([foreignEntry, ["run": "different key\(flatOwnershipComment)"]]))
}

@Test func flatSweepPrunesOnlyEventsEmptiedByOwnedRemovalAcrossEveryEvent() throws {
    let hooks: [String: Any] = [
        "owned-only": [["command": "one\(flatOwnershipComment)"]],
        "mixed": [["command": "two\(flatOwnershipComment)"], ["command": "foreign"]],
        "retired": [["command": "three\(flatOwnershipComment)"]],
        "foreign-empty": [],
    ]

    let swept = FlatHookFile.sweep(hooks, marker: flatMarker, commandKey: "command")

    #expect(Set(swept.keys) == ["mixed", "foreign-empty"])
    let mixed = try #require(swept["mixed"] as? [Any])
    #expect(mixed.count == 1)
    #expect(try flatJSON(mixed[0]) == flatJSON(["command": "foreign"]))
    #expect((swept["foreign-empty"] as? [Any])?.isEmpty == true)
}

@Test func flatEntryUsesCallerSuppliedKeys() throws {
    let entry = FlatHookFile.entry(
        command: "run", commandKey: "exec", timeoutKey: "deadline", timeout: 7
    )

    #expect(Set(entry.keys) == ["exec", "deadline"])
    #expect(entry["exec"] as? String == "run")
    #expect(entry["deadline"] as? Int == 7)
}

@Test func flatReportClassifiesExactCardinalityForEveryState() {
    let marker = flatMarker
    let expected: (String) -> String = { "run \($0)\(flatOwnershipComment)" }
    let hooks: [String: Any] = [
        "healthy": [["command": expected("healthy")]],
        "stale": [["command": "old stale\(flatOwnershipComment)"]],
        "duplicated": [
            ["command": expected("duplicated")],
            ["command": expected("duplicated")],
            ["command": "also stale\(flatOwnershipComment)"],
        ],
        "orphaned": [["command": expected("orphaned")]],
        "foreign": [["command": "foreign \(flatMarker)"]],
    ]

    let report = FlatHookFile.report(
        hooks: hooks,
        events: ["healthy", "stale", "duplicated", "missing"],
        marker: marker,
        commandKey: "command",
        expectedCommand: expected
    )

    #expect(report.healthy == ["healthy"])
    #expect(report.stale == ["stale"])
    #expect(report.duplicated == ["duplicated"])
    #expect(report.missing == ["missing"])
    #expect(report.orphaned == ["orphaned"])
    #expect(report.healthy.count == 1)
    #expect(report.stale.count == 1)
    #expect(report.duplicated.count == 1)
    #expect(report.missing.count == 1)
    #expect(report.orphaned.count == 1)
}

@Test func flatReportTreatsNilHooksAsAllMissing() {
    let report = FlatHookFile.report(
        hooks: nil,
        events: ["stop", "session-end"],
        marker: flatMarker,
        commandKey: "command",
        expectedCommand: { _ in "unneeded" }
    )

    #expect(report.missing == ["stop", "session-end"])
    #expect(report.isAbsent)
}
