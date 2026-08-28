import Foundation
import Testing
@testable import LetItBrewAppCore
import LetItBrewCore

@Test func headerCopyPrioritizesPausedThenAwakeThenSafetyRelease() {
    #expect(MenuHeaderCopy.resolve(isPaused: true, isKeepingAwake: true)
        == "Let It Brew is paused")
    #expect(MenuHeaderCopy.resolve(isPaused: false, isKeepingAwake: true)
        == "Keeping your Mac awake")
    #expect(MenuHeaderCopy.resolve(
        isPaused: true,
        isKeepingAwake: false,
        releaseConstraint: .battery(percent: 20)
    ) == "Let It Brew is paused")
    #expect(MenuHeaderCopy.resolve(
        isPaused: false,
        isKeepingAwake: true,
        releaseConstraint: .thermal
    ) == "Keeping your Mac awake")
    #expect(MenuHeaderCopy.resolve(
        isPaused: false,
        isKeepingAwake: false,
        releaseConstraint: .battery(percent: 20)
    ) == "Battery at 20% — your Mac can sleep")
    #expect(MenuHeaderCopy.resolve(
        isPaused: false,
        isKeepingAwake: false,
        releaseConstraint: .thermal
    ) == "Mac is too warm — it can sleep")
    #expect(MenuHeaderCopy.resolve(
        isPaused: false,
        isKeepingAwake: false,
        releaseConstraint: .powerUnavailable
    ) == "Power status unavailable — your Mac can sleep")
    #expect(MenuHeaderCopy.resolve(isPaused: false, isKeepingAwake: false)
        == "Watching for agents")
}

@Test func headerDetailDescribesOnlyWorkingRows() {
    let now = Date(timeIntervalSince1970: 10_000)
    let rows = MenuSessionPresentationPolicy.rows(from: [
        input(id: "working", state: .working, updatedAt: now),
        input(id: "idle", state: .idle, updatedAt: now.addingTimeInterval(-1)),
    ], now: now)

    #expect(MenuHeaderDetailCopy.resolve(context: .awake, rows: rows)
        == "1 agent is working")
    #expect(MenuHeaderDetailCopy.resolve(context: .idle, rows: rows)
        == "Your Mac can sleep normally")
    #expect(MenuHeaderDetailCopy.resolve(context: .paused, rows: rows)
        == "Agents will not keep your Mac awake")
    #expect(MenuHeaderDetailCopy.resolve(context: .paused, rows: [])
        == "Agents will not keep your Mac awake")
}

@Test func batteryRowIsConditionalAndProtectionAware() {
    let battery = PowerState(onBattery: true, batteryPercent: 68, thermal: .nominal)
    #expect(MenuBatteryPresentationPolicy.resolve(
        power: battery,
        batteryFloor: 20,
        releaseConstraint: nil
    )?.text == "Battery 68% · Sleep hold stops below 20%")

    let plugged = PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
    #expect(MenuBatteryPresentationPolicy.resolve(
        power: plugged,
        batteryFloor: 20,
        releaseConstraint: nil
    ) == nil)

    #expect(MenuBatteryPresentationPolicy.resolve(
        power: plugged,
        batteryFloor: 20,
        releaseConstraint: .lowPowerMode
    )?.text == "Low Power Mode released the sleep hold")

    #expect(MenuBatteryPresentationPolicy.resolve(
        power: battery,
        batteryFloor: 20,
        releaseConstraint: .battery(percent: 20)
    )?.isAttention == true)
}

@Test func batteryIconUsesTheNearestNativeSteppedLevel() {
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 0) == "battery.0percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 12) == "battery.0percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 13) == "battery.25percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 24) == "battery.25percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 25) == "battery.25percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 37) == "battery.25percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 38) == "battery.50percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 50) == "battery.50percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 62) == "battery.50percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 63) == "battery.75percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 75) == "battery.75percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 87) == "battery.75percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 88) == "battery.100percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 99) == "battery.100percent")
    #expect(MenuBatteryIconPolicy.systemImageName(percent: 100) == "battery.100percent")
}

