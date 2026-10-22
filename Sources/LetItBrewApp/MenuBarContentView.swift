import AppKit
import LetItBrewAppCore
import LetItBrewCore
import SwiftUI

struct MenuBarStatusIcon: View {
    let state: LetItBrewPresentationState

    // ponytail: a fraction of the cone's height, not its area. The cone widens
    // downward, so this pour covers well over half the glyph — the point is that
    // awake reads as clearly filled vs an empty idle outline at 18pt monochrome
    // in the menu bar, where fill level is the only state signal. Nudge down if
    // it reads heavy, up if awake/idle look too alike.
    private static let activeFillLevel: CGFloat = 0.62
    private static let size: CGFloat = 18

    private var level: CGFloat { state == .awake ? Self.activeFillLevel : 0 }

    // A MenuBarExtra label must be Text or an Image. A ZStack of Shapes draws
    // correctly everywhere else and renders as an empty status item here, so
    // the glyph is drawn into a template NSImage rather than composed in
    // SwiftUI. Drawing it also costs the pour animation: an Image cannot tween
    // between levels.
    var body: some View {
        Image(nsImage: flaskImage(level: level, side: Self.size))
    }
}

/// The flask as a template image: macOS recolours it for the current menu-bar
/// appearance and inverts it on highlight, keying entirely off the alpha
/// channel — which is exactly what the opaque PNGs this replaced got wrong.
private func flaskImage(level: CGFloat, side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.setFillColor(NSColor.black.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        FlaskGeometry.draw(
            in: context,
            level: level,
            scale: min(rect.width, rect.height) / FlaskGeometry.canvas
        )
        return true
    }
    image.isTemplate = true
    return image
}

private struct PopoverHoverHighlight: ViewModifier {
    let isEnabled: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                isEnabled && isHovered ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .onHover { isHovered = $0 }
    }
}

private extension View {
    /// The rounded, inset highlight a menu item shows under the pointer.
    func popoverHoverHighlight(_ isEnabled: Bool = true) -> some View {
        modifier(PopoverHoverHighlight(isEnabled: isEnabled))
    }

    /// The row's default VoiceOver action, only when its app can be opened.
    @ViewBuilder
    func accessibilityOpenAction(_ open: (() -> Void)?) -> some View {
        if let open {
            accessibilityAction(.default, open)
        } else {
            self
        }
    }
}

private typealias RowMetrics = MenuActivityViewportMetrics

struct MenuBarContentView: View {
    @EnvironmentObject private var model: LetItBrewAppModel
    @Environment(\.openSettings) private var openSettings
    @State private var expandedRepositoryID: String?
    @State private var initializedExpansion = false

    var body: some View {
        Group {
            if case .report = model.uninstallState {
                uninstallRecovery
            } else {
                ordinaryContent
            }
        }
    }

    private var ordinaryContent: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if !boardItems.isEmpty {
                menuDivider
                sessionBoard
                    .padding(.vertical, 5)
            }

            if !otherSupplementaryRows.isEmpty || setupAttention != nil {
                menuDivider
                VStack(spacing: 4) {
                    ForEach(Array(otherSupplementaryRows.enumerated()), id: \.offset) { _, row in
                        supplementaryRow(row)
                    }
                    if let setupAttention {
                        setupAttentionRow(setupAttention)
                    }
                }
                .padding(6)
            }

