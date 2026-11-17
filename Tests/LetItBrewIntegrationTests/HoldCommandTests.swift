import Darwin
import Foundation
import LetItBrewCore
import Testing

/// End-to-end tests of `letitbrew hold -- <cmd>` against the built binary.
/// Each run gets its own home (holds folder) and its own process group, so a
/// signal sent to the group stands in for Ctrl-C in a terminal.
@Suite(.serialized)
struct HoldCommandTests {
    @Test func exitStatusPassesThrough() throws {
        let run = try HoldRun(command: ["sh", "-c", "exit 7"])
        #expect(try run.wait() == 7)
    }

    @Test func signalExitBecomes128PlusSignal() throws {
        let run = try HoldRun(command: ["sh", "-c", "kill -TERM $$"])
        #expect(try run.wait() == 128 + SIGTERM)
    }

    @Test func missingCommandExits127AndSaysSo() throws {
        let run = try HoldRun(command: ["letitbrew-no-such-command"])
        #expect(try run.wait() == 127)
        #expect(run.stderr.contains("command not found"))
    }

    @Test func ctrlCReachesTheCommand() throws {
        let run = try HoldRun(command: [
            "sh", "-c",
            "trap 'exit 42' INT; touch \"$1\"; while :; do sleep 0.05; done",
            "sh", HoldRun.marker,
        ])
        try run.waitForMarker()
        kill(-run.pid, SIGINT)
        #expect(try run.wait() == 42)
    }

    @Test func terminationSignalIsForwardedToTheCommand() throws {
        let run = try HoldRun(command: [
            "sh", "-c",
            "trap 'exit 9' TERM; touch \"$1\"; while :; do sleep 0.05; done",
            "sh", HoldRun.marker,
        ])
        try run.waitForMarker()
        kill(run.pid, SIGTERM)
        #expect(try run.wait() == 9)
    }

    @Test func holdRecordExistsWhileTheCommandRunsAndIsRemovedAfter() throws {
        let run = try HoldRun(command: [
            "sh", "-c",
            "touch \"$1\"; while [ ! -f \"$1.go\" ]; do sleep 0.05; done",
            "sh", HoldRun.marker,
        ])
        try run.waitForMarker()
        // The CLI writes the record just after starting the command.
        let deadline = Date().addingTimeInterval(10)
        while run.storage.loadAll().isEmpty, Date() < deadline { usleep(20_000) }

        let records = run.storage.loadAll()
        #expect(records.count == 1)
        #expect(records.first?.pid != run.pid)
        #expect(records.first?.label.hasPrefix("sh -c touch") == true)
        #expect(run.storage.loadLive().count == 1)

        FileManager.default.createFile(atPath: run.markerPath + ".go", contents: nil)
        #expect(try run.wait() == 0)
        #expect(run.storage.loadAll().isEmpty)
    }

    @Test func killedCLIRecordIsPrunedOnceTheCommandIsGone() throws {
        let run = try HoldRun(command: [
            "sh", "-c", "touch \"$1\"; while :; do sleep 0.05; done", "sh", HoldRun.marker,
        ])
        try run.waitForMarker()
        let deadline = Date().addingTimeInterval(10)
        while run.storage.loadAll().isEmpty, Date() < deadline { usleep(20_000) }
        kill(-run.pid, SIGKILL)
        _ = try run.wait()
        #expect(run.storage.loadAll().count == 1)

        // The orphaned command may linger as a zombie for a moment.
        let pruneDeadline = Date().addingTimeInterval(10)
        while !run.storage.loadLive().isEmpty, Date() < pruneDeadline {
            usleep(50_000)
        }
        #expect(run.storage.loadLive().isEmpty)
        #expect(run.storage.loadAll().isEmpty)
    }

    @Test func pausedAppWarnsAndStillRunsTheCommand() throws {
        let run = try HoldRun(
            command: ["sh", "-c", "touch \"$1\"; exit 5", "sh", HoldRun.marker],
            appRunning: true, appPaused: true
        )
        #expect(try run.wait() == 5)
        #expect(FileManager.default.fileExists(atPath: run.markerPath))
        #expect(run.stderr.contains("Let It Brew is paused"))
        #expect(run.stderr.split(separator: "\n").count == 1)
    }

