import Foundation
import Testing
import LetItBrewAppCore
import LetItBrewCore

private let now = Date(timeIntervalSince1970: 10_000)

private func holdRows(_ labels: [String]) -> [MenuHoldPresentation] {
    MenuHoldPresentationPolicy.rows(
        from: labels.enumerated().map {
            HoldRecord(pid: Int32(100 + $0.offset), label: $0.element,
                       startedAt: now.addingTimeInterval(-125))
        },
        now: now
    )
}

private func agentRows(_ states: [MenuSessionState]) -> [MenuSessionPresentation] {
    MenuSessionPresentationPolicy.rows(
        from: states.enumerated().map {
            SessionMenuInput(id: "s\($0.offset)", tool: "claude", project: "app",
                             repositoryPath: "/work/app", state: $0.element,
                             activeWorkingTime: 60, updatedAt: now)
        },
        now: now
    )
}

@Test func holdRowReadsHoldingLabelWithElapsedTime() {
    let row = holdRows(["npm run build"]).first
    #expect(row?.title == "Holding · npm run build")
    #expect(row?.subtitle == "Command")
    #expect(row?.elapsedText == "2m")
}

@Test func holdsAreListedAfterAgentSessions() {
    let rows = agentRows([.working])
    let items = MenuBoardLayoutPolicy.items(
        waiting: [],
        groups: MenuRepositoryPresentationPolicy.groups(from: rows),
        holds: holdRows(["npm run build"]),
        expandedRepositoryID: nil
    )
    #expect(items.map(\.id) == [.session("s0"), .hold(100)])
    #expect(MenuActivityViewportMetrics.height(for: items) == 84)
}

@Test func holdOnlyMenuStillListsTheHold() {
    let items = MenuBoardLayoutPolicy.items(
        waiting: [], groups: [], holds: holdRows(["make"]), expandedRepositoryID: nil
    )
    #expect(items.map(\.id) == [.hold(100)])
}

@Test func holdsSitUnderWorkingWhenSomethingWaits() {
    let rows = agentRows([.waitingForApproval])
    let items = MenuBoardLayoutPolicy.items(
        waiting: rows.filter(\.isWaiting),
        groups: [],
        holds: holdRows(["make"]),
        expandedRepositoryID: nil
    )
    #expect(items.map(\.id) == [
        .section(.needsYou), .session("s0"), .section(.working), .hold(100),
    ])
}

@Test func headerDetailCountsHolds() {
    #expect(MenuHeaderDetailCopy.resolve(context: .awake, rows: [], holdCount: 1)
        == "1 command is holding")
    #expect(MenuHeaderDetailCopy.resolve(context: .awake, rows: [], holdCount: 2)
        == "2 commands are holding")
    #expect(MenuHeaderDetailCopy.resolve(context: .awake, rows: agentRows([.working]), holdCount: 2)
        == "1 agent is working · 2 commands are holding")
    #expect(MenuHeaderDetailCopy.resolve(
        context: .awake, rows: agentRows([.working, .waitingForAnswer]), holdCount: 1
    ) == "1 agent is working · 1 command is holding · 1 waiting")
    #expect(MenuHeaderDetailCopy.resolve(context: .awake, rows: [], holdCount: 0)
        == "No agents are working")
}
