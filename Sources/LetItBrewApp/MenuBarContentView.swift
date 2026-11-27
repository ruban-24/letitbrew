import AppKit
import LetItBrewAppCore
import LetItBrewCore
import SwiftUI

struct MenuBarStatusIcon: View {
    let icon: BrewIcon
    let state: BrewIconState
    let toolTip: String
    private static let size: CGFloat = 18

    @State private var frame = 0
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var frameCount: Int {
        icon.frameCount(for: state, reduceMotion: reduceMotion, lowPowerMode: lowPowerMode)
    }

    // A MenuBarExtra label must be Text or an Image. A ZStack of Shapes draws
    // correctly everywhere else and renders as an empty status item here, so
    // the glyph is drawn into an NSImage rather than composed in SwiftUI, and
    // the awake animation swaps pre-rendered frames on a timer instead of
    // tweening. The timer exists only while there is more than one frame.
    var body: some View {
        Image(nsImage: BrewIconImages.image(
            icon: icon,
            state: state,
            frame: frameCount > 1 ? frame % frameCount : 0,
            side: Self.size
        ))
        .task(id: frameCount) {
            frame = 0
            guard frameCount > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: BrewIcon.frameInterval)
                frame = BrewIcon.frame(after: frame, count: frameCount)
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSProcessInfoPowerStateDidChange
        ).receive(on: RunLoop.main)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onAppear { MenuBarStatusItemToolTip.apply(toolTip) }
        .onChange(of: toolTip) { _, newValue in MenuBarStatusItemToolTip.apply(newValue) }
    }
}

/// Pre-rendered icon frames, for the menu bar and the Settings previews.
/// Every state but needs-you is a template image: macOS recolours it for the
/// current menu-bar appearance and inverts it on highlight, keying entirely off the alpha channel. Needs-you carries
/// the orange dot, which a template would flatten, so it draws its glyph in
/// the label colour resolved for the appearance it is drawn in.
@MainActor
enum BrewIconImages {
    private struct Key: Hashable {
        let icon: BrewIcon
        let state: BrewIconState
        let frame: Int
        let side: CGFloat
    }

    private static var cache: [Key: NSImage] = [:]

    static func image(icon: BrewIcon, state: BrewIconState, frame: Int, side: CGFloat) -> NSImage {
        let key = Key(icon: icon, state: state, frame: frame, side: side)
        if let image = cache[key] { return image }

        let isTemplate = state != .needsYou
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            icon.draw(
                in: context,
                state: state,
                frame: frame,
                scale: min(rect.width, rect.height) / FlaskGeometry.canvas,
                ink: isTemplate ? NSColor.black.cgColor : NSColor.labelColor.cgColor,
                dot: NSColor.systemOrange.cgColor
            )
            return true
        }
        image.isTemplate = isTemplate
        // A non-template image must redraw for each appearance so its glyph
        // follows light and dark menu bars.
        if !isTemplate { image.cacheMode = .never }
        cache[key] = image
        return image
    }
}

/// A MenuBarExtra label ignores `.help`, so the tooltip goes straight onto
/// the status item's button, found through the status bar window that hosts
/// it. Missing the button only loses the tooltip.
@MainActor
private enum MenuBarStatusItemToolTip {
    static func apply(_ text: String) {
        // The status item's window can appear after the label does.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.className == "NSStatusBarWindow" {
                guard let button = statusBarButton(in: window.contentView) else { continue }
                button.toolTip = text
            }
        }
    }

    private static func statusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusBarButton(in: subview) { return button }
        }
        return nil
    }
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

/// A quiet card for setup prompts and warnings: a near-white panel in light
/// mode, a faint lift in dark mode. Only the card's icon carries colour. It
/// sits 4 pt inside the menu's row inset.
private struct MenuCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: 9)
        content
            .background(Color.white.opacity(isDark ? 0.07 : 0.78), in: shape)
            .overlay(shape.strokeBorder(isDark ? Color.white.opacity(0.09) : Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(isDark ? 0 : 0.05), radius: 1, y: 1)
            .padding(.horizontal, 4)
    }
}

