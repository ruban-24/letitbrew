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

private struct PopoverAppIcon: View {
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}

private struct PopoverHoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                isHovered ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .onHover { isHovered = $0 }
    }
}

private extension View {
    func popoverHoverHighlight(cornerRadius: CGFloat = 6) -> some View {
        modifier(PopoverHoverHighlight(cornerRadius: cornerRadius))
    }

    func popoverActionRowAffordance() -> some View {
        popoverHoverHighlight(cornerRadius: 0)
            .overlay(alignment: .top) {
                Divider()
                    .opacity(0.5)
            }
    }
}

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
                .padding(.vertical, 14)

            if let batteryPresentation {
                supplementaryRow(.battery(batteryPresentation))
            }

            if !model.sessions.isEmpty {
                sessionBoard
                    .padding(.top, 2)
            }

            if !otherSupplementaryRows.isEmpty {
                supplementaryRowsView(otherSupplementaryRows)
                    .padding(.top, 2)
            }

            if let setupAttention {
                Button {
                    showSettings()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(setupAttention.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text(setupAttention.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07))
            }

            footer
        }
        .frame(width: 344)
        .background(.regularMaterial)
        // Key animation and reconciliation to stable policy identity, never
        // active-time copy that changes on each refresh tick.
        .animation(.snappy, value: model.sessions.map(\.id))
        .onAppear(perform: updateExpansionState)
        .onDisappear {
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
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            PopoverAppIcon()

            VStack(alignment: .leading, spacing: 3) {
                Text(model.reason)
                    .font(.headline)
                    .foregroundStyle(headerColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityAddTraits(.isHeader)
                Text(headerDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func supplementaryRowsView(_ rows: [MenuSupplementaryRow]) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                supplementaryRow(row)
            }
        }
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
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button("Retry") { model.setEnabled(false) }
                    .controlSize(.small)
                    .help("Try to release every sleep hold again")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.07))

        case .battery(let presentation):
            Label {
                Text(presentation.text)
                    .font(.caption)
            } icon: {
                Image(systemName: presentation.isAttention
                      ? "exclamationmark.triangle.fill"
                      : MenuBatteryIconPolicy.systemImageName(
                        percent: model.currentPower.batteryPercent
                      ))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(presentation.isAttention ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

        case .update(let version):
            Button {
                model.presentAvailableUpdate(on: .menuBar)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color(.brewPurple))
                        .accessibilityHidden(true)
                    Text("Update \(version.description) available")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .popoverActionRowAffordance()
        }
    }

    private var sessionBoard: some View {
        ScrollView {
            // Plain VStack, not Lazy: this single outer scroll view is capped by
            // the presentation policy and preserves insertion/removal transitions.
            VStack(spacing: 2) {
                ForEach(sessionLayoutItems) { item in
                    Group {
                        switch item {
                        case .header(let group):
                            RepositoryGroupRowView(
                                group: group,
                                isExpanded: expandedRepositoryID == group.id,
                                onToggle: { toggle(group.id) }
                            )

                        case .session(let session, _):
                            SessionRowView(
                                session: session.session,
                                groupedProject: item.groupedProject,
                                shortID: item.shortSessionID,
                                onStopTracking: { stopTracking(session.session) }
                            )
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(height: MenuActivityViewportMetrics.height(for: sessionLayoutItems))
    }

    private var sessionLayoutItems: [MenuRepositoryLayoutItem] {
        model.sessionGroups.flatMap { group in
            MenuRepositoryLayoutPolicy.items(
                for: group,
                isExpanded: expandedRepositoryID == group.id
            )
        }
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
            Button {
                showSettings()
            } label: {
                HStack {
                    Text("Settings…")
                    Spacer(minLength: 12)
                    Text("⌘,")
                        .foregroundStyle(.secondary)
                }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 32)
            .popoverActionRowAffordance()
            .keyboardShortcut(",")

            Button {
                model.cleanQuit()
            } label: {
                HStack {
                    Text("Quit Let It Brew")
                    Spacer(minLength: 12)
                    Text("⌘Q")
                        .foregroundStyle(.secondary)
                }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 32)
            .popoverActionRowAffordance()
            .keyboardShortcut("q")
        }
        .font(.caption)
    }

    private var headerDetail: String {
        let context: MenuHeaderDetailContext = switch model.presentationState {
        case .awake: .awake
        case .idle: .idle
        case .paused: .paused
        }
        return MenuHeaderDetailCopy.resolve(context: context, rows: model.sessions)
    }

    private var headerColor: Color {
        .primary
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
            HStack(spacing: 10) {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.project)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(group.summaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)

                Text(group.sessionCountText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.11), in: Capsule())
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .frame(height: 54)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(group.project) folder at \(group.id), \(group.sessionCountText), \(group.summaryText), \(isExpanded ? "expanded" : "collapsed")"
        )
        .accessibilityHint(isExpanded ? "Collapse sessions" : "Expand sessions")
    }
}

private struct SessionRowView: View {
    let session: MenuSessionPresentation
    let groupedProject: String?
    let shortID: String?
    let onStopTracking: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AgentLogo(toolID: session.toolID)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(primaryText)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Spacer(minLength: 8)
                    Text(session.activeTimeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)

            Button(action: onStopTracking) {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .popoverHoverHighlight()
            .help("Stop watching this session")
            .accessibilityLabel("Stop watching \(session.project)")
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
    }

    private var primaryText: String {
        guard let groupedProject else { return session.project }
        return "\(session.toolName) · \(groupedProject)"
    }

    private var secondaryText: String {
        groupedProject == nil
            ? "\(session.toolName) · \(session.stateText)"
            : session.stateText
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
            case "copilot":
                Image("CopilotAgent")
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