    @Test func appNotRunningWarnsAndStillRunsTheCommand() throws {
        let run = try HoldRun(
            command: ["sh", "-c", "touch \"$1\"", "sh", HoldRun.marker],
            appRunning: false, appPaused: false
        )
        #expect(try run.wait() == 0)
        #expect(FileManager.default.fileExists(atPath: run.markerPath))
        #expect(run.stderr.contains("Let It Brew isn't running"))
        #expect(run.stderr.split(separator: "\n").count == 1)
    }

    @Test func runningAppPrintsNoWarning() throws {
        let run = try HoldRun(command: ["true"])
        #expect(try run.wait() == 0)
        #expect(run.stderr.isEmpty)
    }
}

/// Any symbol in this test image, to find where the image lives.
private let imageAnchor: @convention(c) () -> Void = {}

private struct HoldTestError: Error, CustomStringConvertible {
    let description: String
}

private final class HoldRun {
    /// Replaced in `command` with this run's marker file path.
    static let marker = "@MARKER@"

    let pid: pid_t
    let home: URL
    let markerPath: String
    let storage: HoldStorage
    private let stderrPath: String
    private var exitStatus: Int32?

    init(command: [String], appRunning: Bool = true, appPaused: Bool = false) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("letitbrew-hold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let markerPath = home.appendingPathComponent("marker").path
        let stderrPath = home.appendingPathComponent("stderr").path
        self.home = home
        self.markerPath = markerPath
        self.stderrPath = stderrPath
        storage = HoldStorage(directory: SessionStorage
            .applicationSupportDirectory(in: home.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("holds", isDirectory: true))

        let arguments = [try Self.binary(), "hold", "--"]
            + command.map { $0 == Self.marker ? markerPath : $0 }
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        environment["LETITBREW_TEST_APP_RUNNING"] = appRunning ? "1" : "0"
        environment["LETITBREW_TEST_APP_PAUSED"] = appPaused ? "1" : "0"

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(
            &actions, 2, stderrPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600
        )
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, like a terminal's foreground job.
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0)=\($1)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let error = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
        guard error == 0 else {
            throw HoldTestError(description: "spawn failed: \(String(cString: strerror(error)))")
        }
        self.pid = pid
    }

    deinit {
        if exitStatus == nil {
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        try? FileManager.default.removeItem(at: home)
    }

    var stderr: String {
        (try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? ""
    }

    func waitForMarker(timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: markerPath) {
            guard Date() < deadline else {
                throw HoldTestError(description: "command never started; stderr: \(stderr)")
            }
            usleep(20_000)
        }
    }

    /// The CLI's own exit code, or 128 + signal if a signal killed it.
    func wait(timeout: TimeInterval = 10) throws -> Int32 {
        if let exitStatus { return exitStatus }
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == 0 {
            guard Date() < deadline else {
                throw HoldTestError(description: "letitbrew hold did not exit in time")
            }
            usleep(20_000)
        }
        let signalNumber = status & 0x7f
        let result = signalNumber == 0 ? (status >> 8) & 0xff : 128 + signalNumber
        exitStatus = result
        return result
    }

    /// The `letitbrew` executable SwiftPM built beside this test bundle.
    private static func binary() throws -> String {
        var info = Dl_info()
        guard dladdr(unsafeBitCast(imageAnchor, to: UnsafeRawPointer.self), &info) != 0,
              let image = info.dli_fname
        else { throw HoldTestError(description: "test image not found") }
        var bundle = URL(fileURLWithPath: String(cString: image))
        while bundle.pathExtension != "xctest", bundle.pathComponents.count > 1 {
            bundle.deleteLastPathComponent()
        }
        let path = bundle.deletingLastPathComponent()
            .appendingPathComponent("letitbrew").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw HoldTestError(description: "letitbrew not built at \(path)")
        }
        return path
    }
}
