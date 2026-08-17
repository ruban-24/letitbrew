import Foundation

/// Marker-scoped operations on flat `event -> [entry]` hook trees.
///
/// These trees are user-owned JSON. Keeping them as `[String: Any]` means an
/// operation can remove only its own entries without re-encoding unknown
/// fields, entry shapes, or event values through a narrower typed model.
public enum FlatHookFile {
    /// The sole definition of ownership for a flat entry. The ownership
    /// comment must be the exact suffix of the command under the caller's
    /// command key; text in another key or elsewhere in the command is
    /// foreign.
    public static func isOurs(
        _ entry: Any,
        marker: String,
        commandKey: String
    ) -> Bool {
        ((entry as? [String: Any])?[commandKey] as? String)?
            .hasSuffix(HookFile.ownershipComment(marker: marker)) ?? false
    }

    /// Removes this marker's entries from every flat event array.
    ///
    /// An event that does not contain an owned entry passes through unchanged,
    /// including empty arrays and values whose type is not an array. An event
    /// is pruned only when removing owned entries made its array empty.
    public static func sweep(
        _ hooks: [String: Any],
        marker: String,
        commandKey: String
    ) -> [String: Any] {
        var result = hooks

        for (event, value) in hooks {
            guard let entries = value as? [Any] else { continue }
            let retained = entries.filter {
                !isOurs($0, marker: marker, commandKey: commandKey)
            }
            guard retained.count != entries.count else { continue }

            if retained.isEmpty {
                result.removeValue(forKey: event)
            } else {
                result[event] = retained
            }
        }

        return result
    }

    /// One flat hook entry using the keys required by the caller's format.
    public static func entry(
        command: String,
        commandKey: String,
        timeoutKey: String,
        timeout: Int
    ) -> [String: Any] {
        [commandKey: command, timeoutKey: timeout]
    }

    /// Classifies every owned flat entry by event.
    ///
    /// Expected events are healthy, stale, duplicated, or missing. Owned
    /// entries under an event outside `events` are orphaned. Each event enters
    /// exactly one of the expected-event classifications, based on the number
    /// of owned entries found in its flat array.
    public static func report(
        hooks: [String: Any]?,
        events: [String],
        marker: String,
        commandKey: String,
        expectedCommand: (String) -> String
    ) -> HookInstallReport {
        var report = HookInstallReport()
        let expectedEvents = Set(events)

        guard let hooks else {
            report.missing = expectedEvents
            return report
        }

        for (event, value) in hooks {
            guard let entries = value as? [Any] else { continue }
            let ownedEntries = entries.filter {
                isOurs($0, marker: marker, commandKey: commandKey)
            }
            guard !ownedEntries.isEmpty else { continue }

            guard expectedEvents.contains(event) else {
                report.orphaned.insert(event)
                continue
            }

            if ownedEntries.count > 1 {
                report.duplicated.insert(event)
            } else if let command = (ownedEntries[0] as? [String: Any])?[commandKey] as? String,
                      command == expectedCommand(event) {
                report.healthy.insert(event)
            } else {
                // `isOurs` guarantees an owned entry has a string command at
                // this key. The fallback remains conservative if that
                // invariant ever changes.
                report.stale.insert(event)
            }
        }

        report.missing = expectedEvents
            .subtracting(report.healthy)
            .subtracting(report.stale)
            .subtracting(report.duplicated)
        return report
    }
}
