import Foundation
import LetItBrewAppCore
import SwiftUI

/// Settings → General → Command-line tool: links `/usr/local/bin/letitbrew`
/// to the bundled CLI behind the standard administrator prompt. Agent hooks
/// never use this link; they keep the absolute path inside the bundle.
struct CommandLineToolSettingsSection: View {
    var actionsBlocked: Bool
    @State private var state = CommandLineTool.state(at: locations)
    @State private var isWorking = false
    @State private var failureMessage: String?

    private static let locations = CommandLineToolLocations(
        bundledCLI: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/letitbrew").path
    )

    var body: some View {
        let presentation = CommandLineToolPresentation(state: state)
        Section {
            LabeledContent {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else if let action = presentation.action {
                    Button(action.title) { perform(action) }
                        .disabled(actionsBlocked)
                }
            } label: {
                Text("\(Text("letitbrew").monospaced()) command")
                detail(presentation)
            }
            .onAppear(perform: refresh)
        } header: {
            Text("Command-line tool")
        } footer: {
            if let footer = presentation.footer {
                Text(LocalizedStringKey(footer))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .alert(
            "Couldn’t change the command-line tool",
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button("OK") { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    private func detail(_ presentation: CommandLineToolPresentation) -> Text {
        guard presentation.showsInstalledDot else { return Text(presentation.detail) }
        return Text("\(Text("●").foregroundStyle(.green)) \(presentation.detail)")
            .accessibilityLabel(presentation.detail)
    }

    private func refresh() {
        state = CommandLineTool.state(at: Self.locations)
    }

    private func perform(_ action: CommandLineToolPresentation.Action) {
        let command = switch action {
        case .install: CommandLineTool.installCommand(at: Self.locations)
        case .remove: CommandLineTool.removeCommand(at: Self.locations)
        }
        guard let command else {
            refresh()
            return
        }
        isWorking = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.runWithAdministratorPrompt(command)
            }.value
            isWorking = false
            refresh()
            if case .failed(let message) = outcome {
                failureMessage = message
            }
        }
    }

    private nonisolated static func runWithAdministratorPrompt(
        _ command: String
    ) -> CommandLineToolAuthorization {
        let result = BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", CommandLineTool.administratorAppleScript(running: command)],
            timeout: 600
        )
        if let launchError = result.launchError { return .failed(launchError) }
        if result.timedOut { return .failed("The password prompt timed out.") }
        return CommandLineToolAuthorization.outcome(
            status: result.status,
            output: String(decoding: result.output, as: UTF8.self)
        )
    }
}
