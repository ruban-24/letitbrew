import Foundation
import Testing
@testable import LetItBrewAppCore

/// Stands in for the ntfy server: records each request and answers with the
/// next scripted outcome. No test ever reaches the network.
private actor StubServer {
    enum Outcome {
        case status(Int)
        case failure(URLError.Code)
    }

    private var outcomes: [Outcome]
    private(set) var requests: [URLRequest] = []

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func handle(_ request: URLRequest) throws -> Int {
        requests.append(request)
        let outcome = outcomes.isEmpty ? .status(200) : outcomes.removeFirst()
        switch outcome {
        case .status(let code): return code
        case .failure(let code): throw URLError(code)
        }
    }

    var transport: NtfyTransport {
        { request in try await self.handle(request) }
    }
}

private let configuration = NtfyConfiguration(
    server: URL(string: "https://ntfy.example.com")!,
    topic: "letitbrew-abcdefghjkmnpqrs",
    token: nil
)

private func publish(
    _ outcomes: [StubServer.Outcome],
    configuration: NtfyConfiguration = configuration
) async -> (sent: Bool, requests: [URLRequest]) {
    let server = StubServer(outcomes)
    let publisher = NtfyPublisher(
        configuration: configuration,
        transport: await server.transport,
        retryDelay: 0
    )
    let sent = await publisher.publish(
        title: "Claude Code needs you · letitbrew",
        body: "Waiting for your approval"
    )
    return (sent, await server.requests)
}

private func json(_ request: URLRequest) -> [String: String] {
    let object = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())
    return object as? [String: String] ?? [:]
}

@Test func publishIsOneJSONPostToTheServerRoot() async throws {
    let (sent, requests) = await publish([.status(200)])
    #expect(sent)
    let request = try #require(requests.only)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://ntfy.example.com/")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(json(request) == [
        "topic": "letitbrew-abcdefghjkmnpqrs",
        "title": "Claude Code needs you · letitbrew",
        "message": "Waiting for your approval",
    ])
}

@Test func anAccessTokenIsSentAsABearerTokenAndOnlyWhenSet() async throws {
    let plain = try #require(await publish([.status(200)]).requests.only)
    #expect(plain.value(forHTTPHeaderField: "Authorization") == nil)

    var withToken = configuration
    withToken.token = "tk_secret"
    let authorized = try #require(
        await publish([.status(200)], configuration: withToken).requests.only
    )
    #expect(authorized.value(forHTTPHeaderField: "Authorization") == "Bearer tk_secret")
}

@Test func aFailedSendRetriesOnceThenDrops() async {
    let timedOut = await publish([.failure(.timedOut), .failure(.timedOut), .status(200)])
    #expect(!timedOut.sent)
    #expect(timedOut.requests.count == 2)

    let rejected = await publish([.status(500), .status(403)])
    #expect(!rejected.sent)
    #expect(rejected.requests.count == 2)
}

@Test func aRetryThatSucceedsCountsAsSent() async {
    let result = await publish([.failure(.networkConnectionLost), .status(200)])
    #expect(result.sent)
    #expect(result.requests.count == 2)
}

@Test func aSuccessfulSendIsNeverRepeated() async {
    let result = await publish([.status(201)])
    #expect(result.sent)
    #expect(result.requests.count == 1)
}

@Test func generatedTopicsArePrivateAndRandom() {
    let topic = NtfyTopic.generate()
    #expect(topic.hasPrefix("letitbrew-"))
    let suffix = topic.dropFirst("letitbrew-".count)
    #expect(suffix.count >= 12)
    #expect(suffix.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
    #expect(NtfyTopic.generate() != topic)
}

@Test func serverMustBeHTTPSSoTheTokenNeverTravelsInTheClear() {
    #expect(NtfyServer.parse("https://ntfy.sh")?.absoluteString == "https://ntfy.sh")
    #expect(NtfyServer.parse("  https://push.example.com/ ")?.absoluteString == "https://push.example.com")
    #expect(NtfyServer.parse("https://example.com/ntfy/")?.absoluteString == "https://example.com/ntfy")
    #expect(NtfyServer.parse("http://push.example.com") == nil)
    #expect(NtfyServer.parse("push.example.com") == nil)
    #expect(NtfyServer.parse("https://") == nil)
    #expect(NtfyServer.parse("") == nil)
}

@Test func publishingToAServerUnderAPathPostsToThatRoot() async throws {
    var custom = configuration
    custom.server = try #require(NtfyServer.parse("https://example.com/ntfy"))
    let request = try #require(await publish([.status(200)], configuration: custom).requests.only)
    #expect(request.url?.absoluteString == "https://example.com/ntfy/")
}

@Test func theTopicAddressShownAndScannedUsesTheRealServer() {
    #expect(configuration.topicURL.absoluteString == "https://ntfy.example.com/letitbrew-abcdefghjkmnpqrs")
    #expect(configuration.displayAddress == "ntfy.example.com/letitbrew-abcdefghjkmnpqrs")
    #expect(NtfyServer.displayHost(URL(string: "https://ntfy.sh")!) == "ntfy.sh")
    #expect(NtfyServer.displayHost(URL(string: "https://example.com:8443/ntfy")!) == "example.com:8443/ntfy")
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
