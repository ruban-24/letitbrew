import AppKit
import LetItBrewAppCore
import SwiftUI

enum LetItBrewRuntimeLaunchMode {
    static let current: LetItBrewLaunchMode = {
#if DEBUG
        LetItBrewLaunchMode(
            arguments: CommandLine.arguments,
            allowsDesignPreview: true
        )
#else
        LetItBrewLaunchMode(
            arguments: CommandLine.arguments,
            allowsDesignPreview: false
        )
#endif
    }()
}

@main
enum LetItBrewApplication {
    @MainActor
    static func main() {
        if LetItBrewRuntimeLaunchMode.current.constructsOrdinaryScenes {
            LetItBrewMenuBarApp.main()
        } else {
            LetItBrewCommandApp.main()
        }
    }
}

private struct LetItBrewMenuBarApp: App {
    @NSApplicationDelegateAdaptor(LetItBrewBootstrap.self) private var bootstrap
    @StateObject private var model = LetItBrewAppModel()

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: {
                UninstallStatusItemPresentationPolicy.isInserted(
                    state: model.uninstallState,
                    reportIsPresented: model.uninstallReportIsPresented
                )
            },
            set: { _ in }
        )) {
            MenuBarContentView()
                .environmentObject(model)
        } label: {
            MenuBarStatusIcon(state: model.presentationState)
                .accessibilityLabel(model.menuBarAccessibilityLabel)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    model.applicationDidBecomeActive()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: Notification.Name.NSProcessInfoPowerStateDidChange
                )) { _ in
                    model.refreshNow()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            LetItBrewSettingsView()
                .environmentObject(model)
        }
    }
}

/// Command modes deliberately enter SwiftUI through a separate App type, so
/// the ordinary model and MenuBarExtra are never constructed.
private struct LetItBrewCommandApp: App {
    @NSApplicationDelegateAdaptor(LetItBrewBootstrap.self) private var bootstrap

    var body: some Scene {
        // Dormant until explicitly opened and creates no menu-bar item.
        Settings {
            EmptyView()
        }
    }
}