            menuDivider
            footer
                .padding(6)
        }
        .frame(width: 344)
        // Polling updates content in place. Only an explicit disclosure click
        // animates layout, so background work cannot animate the scroll area.
        .onAppear {
            model.menuDidOpen()
            updateExpansionState()
        }
        .onDisappear {
            model.menuDidClose()
            expandedRepositoryID = nil
            initializedExpansion = false
            model.cancelUpdate(from: .menuBar)
        }
        .onChange(of: model.hasLoadedSessionSnapshot) {
            updateExpansionState()
        }
        .onChange(of: repositoryStructure) {
            updateExpansionState()
        }
        .task { model.refreshNow() }
        .confirmationDialog(
            updateConfirmationTitle,
            isPresented: updateConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Install Update") { model.confirmUpdate() }
            Button("Cancel", role: .cancel) { model.cancelUpdate(from: .menuBar) }
        } message: {
            Text(updateConfirmationMessage)
        }
    }

    private var menuDivider: some View {
        Divider()
            .padding(.horizontal, 12)
    }

    private var uninstallRecovery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Uninstall needs attention", systemImage: "exclamationmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Cleanup still needs your attention. Open the instructions to finish and quit Let It Brew.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Show Cleanup Instructions") { showSettings() }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 344, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text(model.reason)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)

                Toggle("Let It Brew enabled", isOn: Binding(
                    get: { model.isEnabled },
                    set: { model.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityHint("Controls whether working agents may keep this Mac awake")
            }
            Text(headerDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let batteryPresentation {
                batteryLine(batteryPresentation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func batteryLine(_ presentation: MenuBatteryPresentation) -> some View {
        Label {
            Text(presentation.text)
        } icon: {
            Image(systemName: presentation.isAttention
                  ? "exclamationmark.triangle.fill"
                  : MenuBatteryIconPolicy.systemImageName(
                    percent: model.currentPower.batteryPercent
                  ))
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .foregroundStyle(presentation.isAttention ? Color.orange : Color.secondary)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func supplementaryRow(_ row: MenuSupplementaryRow) -> some View {
        switch row {
        case .holdReleaseFailure(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                Text(message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button("Retry") { model.setEnabled(false) }
                    .controlSize(.small)
                    .help("Try to release every sleep hold again")
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

        case .battery(let presentation):
            batteryLine(presentation)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)

        case .update(let version):
            Button {
                model.presentAvailableUpdate(on: .menuBar)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color(.brewPurple))
                        .accessibilityHidden(true)
                    Text("Update \(version.description) available")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popoverHoverHighlight()
        }
    }

    private func setupAttentionRow(_ attention: MenuSetupAttentionPresentation) -> some View {
        Button {
            showSettings()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(attention.title)
                        .fontWeight(.medium)
                    Text(attention.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sessionBoard: some View {
        ScrollView {
            // Plain VStack, not Lazy: this single outer scroll view is capped by
            // the presentation policy and preserves insertion/removal transitions.
            VStack(spacing: 0) {
                ForEach(boardItems) { item in
                    Group {
                        switch item {
                        case .section(let section):
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 6)
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: RowMetrics.sectionHeaderHeight,
                                    maxHeight: RowMetrics.sectionHeaderHeight,
                                    alignment: .leading
                                )
                                .accessibilityAddTraits(.isHeader)

                        case .header(let group):
                            RepositoryGroupRowView(
                                group: group,
                                isExpanded: expandedRepositoryID == group.id,
                                onToggle: { toggle(group.id) }
                            )

                        case .session(let session, _, _):
                            SessionRowView(
                                session: session.session,
                                isGrouped: item.isGroupedSession,
                                shortID: item.shortSessionID,
                                onOpen: session.session.agentPID.map { pid in
                                    { model.bringSessionForward(agentPID: pid) }
                                },
                                onStopTracking: { stopTracking(session.session) }
                            )
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: MenuActivityViewportMetrics.height(for: boardItems))
    }

    private var boardItems: [MenuRepositoryLayoutItem] {
        MenuBoardLayoutPolicy.items(
            waiting: model.sessions.filter(\.isWaiting),
            groups: model.sessionGroups,
            expandedRepositoryID: expandedRepositoryID
        )
    }

    private var repositoryStructure: [String] {
        model.sessionGroups.map { "\($0.id)\u{1F}\($0.sessions.count)" }
    }

    private func updateExpansionState() {
        let state = MenuRepositoryExpansionPolicy.updatedState(
            current: MenuRepositoryExpansionState(
                expandedRepositoryID: expandedRepositoryID,
                initialized: initializedExpansion
            ),
            hasLoadedSnapshot: model.hasLoadedSessionSnapshot,
            groups: model.sessionGroups
        )
        expandedRepositoryID = state.expandedRepositoryID
        initializedExpansion = state.initialized
    }

    private func toggle(_ repositoryID: String) {
        withAnimation(.snappy) {
            expandedRepositoryID = MenuRepositoryExpansionPolicy.toggle(
                current: expandedRepositoryID,
                requested: repositoryID
            )
        }
    }

    private func stopTracking(_ session: MenuSessionPresentation) {
        model.stopTrackingSession(id: session.id, toolID: session.toolID)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            menuCommand("Settings…", shortcut: "⌘,") { showSettings() }
                .keyboardShortcut(",")
            menuCommand("Quit Let It Brew", shortcut: "⌘Q") { model.cleanQuit() }
                .keyboardShortcut("q")
        }
    }

    private func menuCommand(
        _ title: String,
        shortcut: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Text(shortcut)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popoverHoverHighlight()
    }

    private var headerDetail: String {
        let context: MenuHeaderDetailContext = switch model.presentationState {
        case .awake: .awake
        case .idle: .idle
        case .paused: .paused
        }
        return MenuHeaderDetailCopy.resolve(context: context, rows: model.sessions)
    }

    private var batteryPresentation: MenuBatteryPresentation? {
        MenuBatteryPresentationPolicy.resolve(
            power: model.currentPower,
            batteryFloor: Int(model.batteryFloor),
            releaseConstraint: model.releaseConstraint
        )
    }

    private var otherSupplementaryRows: [MenuSupplementaryRow] {
        MenuSupplementaryRowPolicy.rows(
            holdReleaseFailure: model.holdReleaseFailure,
            availableVersion: model.availableUpdate?.version
        )
    }

    private var setupAttention: MenuSetupAttentionPresentation? {
        MenuSetupAttentionPolicy.presentation(for: MenuSetupAttentionInput(
            hasUpdateResult: model.updateCompletionReport != nil,
            closedLidNeedsAttention: model.daemonNeedsSetupAttention,
            connectedAgentCount: model.agentHooks.filter {
                $0.state == .connected && $0.disposition == .managed
            }.count
        ))
    }

    private var updateConfirmationTitle: String {
        guard case .available(let release) = model.updateState else {
            return "Install Let It Brew update?"
        }
        return "Install Let It Brew \(release.version)?"
    }

    private var updateConfirmationMessage: String {
        "Let It Brew will download and verify the signed update, briefly quit, safely transition its background service if present, and relaunch. Your settings and session records stay in place."
    }

    private var updateConfirmationBinding: Binding<Bool> {
        Binding(
            get: {
                guard model.updateConfirmationSurface == .menuBar,
                      case .available = model.updateState
                else { return false }
                return true
            },
            set: { presented in
                if !presented && !model.updateInProgress {
                    model.cancelUpdate(from: .menuBar)
                }
            }
        )
    }

    private func showSettings() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct RepositoryGroupRowView: View {
    let group: MenuRepositoryPresentation
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14)

                Text(group.project)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if !isExpanded {
                    HStack(spacing: 3) {
                        ForEach(agentIDs, id: \.self) { toolID in
                            AgentLogo(toolID: toolID)
                                .frame(width: 14, height: 14)
                        }
                    }
                }

                Text(group.sessionCountText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: RowMetrics.repositoryHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popoverHoverHighlight()
        .accessibilityLabel(
            "\(group.project) folder at \(group.id), \(group.sessionCountText), \(group.summaryText), \(isExpanded ? "expanded" : "collapsed")"
        )
        .accessibilityHint(isExpanded ? "Collapse sessions" : "Expand sessions")
    }

    /// Each agent in the folder once, in row order.
    private var agentIDs: [String] {
        var seen: Set<String> = []
        return group.sessions.map(\.session.toolID).filter { seen.insert($0).inserted }
    }
}

private struct SessionRowView: View {
    let session: MenuSessionPresentation
    /// Listed under its folder's header, so the folder name is not repeated.
    let isGrouped: Bool
    let shortID: String?
    /// Brings the session's app forward. Nil when its agent process is unknown.
    let onOpen: (() -> Void)?
    let onStopTracking: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let onOpen {
                    Button(action: onOpen) {
                        summary
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show this session's app")
                } else {
                    summary
                }
            }

            // Under the pointer the active time gives way to Stop Watching;
            // VoiceOver reaches it as an action on the row.
            ZStack(alignment: .trailing) {
                activeTime
                    .opacity(isHovered ? 0 : 1)
                Button(action: onStopTracking) {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop watching this session")
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(true)
            }
        }
        .padding(.leading, isGrouped ? 30 : 10)
        .padding(.trailing, 10)
        .frame(height: isGrouped ? RowMetrics.groupedSessionHeight : RowMetrics.sessionHeight)
        .background(
            isHovered && onOpen != nil ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            if let onOpen {
                Button("Show Session’s App", action: onOpen)
            }
            Button("Stop Watching", action: onStopTracking)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        .accessibilityHint(onOpen == nil ? "" : "Shows the app running this session")
        .accessibilityOpenAction(onOpen)
        .accessibilityAction(named: "Stop Watching", onStopTracking)
    }

    @ViewBuilder
    private var summary: some View {
        if isGrouped {
            HStack(spacing: 8) {
                AgentLogo(toolID: session.toolID)
                    .frame(width: 16, height: 16)
                Text(session.toolName)
                    .lineLimit(1)
                stateLabel
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 10) {
                AgentLogo(toolID: session.toolID)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.project)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        stateDot
                        Text("\(session.toolName) · \(session.stateText)")
                            .font(.subheadline)
                            .foregroundStyle(stateTextStyle)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stateLabel: some View {
        HStack(spacing: 5) {
            stateDot
            Text(session.stateText)
                .font(.subheadline)
                .foregroundStyle(stateTextStyle)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
    }

    private var stateDot: some View {
        Circle()
            .fill(session.isWaiting ? Color.orange : Color.green)
            .frame(width: 6, height: 6)
    }

    private var activeTime: some View {
        Text(session.activeTimeText)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var stateTextStyle: AnyShapeStyle {
        session.isWaiting ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary)
    }

    private var accessibilityLabel: String {
        if let shortID {
            return "\(session.toolName), folder \(session.repositoryID), session \(shortID), \(session.accessibilityState), accumulated active time \(session.activeTimeText)"
        }
        return "\(session.toolName), folder \(session.repositoryID), single session, \(session.accessibilityState), accumulated active time \(session.activeTimeText)"
    }
}

struct AgentLogo: View {
    let toolID: String

    var body: some View {
        Group {
            switch toolID.lowercased() {
            case "claude":
                Image("ClaudeAgent")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case "codex":
                Image("CodexAgent")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case "opencode":
                Image("OpenCodeAgent")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case "pi":
                Image("PiAgent")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case "copilot":
                // A black glyph: a template follows the label colour, so it
                // stays visible in dark mode.
                Image("CopilotAgent")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            default:
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(3)
            }
        }
        .accessibilityHidden(true)
    }
}

private func previewSession(
    id: String,
    tool: String,
    state: SessionState = .working,
    cwd: String,
    updatedAt: Date,
    activeTime: TimeInterval = 300
) -> SessionRecord {
    SessionRecord(
        id: id,
        tool: tool,
        state: state,
        detail: state == .working ? "running-command" : nil,
        cwd: cwd,
        pid: nil,
        updatedAt: updatedAt,
        lastEvent: state == .working ? "PreToolUse" : "Stop",
        startedAt: updatedAt.addingTimeInterval(-activeTime),
        accumulatedWorkingTime: activeTime
    )
}

#Preview("Zero visible — stored Idle") {
    let now = Date()
    MenuBarContentView()
        .environmentObject(LetItBrewAppModel.preview(sessions: [
            previewSession(
                id: "stored-idle", tool: "claude", state: .idle,
                cwd: "/Projects/idle", updatedAt: now.addingTimeInterval(-30)
            ),
        ], now: now))
}

#Preview("One flat Codex session") {
    let now = Date()
    MenuBarContentView()
        .environmentObject(LetItBrewAppModel.preview(sessions: [
            previewSession(
                id: "codex-flat", tool: "codex",
                cwd: "/Projects/letitbrew", updatedAt: now.addingTimeInterval(-5)
            ),
        ], now: now))
}

#Preview("Five mixed sessions — four-row window") {
    let now = Date()
    MenuBarContentView()
        .environmentObject(LetItBrewAppModel.preview(sessions: (0..<5).map { index in
            previewSession(
                id: "shared-\(index)",
                tool: index.isMultiple(of: 2) ? "codex" : "claude",
                cwd: "/Projects/shared",
                updatedAt: now.addingTimeInterval(TimeInterval(-index))
            )
        }, now: now))
}

#Preview("Two multi-session folders — newest expands") {
    let now = Date()
    MenuBarContentView()
        .environmentObject(LetItBrewAppModel.preview(sessions: [
            previewSession(
                id: "newest-codex", tool: "codex",
                cwd: "/Projects/newest", updatedAt: now
            ),
            previewSession(
                id: "newest-claude", tool: "claude",
                cwd: "/Projects/newest", updatedAt: now.addingTimeInterval(-1)
            ),
            previewSession(
                id: "older-codex", tool: "codex",
                cwd: "/Projects/older", updatedAt: now.addingTimeInterval(-20)
            ),
            previewSession(
                id: "older-claude", tool: "claude",
                cwd: "/Projects/older", updatedAt: now.addingTimeInterval(-21)
            ),
        ], now: now))
}

#Preview("Same folder name — separate full paths") {
    let now = Date()
    MenuBarContentView()
        .environmentObject(LetItBrewAppModel.preview(sessions: [
            previewSession(
                id: "projects-app", tool: "codex",
                cwd: "/Projects/app", updatedAt: now
            ),
            previewSession(
                id: "archive-app", tool: "claude",
                cwd: "/Archive/app", updatedAt: now.addingTimeInterval(-1)
            ),
        ], now: now))
}
