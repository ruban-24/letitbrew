import Darwin
import Foundation

/// Copilot 1.0.103 records Esc as an abort but does not emit a Stop hook.
/// Project that explicit cancellation into the snapshot, leaving hook storage
/// untouched. No timeout or keyboard input is evidence that a turn ended.
public enum CopilotCancellation {
    public static func reconcile(_ records: [SessionRecord]) -> [SessionRecord] {
        records.map { record in
            guard record.tool == AgentID.copilot.rawValue, record.state.isInTurn,
                  let id = HookRecordID(encoded: record.id), id.agent == .copilot,
                  id.childID == nil,
                  UUID(uuidString: id.parentID) != nil else { return record }
            let home = record.copilotHome.map { URL(fileURLWithPath: $0) }
                ?? CopilotHooks.hooksURL().deletingLastPathComponent().deletingLastPathComponent()
            let url = home.appendingPathComponent("session-state")
                .appendingPathComponent(id.parentID).appendingPathComponent("events.jsonl")
            guard let data = tail(of: url) else { return record }
            return reconcile(record, tail: data)
        }
    }

    private struct Event: Decodable {
        var type: String
        var timestamp: String
    }

    static func reconcile(_ record: SessionRecord, tail: Data) -> SessionRecord {
        guard record.tool == AgentID.copilot.rawValue, record.state.isInTurn,
              tail.last == 0x0a else { return record }
        let decoder = JSONDecoder()
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var cancelledAt: Date?
        for line in tail.split(separator: 0x0a) {
            guard let event = try? decoder.decode(Event.self, from: Data(line)),
                  let date = dates.date(from: event.timestamp) else { return record }
            if event.type == "abort" {
                cancelledAt = date
            } else if event.type != "session.usage_checkpoint"
                        && event.type != "session.usage_record" {
                // New prompts, tools, hooks, or unknown activity invalidate an
                // earlier abort, including before their hook write arrives.
                cancelledAt = nil
            }
        }
        guard let cancelledAt,
              cancelledAt.timeIntervalSince1970 > max(
                record.eventObservedAt ?? record.updatedAt.timeIntervalSince1970,
                record.promptObservedAt ?? 0
              ) else { return record }
        var result = record
        result.state = .idle
        result.detail = nil
        result.accumulatedWorkingTime = SessionTimeline.accumulatedWorkingTime(
            previous: record, now: cancelledAt
        )
        result.updatedAt = cancelledAt
        result.eventObservedAt = cancelledAt.timeIntervalSince1970
        result.lastEvent = "abort"
        result.stateChangedAt = cancelledAt
        result.stateTransitionID = "copilot-abort-\(cancelledAt.timeIntervalSince1970)"
        return result
    }

    /// Bound every poll regardless of transcript size. Never follow a final
    /// symlink or block on a pipe; a missing/partial/unreadable log keeps the
    /// hook's state. Only lifecycle fields are decoded, never prompt content.
    private static func tail(of url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        let count = Int(min(status.st_size, 256 * 1024))
        guard count > 0 else { return nil }
        let offset = status.st_size - off_t(count)
        var bytes = [UInt8](repeating: 0, count: count)
        guard pread(fd, &bytes, count, offset) == count else { return nil }
        if offset > 0 {
            guard let newline = bytes.firstIndex(of: 0x0a) else { return nil }
            return Data(bytes.dropFirst(newline + 1))
        }
        return Data(bytes)
    }
}
