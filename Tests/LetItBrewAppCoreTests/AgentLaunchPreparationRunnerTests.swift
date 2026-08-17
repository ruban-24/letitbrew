import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

@Test func launchRunnerForwardsExactSnapshot() throws {
 let snapshot=try ExactFileSnapshot(path:"/tmp/A",exists:false); var received: ExactTargetPreparation?
 AgentLaunchPreparationRunner.run([.exactTarget(agentID:"claude",expectedState:.absent,snapshot:snapshot)],runRecorded:{ _ in },runExact:{ received=$0 })
 #expect(received?.snapshot == snapshot); #expect(received?.agent == .claude)
}

@Test func launchRunnerPreservesSortedPreparationIdentity() throws {
    let snapshot = try ExactFileSnapshot(path: "/tmp/recorded", exists: false)
    var events: [String] = []
    var exact: ExactTargetPreparation?
    AgentLaunchPreparationRunner.run(
        [
            .recordedTarget(agentID: "cursor"),
            .exactTarget(agentID: "claude", expectedState: .absent, snapshot: snapshot),
        ],
        runRecorded: { events.append("recorded:\($0)") },
        runExact: { request in exact = request; events.append("exact:\(request.agent.rawValue)") }
    )
    #expect(events == ["recorded:cursor", "exact:claude"])
    #expect(exact?.snapshot == snapshot)
    #expect(exact?.expectedState == .absent)
}