private extension View {
    func menuCard() -> some View {
        modifier(MenuCard())
    }

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
    /// Rows under the pointer that belong to an expanded folder, by the folder
    /// they belong to. Moving between rows of one folder can report the new
    /// row's entry before the old row's exit, so each row is tracked.
    @State private var hoveredFolderRows: [MenuRepositoryLayoutItem.ID: String] = [:]

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

            // Groups are separated by space; the only divider sits above the
            // footer.
            KeepAwakeRowView()
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)

            if !boardItems.isEmpty {
                sessionBoard
                    .padding(.bottom, 4)
            }

            if !otherSupplementaryRows.isEmpty || setupAttention != nil || model.showsAlertsTip {
                VStack(spacing: 6) {
                    ForEach(Array(otherSupplementaryRows.enumerated()), id: \.offset) { _, row in
                        supplementaryRow(row)
                    }
                    if let setupAttention {
                        setupAttentionRow(setupAttention)
                    }
                    if model.showsAlertsTip {
                        alertsTip
                    }
                }
                // Rows keep the menu's 6 pt inset; cards sit 4 pt further in.
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }

            menuDivider
            footer
                .padding(6)
        }
        .frame(width: 344)
        // Polling updates content in place. Only an explicit disclosure click
        // animates layout, so background work cannot animate the scroll area.
        .onAppear {
            updateExpansionState()
        }
        .onDisappear {
            expandedRepositoryID = nil
            initializedExpansion = false
            hoveredFolderRows = [:]
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
                    .font(.body.weight(.semibold))
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
                .controlSize(.mini)
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
            .menuCard()

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
                Image(systemName: attention.systemImageName)
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
        .menuCard()
    }

    /// Offered once after updating; dismissing or turning alerts on ends it.
    private var alertsTip: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge")
                .font(.system(size: 15))
                .foregroundStyle(Color(.brewPurple))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(AlertsTipPolicy.title)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AlertsTipPolicy.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Turn On") { model.setDesktopAlerts(true) }
                        .buttonStyle(.borderedProminent)
                    Button("Not Now") { model.dismissAlertsTip() }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .menuCard()
    }

    private var sessionBoard: some View {
        let items = boardItems
        return ScrollView {
            // Plain VStack, not Lazy: this single outer scroll view is capped by
            // the presentation policy and preserves insertion/removal transitions.
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
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
                                // Expanded, the whole folder block highlights instead.
                                highlightsOnHover: expandedRepositoryID != group.id,
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

                        case .hold(let hold):
                            HoldRowView(hold: hold)
                        }
                    }
                    .background { folderGroupBackground(at: index, in: items) }
                    .onHover { hovering in
                        if hovering, let folder = expandedFolderID(of: item) {
                            hoveredFolderRows[item.id] = folder
                        } else {
                            hoveredFolderRows[item.id] = nil
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: MenuActivityViewportMetrics.height(for: items))
        // A row can vanish under the pointer, for example after Stop Watching,
        // without reporting a hover exit, and collapsing moves a row out of its
        // folder. Keep only rows still shown in the folder they were hovered in.
        .onChange(of: items) { _, current in
            hoveredFolderRows = hoveredFolderRows.filter { id, folder in
                current.contains { $0.id == id && expandedFolderID(of: $0) == folder }
            }
        }
    }

    /// The expanded folder a row belongs to: its header or one of its sessions.
    private func expandedFolderID(of item: MenuRepositoryLayoutItem) -> String? {
        switch item {
        case .header(let group):
            expandedRepositoryID == group.id ? group.id : nil
        case .session(let session, _, _):
            item.isGroupedSession ? session.session.repositoryID : nil
        case .section, .hold:
            nil
        }
    }

    /// An expanded folder and its sessions share one rounded, shaded block,
    /// drawn row by row: rounded on top at the folder, at the bottom after its
    /// last session. Its sessions keep the same left edge as every other row.
    /// The pointer anywhere in the folder deepens the whole block, and a
    /// session under it adds its own highlight on top.
    @ViewBuilder
    private func folderGroupBackground(
        at index: Int,
        in items: [MenuRepositoryLayoutItem]
    ) -> some View {
        let item = items[index]
        if let folder = expandedFolderID(of: item) {
            let isTop = if case .header = item { true } else { false }
            let isBottom = index + 1 == items.count || !items[index + 1].isGroupedSession
            let isHovered = hoveredFolderRows.values.contains(folder)
            UnevenRoundedRectangle(
                topLeadingRadius: isTop ? 8 : 0,
                bottomLeadingRadius: isBottom ? 8 : 0,
                bottomTrailingRadius: isBottom ? 8 : 0,
                topTrailingRadius: isTop ? 8 : 0
            )
            .fill(Color.primary.opacity(isHovered ? 0.1 : 0.05))
        }
    }

    private var boardItems: [MenuRepositoryLayoutItem] {
        MenuBoardLayoutPolicy.items(
            waiting: model.sessions.filter(\.isWaiting),
            groups: model.sessionGroups,
            holds: model.holdRows,
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
        if let manualSessionHeaderDetail = model.manualSessionHeaderDetail {
            return manualSessionHeaderDetail
        }
        let context: MenuHeaderDetailContext = switch model.presentationState {
        case .awake: .awake
        case .idle: .idle
        case .paused: .paused
        }
        return MenuHeaderDetailCopy.resolve(
            context: context,
            rows: model.sessions,
            holdCount: model.holdRows.count
        )
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
    let highlightsOnHover: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            // The folder sits in the same icon and text columns as a session
            // on its own row; the disclosure chevron trails, as in system menus.
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(group.project)
                    .fontWeight(.medium)
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

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: RowMetrics.repositoryHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popoverHoverHighlight(highlightsOnHover)
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
        .padding(.horizontal, 10)
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

    /// A session on its own row is titled by its project; under a folder,
    /// which already names the project, by its agent.
    private var summary: some View {
        HStack(spacing: 10) {
            AgentLogo(toolID: session.toolID)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(isGrouped ? session.toolName : session.project)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    stateDot
                    Text(subtitle)
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

    /// The agent's name joins the state on a row of its own, except for the
    /// long monitoring states, where the logo already names the agent.
    private var subtitle: String {
        let isMonitoringState = session.isMonitoring || (!session.isWorking && !session.isWaiting)
        return isGrouped || isMonitoringState
            ? session.stateText
            : "\(session.toolName) · \(session.stateText)"
    }

    private var stateDot: some View {
        Circle()
            .fill(session.isWaiting
                  ? Color.orange
                  : session.isWorking ? Color.green.opacity(0.75) : Color.secondary)
            .frame(width: 6, height: 6)
    }

    private var activeTime: some View {
        Text(session.activeTimeText)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .help("Active for \(session.activeTimeText)")
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

/// A `letitbrew hold`: laid out like an agent session row, with a terminal
/// glyph in place of the agent's logo and nothing to open or stop watching.
private struct HoldRowView: View {
    let hold: MenuHoldPresentation

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                AgentLogo(toolID: "")
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hold.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green.opacity(0.75))
                            .frame(width: 6, height: 6)
                        Text(hold.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(hold.elapsedText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("Holding for \(hold.elapsedText)")
        }
        .padding(.horizontal, 10)
        .frame(height: RowMetrics.sessionHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(hold.title), \(hold.subtitle), active for \(hold.elapsedText)")
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
            case "cursor":
                Image("CursorAgent")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case "gemini":
                Image("GeminiAgent")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case "qwen":
                Image("QwenAgent")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case "kimi":
                Image("KimiAgent")
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

#Preview("Hold running beside an agent") {
    let now = Date()
    MenuBarContentView()
        .environmentObject(LetItBrewAppModel.preview(
            sessions: [
                previewSession(
                    id: "codex-flat", tool: "codex",
                    cwd: "/Projects/letitbrew", updatedAt: now.addingTimeInterval(-5)
                ),
            ],
            holds: [
                HoldRecord(pid: 4_182, label: "npm run build",
                           startedAt: now.addingTimeInterval(-1_520)),
            ],
            now: now
        ))
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
