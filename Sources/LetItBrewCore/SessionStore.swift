import Darwin
import Foundation

/// Whether a process still exists. Injected so eviction is testable.
public protocol ProcessLiveness: Sendable {
    func isAlive(pid: Int32) -> Bool
}

public struct KillZeroLiveness: ProcessLiveness {
    public init() {}

    public func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM means the process exists but belongs to another user.
        return errno == EPERM
    }
}

public enum SessionStore {
    /// Filters raw storage records to current, hook-written sessions.
    ///
    /// Agent process liveness cannot establish a trustworthy activity edge:
    /// only a current lifecycle hook record is eligible, and its freshness is
    /// the full activity boundary. The liveness primitives above remain for
    /// validating the app-owned closed-lid watchdog lease.
    public static func recent(
        records: [SessionRecord],
        now: Date,
        ttl: TimeInterval
    ) -> [SessionRecord] {
        guard ttl.isFinite, ttl > 0 else { return [] }
        return records
            .filter { record in
                guard let parsed = HookRecordID(encoded: record.id),
                      parsed.agent.rawValue == record.tool
                else { return false }
                let age = now.timeIntervalSince(record.updatedAt)
                return age >= 0 && age < ttl
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
