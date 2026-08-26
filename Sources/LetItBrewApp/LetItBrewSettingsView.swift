import AppKit
import LetItBrewAppCore
import SwiftUI

struct LetItBrewSettingsView: View {
    @EnvironmentObject private var model: LetItBrewAppModel
    @State private var selectedPane: SettingsPane = .general
    @State private var presentedRecovery: RecoveryGuidance?
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
        case .powerAndDisplay:
            powerAndDisplay
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
            }
        }
        .formStyle(.grouped)
    }

    private var agents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Watched Agents")
                    .font(.headline)

                VStack(spacing: 0) {
                    ForEach(Array(model.agentHooks.enumerated()), id: \.element.id) { index, health in
                        WatchedAgentRow(
                            health: health,
                            isWatched: model.isAgentWatched(health.id),
                            isWorking: model.hookActionInProgress || model.updateBlocksOtherActions,
                            setWatched: { model.setAgent(health.id, watched: $0) },
                            retry: {
                                if health.disposition == .disconnectFailed {
                                    model.setAgent(health.id, watched: false)
                                } else {
                                    model.retryAgentConnection(health.id)
                                }
                            }
                        )

                        if index < model.agentHooks.count - 1 {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(22)
        }
        .onAppear {
            model.refreshCodexTrustIfNeeded()
        }
    }

    private var powerAndDisplay: some View {
        let helper = BackgroundHelperPresentationPolicy.resolve(
            closedLidEnabled: model.keepWorkingWithLidClosed,
            recoveryState: model.daemonRecoveryState
        )

        return Form {
            Section("Background helper") {
                HStack(alignment: .center, spacing: 10) {
                    Label(helper.status, systemImage: !model.keepWorkingWithLidClosed
                          ? "minus.circle"
                          : helper.requiresAttention
                            ? "exclamationmark.triangle.fill"
                            : helper.showsProgress
                              ? "clock"
                              : "checkmark.circle.fill")
                        .foregroundStyle(helper.requiresAttention ? .orange : .secondary)

                    Spacer()

                    if helper.showsProgress {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(helper.status)
                    }
                }

                Text("Required for closed-lid operation. The helper runs locally and releases its hold if communication with Let It Brew stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if helper.requiresAttention {
                    Text(helper.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

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

            Section("Battery") {
                LabeledContent("Stop keeping Mac awake below") {
                    Text("\(Int(model.batteryFloor))%")
                        .monospacedDigit()
                }
                Slider(value: $model.batteryFloor, in: 5...50, step: 5)
                    .disabled(model.onlyWhileConnectedToPower)
                    .accessibilityLabel("Stop keeping Mac awake below")
                    .accessibilityValue("\(Int(model.batteryFloor)) percent")
                    .accessibilityHint(model.onlyWhileConnectedToPower
                        ? "Unavailable because Let It Brew is limited to connected power"
                        : "Sets the battery level where Let It Brew releases its sleep hold")

                Toggle(
                    "Only keep Mac awake while connected to power",
                    isOn: $model.onlyWhileConnectedToPower
                )
                Toggle("Respect Low Power Mode", isOn: $model.respectLowPowerMode)
            }

            Section("Display") {
                Toggle(
                    "Allow displays to sleep while agents are working",
                    isOn: $model.allowDisplaysToSleep
                )
            }

            Section("Built-in protections") {
                ProtectionRow(
                    title: "Thermal protection",
                    detail: "Releases sleep holds under serious or critical thermal pressure.",
                    status: "Always on",
                    systemImage: "thermometer.high",
                    accent: Color(.brewPurple)
                )

                ProtectionRow(
                    title: "Helper fail-safe",
                    detail: "Releases the closed-lid hold if the app and helper stop communicating.",
                    status: "Always on",
                    systemImage: "bolt.slash",
                    accent: Color(.brewPurple)
                )

                ProtectionRow(
                    title: "Display handling",
                    detail: model.allowDisplaysToSleep
                        ? "Displays may sleep while the system sleep hold remains active."
                        : "Display idle sleep is held only while an agent keeps the Mac awake.",
                    status: model.allowDisplaysToSleep ? "Can sleep" : "Held while working",
                    systemImage: "display",
                    accent: Color(.brewPurple)
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
        .onAppear { model.refreshBackgroundHelper() }
    }

    private var about: some View {
        ScrollView {
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
                Text("Keeps your Mac awake while local coding agents work, then lets it sleep when they finish.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                    .foregroundStyle(.secondary)
                updateControl
                    .padding(.top, 6)

                HStack(spacing: 8) {
                    Link("GitHub", destination: ProductLinks.repository)
                    Text("·")
                    Link("Release Notes", destination: ProductLinks.releases)
                    Text("·")
                    Link("Report an Issue", destination: ProductLinks.reportIssue)
                    Text("·")
                    Link("Privacy", destination: ProductLinks.privacy)
                }
                .font(.caption)

                Divider()
                    .frame(maxWidth: 360)
                    .padding(.top, 18)
                uninstallControl
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        }
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
            Text("This disconnects all connected agent integrations, stops Let It Brew's background service, removes its settings and session records, and moves Let It Brew to the Trash.")
        }
        .sheet(item: $presentedRecovery) { guidance in
            recoverySheet(guidance)
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
            let guidance = OperationRecoveryCatalog.update(
                kind: failure.kind,
                diagnostic: model.updateDiagnostic(for: failure)
            )
            VStack(spacing: 8) {
                Text(guidance.title)
                    .font(.callout.weight(.medium))
                Text(guidance.summary)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Try Again") { model.retryUpdate() }
                        .disabled(model.updateInProgress)
                    Button("Recovery Steps…") {
                        presentedRecovery = guidance
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
                let guidance = OperationRecoveryCatalog.uninstall(
                    step: failure.step,
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(leftovers, id: \.step) { leftover in
                            let guidance = OperationRecoveryCatalog.uninstall(
                                step: leftover.step,
                                diagnostic: model.uninstallDiagnostic(for: [leftover])
                            )
                            VStack(alignment: .leading, spacing: 5) {
                                Text(guidance.title)
                                    .font(.callout.weight(.semibold))
                                Text(leftover.message)
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
        .sheet(item: $presentedRecovery) { guidance in
            recoverySheet(guidance)
        }
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
            .sheet(item: $presentedRecovery) { guidance in
                recoverySheet(guidance)
            }
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

    private var closedLidDescription: String {
        "Uses a local background helper only when enabled. Let It Brew never sends your agent data off this Mac."
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

private struct ProtectionRow: View {
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
    case powerAndDisplay = "Power & Display"
    case about = "About"

    var id: String { rawValue.lowercased() }
    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .agents: "terminal"
        case .powerAndDisplay: "battery.100percent"
        case .about: "info.circle"
        }
    }
}

private struct WatchedAgentRow: View {
    let health: AgentHookHealth
    let isWatched: Bool
    let isWorking: Bool
    let setWatched: (Bool) -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { isWatched },
                set: { watched in setWatched(watched) }
            )) {
                HStack(spacing: 12) {
                    AgentLogo(toolID: health.id)
                        .frame(width: 28, height: 28)
                    Text(health.name)
                }
            }
            .toggleStyle(.switch)
            .disabled(isWorking)
            .accessibilityHint(isWatched
                ? "Stop watching \(health.name) sessions"
                : "Watch \(health.name) sessions")

            if isWatched && health.state == .connecting {
                ProgressView("Checking…")
                    .controlSize(.small)
                    .padding(.leading, 40)
                    .accessibilityLabel("Checking \(health.name)")
            } else if showsRecovery, let detail = health.details.first {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }

                    Spacer(minLength: 8)

                    Button("Retry", action: retry)
                        .disabled(isWorking)
                }
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
    }

    private var showsRecovery: Bool {
        health.disposition == .disconnectFailed
            || (isWatched && health.requiresSetupAttention)
    }
}
