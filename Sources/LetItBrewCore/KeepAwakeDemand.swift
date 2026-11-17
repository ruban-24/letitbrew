import Darwin
import Foundation

/// A keep-awake request that is not an agent session: it has no `AgentID`,
/// never takes part in hook install, uninstall, or doctor, and is not bounded
/// by `MonitoringLease`. A live demand holds like a Working session, under the
/// same power rules.
public enum KeepAwakeDemand: Equatable, Sendable {
    /// `letitbrew hold`: held while its process runs.
    case hold(HoldRecord)
    /// A session started from the menu: held until its deadline, or until
    /// it is ended when the deadline is nil.
    case manualSession(deadline: Date?)
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

    /// The label of a bare `letitbrew hold`, which lasts until Ctrl-C.
    public static let terminalLabel = "Terminal"

    /// The label of `letitbrew hold --pid N`.
    public static func processLabel(pid: Int32) -> String {
        "Process \(pid)"
    }

    /// A process that started this long after the record's start time is a
    /// different process that reused the PID.
    public static let startTolerance: TimeInterval = 2

    /// Keeps holds whose own process is still running. `startTime` reports
    /// when the process now at a PID started, or nil if there is none; a
    /// process that started after the hold did reused the PID, so a stale
    /// record left by a crash or power loss never holds.
    public static func live(
        _ records: [HoldRecord],
        startTime: (Int32) -> Date? = ProcessStartTime.of
    ) -> [HoldRecord] {
        records.filter { record in
            guard let started = startTime(record.pid) else { return false }
            return started <= record.startedAt.addingTimeInterval(startTolerance)
        }
    }
}

/// How a held command ended, left by the CLI for the app's finished alert.
public struct HoldResult: Codable, Equatable, Sendable {
    public var hold: HoldRecord
    public var endedAt: Date
    /// The command's exit code, or 128 + signal.
    public var exitStatus: Int32

    public init(hold: HoldRecord, endedAt: Date, exitStatus: Int32) {
        self.hold = hold
        self.endedAt = endedAt
        self.exitStatus = exitStatus
    }
}

/// When a process started, read from the kernel's process table.
public enum ProcessStartTime {
    @Sendable
    public static func of(_ pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid
        else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec)
            + TimeInterval(start.tv_usec) / 1_000_000)
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

    /// Results sit beside the holds folder, so pruning dead holds never
    /// removes one before the app reads it.
    public var resultsDirectory: URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent("hold-results", isDirectory: true)
    }

    public func writeResult(_ result: HoldResult) throws {
        try FileManager.default.createDirectory(
            at: resultsDirectory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(result).write(
            to: resultsDirectory.appendingPathComponent("\(result.hold.pid).json"),
            options: .atomic
        )
    }

    /// Every result written since the last call, each returned once.
    public func takeResults() -> [HoldResult] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resultsDirectory.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let url = resultsDirectory.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
            return try? decoder.decode(HoldResult.self, from: data)
        }
        .sorted { $0.endedAt < $1.endedAt }
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

    /// Live holds. Records whose process has exited, or whose PID now
    /// belongs to another process, are deleted, so a killed CLI never leaves
    /// a hold behind.
    public func loadLive(
        startTime: (Int32) -> Date? = ProcessStartTime.of
    ) -> [HoldRecord] {
        let all = loadAll()
        let live = HoldRecord.live(all, startTime: startTime)
        for record in all where !live.contains(record) {
            remove(pid: record.pid)
        }
        return live
    }
}

/// The one line `letitbrew hold` prints when Let It Brew cannot hold the Mac
/// awake. The hold goes ahead either way; `anyway` says what happens next.
public enum HoldWarning {
    public static func message(
        appRunning: Bool,
        paused: Bool,
        anyway: String = "Running your command anyway."
    ) -> String? {
        if !appRunning {
            return "letitbrew: Let It Brew isn't running, so your Mac may still sleep. \(anyway)"
        }
        if paused {
            return "letitbrew: Let It Brew is paused, so your Mac may still sleep. \(anyway)"
        }
        return nil
    }
}
