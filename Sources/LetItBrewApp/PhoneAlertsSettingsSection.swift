import LetItBrewAppCore
import SwiftUI

/// Settings → Alerts → "On your phone": ntfy setup with an inline QR code.
struct PhoneAlertsSettingsSection: View {
    @ObservedObject var phone: PhoneAlerts
    @State private var serverText = ""
    @State private var tokenText = ""
    @State private var advancedExpanded = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case server
        case token
    }

    var body: some View {
        Section {
            if let configuration = phone.configuration {
                if phone.isWorking {
                    working(configuration)
                } else {
                    settingUp(configuration)
                }
            } else {
                notSetUp
            }
        } header: {
            Text("On your phone")
        } footer: {
            if !phone.isWorking {
                Text("Phone alerts go out only when you're away from your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: loadFields)
        .onChange(of: phone.topic) { loadFields() }
        .onChange(of: focusedField) { previous, _ in
            if previous == .server { commitServer() }
            if previous == .token { commitToken() }
        }
    }

    // MARK: States

    private var notSetUp: some View {
        statusRow(
            Text("Get alerts on your phone through the free ntfy app."),
            button: Button("Set Up") { phone.setUp() }
        )
    }

    @ViewBuilder
    private func settingUp(_ configuration: NtfyConfiguration) -> some View {
        statusRow(
            testFailure(configuration) ?? Text("Waiting for a test to arrive…"),
            button: Button("Cancel") { phone.turnOff() }
        )

        HStack(alignment: .top, spacing: 14) {
            qrCode(configuration, size: 92)
            VStack(alignment: .leading, spacing: 3) {
                Text("1. Install ntfy on your phone")
                    .fontWeight(.medium)
                Text("Free on the App Store and Google Play.")
                    .foregroundStyle(.secondary)
                Text("2. Scan this code with it")
                    .fontWeight(.medium)
                    .padding(.top, 6)
                Text("It subscribes to your private topic \(Text(configuration.topic).monospaced()).")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                sendTestButton
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)

        Text("Advanced")
        advancedFields
    }

    @ViewBuilder
    private func working(_ configuration: NtfyConfiguration) -> some View {
        statusRow(
            testFailure(configuration) ?? workingStatus,
            button: Button("Turn Off") { phone.turnOff() }
        )

        HStack(alignment: .top, spacing: 14) {
            qrCode(configuration, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("Subscribe another phone by scanning this code in the ntfy app.")
                    .foregroundStyle(.secondary)
                Text(configuration.displayAddress)
                    .monospaced()
                    .textSelection(.enabled)
                sendTestButton
                    .padding(.top, 6)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)

        Toggle(isOn: $phone.alwaysSendToPhone) {
            Text("Always send to phone")
            Text("Otherwise only when the lid is closed, the screen is locked, or you've been away for 5 minutes.")
        }

        DisclosureGroup(isExpanded: $advancedExpanded) {
            advancedFields
        } label: {
            HStack {
                Text("Advanced")
                Spacer()
                Text(NtfyServer.displayHost(phone.server))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Parts

    private func statusRow(_ status: Text, button: Button<Text>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Phone alerts")
                status
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            button
        }
    }

    private var workingStatus: Text {
        let time = (phone.testReceivedAt ?? Date()).formatted(date: .omitted, time: .shortened)
        return Text(Image(systemName: "circle.fill")).font(.system(size: 7)).foregroundColor(.green)
            + Text(" Working · test received at \(time)")
    }

    /// Settings only; a failed alert send is never surfaced anywhere.
    private func testFailure(_ configuration: NtfyConfiguration) -> Text? {
        guard phone.testState == .failed else { return nil }
        return Text("The test didn't reach \(NtfyServer.displayHost(configuration.server)). Check your connection and try again.")
    }

    private var sendTestButton: some View {
        Button(phone.testState == .sending ? "Sending…" : "Send Test") {
            commitServer()
            commitToken()
            phone.sendTest()
        }
        .disabled(phone.testState == .sending)
    }

    private func qrCode(_ configuration: NtfyConfiguration, size: CGFloat) -> some View {
        Group {
            if let image = NtfyQRCode.image(for: configuration.topicURL) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .padding(5)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("QR code for your ntfy topic")
    }

    @ViewBuilder
    private var advancedFields: some View {
        LabeledContent("Server") {
            TextField("Server", text: $serverText, prompt: Text(NtfyServer.default.absoluteString))
                .labelsHidden()
                .focused($focusedField, equals: .server)
                .onSubmit(commitServer)
                .frame(maxWidth: 220)
        }
        .padding(.leading, 16)

        LabeledContent {
            SecureField("Access token", text: $tokenText, prompt: Text("Optional"))
                .labelsHidden()
                .focused($focusedField, equals: .token)
                .onSubmit(commitToken)
                .frame(maxWidth: 220)
        } label: {
            Text("Access token")
            Text("Only for your own server. Kept in your Keychain.")
        }
        .padding(.leading, 16)
    }

    // MARK: Fields

    private func loadFields() {
        serverText = phone.server.absoluteString
        tokenText = phone.token ?? ""
    }

    /// An address that isn't https goes back to the saved server.
    private func commitServer() {
        if !phone.setServer(serverText) {
            serverText = phone.server.absoluteString
        }
    }

    private func commitToken() {
        phone.setToken(tokenText)
    }
}
