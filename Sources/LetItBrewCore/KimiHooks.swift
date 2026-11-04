import Foundation

/// Observes Kimi Code through `[[hooks]]` tables in its `config.toml`.
///
/// The file belongs to the user, so it is edited as lines rather than parsed
/// and rewritten: every byte outside our own tables survives. A table is ours
/// when its `command` carries our ownership comment. Block markers would not
/// do, because Kimi drops TOML comments when it rewrites the file.
///
/// Kimi validates this section strictly, so a table holds only `event`,
/// `command`, and `timeout`. Its stdout may be added to the model's context,
/// and the generated command discards it.
public enum KimiHooks {
    /// Frozen ownership marker for commands in `config.toml`.
    public static let marker = "__letitbrew_kimi_hook"

    /// Each event to install, and the name `HookReducer` knows it by.
    /// `Interrupt` (Kimi 0.14.0+) fires in place of `Stop` on Esc.
    /// `PermissionResult` reports an approval's answer.
    public static let events = [
        "SessionStart": "SessionStart",
        "UserPromptSubmit": "UserPromptSubmit",
        "PreToolUse": "PreToolUse",
        "PostToolUse": "PostToolUse",
        "PermissionRequest": "PermissionRequest",
        "PermissionResult": "UserInputResolved",
        "Stop": "Stop",
        "StopFailure": "StopFailure",
        "Interrupt": "Interrupt",
        "SessionEnd": "SessionEnd",
    ]

    public struct ConfigUnreadable: Error, Equatable {
        public init() {}
    }

    public static func configURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let root = environment["KIMI_CODE_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".kimi-code", isDirectory: true)
        return root.appendingPathComponent("config.toml")
    }

    public static func hookCommand(event: String, cliPath: String) throws -> String {
        guard cliPath.hasPrefix("/") else { throw ClaudeHooks.RelativeCLIPath(cliPath) }
        return "c=\(ClaudeHooks.shellSingleQuoted(cliPath)); "
            + "[ -x \"$c\" ] || c=\(ClaudeHooks.shellSingleQuoted(ClaudeHooks.fallbackCLIPath)); "
            + "\"$c\" hook kimi \(events[event] ?? event) >/dev/null 2>&1; "
            + HookFile.ownershipComment(marker: marker)
    }

    /// Removes our tables, then appends one per event, so reinstall is
    /// idempotent and repairs a stale path or a retired event.
    public static func install(into data: Data?, cliPath: String) throws -> Data {
        let scan = try Scan(data ?? Data())
        let tables = try events.keys.sorted().map { event in
            [
                "[[hooks]]",
                "event = \(basicString(event))",
                "command = \(basicString(try hookCommand(event: event, cliPath: cliPath)))",
                "timeout = 5",
            ].joined(separator: scan.eol)
        }
        var result = trimmedTrailingWhitespace(scan.linesWithoutOwnedTables())
        if !result.isEmpty { result += Array((scan.eol + scan.eol).utf8) }
        result += Array((tables.joined(separator: scan.eol + scan.eol) + scan.eol).utf8)
        return Data(result)
    }

    /// Removes exactly our tables. A file without any is returned untouched.
    public static func remove(from data: Data?) throws -> Data {
        let scan = try Scan(data ?? Data())
        guard !scan.owned.isEmpty else { return data ?? Data() }
        var result = trimmedTrailingWhitespace(scan.linesWithoutOwnedTables())
        if !result.isEmpty { result += Array(scan.eol.utf8) }
        return Data(result)
    }

    /// Unreadable configuration reports as absent, because status must always
    /// render; `install` and `remove` are the paths that refuse.
    public static func report(for data: Data?, cliPath: String) -> HookInstallReport {
        var report = HookInstallReport()
        let expected = Set(events.keys)
        guard let scan = try? Scan(data ?? Data()) else {
            report.missing = expected
            return report
        }
        for (event, tables) in Dictionary(grouping: scan.owned, by: { $0.event ?? "" }) {
            guard expected.contains(event) else { report.orphaned.insert(event); continue }
            if tables.count > 1 {
                report.duplicated.insert(event)
            } else if let command = try? hookCommand(event: event, cliPath: cliPath),
                      tables[0].commandLiteral == basicString(command) {
                report.healthy.insert(event)
            } else {
                report.stale.insert(event)
            }
        }
        report.missing = expected
            .subtracting(report.healthy).subtracting(report.stale).subtracting(report.duplicated)
        return report
    }

