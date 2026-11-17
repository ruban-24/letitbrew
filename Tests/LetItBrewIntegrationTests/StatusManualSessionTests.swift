import Darwin
import Foundation
import LetItBrewCore
import Testing

/// `letitbrew status` against the built binary, with Application Support
/// redirected to a temporary home so the live app never sees the session.
@Suite(.serialized)
struct StatusManualSessionTests {
    @Test func jsonReportsATimedSessionWithItsDeadlineAndTimeLeft() throws {
        let home = try TemporaryHome()
        let deadline = Date().addingTimeInterval(2 * 3_600)
        try home.storage.save(ManualSessionRecord(
            startedAt: Date(), deadline: deadline, bootSessionID: try #require(BootSession.currentID())
        ))

        let json = try home.statusJSON()
        let session = try #require(json["manual_session"] as? [String: Any])
        #expect(session["indefinite"] as? Bool == false)
        let deadlineText = try #require(session["deadline"] as? String)
        let parsed = try #require(ISO8601DateFormatter().date(from: deadlineText))
        #expect(abs(parsed.timeIntervalSince(deadline)) < 1)
        let remaining = try #require(session["seconds_remaining"] as? Int)
        #expect((2 * 3_600 - 60)...(2 * 3_600) ~= remaining)
    }

    @Test func jsonReportsAnIndefiniteSession() throws {
        let home = try TemporaryHome()
        try home.storage.save(ManualSessionRecord(
            startedAt: Date(), deadline: nil, bootSessionID: try #require(BootSession.currentID())
        ))

        let session = try #require(try home.statusJSON()["manual_session"] as? [String: Any])
        #expect(session["indefinite"] as? Bool == true)
        #expect(session["deadline"] == nil)
        #expect(session["seconds_remaining"] == nil)
    }

    @Test func textReportsTheSession() throws {
        let home = try TemporaryHome()
        try home.storage.save(ManualSessionRecord(
            startedAt: Date(), deadline: nil, bootSessionID: try #require(BootSession.currentID())
        ))
        #expect(try home.status([]).contains("manual session: no time limit"))

        try home.storage.save(ManualSessionRecord(
            startedAt: Date(), deadline: Date().addingTimeInterval(102 * 60 - 1),
            bootSessionID: try #require(BootSession.currentID())
        ))
        let text = try home.status([])
        #expect(text.contains("manual session: until "))
        #expect(text.contains("(1:42 left)"))
    }

    @Test func expiredOrOtherBootSessionsAreNotReported() throws {
        let home = try TemporaryHome()
        try home.storage.save(ManualSessionRecord(
            startedAt: Date().addingTimeInterval(-3_600), deadline: Date().addingTimeInterval(-1),
            bootSessionID: try #require(BootSession.currentID())
        ))
        #expect(try home.statusJSON()["manual_session"] == nil)
        #expect(!(try home.status([]).contains("manual session")))

        try home.storage.save(ManualSessionRecord(
            startedAt: Date(), deadline: nil, bootSessionID: "an-earlier-boot"
        ))
        #expect(try home.statusJSON()["manual_session"] == nil)
    }
}

private struct StatusTestError: Error, CustomStringConvertible {
    let description: String
}

/// Any symbol in this test image, to find where the image lives.
private let imageAnchor: @convention(c) () -> Void = {}

private final class TemporaryHome {
    let url: URL
    let storage: ManualSessionStorage

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("letitbrew-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        storage = ManualSessionStorage(directory: SessionStorage.applicationSupportDirectory(
            in: url.appendingPathComponent("Library/Application Support")
        ))
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func statusJSON() throws -> [String: Any] {
        let output = try status(["--json"])
        guard let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        else { throw StatusTestError(description: "not a JSON object: \(output)") }
        return json
    }

    func status(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.binary())
        process.arguments = ["status"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = url.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The `letitbrew` executable SwiftPM built beside this test bundle.
    private static func binary() throws -> String {
        var info = Dl_info()
        guard dladdr(unsafeBitCast(imageAnchor, to: UnsafeRawPointer.self), &info) != 0,
              let image = info.dli_fname
        else { throw StatusTestError(description: "test image not found") }
        var bundle = URL(fileURLWithPath: String(cString: image))
        while bundle.pathExtension != "xctest", bundle.pathComponents.count > 1 {
            bundle.deleteLastPathComponent()
        }
        let path = bundle.deletingLastPathComponent().appendingPathComponent("letitbrew").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw StatusTestError(description: "letitbrew not built at \(path)")
        }
        return path
    }
}
