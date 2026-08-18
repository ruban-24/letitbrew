import Foundation
import Testing
@testable import LetItBrewCore

private let visibilityNow = Date(timeIntervalSince1970: 1_700_000_000)
private let visibilityPower = PowerState(
    onBattery: false,
    batteryPercent: 100,
    thermal: .nominal
)

private func visibilitySession(
    id: String,
    tool: String,
    state: SessionState = .working,
    detail: String? = nil
) -> SessionRecord {
    SessionRecord(
        id: id,
        tool: tool,
        state: state,
        detail: detail,
        cwd: "/tmp/\(id)",
        pid: 1,
        updatedAt: visibilityNow
    )
}

@Test func disconnectedAgentSessionsAreHiddenWithoutMutatingTheRawSnapshot() {
    let raw = [
        visibilitySession(id: "claude-work", tool: "claude"),
        visibilitySession(id: "codex-work", tool: "codex"),
    ]

    let visible = AgentSessionVisibilityPolicy.visibleSessions(
        from: raw,
        connectedAgentIDs: ["claude"]
    )

    #expect(visible.map(\.id) == ["claude-work"])
    #expect(raw.map(\.id) == ["claude-work", "codex-work"])
}

@Test func disconnectingOneAgentDoesNotAffectOtherAgentSessionsOrTheirHold() {
    let raw = [
        visibilitySession(id: "claude-work", tool: "claude"),
        visibilitySession(id: "codex-work", tool: "codex"),
    ]
    let visible = AgentSessionVisibilityPolicy.visibleSessions(
        from: raw,
        connectedAgentIDs: ["claude"]
    )
    let decision = decide(
        sessions: visible,
        now: visibilityNow,
        settings: Settings(),
        power: visibilityPower
    )

    #expect(visible.map(\.id) == ["claude-work"])
    #expect(decision.holdSystem)
    #expect(decision.reason == "1 working")
}

@Test func reconnectingMakesTheSamePreservedLiveSessionsVisibleAgain() {
    let raw = [
        visibilitySession(id: "claude-work", tool: "claude"),
        visibilitySession(id: "codex-work", tool: "codex"),
    ]
    let disconnected = AgentSessionVisibilityPolicy.visibleSessions(
        from: raw,
        connectedAgentIDs: ["claude"]
    )
    let reconnected = AgentSessionVisibilityPolicy.visibleSessions(
        from: raw,
        connectedAgentIDs: ["claude", "codex"]
    )

    #expect(disconnected.map(\.id) == ["claude-work"])
    #expect(reconnected.map(\.id) == ["claude-work", "codex-work"])
}

@Test func disconnectingTheLastWorkerReleasesBothHoldsImmediately() {
    let raw = [visibilitySession(id: "codex-work", tool: "codex")]
    let visible = AgentSessionVisibilityPolicy.visibleSessions(
        from: raw,
        connectedAgentIDs: []
    )
    let decision = decide(
        sessions: visible,
        now: visibilityNow,
        settings: Settings(),
        power: visibilityPower
    )

    #expect(visible.isEmpty)
    #expect(!decision.holdSystem)
    #expect(!decision.holdLidClosed)
    #expect(decision.reason == "no agent sessions")
}

@Test func disconnectedCodexIdleSessionDoesNotRetainEitherHold() {
    let raw = [visibilitySession(
        id: "codex-idle",
        tool: "codex",
        state: .idle
    )]
    #expect(decide(
        sessions: raw,
        now: visibilityNow,
        settings: Settings(),
        power: visibilityPower
    ).holdSystem == false)

    let visible = AgentSessionVisibilityPolicy.visibleSessions(
        from: raw,
        connectedAgentIDs: []
    )
    let decision = decide(
        sessions: visible,
        now: visibilityNow,
        settings: Settings(),
        power: visibilityPower
    )

    #expect(visible.isEmpty)
    #expect(!decision.holdSystem)
    #expect(!decision.holdLidClosed)
}

@Test func onlyPositivelySelectedToolsAreVisible() {
    let raw = [
        visibilitySession(id: "custom-work", tool: "custom-agent"),
        visibilitySession(id: "claude-work", tool: "claude"),
        visibilitySession(id: "codex-work", tool: "codex"),
    ]

    let visible = AgentSessionVisibilityPolicy.visibleSessions(
        from: raw,
        connectedAgentIDs: ["claude"]
    )

    #expect(visible.map(\.id) == ["claude-work"])
}

@Test func everySupportedAgentReconnectsAndUnknownNeedsExplicitSelection() {
    let all = ["claude", "codex", "opencode", "copilot"]
    let raw = all.map { visibilitySession(id: "\($0)-work", tool: $0) } + [visibilitySession(id: "unknown", tool: "custom")]
    for id in all {
        #expect(AgentSessionVisibilityPolicy.visibleSessions(from: raw, connectedAgentIDs: [id]).map(\.tool) == [id])
    }
    #expect(AgentSessionVisibilityPolicy.visibleSessions(from: raw, connectedAgentIDs: []).isEmpty)
    #expect(AgentSessionVisibilityPolicy.visibleSessions(from: raw, connectedAgentIDs: ["custom"]).map(\.id) == ["unknown"])
}
