import Darwin
import Foundation

/// A manual keep-awake session started from the menu, as stored on disk so it
/// survives an app relaunch or update. It belongs to the boot it started in:
/// after a reboot, or once its deadline passes, it is discarded.
public struct ManualSessionRecord: Codable, Equatable, Sendable {
    public var startedAt: Date
    /// Nil for a session that lasts until it is ended.
    public var deadline: Date?
    /// `BootSession.currentID()` when the session started.
    public var bootSessionID: String

    public init(startedAt: Date, deadline: Date?, bootSessionID: String) {
        self.startedAt = startedAt
        self.deadline = deadline
        self.bootSessionID = bootSessionID
    }

    public func isLive(at now: Date, bootSessionID: String) -> Bool {
        bootSessionID == self.bootSessionID && !isExpired(at: now)
    }

    /// Whether the deadline has come. A session with no deadline never expires.
    public func isExpired(at now: Date) -> Bool {
        deadline.map { $0 <= now } ?? false
    }

    public var demand: KeepAwakeDemand { .manualSession(deadline: deadline) }

    /// Whole minutes left, rounded up, as "H:MM": a fresh 30-minute session
    /// reads "0:30". Nil for a session with no time limit.
    public func timeLeft(at now: Date) -> String? {
        guard let deadline else { return nil }
        let minutes = max(0, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    /// The stored session that still holds now, if any.
    public static func live(
        in storage: ManualSessionStorage, now: Date, bootSessionID: String?
    ) -> ManualSessionRecord? {
        guard let bootSessionID, let record = storage.load(),
              record.isLive(at: now, bootSessionID: bootSessionID)
        else { return nil }
        return record
    }
}

/// The running manual session, one JSON file beside the `holds` folder. The
/// app writes it; `letitbrew status` reads it.
public struct ManualSessionStorage: Sendable {
    public let directory: URL

    public init(directory: URL = SessionStorage.applicationSupportDirectory) {
        self.directory = directory
    }

    public var url: URL { directory.appendingPathComponent("manual-session.json") }

    /// The stored session, or nil if there is none or it can't be read.
    public func load() -> ManualSessionRecord? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ManualSessionRecord.self, from: data)
    }

    /// Replaces the stored session atomically; nil removes it.
    public func save(_ record: ManualSessionRecord?) throws {
        guard let record else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
            }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(record).write(to: url, options: .atomic)
    }
}

/// Identifies the current boot: the kernel issues a new UUID at every boot.
public enum BootSession {
    public static func currentID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let id = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return id.isEmpty ? nil : id
    }
}
