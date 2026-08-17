import Foundation
import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

private func helperStub() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
    )
    let url = directory.appendingPathComponent("helper.sh")
    let script = """
    #!/bin/sh
    if [ "$2" = "claude" ]; then
      trap '' TERM
      while :; do :; done
    fi
    printf 'handled %s' "$2"
    """
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: url.path
    )
    return url
}

@Test func oneTimedOutAgentDoesNotPreventTheOtherAgentAttempt() throws {
    let helper = try helperStub()
    defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }

    let results = AgentHelperBatchRunner.run(
        executableURL: helper,
        command: "uninstall",
        agentIDs: ["claude", "codex"],
        timeout: 5,
        terminationGrace: 0.1
    )

    #expect(results.map(\.agentID) == ["claude", "codex"])
    #expect(results[0].timedOut)
    #expect(!results[0].succeeded)
    #expect(results[1].succeeded)
    #expect(results[1].output == "handled codex")
}

@Test func selectionHelpersArePureAndTask10OwnsEffectOrdering() {
    let connected = AgentConnectionSelectionPolicy.selecting("codex", in: ["claude"])
    let disconnected = AgentConnectionSelectionPolicy.deselecting("claude", from: connected)
    #expect(connected == ["claude", "codex"])
    #expect(disconnected == ["codex"])
}

@Test func disconnectCompletionHasOnlyTerminalPerAgentFollowUps() {
    let results = [
        AgentHelperOperationResult(
            agentID: "claude", status: 0, output: "removed", timedOut: false
        ),
        AgentHelperOperationResult(
            agentID: "codex", status: -1, output: "timed out", timedOut: true
        ),
    ]

    #expect(AgentDisconnectCompletionPolicy.followUps(for: results) == [
        .markDisconnected(agentID: "claude"),
        .showFailure(results[1]),
    ])
}

@Test func allFiveAgentsAreAttemptedOnceAfterAMiddleFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let helper = directory.appendingPathComponent("helper.sh")
    try Data("#!/bin/sh\n[ \"$2\" = \"cursor\" ] && exit 7\nprintf '%s' \"$2\"\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let ids = AgentID.allCases.map(\.rawValue)
    let results = AgentHelperBatchRunner.run(executableURL: helper, command: "uninstall", agentIDs: ids, timeout: 5)
    #expect(results.map(\.agentID) == ids)
    #expect(results.filter(\.succeeded).map(\.agentID) == ["claude", "codex", "opencode", "copilot"])
    #expect(results.first(where: { $0.agentID == "cursor" })?.status == 7)
}
