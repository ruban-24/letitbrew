import AppKit
import LetItBrewAppCore
import SwiftUI

struct LetItBrewSettingsView: View {
    @EnvironmentObject private var model: LetItBrewAppModel
    @State private var selectedPane: SettingsPane
    @State private var presentedRecovery: RecoveryGuidance?
    @State private var uninstallHovered = false

    init(initialPane: SettingsPane = .general) {
        _selectedPane = State(initialValue: initialPane)
    }

    var body: some View {
        // A TabView at the root of the Settings scene gives the standard
        // toolbar tabs; the window resizes to each pane and takes its title.
        TabView(selection: $selectedPane) {
            general
                .settingsPane(.general)
            agents
                .settingsPane(.agents)
            power
                .settingsPane(.power)
            closedLid
                .settingsPane(.closedLid)
            about
                .settingsPane(.about)
        }
        .sheet(isPresented: updateCompletionReportBinding) { updateCompletionReport }
        .sheet(isPresented: uninstallReportBinding) { uninstallReport }
        .sheet(item: $presentedRecovery) { guidance in
            recoverySheet(guidance)
        }
        .confirmationDialog(
            updateConfirmationTitle,
            isPresented: updateConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Install Update") { model.confirmUpdate() }
            Button("Cancel", role: .cancel) { model.cancelUpdate(from: .settings) }
        } message: {
            Text(updateConfirmationMessage)
        }
        .confirmationDialog(
            "Uninstall Let It Brew?",
            isPresented: uninstallConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) { model.confirmUninstall() }
            Button("Cancel", role: .cancel) { model.cancelUninstall() }
        } message: {
            Text("This disconnects all connected agent integrations, stops Let It Brew's background service, removes its settings and session records, and moves Let It Brew to the Trash.")
        }
    }

    // MARK: General

    private var general: some View {
        Form {
            LaunchAtLoginSettingsSection(
                isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ),
                isUpdating: model.loginItemUpdateInProgress,
                actionsBlocked: model.updateBlocksOtherActions,
                errorMessage: model.loginItemMessage,
                openLoginItems: { model.openLoginItemSettings() }
            )

            Section("Updates") {
                LabeledContent {
                    updateAccessory
                } label: {
                    Text("Let It Brew \(shortVersion)")
                    Text(updateStatus)
                }

                if case .failed(let failure, _) = model.updateState {
                    let guidance = OperationRecoveryCatalog.update(
                        kind: failure.kind,
                        diagnostic: model.updateDiagnostic(for: failure)
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Text(guidance.title)
                            .fontWeight(.medium)
                        Text(guidance.summary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Spacer()
                            Button("Dismiss") { model.dismissUpdateStatus() }
                            Button("Recovery Steps…") { presentedRecovery = guidance }
                            Button("Try Again") { model.retryUpdate() }
                                .disabled(model.updateInProgress)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var updateAccessory: some View {
        switch model.updateState {
        case .idle, .failed:
            checkForUpdatesButton("Check for Updates…")
        case .upToDate:
            checkForUpdatesButton("Check Again")
        case .checking, .installing, .readyToQuit:
            ProgressView()
                .controlSize(.small)
        case .available:
            EmptyView()
        }
    }

    private func checkForUpdatesButton(_ title: String) -> some View {
        Button(title) { model.checkForUpdates() }
            .disabled(model.updateBlocksOtherActions || model.uninstallInProgress)
    }

    private var updateStatus: String {
        switch model.updateState {
        case .idle: "Checks for updates daily. Nothing installs until you choose."
        case .checking: "Checking for updates…"
        case .upToDate: "Let It Brew is up to date."
        case .available(let release): "Version \(release.version.description) is available."
        case .installing: "Downloading and verifying update…"
        case .readyToQuit: "Update ready. Restarting Let It Brew…"
        case .failed: "The last update check didn’t finish."
        }
    }

    // MARK: Agents

    private var agents: some View {
        Form {
            Section {
                ForEach(model.agentHooks) { health in
                    WatchedAgentRow(
                        health: health,
                        isWatched: model.isAgentWatched(health.id),
                        isWorking: model.hookActionInProgress
                            || model.uninstallInProgress
                            || model.updateBlocksOtherActions,
                        setWatched: { model.setAgent(health.id, watched: $0) }
                    )
                }
            } header: {
                Text("Watched Agents")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let message = displayedHookMessage {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Spacer()
                        Button {
                            model.refreshAgentConnections()
                        } label: {
                            Label("Refresh Connections", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(
                            model.hookActionInProgress
                                || model.uninstallInProgress
                                || model.updateBlocksOtherActions
                                || !model.agentHooks.contains {
                                    model.isAgentWatched($0.id) || $0.disposition == .disconnectFailed
                                }
                        )
                        .help("Check watched agent connections again")
                        .accessibilityHint("Retry failed cleanup and check watched agent connections again")
                    }
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshCodexTrustIfNeeded()
        }
    }

    // MARK: Power

    private var power: some View {
        Form {
            Section("Battery") {
                Toggle(isOn: $model.onlyWhileConnectedToPower) {
                    Text("Only keep Mac awake while connected to power")
                }

                Picker("Stop keeping Mac awake below", selection: batteryFloorPercent) {
                    ForEach(Self.batteryFloorChoices, id: \.self) { percent in
                        Text("\(percent)%").tag(percent)
                    }
                }
                .disabled(model.onlyWhileConnectedToPower)

                Toggle(isOn: $model.respectLowPowerMode) {
                    Text("Respect Low Power Mode")
                    Text("Lets the Mac sleep when you turn on Low Power Mode. Let It Brew’s own closed-lid switch doesn’t count.")
                }
            }

            Section {
                Toggle(isOn: $model.allowDisplaysToSleep) {
                    Text("Allow displays to sleep while agents are working")
                    Text(model.allowDisplaysToSleep
                         ? "Displays may sleep while the system sleep hold remains active."
                         : "Display idle sleep is held only while an agent keeps the Mac awake.")
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Let It Brew always releases its sleep holds under serious or critical thermal pressure.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The battery floor in the five-point steps it is stored in.
    private static let batteryFloorChoices = Array(stride(from: 5, through: 50, by: 5))

    private var batteryFloorPercent: Binding<Int> {
        Binding(
            get: { Int(model.batteryFloor) },
            set: { model.batteryFloor = Double($0) }
        )
    }

    // MARK: Closed Lid

    private var closedLid: some View {
        let helper = BackgroundHelperPresentationPolicy.resolve(
            closedLidEnabled: model.keepWorkingWithLidClosed,
            recoveryState: model.daemonRecoveryState
        )

        return Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.keepWorkingWithLidClosed },
                    set: { model.setKeepWorkingWithLidClosed($0) }
                )) {
                    Text("Keep agents working when the lid is closed")
                    Text("Uses a local background helper only when enabled. Let It Brew never sends your agent data off this Mac.")
                }

                Toggle(isOn: $model.useLowPowerModeWithLidClosed) {
                    Text("Use Low Power Mode while the lid is closed")
                    Text("Switches to Low Power Mode while agents work with the lid shut and no external display, then restores your own setting when the lid opens or the work stops.")
                }
                .disabled(!model.keepWorkingWithLidClosed)

                if let message = model.lowPowerModeMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Section {
                LabeledContent("Background helper") {
                    HStack(spacing: 6) {
                        if helper.showsProgress {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        } else {
                            Circle()
                                .fill(helperStatusColor)
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                        }
                        Text(helper.status)
                            .foregroundStyle(.secondary)
                    }
                }

                if helper.requiresAttention {
                    Text(helper.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if !helper.actions.isEmpty {
                    HStack(spacing: 8) {
                        Spacer()
                        ForEach(Array(helper.actions.enumerated()), id: \.offset) { _, action in
                            switch action {
                            case .setUp:
                                Button("Repair Helper") { model.setUpDaemon() }
                                    .buttonStyle(.borderedProminent)
                            case .retry:
                                Button("Repair Helper") { model.retryDaemonConnection() }
                            case .openBackgroundItems:
                                Button("Open Background Items…") { model.openLoginItemSettings() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }

                if model.lidCloseDisplaySleepInProgress {
                    ProgressView("Turning off displays…")
                        .controlSize(.small)
                }
                if let message = model.lidCloseDisplaySleepMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Required for closed-lid operation. The helper runs locally and releases its hold if communication with Let It Brew stops.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshBackgroundHelper() }
    }

    private var helperStatusColor: Color {
        guard model.keepWorkingWithLidClosed else { return .secondary }
        return switch model.daemonRecoveryState {
        case .ready:
            .green
        case .approvalRequired:
            .orange
        case .retryableFailure, .ineligible:
            .red
        case .checking, .finishingUpdate, .restartingSupport, .deferredUntilEnabled:
            .secondary
        }
    }

    // MARK: About

    private var about: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("Let It Brew")
                        .font(.title2.weight(.semibold))
                    Text(versionDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("Keeps your Mac awake while local agents work, then lets it sleep when they finish.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)

                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Link("GitHub", destination: ProductLinks.repository)
                        .accessibilityHint("Open the Let It Brew repository")
                    Link("Release Notes", destination: ProductLinks.releases)
                        .accessibilityHint("Open Let It Brew releases")
                    Link("Report Issue", destination: ProductLinks.reportIssue)
                        .accessibilityHint("Open a new Let It Brew issue")
                    Link("Privacy", destination: ProductLinks.privacy)
                        .accessibilityHint("Open the Let It Brew privacy notice")
                }
                // Link paints itself with NSColor.linkColor, so the app
                // accent has to be applied explicitly here.
                .foregroundStyle(Color.accentColor)
                .padding(.top, 20)

                Divider()
                    .frame(maxWidth: 280)
                    .padding(.vertical, 16)

                uninstallControl
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var uninstallControl: some View {
        VStack(spacing: 8) {
            Button("Uninstall Let It Brew…") { model.beginUninstall() }
                .disabled(model.uninstallInProgress || model.updateBlocksOtherActions)
                .buttonStyle(.plain)
                .foregroundStyle(uninstallHovered ? Color.red : Color.secondary)
                .onHover { uninstallHovered = $0 }
            if case .blocked(let failure, let offersDiagnostic) = model.uninstallState {
                let guidance = OperationRecoveryCatalog.uninstall(
                    step: failure.step,
                    failureInstruction: failure.message,
                    diagnostic: offersDiagnostic
                        ? model.uninstallDiagnostic(for: [failure])
                        : nil
                )
                Text(guidance.title)
                    .font(.callout.weight(.medium))
                Text(guidance.summary)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Try Again") { model.retryUninstall() }
                        .disabled(model.uninstallInProgress || model.updateBlocksOtherActions)
                    Button("Recovery Steps…") {
                        presentedRecovery = guidance
                    }
                    if model.isPaused {
                        Button("Resume Let It Brew") {
                            model.resumeAfterBlockedUninstall()
                        }
                    }
                }
            }
        }
    }

    private var uninstallReport: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .report(let leftovers) = model.uninstallState {
                let bundleWasRemoved = !leftovers.contains {
                    $0.step.retainsBundleWhenReported
                }
                Text(bundleWasRemoved
                     ? (leftovers.count == 1
                        ? "Let It Brew was removed, but one step needs attention"
                        : "Let It Brew was removed, but some steps need attention")
                     : "Let It Brew cleanup needs attention")
                    .font(.headline)
                Text(bundleWasRemoved
                     ? "The app bundle and privileged background service are removed. This window remains open only to show you how to finish cleanup."
                     : "The privileged background service is stopped. This window remains open only to show you how to finish cleanup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(leftovers, id: \.step) { leftover in
                            let guidance = OperationRecoveryCatalog.uninstall(
                                step: leftover.step,
                                failureInstruction: leftover.message,
                                diagnostic: model.uninstallDiagnostic(for: [leftover])
                            )
                            VStack(alignment: .leading, spacing: 5) {
                                Text(guidance.title)
                                    .font(.callout.weight(.semibold))
                                Text(guidance.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Recovery Steps…") {
                                    presentedRecovery = guidance
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Spacer()
                    Button("Finish & Quit") { model.acknowledgeUninstallReport() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
        .onAppear { model.uninstallReportDidAppear() }
        .onDisappear { model.uninstallReportDidDisappear() }
    }

    @ViewBuilder
    private var updateCompletionReport: some View {
        if let report = model.updateCompletionReport {
            VStack(alignment: .leading, spacing: 12) {
                if report.outcome == .success {
                    Text("Let It Brew was updated")
                        .font(.headline)
                    Text(report.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(versionDescription)
                        .font(.callout.weight(.medium))
                } else {
                    let guidance = OperationRecoveryCatalog.update(
                        kind: .relaunch,
                        diagnostic: report.diagnostic
                    )
                    Text(guidance.title)
                        .font(.headline)
                    Text(report.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(guidance.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Recovery Steps…") {
                        presentedRecovery = guidance
                    }
                }
                HStack(spacing: 12) {
                    if report.logFile != nil {
                        Button("Reveal Log") { model.revealUpdateLog(report) }
                    }
                    Spacer()
                    Button("Done") { model.dismissUpdateCompletionReport() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 460)
        }
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
                guard model.updateConfirmationSurface == .settings,
                      case .available = model.updateState
                else { return false }
                return true
            },
            // SwiftUI also writes false after the Install button. The model
            // marks that operation in progress synchronously, so only a real
            // dismissal reaches cancelUpdate().
            set: { presented in
                if !presented && !model.updateInProgress {
                    model.cancelUpdate(from: .settings)
                }
            }
        )
    }

    private var updateCompletionReportBinding: Binding<Bool> {
        Binding(
            get: { model.updateCompletionReport != nil },
            set: { presented in
                if !presented {
                    model.dismissUpdateCompletionReport()
                }
            }
        )
    }

    private var uninstallConfirmationBinding: Binding<Bool> {
        Binding(
            get: {
                UninstallConfirmationPresentationPolicy.isPresented(
                    state: model.uninstallState,
                    inProgress: model.uninstallInProgress
                )
            },
            // SwiftUI writes `false` here for EVERY button in the dialog,
            // including the destructive one, so a bare `!presented` check
            // would cancel the very run the user just confirmed. The
            // in-progress flag is set synchronously by confirmUninstall()
            // before this write lands, which is what tells the two apart.
            set: { presented in
                if UninstallConfirmationPresentationPolicy.shouldCancel(
                    presented: presented,
                    state: model.uninstallState,
                    inProgress: model.uninstallInProgress
                ) {
                    model.cancelUninstall()
                }
            }
        )
    }

    private var uninstallReportBinding: Binding<Bool> {
        Binding(
            get: { if case .report = model.uninstallState { true } else { false } },
            set: { _ in }
        )
    }

    private func recoverySheet(_ guidance: RecoveryGuidance) -> some View {
        RecoveryGuidanceSheet(
            guidance: guidance,
            perform: performRecoveryAction,
            dismiss: { presentedRecovery = nil }
        )
    }

    private func performRecoveryAction(_ action: RecoveryAction) {
        switch action {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .copyDetails(let details):
            copyToPasteboard(details)
        case .openLoginItems:
            model.openLoginItemSettings()
        case .revealApplication:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var displayedHookMessage: String? {
        AgentConnectionMessagePolicy.displayedMessage(
            operationMessage: model.hookMessage,
            connections: model.agentHooks.map {
                AgentConnectionMessageInput(
                    name: $0.name,
                    state: $0.state,
                    disposition: $0.disposition
                )
            }
        )
    }

    private var shortVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
    }

    private var versionDescription: String {
        "Version \(shortVersion)"
    }
}

private struct RecoveryGuidanceSheet: View {
    let guidance: RecoveryGuidance
    let perform: (RecoveryAction) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(guidance.title)
                .font(.headline)

            Text(guidance.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(guidance.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.callout.weight(.semibold))
                        Text(step.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            HStack(spacing: 10) {
                ForEach(Array(guidance.actions.enumerated()), id: \.offset) { _, action in
                    Button(actionLabel(action)) { perform(action) }
                }

                Spacer()

                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func actionLabel(_ action: RecoveryAction) -> String {
        switch action {
        case .openURL(let url):
            url == ProductLinks.releases ? "Open Releases" : "Open Link"
        case .copyDetails:
            "Copy Details"
        case .openLoginItems:
            "Open Background Items…"
        case .revealApplication:
            "Reveal in Finder"
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case agents = "Agents"
    case power = "Power"
    case closedLid = "Closed Lid"
    case about = "About"

    var id: String { rawValue.lowercased() }
    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .agents: "terminal"
        case .power: "bolt"
        case .closedLid: "laptopcomputer"
        case .about: "info.circle"
        }
    }

    /// Fixed per pane: the Settings window animates between them. Tall
    /// failure text scrolls inside the pane instead of growing the window.
    var height: CGFloat {
        switch self {
        case .general: 240
        case .agents: 430
        case .power: 380
        case .closedLid: 360
        case .about: 360
        }
    }
}

private extension View {
    func settingsPane(_ pane: SettingsPane) -> some View {
        frame(width: 520, height: pane.height)
            .tabItem { Label(pane.title, systemImage: pane.systemImage) }
            .tag(pane)
            .accessibilityIdentifier("settings-pane-\(pane.id)")
    }
}

private struct WatchedAgentRow: View {
    let health: AgentHookHealth
    let isWatched: Bool
    let isWorking: Bool
    let setWatched: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(
            get: { isWatched },
            set: { watched in setWatched(watched) }
        )) {
            HStack(spacing: 10) {
                AgentLogo(toolID: health.id)
                    .frame(width: 22, height: 22)
                    .padding(4)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(health.name)
                    status
                }
            }
        }
        .toggleStyle(.switch)
        .disabled(isWorking)
        .accessibilityLabel("Watch \(health.name)")
        .accessibilityValue(statusText)
        .accessibilityHint(isWatched
            ? "Stop watching \(health.name) sessions"
            : "Watch \(health.name) sessions")
    }

    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            switch tone {
            case .progress:
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            case .attention:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            case .connected:
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            case .off:
                EmptyView()
            }
            Text(statusText)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.callout)
        .help(statusText)
    }

    private enum Tone { case progress, attention, connected, off }

    private var tone: Tone {
        if showsRecovery { return .attention }
        guard isWatched else { return .off }
        return switch health.state {
        case .connecting: .progress
        case .connected: .connected
        case .actionNeeded, .couldNotConnect: .attention
        }
    }

    private var statusText: String {
        if showsRecovery, let detail = health.details.first {
            return detail
        }
        guard isWatched else { return "Not watched" }
        return switch health.state {
        case .connecting: "Checking…"
        case .connected: "Connected"
        case .actionNeeded, .couldNotConnect: health.state.rawValue
        }
    }

    private var showsRecovery: Bool {
        health.disposition == .disconnectFailed
            || (isWatched && health.requiresSetupAttention)
    }
}
