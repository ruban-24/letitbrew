import Testing
import Foundation
@testable import LetItBrewCore

/// The two integrations carry deliberately different ownership markers so
/// that removing one can never strip the other's entries. `CodexHooksTests`
/// already pins that the marker *strings* are distinct and non-overlapping;
/// these pin the behaviour that property exists to guarantee — that each
/// `remove` sweeps only its own entries out of a file containing both.
///
/// Ordinarily the two live in separate files, so this is the defence that
/// holds when they do not: a `CODEX_HOME` pointed at Claude's directory, a
/// merged or hand-edited config, or a future shared file.

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func commands(_ root: [String: Any], event: String) throws -> [String] {
    let hooks = try #require(root["hooks"] as? [String: Any])
    let groups = try #require(hooks[event] as? [Any])
    return groups.compactMap { group in
        guard let group = group as? [String: Any],
              let entries = group["hooks"] as? [Any],
              let entry = entries.first as? [String: Any]
        else { return nil }
        return entry["command"] as? String
    }
}

/// A file holding one Claude-owned entry, one Codex-owned entry, and one
/// entry belonging to neither, all under the same event.
private func mixedOwnershipFile() throws -> Data {
    let claudeEntry: [String: Any] = [
        "type": "command",
        "command": "letitbrew hook Stop; : # \(ClaudeHooks.marker)",
    ]
    let codexEntry: [String: Any] = [
        "type": "command",
        "command": "letitbrew hook Stop; : # \(CodexHooks.marker)",
    ]
    let foreignEntry: [String: Any] = [
        "type": "command",
        "command": "/usr/local/bin/not-ours",
    ]
    return try JSONSerialization.data(withJSONObject: [
        "hooks": [
            "Stop": [
                ["hooks": [claudeEntry]],
                ["hooks": [codexEntry]],
                ["hooks": [foreignEntry]],
            ]
        ]
    ] as [String: Any])
}

@Test func claudeRemoveLeavesCodexOwnedEntriesAlone() throws {
    let remaining = try commands(try object(try ClaudeHooks.remove(from: mixedOwnershipFile())),
                                 event: "Stop")

    #expect(!remaining.contains { $0.contains(ClaudeHooks.marker) })
    #expect(remaining.contains { $0.contains(CodexHooks.marker) })
    #expect(remaining.contains("/usr/local/bin/not-ours"))
}

@Test func codexRemoveLeavesClaudeOwnedEntriesAlone() throws {
    let remaining = try commands(try object(try CodexHooks.remove(from: mixedOwnershipFile())),
                                 event: "Stop")

    #expect(!remaining.contains { $0.contains(CodexHooks.marker) })
    #expect(remaining.contains { $0.contains(ClaudeHooks.marker) })
    #expect(remaining.contains("/usr/local/bin/not-ours"))
}

@Test func neitherRemoveTreatsTheOthersMarkerAsItsOwnPrefix() {
    // `isOurs` matches the ownership sentinel as an exact suffix. A substring
    // or prefix match would make one integration's sweep claim the other's
    // entries the moment either marker changed.
    let claudeEntry: [String: Any] = [
        "type": "command",
        "command": "x; \(HookFile.ownershipComment(marker: ClaudeHooks.marker))",
    ]
    let codexEntry: [String: Any] = [
        "type": "command",
        "command": "x; \(HookFile.ownershipComment(marker: CodexHooks.marker))",
    ]

    #expect(HookFile.isOurs(claudeEntry, marker: ClaudeHooks.marker))
    #expect(!HookFile.isOurs(claudeEntry, marker: CodexHooks.marker))
    #expect(HookFile.isOurs(codexEntry, marker: CodexHooks.marker))
    #expect(!HookFile.isOurs(codexEntry, marker: ClaudeHooks.marker))
}

@Test func everyAgentOwnershipMarkerIsUniqueAndNonOverlapping() {
    let markers = [
        ClaudeHooks.marker, CodexHooks.marker, CursorHooks.marker,
        CopilotHooks.marker, OpenCodePlugin.marker,
    ]
    #expect(Set(markers).count == 5)
    for marker in markers {
        #expect(markers.filter { $0 != marker }.allSatisfy {
            !marker.contains($0) && !$0.contains(marker)
        })
    }
}
