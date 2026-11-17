import Foundation

/// A keep-awake request that is not an agent session: it has no `AgentID`,
/// never takes part in hook install, uninstall, or doctor, and is not bounded
/// by `MonitoringLease`. A live demand holds like a Working session, under the
/// same power rules.
public enum KeepAwakeDemand: Equatable, Sendable {
    /// `letitbrew hold`: held while its process runs.
    case hold(HoldRecord)
}

/// One `letitbrew hold`, written by the CLI and read by the app.
public struct HoldRecord: Codable, Equatable, Sendable {
    /// The process whose life the hold lasts for.
    public var pid: Int32
    /// What the menu shows after "Holding · ".
    public var label: String
    public var startedAt: Date

    public init(pid: Int32, label: String, startedAt: Date) {
        self.pid = pid
        self.label = label
        self.startedAt = startedAt
    }

    public static let maxLabelLength = 60

    /// A single line naming the command: control characters become spaces,
    /// runs of spaces collapse, and a long line ends in an ellipsis.
    public static func label(for arguments: [String]) -> String {
        let joined = arguments.joined(separator: " ")
        let cleaned = String(String.UnicodeScalarView(joined.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        let words = cleaned.split(separator: " ", omittingEmptySubsequences: true)
        let line = words.joined(separator: " ")
        guard line.count > maxLabelLength else { return line }
        return String(line.prefix(maxLabelLength - 1)) + "…"
    }

    /// Keeps holds whose process is still running. A PID the caller may not
    /// signal counts as alive.
    public static func live(
        _ records: [HoldRecord],
        isAlive: (Int32) -> Bool = { KillZeroLiveness().isAlive(pid: $0) }
    ) -> [HoldRecord] {
        records.filter { isAlive($0.pid) }
    }
}

/// The `holds` folder beside the session records: one JSON file per hold,
/// named by the held PID.
public struct HoldStorage: Sendable {
    public let directory: URL

    public init(directory: URL = HoldStorage.holdsDirectory) {
        self.directory = directory
    }

    public static var holdsDirectory: URL {
        SessionStorage.applicationSupportDirectory
            .appendingPathComponent("holds", isDirectory: true)
    }

    private func url(for pid: Int32) -> URL {
        directory.appendingPathComponent("\(pid).json")
    }

    public func write(_ record: HoldRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(record).write(to: url(for: record.pid), options: .atomic)
    }

    public func remove(pid: Int32) {
        try? FileManager.default.removeItem(at: url(for: pid))
    }

    /// Every readable record. Unreadable files are skipped, not deleted: a
    /// record mid-write must not be lost.
    public func loadAll() -> [HoldRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = FileManager.default.contents(
                atPath: directory.appendingPathComponent(name).path
            ) else { return nil }
            return try? decoder.decode(HoldRecord.self, from: data)
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    /// Live holds. Records whose process has exited are deleted, so a killed
    /// CLI never leaves a hold behind.
    public func loadLive(
        isAlive: (Int32) -> Bool = { KillZeroLiveness().isAlive(pid: $0) }
    ) -> [HoldRecord] {
        let all = loadAll()
        let live = HoldRecord.live(all, isAlive: isAlive)
        for record in all where !live.contains(record) {
            remove(pid: record.pid)
        }
        return live
    }
}

/// The one line `letitbrew hold` prints when Let It Brew cannot hold the Mac
/// awake. The command runs either way.
public enum HoldWarning {
    public static func message(appRunning: Bool, paused: Bool) -> String? {
        if !appRunning {
            return "letitbrew: Let It Brew isn't running, so your Mac may still sleep. Running your command anyway."
        }
        if paused {
            return "letitbrew: Let It Brew is paused, so your Mac may still sleep. Running your command anyway."
        }
        return nil
    }
}
