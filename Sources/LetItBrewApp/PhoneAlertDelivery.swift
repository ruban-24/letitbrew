import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import LetItBrewAppCore
import Security

/// Phone alerts through ntfy: the setup Settings shows, and delivery of the
/// alerts `AlertPolicy` sends to the phone. Nothing is sent until the person
/// has set up ntfy; a send that fails is retried once and then dropped.
@MainActor
final class PhoneAlerts: ObservableObject, AlertDelivering {
    enum TestState: Equatable {
        case idle
        case sending
        case failed
    }

    /// Nil until Set Up generates one.
    @Published private(set) var topic: String?
    @Published private(set) var server: URL
    @Published private(set) var token: String?
    /// When the server last accepted a Send Test. The Mac cannot see the
    /// phone, so a 2xx response counts as received.
    @Published private(set) var testReceivedAt: Date?
    @Published private(set) var testState: TestState = .idle
    @Published var alwaysSendToPhone: Bool {
        didSet { defaults.set(alwaysSendToPhone, forKey: Keys.alwaysSendToPhone) }
    }

    private enum Keys {
        static let topic = "ntfyTopic"
        static let server = "ntfyServer"
        static let testReceivedAt = "ntfyTestReceivedAt"
        static let alwaysSendToPhone = "alwaysSendToPhone"
    }

    private let defaults: UserDefaults
    private let keychain: NtfyTokenKeychain

    init(defaults: UserDefaults, keychain: NtfyTokenKeychain = NtfyTokenKeychain()) {
        self.defaults = defaults
        self.keychain = keychain
        topic = defaults.string(forKey: Keys.topic)
        server = defaults.string(forKey: Keys.server).flatMap(NtfyServer.parse)
            ?? NtfyServer.default
        testReceivedAt = defaults.object(forKey: Keys.testReceivedAt) as? Date
        alwaysSendToPhone = defaults.bool(forKey: Keys.alwaysSendToPhone)
        // Read once while unlocked, so alerts sent with the screen locked
        // never need the Keychain.
        token = topic == nil ? nil : keychain.read()
    }

    /// Set up and a test has reached the server.
    var isWorking: Bool { topic != nil && testReceivedAt != nil }

    var configuration: NtfyConfiguration? {
        topic.map { NtfyConfiguration(server: server, topic: $0, token: token) }
    }

    /// Generates a private topic. Sends nothing.
    func setUp() {
        let topic = NtfyTopic.generate()
        self.topic = topic
        defaults.set(topic, forKey: Keys.topic)
        setTestReceived(nil)
    }

    /// Cancel and Turn Off both forget the topic, server and token.
    func turnOff() {
        topic = nil
        defaults.removeObject(forKey: Keys.topic)
        server = NtfyServer.default
        defaults.removeObject(forKey: Keys.server)
        token = nil
        keychain.delete()
        alwaysSendToPhone = false
        setTestReceived(nil)
    }

    /// False, changing nothing, unless `text` is an https URL. A new server
    /// needs a new test.
    @discardableResult
    func setServer(_ text: String) -> Bool {
        guard let url = NtfyServer.parse(text) else { return false }
        guard url != server else { return true }
        server = url
        defaults.set(url.absoluteString, forKey: Keys.server)
        setTestReceived(nil)
        return true
    }

    /// An empty token removes it. A new token needs a new test.
    func setToken(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newToken = trimmed.isEmpty ? nil : trimmed
        guard newToken != token else { return }
        token = newToken
        if let newToken { keychain.save(newToken) } else { keychain.delete() }
        setTestReceived(nil)
    }

    func sendTest() {
        guard let configuration, testState != .sending else { return }
        testState = .sending
        Task { [weak self] in
            let sent = await Self.publisher(configuration).publish(
                title: NtfyPublisher.testTitle,
                body: NtfyPublisher.testBody
            )
            guard let self else { return }
            // A test of a server or token since replaced proves nothing.
            let current = self.configuration == configuration
            self.testState = sent || !current ? .idle : .failed
            if sent, current { self.setTestReceived(Date()) }
        }
    }

    func deliver(_ alerts: [Alert]) {
        guard isWorking, let configuration else { return }
        let publisher = Self.publisher(configuration)
        for alert in alerts where alert.destinations.contains(.phone) {
            let title = alert.title
            let body = alert.body
            Task.detached { await publisher.publish(title: title, body: body) }
        }
    }

    private static func publisher(_ configuration: NtfyConfiguration) -> NtfyPublisher {
        NtfyPublisher(configuration: configuration, transport: urlSession)
    }

    /// A short timeout, no cookies, no cache.
    private static let urlSession: NtfyTransport = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func setTestReceived(_ date: Date?) {
        testReceivedAt = date
        defaults.set(date, forKey: Keys.testReceivedAt)
        if date == nil, testState == .failed { testState = .idle }
    }
}

/// The optional ntfy access token, in the login Keychain.
struct NtfyTokenKeychain {
    private let service = (Bundle.main.bundleIdentifier ?? "com.ruban24.letitbrew") + ".ntfy"
    private let account = "access-token"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = "Let It Brew ntfy access token"
        SecItemAdd(item as CFDictionary, nil)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

enum NtfyQRCode {
    /// A crisp QR code of `url`, or nil if CoreImage can't make one.
    static func image(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