@Test func supplementaryRowsKeepReleaseFailureBeforeBatteryAndUpdate() throws {
    let battery = MenuBatteryPresentation(
        text: "Battery 68% · Sleep hold stops below 20%",
        isAttention: false
    )
    let version = try #require(StableUpdateVersion("0.6.6"))

    #expect(MenuSupplementaryRowPolicy.rows(
        holdReleaseFailure: "Release failed",
        battery: battery,
        availableVersion: version
    ) == [
        .holdReleaseFailure("Release failed"),
        .battery(battery),
        .update(version),
    ])
}

@Test func headerCopyMatchesEnabledIdleAndPausedStates() {
    #expect(MenuHeaderCopy.resolve(
        isPaused: false,
        isKeepingAwake: false
    ) == "Watching for agents")
    #expect(MenuHeaderDetailCopy.resolve(
        context: .idle,
        rows: []
    ) == "Your Mac can sleep normally")
    #expect(MenuHeaderDetailCopy.resolve(
        context: .paused,
        rows: []
    ) == "Agents will not keep your Mac awake")
}

@Test func sessionRowsAndRepositorySummaryUseAllFourCatalogNames() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let ids = ["claude", "codex", "opencode", "copilot"]
    let rows = MenuSessionPresentationPolicy.rows(from: ids.enumerated().map { index, id in
        input(id: id, tool: id, repositoryPath: "/work/all", updatedAt: now.addingTimeInterval(TimeInterval(-index)))
    }, now: now)
    #expect(rows.map(\.toolName) == ["Claude Code", "Codex", "OpenCode", "GitHub Copilot CLI"])
    let summary = try #require(MenuRepositoryPresentationPolicy.groups(from: rows).first?.summaryText)
    #expect(summary == "1 Claude Code · 1 Codex · 1 OpenCode · 1 GitHub Copilot CLI")
}

@Test func sessionRowsKeepOnlyWorkingInputs() {
    let now = Date(timeIntervalSince1970: 10_000)
    let cases: [(SessionMenuInput, [String])] = [
        (input(id: "working", state: .working, updatedAt: now), ["working"]),
        (input(id: "idle", state: .idle, updatedAt: now), []),
    ]

    for (session, expectedIDs) in cases {
        let rows = MenuSessionPresentationPolicy.rows(from: [session], now: now)
        #expect(rows.map(\.id) == expectedIDs)
        #expect(rows.allSatisfy { $0.stateText == "Working" })
    }
}

@Test func sessionRowsKeepBlankToolIdentityWhileDisplayingUnknownAgent() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let cases = [("", ""), (" \n\t ", " \n\t ")]

    for (tool, expectedToolID) in cases {
        let rows = MenuSessionPresentationPolicy.rows(from: [
            input(id: "unknown", tool: tool, repositoryPath: "/work/unknown", updatedAt: now)
        ], now: now)
        let row = try #require(rows.first)
        let group = try #require(MenuRepositoryPresentationPolicy.groups(from: rows).first)

        #expect(row.toolID == expectedToolID)
        #expect(row.toolName == "Unknown agent")
        #expect(group.summaryText == "1 Unknown agent")
    }
}

@Test func sessionRowsSortByUpdatedTimeThenSessionIDAndKeepDurationFormatting() {
    let now = Date(timeIntervalSince1970: 10_000)
    let rows = MenuSessionPresentationPolicy.rows(from: [
        input(id: "z-last", activeWorkingTime: 3_725, updatedAt: now.addingTimeInterval(-1)),
        input(id: "a-first", activeWorkingTime: 60, updatedAt: now),
        input(id: "b-second", activeWorkingTime: 95, updatedAt: now),
    ], now: now)

    #expect(rows.map(\.id) == ["a-first", "b-second", "z-last"])
    #expect(rows.map(\.activeTimeText) == ["1m active", "1m active", "1h 2m active"])
    #expect(rows.map(\.stateText) == ["Working", "Working", "Working"])
}

@Test func activeTimeUsesTheAccumulatedWorkingDuration() {
    let now = Date(timeIntervalSince1970: 10_000)
    let row = MenuSessionPresentationPolicy.rows(from: [
        input(id: "session", activeWorkingTime: 7_320, updatedAt: now)
    ], now: now).first

    #expect(row?.activeTimeText == "2h 2m active")
}

@Test func olderRefreshCannotReplaceANewerPresentedSnapshot() {
    let newer = Date(timeIntervalSince1970: 10_000)
    let older = newer.addingTimeInterval(-1)

    #expect(!MenuSnapshotOrderPolicy.shouldApply(
        candidateObservedAt: older,
        latestAppliedAt: newer
    ))
}

