import Foundation

/// Where phone alerts go: a topic on an ntfy server. The topic is the only
/// secret on a public server, so it is long and random.
public struct NtfyConfiguration: Equatable, Sendable {
    public var server: URL
    public var topic: String
    /// Only for the person's own server. Kept in the Keychain.
    public var token: String?

    public init(server: URL, topic: String, token: String?) {
        self.server = server
        self.topic = topic
        self.token = token
    }

    /// The topic's web address. The QR code encodes it: the ntfy apps have
    /// no subscribe link shared by iOS and Android.
    public var topicURL: URL {
        server.appendingPathComponent(topic)
    }

    /// "ntfy.sh/letitbrew-…", for Settings.
    public var displayAddress: String {
        "\(NtfyServer.displayHost(server))/\(topic)"
    }
}

public enum NtfyTopic {
    public static let prefix = "letitbrew-"
    static let suffixLength = 16

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = (0..<suffixLength).map { _ in
            alphabet.randomElement(using: &generator)!
        }
        return prefix + String(suffix)
    }
}

public enum NtfyServer {
    public static let `default` = URL(string: "https://ntfy.sh")!

    /// HTTPS only, so an access token never travels in the clear. Trailing
    /// slashes are dropped; a path is kept for servers behind a prefix.
    public static func parse(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil
        else { return nil }
        return components.url
    }

    /// "ntfy.sh", or host, port and path for a custom server.
    public static func displayHost(_ server: URL) -> String {
        var text = server.host ?? server.absoluteString
        if let port = server.port { text += ":\(port)" }
        let path = server.path
        if !path.isEmpty, path != "/" { text += path }
        return text
    }
}

/// The server phone alerts go to and its optional access token. A token
/// belongs to one server, so a different server drops it.
public struct NtfyServerAccess: Equatable, Sendable {
    public private(set) var server: URL
    public private(set) var token: String?

    public init(server: URL, token: String?) {
        self.server = server
        self.token = token
    }

    /// False, changing nothing, unless `text` is an https URL.
    public mutating func setServer(_ text: String) -> Bool {
        guard let url = NtfyServer.parse(text) else { return false }
        guard url != server else { return true }
        server = url
        token = nil
        return true
    }
}

/// Sends one request and returns its HTTP status code.
public typealias NtfyTransport = @Sendable (URLRequest) async throws -> Int

/// Publishes one alert as a single JSON POST to the server root. A failure
/// is retried once and then dropped: it is never surfaced in the menu and
/// never affects the hold.
public struct NtfyPublisher: Sendable {
    public static let testTitle = "Let It Brew test"
    public static let testBody = "Phone alerts are working."

    let configuration: NtfyConfiguration
    let transport: NtfyTransport
    let retryDelay: TimeInterval

    public init(
        configuration: NtfyConfiguration,
        transport: @escaping NtfyTransport,
        retryDelay: TimeInterval = 2
    ) {
        self.configuration = configuration
        self.transport = transport
        self.retryDelay = retryDelay
    }

    /// True once the server accepted the message (any 2xx).
    @discardableResult
    public func publish(title: String, body: String) async -> Bool {
        let request = request(title: title, body: body)
        if await attempt(request) { return true }
        if retryDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        }
        return await attempt(request)
    }

    private func attempt(_ request: URLRequest) async -> Bool {
        guard let status = try? await transport(request) else { return false }
        return (200..<300).contains(status)
    }

    private func request(title: String, body: String) -> URLRequest {
        // JSON, not ntfy's Title header: titles carry "·", which a raw
        // header cannot.
        var request = URLRequest(url: configuration.server.appendingPathComponent(""))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = configuration.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "topic": configuration.topic,
            "title": title,
            "message": body,
        ])
        return request
    }
}
