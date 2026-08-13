import AppKit
import LetItBrewAppCore
import SwiftUI

struct LetItBrewSettingsView: View {
    @EnvironmentObject private var model: LetItBrewAppModel
    @State private var selectedPane: SettingsPane = .general
    @FocusState private var focusedPane: SettingsPane?

    var body: some View {
        VStack(spacing: 0) {
            settingsNavigation
            Divider()
            selectedSettings
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 540, height: 430)
        .padding(12)
        .sheet(isPresented: updateCompletionReportBinding) { updateCompletionReport }
        .sheet(isPresented: uninstallReportBinding) { uninstallReport }
    }

    private var settingsNavigation: some View {
        HStack(spacing: 6) {
            ForEach(SettingsPane.allCases) { pane in
                settingsButton(for: pane)
            }
        }
        .focusSection()
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func settingsButton(for pane: SettingsPane) -> some View {
        let isSelected = selectedPane == pane
        let isFocused = focusedPane == pane

        return Button {
            selectedPane = pane
        } label: {
            VStack(spacing: 4) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                Text(pane.title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
            }
            .frame(width: 74, height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .focused($focusedPane, equals: pane)
        .accessibilityLabel(pane.title)
        .accessibilityHint("Show \(pane.title) settings")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings-pane-\(pane.id)")
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selectedPane {
        case .general:
            general
        case .agents:
            agents
        case .safety:
            safety
        case .about:
            about
        }
    }

    private var general: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Let It Brew at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .disabled(model.loginItemUpdateInProgress || model.updateBlocksOtherActions)

                if model.loginItemUpdateInProgress {
                    ProgressView("Updating…")
                        .controlSize(.small)
                }
                if let message = model.loginItemMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Open Login Items…") { model.openLoginItemSettings() }
                }
            }

            Section("Closed lid") {
                Toggle("Keep agents working when the lid is closed", isOn: Binding(
                    get: { model.keepWorkingWithLidClosed },
                    set: { model.setKeepWorkingWithLidClosed($0) }
                ))

                Text(closedLidDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.keepWorkingWithLidClosed {
                    daemonRecoveryControls
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var daemonRecoveryControls: some View {
        let presentation = model.daemonRecoveryPresentation

        if presentation.showsProgress {
            ProgressView(presentation.headline)
                .controlSize(.small)
        } else if !model.daemonAvailable {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(presentation.actions.contains(.setUp)
                         ? "Setup required"
                         : presentation.headline)
                        .font(.callout.weight(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }

                if let detail = presentation.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    ForEach(Array(presentation.actions.enumerated()), id: \.offset) { _, action in
                        switch action {
                        case .setUp:
                            Button("Set Up Closed-Lid Support") { model.setUpDaemon() }
                                .buttonStyle(.borderedProminent)
                        case .retry:
                            Button("Retry") { model.retryDaemonConnection() }
                        case .openBackgroundItems:
                            Button("Open Background Items…") {
                                model.openLoginItemSettings()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private var agents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Let It Brew connects to local Claude Code and Codex sessions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(model.agentHooks) { health in
                    AgentConnectionRow(
                        health: health,
                        isWorking: model.hookActionInProgress || model.updateBlocksOtherActions,
                        checkAgain: { model.retryAgentConnection(health.id) },
                        connect: { model.connectAgent(health.id) },
                        disconnect: { model.disconnectAgent(health.id) }
                    )
                }

                if let message = displayedHookMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
            }
            .padding(22)
        }
        .onAppear {
            model.refreshCodexTrustIfNeeded()
        }
    }

    private var safety: some View {
        Form {
            Section("Battery") {
                LabeledContent("Release sleep hold at") {
                    Text("\(Int(model.batteryFloor))%")
                        .monospacedDigit()
                }
                Slider(value: $model.batteryFloor, in: 5...50, step: 1)
                    .accessibilityLabel("Release sleep hold at")
                    .accessibilityValue("\(Int(model.batteryFloor)) percent")
                Text("When your Mac is on battery, Let It Brew stops keeping it awake at this level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Built-in protections") {
                SafetyProtectionRow(
                    title: "Thermal protection",
                    detail: "Releases the hold immediately if your Mac becomes too warm.",
                    status: "Always on",
                    systemImage: "thermometer.high",
                    accent: .orange
                )

                SafetyProtectionRow(
                    title: "Closed-lid display sleep",
                    detail: "Requests display sleep again if the last external display disconnects.",
                    status: "Automatic",
                    systemImage: "display",
                    accent: .blue
                )

                if model.lidCloseDisplaySleepInProgress {
                    ProgressView("Turning off displays…")
                        .controlSize(.small)
                }
                if let message = model.lidCloseDisplaySleepMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("Let It Brew")
                .font(.title2.weight(.semibold))
            Text(versionDescription)
                .foregroundStyle(.secondary)
            Text("Keeps your Mac awake while local coding agents work, then lets it sleep when they stop.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .foregroundStyle(.secondary)
            updateControl
                .padding(.top, 6)
            Spacer(minLength: 28)
            Divider()
                .frame(maxWidth: 360)
            uninstallControl
                .padding(.top, 4)
        }
        .padding(28)
        .confirmationDialog(
            updateConfirmationTitle,
            isPresented: updateConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Install Update") { model.confirmUpdate() }
            Button("Cancel", role: .cancel) { model.cancelUpdate() }
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
            Text("This disconnects Claude Code and Codex, stops Let It Brew's background service, removes its settings and session records, and moves Let It Brew to the Trash.")
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        switch model.updateState {
        case .idle:
            Button("Check for Updates…") { model.checkForUpdates() }
                .disabled(model.updateBlocksOtherActions || model.uninstallInProgress)
        case .checking:
            ProgressView("Checking for updates…")
                .controlSize(.small)
        case .upToDate:
            VStack(spacing: 8) {
                Text("Let It Brew is up to date.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Check Again") { model.checkForUpdates() }
                    Button("Dismiss") { model.dismissUpdateStatus() }
                }
            }
        case .available(let release):
            Text("Version \(release.version.description) is available.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .installing:
            ProgressView("Downloading and verifying update…")
                .controlSize(.small)
        case .readyToQuit:
            ProgressView("Update ready. Restarting Let It Brew…")
                .controlSize(.small)
        case .failed(let failure, _):
            VStack(spacing: 8) {
                Text(failure.message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Try Again") { model.retryUpdate() }
                        .disabled(model.updateInProgress)
                    Button("Copy Diagnostic") {
                        copyToPasteboard(model.updateDiagnostic(for: failure))
                    }
                    Button("Dismiss") { model.dismissUpdateStatus() }
                }
            }
        }
    }

    private var uninstallControl: some View {
        VStack(spacing: 8) {
            Button("Uninstall Let It Brew…") { model.beginUninstall() }
                .disabled(model.uninstallInProgress || model.updateBlocksOtherActions)
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            if case .blocked(let failure, let offersDiagnostic) = model.uninstallState {
                Text(failure.message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Try Again") { model.retryUninstall() }
                        .disabled(model.uninstallInProgress || model.updateBlocksOtherActions)
                    if offersDiagnostic {
                        Button("Copy Diagnostic") {
                            copyToPasteboard(model.uninstallDiagnostic(for: [failure]))
                        }
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
                let bundleWasRemoved = !leftovers.contains { $0.step == .trashBundle }
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
                ForEach(leftovers, id: \.step) { leftover in
                    Text("• \(leftover.message)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Copy Diagnostic") {
                        copyToPasteboard(model.uninstallDiagnostic(for: leftovers))
                    }
                    if leftovers.contains(where: { $0.step == .disableLaunchAtLogin }) {
                        Button("Open Login Items…") {
                            model.openLoginItemSettings()
                        }
                    }
                    if leftovers.contains(where: { $0.step == .trashBundle }) {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                    }
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
                Text(report.outcome == .success ? "Let It Brew was updated" : "Let It Brew update needs attention")
                    .font(.headline)
                Text(report.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if report.outcome == .success {
                    Text(versionDescription)
                        .font(.callout.weight(.medium))
                }
                if let diagnostic = report.diagnostic {
                    Text(diagnostic)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                }
                HStack(spacing: 12) {
                    if let diagnostic = report.diagnostic {
                        Button("Copy Diagnostic") { copyToPasteboard(diagnostic) }
                    }
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
            get: { if case .available = model.updateState { true } else { false } },
            // SwiftUI also writes false after the Install button. The model
            // marks that operation in progress synchronously, so only a real
            // dismissal reaches cancelUpdate().
            set: { presented in
                if !presented && !model.updateInProgress {
                    model.cancelUpdate()
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

    private var closedLidDescription: String {
        guard model.keepWorkingWithLidClosed else {
            return "Turn this on if agents should keep working after you close your MacBook."
        }
        return "Uses a local background helper. Let It Brew never sends your agent data off this Mac."
    }

    private var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
        guard let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String,
              !build.isEmpty else {
            return "Version \(version)"
        }
        return "Version \(version) (\(build))"
    }
}

private struct SafetyProtectionRow: View {
    let title: String
    let detail: String
    let status: String
    let systemImage: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Label(status, systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case agents = "Agents"
    case safety = "Safety"
    case about = "About"

    var id: String { rawValue.lowercased() }
    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .agents: "terminal"
        case .safety: "shield"
        case .about: "info.circle"
        }
    }
}

private struct AgentConnectionRow: View {
    let health: AgentHookHealth
    let isWorking: Bool
    let checkAgain: () -> Void
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentLogo(toolID: health.id)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(health.name)
                    .font(.headline)
                Label(displayedState, systemImage: displayedSymbol)
                    .font(.caption)
                    .foregroundStyle(stateColor)
                ForEach(health.details, id: \.self) { detail in
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if isDisconnected || disconnectFailed {
                    Text("Current sessions are hidden and no longer keep this Mac awake.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 10)

            if health.state == .connecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting \(health.name)")
            } else if isDisconnected {
                Button("Connect", action: connect)
                    .disabled(isWorking)
            } else if disconnectFailed {
                Button("Retry Disconnect", action: disconnect)
                    .disabled(isWorking)

                Menu {
                    Button("Connect Instead", action: connect)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("More options for \(health.name)")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isWorking)
            } else {
                if health.state == .actionNeeded || health.state == .couldNotConnect {
                    Button("Check Again", action: checkAgain)
                        .disabled(isWorking)
                }

                Menu {
                    Button("Disconnect", role: .destructive, action: disconnect)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("More options for \(health.name)")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isWorking)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var isDisconnected: Bool {
        health.disposition == .intentionallyDisconnected
    }

    private var disconnectFailed: Bool {
        health.disposition == .disconnectFailed
    }

    private var displayedState: String {
        switch health.disposition {
        case .intentionallyDisconnected: "Disconnected"
        case .disconnectFailed: "Disconnect incomplete"
        case .managed: health.state.rawValue
        }
    }

    private var displayedSymbol: String {
        switch health.disposition {
        case .intentionallyDisconnected: "minus.circle"
        case .disconnectFailed: "exclamationmark.triangle.fill"
        case .managed: health.symbol
        }
    }

    private var stateColor: Color {
        if health.disposition == .disconnectFailed { return .red }
        if health.disposition == .intentionallyDisconnected { return .secondary }
        return switch health.state {
        case .connecting: .secondary
        case .connected: .green
        case .actionNeeded: .orange
        case .couldNotConnect: .red
        }
    }
}