@Test func repositoryGroupsUseAgentMixWorkingCountAndCollisionSafeShortIDs() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let rows = MenuSessionPresentationPolicy.rows(from: [
        input(id: "5279876d-6100", tool: "codex", project: "letitbrew",
              repositoryPath: "/Users/me/code/letitbrew", updatedAt: now),
        input(id: "94eea3c2-9000", tool: "claude", project: "letitbrew",
              repositoryPath: "/Users/me/code/letitbrew", updatedAt: now.addingTimeInterval(-1)),
        input(id: "a211c7f4-2200", tool: "codex", project: "letitbrew",
              repositoryPath: "/Users/me/code/letitbrew", updatedAt: now.addingTimeInterval(-2)),
    ], now: now)

    let group = try #require(MenuRepositoryPresentationPolicy.groups(from: rows).first)

    #expect(group.id == "/Users/me/code/letitbrew")
    #expect(group.project == "letitbrew")
    #expect(group.summaryText == "1 Claude Code · 2 Codex")
    #expect(group.sessionCountText == "3 working")
    #expect(group.sessions.map(\.shortID) == ["5279876d", "94eea3c2", "a211c7f4"])
}

@Test func repositoryGroupUsesSingularWorkingCopyAndOrdersUnknownAgentsAlphabetically() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let single = try #require(group(
        repositoryPath: "/work/single",
        sessions: [input(id: "single", repositoryPath: "/work/single", updatedAt: now)],
        now: now
    ))
    let mixed = try #require(group(
        repositoryPath: "/work/mixed",
        sessions: [
            input(id: "codex", tool: "codex", repositoryPath: "/work/mixed", updatedAt: now),
            input(id: "claude", tool: "claude", repositoryPath: "/work/mixed", updatedAt: now.addingTimeInterval(-1)),
            input(id: "zeta", tool: "zeta", repositoryPath: "/work/mixed", updatedAt: now.addingTimeInterval(-2)),
            input(id: "alpha", tool: "alpha", repositoryPath: "/work/mixed", updatedAt: now.addingTimeInterval(-3)),
        ],
        now: now
    ))

    #expect(single.sessionCountText == "1 working")
    #expect(mixed.summaryText == "1 Claude Code · 1 Codex · 1 Alpha · 1 Zeta")
}

@Test func repositoryGroupsUseFullPathsSortByNewestActivityAndExtendShortIDCollisions() {
    let now = Date(timeIntervalSince1970: 10_000)
    let rows = MenuSessionPresentationPolicy.rows(from: [
        input(id: "abcdef12-one", tool: "codex", project: "app",
              repositoryPath: "/work/one/app", updatedAt: now),
        input(id: "abcdef12-two", tool: "claude", project: "app",
              repositoryPath: "/work/one/app", updatedAt: now.addingTimeInterval(-1)),
        input(id: "separate", tool: "codex", project: "app",
              repositoryPath: "/work/two/app", updatedAt: now.addingTimeInterval(-2)),
        input(id: "same-time", tool: "other", project: "app",
              repositoryPath: "/work/three/app", updatedAt: now.addingTimeInterval(-2)),
    ], now: now)

    let groups = MenuRepositoryPresentationPolicy.groups(from: rows)

    #expect(groups.map(\.id) == ["/work/one/app", "/work/three/app", "/work/two/app"])
    #expect(groups[0].sessions.map(\.shortID) == ["abcdef12-o", "abcdef12-t"])
    #expect(groups[0].summaryText == "1 Claude Code · 1 Codex")
}

