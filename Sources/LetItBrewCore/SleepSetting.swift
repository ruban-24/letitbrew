import Foundation

public enum SleepSettingResult: Equatable, Sendable {
    case applied
    /// The user dismissed the administrator prompt. Not an error to nag about.
    case cancelled
    case failed(String)
}

/// Reads the flag with `pmset -g`.
///
/// Not `@MainActor`, and callers must keep it off the main thread: a
/// synchronous `Process.waitUntilExit` spins the main run loop, where a
/// re-entrant display-driver callback can crash the process.
public final class PMSetSleepControl: @unchecked Sendable {
    public init() {}

    public func isSleepDisabled() -> Bool? {
        PMSet.parseSleepDisabled(from: Self.run("/usr/bin/pmset", ["-g"]))
    }

    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // A Pipe() nothing reads can fill up and deadlock the child if it
        // writes enough to stderr; discard it instead.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(decoding: data, as: UTF8.self)
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }
}
