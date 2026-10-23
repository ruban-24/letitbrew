import AppKit
import Darwin
import Foundation
import os
import LetItBrewAppCore
import LetItBrewCore
import LetItBrewDaemonCore
import SwiftUI

/// AppKit delegate for lifecycle and explicit daemon diagnostic commands.
/// The ordinary application entry point lives in `LetItBrewMenuBarApp`.
final class LetItBrewBootstrap: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.ruban24.letitbrew", category: "bootstrap")
    private var daemonConnection: DaemonConnection?
#if DEBUG
    private var designPreviewWindow: NSWindow?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        if ProcessInfo.processInfo.environment["LETITBREW_DESIGN_PREVIEW_APPEARANCE"] == "dark" {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
#endif
        switch LetItBrewRuntimeLaunchMode.current {
        case .registerDaemon:
            finishRegistration(register: true)
        case .unregisterDaemon:
            finishRegistration(register: false)
        case .probeDaemon:
            beginDaemonProbe(hold: false)
        case .prepareUpdate:
            beginUpdatePreparation()
        case .prepareDaemonUpgrade:
            beginDaemonUpgradePreparation()
        case .holdDaemon:
            beginDaemonProbe(hold: true)
        case .probeLidDisplay:
            finishLidDisplayProbe()
        case .designPreview:
#if DEBUG
            Task { @MainActor [weak self] in
                self?.showDesignPreview()
            }
#else
            Self.fail(DaemonConnectionFailure.unavailable(
                "Design preview is available only in Debug builds."
            ))
#endif
        case .designPreviewSettings:
#if DEBUG
            // LetItBrewSettingsPreviewApp opens its own Settings window.
            break
#else
            Self.fail(DaemonConnectionFailure.unavailable(
                "Design preview is available only in Debug builds."
            ))
#endif
        case .ordinary:
            let installed = BackgroundServiceEligibility.mayManageBackgroundServices(
                bundleURL: Bundle.main.bundleURL,
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
            Self.logger.notice("Menu-bar app ready; BTM-eligible location: \(installed)")
        }
    }

#if DEBUG
    @MainActor
    private func showDesignPreview() {
        let model = LetItBrewAppModel.designPreview()
        let content = MenuBarContentView()
            .environmentObject(model)
            .frame(width: 380, height: 570, alignment: .top)
        showDesignPreviewWindow(
            rootView: content,
            size: NSSize(width: 380, height: 570),
            title: "Let It Brew Design Preview"
        )
    }

    @MainActor
    private func showDesignPreviewWindow<Content: View>(
        rootView: Content,
        size: NSSize,
        title: String
    ) {
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = hostingView
        window.center()
        designPreviewWindow = window
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
#endif

    private func finishRegistration(register: Bool) {
        if register {
            do {
                try DaemonRegistration.register()
                print("Let It Brew development daemon submitted for approval.")
                fflush(stdout)
                exit(EXIT_SUCCESS)
            } catch {
                Self.failRegistration(error)
            }
            return
        }

        Task {
            do {
                try await DaemonRegistration.unregisterAndWait()
                print("Let It Brew development daemon unregistered and stopped.")
                fflush(stdout)
                exit(EXIT_SUCCESS)
            } catch {
                Self.failRegistration(error)
            }
        }
    }

    private static func failRegistration(_ registrationError: Error) -> Never {
        let error = registrationError as NSError
        var lines = [
            "\(error.domain) (\(error.code)): \(error.localizedDescription)"
        ]
        if let reason = error.localizedFailureReason {
            lines.append("Reason: \(reason)")
        }
        if let suggestion = error.localizedRecoverySuggestion {
            lines.append("Suggestion: \(suggestion)")
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        exit(EXIT_FAILURE)
    }

    private func beginDaemonProbe(hold: Bool) {
        do {
            let connection = try DaemonConnection()
            daemonConnection = connection
            connection.connect { result in
                switch result {
                case .failure(let error):
                    Self.fail(error)
                case .success(let buildIdentity):
                    guard hold else {
                        Self.printDaemonProbe(buildIdentity)
                        fflush(stdout)
                        connection.invalidate()
                        exit(EXIT_SUCCESS)
                    }
                    connection.setLidClosedHold(true) { holdResult in
                        switch holdResult {
                        case .failure(let error):
                            Self.fail(error)
                        case .success:
                            print("Let It Brew daemon hold active for client pid \(getpid()).")
                            fflush(stdout)
                        }
                    }
                }
            }
        } catch {
            Self.fail(error)
        }
    }

    private func beginDaemonUpgradePreparation() {
        do {
            let connection = try DaemonConnection()
            daemonConnection = connection
            connection.connect { result in
                switch result {
                case .failure(let error):
                    Self.fail(error)
                case .success(let buildIdentity):
                    connection.prepareForUpgrade { preparation in
                        switch preparation {
                        case .failure(let error):
                            Self.fail(error)
                        case .success(let baseline):
                            let value = baseline ? 1 : 0
                            if CommandLine.arguments.contains("--json") {
                                Self.printJSON([
                                    "build": buildIdentity.buildVersion,
                                    "buildIdentity": buildIdentity.codeDirectoryHash,
                                    "marketingVersion": buildIdentity.marketingVersion,
                                    "protocolVersion": LetItBrewDaemonProtocolVersion.current,
                                    "reconciliationReady": true,
                                    "sleepDisabledBaseline": value,
                                ])
                            } else {
                                print(
                                    "Let It Brew daemon prepared for upgrade; SleepDisabled baseline \(value)."
                                )
                            }
                            fflush(stdout)
                            connection.invalidate()
                            exit(EXIT_SUCCESS)
                        }
                    }
                }
            }
        } catch {
            Self.fail(error)
        }
    }

    /// Classifies actual service presence and, when present, reconciles its
    /// exact power baseline before the detached updater is allowed to move a
    /// bundle. Preference state is intentionally irrelevant: a toggle-off
    /// daemon is still registered and must take the registered path.
    private func beginUpdatePreparation() {
        Task {
            switch await LiveDaemonUninstallPreparer.reconcile() {
            case .reconciled(let baseline, let buildIdentity):
                Self.printJSON([
                    "build": buildIdentity.buildVersion,
                    "buildIdentity": buildIdentity.codeDirectoryHash,
                    "daemonState": "registered",
                    "marketingVersion": buildIdentity.marketingVersion,
                    "protocolVersion": LetItBrewDaemonProtocolVersion.current,
                    "reconciliationReady": true,
                    "sleepDisabledBaseline": baseline ? 1 : 0,
                ])
                fflush(stdout)
                exit(EXIT_SUCCESS)
            case .absent:
                Self.printJSON([
                    "daemonState": "absent",
                    "reconciliationReady": true,
                ])
                fflush(stdout)
                exit(EXIT_SUCCESS)
            case .failed(let failure):
                Self.fail(failure)
            }
        }
    }

    private static func printDaemonProbe(
        _ buildIdentity: LetItBrewDaemonBuildIdentity
    ) {
        if CommandLine.arguments.contains("--json") {
            printJSON([
                "build": buildIdentity.buildVersion,
                "buildIdentity": buildIdentity.codeDirectoryHash,
                "marketingVersion": buildIdentity.marketingVersion,
                "protocolVersion": LetItBrewDaemonProtocolVersion.current,
                "reconciliationReady": true,
            ])
        } else {
            print(
                "Let It Brew daemon protocol v\(LetItBrewDaemonProtocolVersion.current) build \(buildIdentity.versionDescription) cdhash \(buildIdentity.codeDirectoryHash) ready."
            )
        }
    }

    private static func printJSON(_ value: [String: Any]) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys]
            )
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fail(error)
        }
    }

    private func finishLidDisplayProbe() -> Never {
        let clamshell = IOKitClamshellMonitor().currentClamshellState()
        let displays = CoreGraphicsActiveDisplayMonitor().currentDisplayTopology()
        print("Clamshell: \(clamshell.rawValue)")
        print("Active displays: \(displays.rawValue)")
        fflush(stdout)
        exit(EXIT_SUCCESS)
    }

    private static func fail(_ error: Error) -> Never {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

#if DEBUG
extension LetItBrewAppModel {
    /// Sample sessions for the design previews: a folder with two agents,
    /// sessions on their own, one running only background shells, and one
    /// waiting for approval, on battery.
    @MainActor
    static func designPreview() -> LetItBrewAppModel {
        let now = Date()
        return LetItBrewAppModel.preview(sessions: [
            SessionRecord(
                id: "newest-codex", tool: "codex", state: .working,
                detail: "running-command", cwd: "/Projects/letitbrew", pid: nil,
                updatedAt: now, lastEvent: "PreToolUse",
                startedAt: now.addingTimeInterval(-3_800), accumulatedWorkingTime: 3_800
            ),
            SessionRecord(
                id: "newest-claude", tool: "claude", state: .working,
                detail: "editing-file", cwd: "/Projects/letitbrew", pid: nil,
                updatedAt: now.addingTimeInterval(-5), lastEvent: "PreToolUse",
                startedAt: now.addingTimeInterval(-2_400), accumulatedWorkingTime: 2_395
            ),
            SessionRecord(
                id: "waiting-claude", tool: "claude", state: .waiting,
                detail: SessionWaitDetail.approval, cwd: "/Projects/website", pid: nil,
                updatedAt: now.addingTimeInterval(-40), lastEvent: "PermissionRequest",
                startedAt: now.addingTimeInterval(-900), accumulatedWorkingTime: 860
            ),
            SessionRecord(
                id: "older-codex", tool: "codex", state: .working,
                detail: "running-command", cwd: "/Archive/api", pid: nil,
                updatedAt: now.addingTimeInterval(-30), lastEvent: "PreToolUse",
                startedAt: now.addingTimeInterval(-1_800), accumulatedWorkingTime: 1_770
            ),
            SessionRecord(
                id: "background-claude", tool: "claude", state: .working,
                detail: SessionWorkDetail.backgroundShell, cwd: "/Projects/docs", pid: nil,
                updatedAt: now.addingTimeInterval(-120), lastEvent: "Stop",
                startedAt: now.addingTimeInterval(-700), accumulatedWorkingTime: 580
            ),
        ], power: PowerState(onBattery: true, batteryPercent: 64, thermal: .nominal), now: now)
    }
}
#endif
