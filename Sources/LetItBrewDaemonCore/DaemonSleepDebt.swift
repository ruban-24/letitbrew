import Darwin
import Foundation
import LetItBrewCore

public struct DaemonSleepDebt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let priorValue: Bool
    public let setAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        priorValue: Bool,
        setAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.priorValue = priorValue
        self.setAt = setAt
    }
}

public enum DaemonSleepDebtState: Equatable, Sendable {
    case none
    case valid(DaemonSleepDebt)
    case unreadable
}

public protocol DaemonSleepDebtStoring: AnyObject {
    func load() -> DaemonSleepDebtState
    func save(_ debt: DaemonSleepDebt) -> Bool
    func remove() -> Bool
}

/// Root-owned persistence for the `disablesleep` value Let It Brew may need to
/// restore. The daemon writes this before touching pmset and removes it only
/// after a read-back confirms the prior value.
public final class FileDaemonSleepDebtStore: DaemonSleepDebtStoring {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> DaemonSleepDebtState {
        switch DaemonRestoreRecordFile.load(DaemonSleepDebt.self, from: url) {
        case .none:
            return .none
        case .unreadable:
            return .unreadable
        case .valid(let debt):
            guard debt.schemaVersion == DaemonSleepDebt.currentSchemaVersion else {
                return .unreadable
            }
            return .valid(debt)
        }
    }

    public func save(_ debt: DaemonSleepDebt) -> Bool {
        DaemonRestoreRecordFile.save(debt, to: url)
    }

    public func remove() -> Bool {
        DaemonRestoreRecordFile.remove(url)
    }
}

/// The exact per-source energy mode recorded before Let It Brew switched this
/// Mac to Low Power Mode for closed-lid work.
public struct DaemonPowerModeDebt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let prior: PowerModeSnapshot
    public let setAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        prior: PowerModeSnapshot,
        setAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.prior = prior
        self.setAt = setAt
    }
}

public enum DaemonPowerModeDebtState: Equatable, Sendable {
    case none
    case valid(DaemonPowerModeDebt)
    case unreadable
}

public protocol DaemonPowerModeDebtStoring: AnyObject {
    func load() -> DaemonPowerModeDebtState
    func save(_ debt: DaemonPowerModeDebt) -> Bool
    func remove() -> Bool
}

/// Root-owned persistence for the energy mode, kept beside the sleep debt and
/// following the same write-before-change, remove-after-read-back rule.
public final class FileDaemonPowerModeDebtStore: DaemonPowerModeDebtStoring {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> DaemonPowerModeDebtState {
        switch DaemonRestoreRecordFile.load(DaemonPowerModeDebt.self, from: url) {
        case .none:
            return .none
        case .unreadable:
            return .unreadable
        case .valid(let debt):
            guard debt.schemaVersion == DaemonPowerModeDebt.currentSchemaVersion else {
                return .unreadable
            }
            return .valid(debt)
        }
    }

    public func save(_ debt: DaemonPowerModeDebt) -> Bool {
        DaemonRestoreRecordFile.save(debt, to: url)
    }

    public func remove() -> Bool {
        DaemonRestoreRecordFile.remove(url)
    }
}

/// Shared file discipline for the daemon's restore records: atomic write,
/// mode 0600, and a missing file that reads as "nothing to restore".
enum DaemonRestoreRecordFile {
    enum Loaded<Record> {
        case none
        case valid(Record)
        case unreadable
    }

    static func load<Record: Decodable>(_ type: Record.Type, from url: URL) -> Loaded<Record> {
        do {
            let data = try Data(contentsOf: url)
            return .valid(try JSONDecoder().decode(type, from: data))
        } catch {
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileReadNoSuchFileError {
                return .none
            }
            return .unreadable
        }
    }

    static func save<Record: Encodable>(_ record: Record, to url: URL) -> Bool {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, 0o600) == 0 else {
                try? FileManager.default.removeItem(at: url)
                return false
            }
            return true
        } catch {
            return false
        }
    }

    static func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            let cocoa = error as NSError
            return cocoa.domain == NSCocoaErrorDomain
                && cocoa.code == NSFileNoSuchFileError
        }
    }
}
