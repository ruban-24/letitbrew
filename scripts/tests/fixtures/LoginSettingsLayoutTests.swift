import AppKit
import SwiftUI

@MainActor
private final class LoginSettingsState: ObservableObject {
    @Published var isOn = false
    @Published var isUpdating = false
    @Published var actionsBlocked = false
    @Published var errorMessage: String?
}

@MainActor
private enum LayoutProbe {
    static var view: NSView?
}

private struct FrameProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        LayoutProbe.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private struct SettingsFixture: View {
    @ObservedObject var state: LoginSettingsState

    var body: some View {
        Form {
            LaunchAtLoginSettingsSection(
                isOn: $state.isOn,
                isUpdating: state.isUpdating,
                actionsBlocked: state.actionsBlocked,
                errorMessage: state.errorMessage,
                openLoginItems: {}
            )
            Section("Closed lid") {
                Toggle("Keep agents working when the lid is closed", isOn: .constant(true))
                    .background(FrameProbe())
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 330)
    }
}

@main
private enum LoginSettingsLayoutTests {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    private static func run() async throws {
        var failures: [String] = []
        for scheme in [ColorScheme.light, .dark] {
            LayoutProbe.view = nil
            let state = LoginSettingsState()
            let host = NSHostingView(rootView: SettingsFixture(state: state).environment(\.colorScheme, scheme))
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 540, height: 330),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.title = "Let It Brew — isolated layout test"
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(200))
            guard let probe = LayoutProbe.view, probe.window === window else {
                throw Failure(description: "Following settings row did not render")
            }
            let baseline = probe.convert(probe.bounds, to: nil)
            let windowFrame = window.frame

            func check(_ stage: String) async throws {
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let frame = probe.convert(probe.bounds, to: nil)
                if abs(frame.minY - baseline.minY) > 0.5 || frame.size != baseline.size {
                    failures.append("\(scheme) \(stage): following row moved \(frame.minY - baseline.minY) points")
                }
                if window.frame != windowFrame {
                    failures.append("\(scheme) \(stage): window resized or moved")
                }
            }

            state.isUpdating = true
            try await check("enabling")
            state.isOn = true
            state.isUpdating = false
            try await check("enabled")
            state.isUpdating = true
            try await check("disabling")
            state.isOn = false
            state.isUpdating = false
            try await check("disabled")
            state.isUpdating = true
            try await check("request before failure")
            state.isUpdating = false
            state.errorMessage = "macOS could not update the login item. " + String(repeating: "Details. ", count: 80)
            try await check("failed with long error")
            state.errorMessage = nil
            state.isUpdating = true
            try await check("retrying")
            state.isOn = true
            state.isUpdating = false
            try await check("recovered")
            state.actionsBlocked = true
            try await check("blocked by another operation")

        }
        guard failures.isEmpty else {
            throw Failure(description: failures.joined(separator: "\n"))
        }
        print("PASS: login settings keep their layout through enable, disable, failure, retry, and blocking in light and dark mode")
    }
}
