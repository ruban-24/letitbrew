import Foundation
import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

@Test func suppressionSurvivesConnectionSelectionChanges() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let record = SessionRecord(id: "one", tool: "claude", state: .working, detail: nil, cwd: "/tmp", pid: 1, updatedAt: now)
    let suppression = SessionTrackingSuppression(session: record)
    let disconnected = AgentSessionVisibilityPipeline.apply(sessions: [record], connectedAgentIDs: [], suppressions: [suppression])
    let connected = AgentSessionVisibilityPipeline.apply(sessions: [record], connectedAgentIDs: ["claude"], suppressions: disconnected.suppressions)
    #expect(disconnected.sessions.isEmpty)
    #expect(connected.sessions.isEmpty)
    #expect(connected.suppressions == [suppression])
}