    /// A TOML basic string.
    static func basicString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func trimmedTrailingWhitespace(_ bytes: [UInt8]) -> [UInt8] {
        var result = bytes
        while let last = result.last, [0x20, 0x09, 0x0D, 0x0A].contains(last) { result.removeLast() }
        return result
    }

    /// The file as lines of bytes, with our tables located. Byte lines keep a
    /// user's line endings exact, and Swift treats `\r\n` as one `Character`.
    private struct Scan {
        struct OwnedTable {
            let lines: Range<Int>
            let event: String?
            let commandLiteral: String
        }

        let lines: [ArraySlice<UInt8>]
        let eol: String
        private(set) var owned: [OwnedTable] = []

        init(_ data: Data) throws {
            guard let text = String(data: data, encoding: .utf8) else { throw ConfigUnreadable() }
            eol = text.contains("\r\n") ? "\r\n" : "\n"
            let bytes = Array(data)
            lines = bytes.isEmpty
                ? []
                : bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            let texts = lines.map { String(decoding: $0, as: UTF8.self) }
            let headers = try Self.tableHeaders(in: texts)
            for (position, header) in headers.enumerated() where Self.isHooksTable(texts[header]) {
                var end = position + 1 < headers.count ? headers[position + 1] : lines.count
                // A table's trailing comments may describe whatever follows it.
                while end > header + 1, Self.isBlankOrComment(texts[end - 1]) { end -= 1 }
                let body = texts[(header + 1)..<end]
                guard let command = Self.value(of: "command", in: body),
                      command.contains(HookFile.ownershipComment(marker: marker))
                else { continue }
                owned.append(OwnedTable(
                    lines: header..<end,
                    event: Self.value(of: "event", in: body).flatMap(Self.unquoted),
                    commandLiteral: command
                ))
            }
        }

        /// Every line outside our tables, plus the blank lines each table's
        /// removal would otherwise leave behind.
        func linesWithoutOwnedTables() -> [UInt8] {
            var removed = Set<Int>()
            for table in owned {
                removed.formUnion(table.lines)
                var next = table.lines.upperBound
                while next < lines.count, lines[next].allSatisfy({ [0x20, 0x09, 0x0D].contains($0) }) {
                    removed.insert(next)
                    next += 1
                }
            }
            let kept = lines.indices.filter { !removed.contains($0) }.map { lines[$0] }
            return Array(kept.joined(separator: [0x0A]))
        }

        /// Line numbers of every table header outside a multi-line string.
        /// Throws when appending `[[hooks]]` could not be valid TOML: `hooks`
        /// is already defined some other way, or a string never closes.
        private static func tableHeaders(in texts: [String]) throws -> [Int] {
            var headers: [Int] = []
            var openString: String?
            for (index, line) in texts.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let delimiter = openString {
                    if occurrences(of: delimiter, in: trimmed) % 2 == 1 { openString = nil }
                    continue
                }
                if trimmed.hasPrefix("#") { continue }
                if trimmed.hasPrefix("[") {
                    let name = tableName(trimmed)
                    if name == "hooks", !isHooksTable(trimmed) { throw ConfigUnreadable() }
                    if name.hasPrefix("hooks.") { throw ConfigUnreadable() }
                    headers.append(index)
                    continue
                }
                if headers.isEmpty, let key = trimmed.split(separator: "=").first {
                    let name = key.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if name == "hooks" || name.hasPrefix("hooks.") { throw ConfigUnreadable() }
                }
                for delimiter in ["\"\"\"", "'''"]
                where occurrences(of: delimiter, in: trimmed) % 2 == 1 {
                    openString = delimiter
                    break
                }
            }
            guard openString == nil else { throw ConfigUnreadable() }
            return headers
        }

        private static func occurrences(of needle: String, in line: String) -> Int {
            line.components(separatedBy: needle).count - 1
        }

        private static func tableName(_ header: String) -> String {
            let withoutComment = header.split(separator: "#", maxSplits: 1).first.map(String.init) ?? header
            return withoutComment.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\r"))
        }

        private static func isHooksTable(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("[[") && tableName(trimmed) == "hooks"
        }

        private static func isBlankOrComment(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }

        /// The raw TOML value of a top-level `key = value` line.
        private static func value(of key: String, in lines: ArraySlice<String>) -> String? {
            for line in lines {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }

        private static func unquoted(_ literal: String) -> String? {
            let quotes = CharacterSet(charactersIn: "\"'")
            let value = literal.trimmingCharacters(in: quotes)
            return value.count == literal.count ? nil : value
        }
    }
}