@Test func repositoryLayoutUsesFlatRowsForOneSessionAndExpandedChildrenForManySessions() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let persistent = input(
        id: "5279876d-persistent", repositoryPath: "/work/letitbrew", updatedAt: now
    )
    let added = input(
        id: "94eea3c2-added", tool: "claude", repositoryPath: "/work/letitbrew",
        updatedAt: now.addingTimeInterval(-1)
    )
    let singleGroup = try #require(MenuRepositoryPresentationPolicy.groups(
        from: MenuSessionPresentationPolicy.rows(from: [persistent], now: now)
    ).first)
    let multiGroup = try #require(MenuRepositoryPresentationPolicy.groups(
        from: MenuSessionPresentationPolicy.rows(from: [persistent, added], now: now)
    ).first)

    let single = MenuRepositoryLayoutPolicy.items(for: singleGroup, isExpanded: false)
    let collapsed = MenuRepositoryLayoutPolicy.items(for: multiGroup, isExpanded: false)
    let expanded = MenuRepositoryLayoutPolicy.items(for: multiGroup, isExpanded: true)

    #expect(single.map(\.id) == [.session("5279876d-persistent")])
    #expect(single[0].shortSessionID == nil)
    #expect(collapsed.map(\.id) == [.header("/work/letitbrew")])
    #expect(expanded.map(\.id) == [
        .header("/work/letitbrew"),
        .session("5279876d-persistent"),
        .session("94eea3c2-added"),
    ])
    #expect(expanded[1].shortSessionID == "5279876d")
}

@Test func groupedSessionTitleUsesTheFolderInsteadOfAnInternalID() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let rows = MenuSessionPresentationPolicy.rows(from: [
        input(
            id: "v1|8:opencode|session-one", tool: "opencode", project: "sandbox",
            repositoryPath: "/Users/me/Documents/Github.nosync/sandbox", updatedAt: now
        ),
        input(
            id: "another-session", tool: "codex", project: "sandbox",
            repositoryPath: "/Users/me/Documents/Github.nosync/sandbox",
            updatedAt: now.addingTimeInterval(-1)
        ),
    ], now: now)
    let group = try #require(MenuRepositoryPresentationPolicy.groups(from: rows).first)
    let expanded = MenuRepositoryLayoutPolicy.items(for: group, isExpanded: true)

    #expect(expanded[1].groupedProject == "sandbox")
    #expect(expanded[1].shortSessionID == "v1|8:ope")
}

@Test func repositoryLayoutItemIDsStayStableWhenActiveTimeChanges() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let original = try #require(group(
        repositoryPath: "/work/stable",
        sessions: [
            input(id: "stable-a", repositoryPath: "/work/stable", activeWorkingTime: 60, updatedAt: now),
            input(id: "stable-b", repositoryPath: "/work/stable", activeWorkingTime: 120, updatedAt: now.addingTimeInterval(-1)),
        ],
        now: now
    ))
    let refreshed = try #require(group(
        repositoryPath: "/work/stable",
        sessions: [
            input(id: "stable-a", repositoryPath: "/work/stable", activeWorkingTime: 600, updatedAt: now),
            input(id: "stable-b", repositoryPath: "/work/stable", activeWorkingTime: 720, updatedAt: now.addingTimeInterval(-1)),
        ],
        now: now
    ))

    #expect(MenuRepositoryLayoutPolicy.items(for: original, isExpanded: true).map(\.id)
        == MenuRepositoryLayoutPolicy.items(for: refreshed, isExpanded: true).map(\.id))
}

@Test func repositoryExpansionKeepsOnlyTheSelectedMultiSessionGroupExpanded() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let older = try #require(group(
        repositoryPath: "/work/older",
        sessions: [
            input(id: "older-a", repositoryPath: "/work/older", updatedAt: now.addingTimeInterval(-2)),
            input(id: "older-b", repositoryPath: "/work/older", updatedAt: now.addingTimeInterval(-3)),
        ],
        now: now
    ))
    let newest = try #require(group(
        repositoryPath: "/work/newest",
        sessions: [
            input(id: "newest-a", repositoryPath: "/work/newest", updatedAt: now),
            input(id: "newest-b", repositoryPath: "/work/newest", updatedAt: now.addingTimeInterval(-1)),
        ],
        now: now
    ))

    #expect(MenuRepositoryExpansionPolicy.initialExpandedID(in: [newest, older]) == newest.id)
    #expect(MenuRepositoryExpansionPolicy.toggle(current: older.id, requested: newest.id) == newest.id)
    #expect(MenuRepositoryExpansionPolicy.toggle(current: newest.id, requested: newest.id) == nil)
    #expect(MenuRepositoryExpansionPolicy.reconcile(current: newest.id, groups: [older]) == nil)
}

