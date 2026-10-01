import SwiftUI

struct LaunchAtLoginSettingsSection: View {
    @Binding var isOn: Bool
    var isUpdating: Bool
    var actionsBlocked: Bool
    var errorMessage: String?
    var openLoginItems: () -> Void
    @State private var showingError = false

    var body: some View {
        Section("Startup") {
            HStack(spacing: 8) {
                Text("Launch Let It Brew at login")
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                status
                Toggle("Launch Let It Brew at login", isOn: $isOn)
                    .labelsHidden()
                    .disabled(isUpdating || actionsBlocked)
            }
        }
        .onChange(of: errorMessage) { _, _ in showingError = false }
    }

    private var status: some View {
        // Reserve space even when idle so neither progress nor errors move
        // the toggle or the settings sections below it.
        ZStack {
            if isUpdating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating launch at login")
            } else if let errorMessage {
                Button {
                    showingError = true
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help(errorMessage)
                .accessibilityLabel("Launch at login couldn't be updated")
                .accessibilityHint("Show error details and login item settings")
                .popover(isPresented: $showingError) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Couldn't update launch at login")
                            .font(.headline)
                        ScrollView {
                            Text(errorMessage)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                        Button("Open Login Items…") {
                            showingError = false
                            openLoginItems()
                        }
                    }
                    .padding()
                    .frame(width: 320)
                }
            }
        }
        .frame(width: 20, height: 20)
    }
}
