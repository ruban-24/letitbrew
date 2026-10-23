import Darwin
import Foundation

/// Whether a process still exists.
public struct KillZeroLiveness: Sendable {
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
    /// the full activity boundary. The liveness check above remains for
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

    /// Drops in-turn records whose recorded agent process has exited. A wait
    /// can no longer be answered, and an agent that quit without `SessionEnd`
    /// has no work left, so such a record neither shows nor holds. Records
    /// without a PID keep the hook-only behavior, and a PID the caller may not
    /// signal counts as alive. Shared by the app, `watch`, and `status` so
    /// every hold decision sees the same set.
    public static func excludingExitedAgents(
        _ records: [SessionRecord],
        isAlive: (Int32) -> Bool = { KillZeroLiveness().isAlive(pid: $0) }
    ) -> [SessionRecord] {
        records.filter { record in
            guard record.state.isInTurn, let pid = record.pid else { return true }
            return isAlive(pid)
        }
    }
}