@Test func repositoryExpansionWaitsForTheFirstLoadedSnapshot() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let newest = try #require(group(
        repositoryPath: "/work/newest",
        sessions: [
            input(id: "newest-a", repositoryPath: "/work/newest", updatedAt: now),
            input(id: "newest-b", repositoryPath: "/work/newest", updatedAt: now.addingTimeInterval(-1)),
        ],
        now: now
    ))

    let unloaded = MenuRepositoryExpansionPolicy.updatedState(
        current: MenuRepositoryExpansionState(
            expandedRepositoryID: nil,
            initialized: false
        ),
        hasLoadedSnapshot: false,
        groups: []
    )
    #expect(unloaded == MenuRepositoryExpansionState(
        expandedRepositoryID: nil,
        initialized: false
    ))

    let loaded = MenuRepositoryExpansionPolicy.updatedState(
        current: unloaded,
        hasLoadedSnapshot: true,
        groups: [newest]
    )
    #expect(loaded == MenuRepositoryExpansionState(
        expandedRepositoryID: "/work/newest",
        initialized: true
    ))
}

@Test func repositoryExpansionTreatsLoadedZeroAsInitializationWithoutOpeningLater() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let later = try #require(group(
        repositoryPath: "/work/later",
        sessions: [
            input(id: "later-a", repositoryPath: "/work/later", updatedAt: now),
            input(id: "later-b", repositoryPath: "/work/later", updatedAt: now.addingTimeInterval(-1)),
        ],
        now: now
    ))

    let loadedZero = MenuRepositoryExpansionPolicy.updatedState(
        current: MenuRepositoryExpansionState(
            expandedRepositoryID: nil,
            initialized: false
        ),
        hasLoadedSnapshot: true,
        groups: []
    )
    #expect(loadedZero == MenuRepositoryExpansionState(
        expandedRepositoryID: nil,
        initialized: true
    ))

    let laterMultiSessionGroup = MenuRepositoryExpansionPolicy.updatedState(
        current: loadedZero,
        hasLoadedSnapshot: true,
        groups: [later]
    )
    #expect(laterMultiSessionGroup == MenuRepositoryExpansionState(
        expandedRepositoryID: nil,
        initialized: true
    ))
}

@Test func activityViewportUsesTheRenderedLayoutAndCapsAtAHeaderPlusFourRows() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let headerPlusFourRows = try #require(group(
        repositoryPath: "/work/four",
        sessions: (1...4).map {
            input(id: "four-\($0)", repositoryPath: "/work/four", updatedAt: now.addingTimeInterval(TimeInterval(-$0)))
        },
        now: now
    ))
    let headerPlusFiveRows = try #require(group(
        repositoryPath: "/work/five",
        sessions: (1...5).map {
            input(id: "five-\($0)", repositoryPath: "/work/five", updatedAt: now.addingTimeInterval(TimeInterval(-$0)))
        },
        now: now
    ))
    let singleSession = try #require(group(
        repositoryPath: "/work/single",
        sessions: [input(id: "single", repositoryPath: "/work/single", updatedAt: now)],
        now: now
    ))

    #expect(MenuActivityViewportMetrics.height(for: MenuRepositoryLayoutPolicy.items(
        for: headerPlusFourRows,
        isExpanded: true
    )) == 294)
    #expect(MenuActivityViewportMetrics.height(for: MenuRepositoryLayoutPolicy.items(
        for: headerPlusFiveRows,
        isExpanded: true
    )) == 294)
    #expect(MenuActivityViewportMetrics.height(for: MenuRepositoryLayoutPolicy.items(
        for: singleSession,
        isExpanded: false
    )) == 60)
}

private func input(
    id: String,
    tool: String = "codex",
    project: String = "app",
    repositoryPath: String = "/work/app",
    state: MenuSessionState = .working,
    activeWorkingTime: TimeInterval = 60,
    updatedAt: Date
) -> SessionMenuInput {
    SessionMenuInput(
        id: id,
        tool: tool,
        project: project,
        repositoryPath: repositoryPath,
        state: state,
        activeWorkingTime: activeWorkingTime,
        updatedAt: updatedAt
    )
}

private func group(
    repositoryPath: String,
    sessions: [SessionMenuInput],
    now: Date
) -> MenuRepositoryPresentation? {
    MenuRepositoryPresentationPolicy.groups(
        from: MenuSessionPresentationPolicy.rows(from: sessions, now: now)
    ).first { $0.id == repositoryPath }
}
