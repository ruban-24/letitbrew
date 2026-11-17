import Darwin
import Foundation
import LetItBrewCore

let holdUsage = "Usage: letitbrew hold -- <command> [args...]\n"

/// `letitbrew hold -- <command> [args...]`: keeps the Mac awake while the
/// command runs.
///
/// The command shares this terminal: same stdin, stdout, stderr, and process
/// group, so Ctrl-C reaches it straight from the terminal. This process
/// ignores Ctrl-C itself and outlives the command to remove its hold record,
/// forwards termination signals, and exits with the command's status, or
/// 128 + signal when a signal ended it.
func runHold(arguments: [String], storage: HoldStorage = HoldStorage()) -> Int32 {
    guard arguments.first == "--", arguments.count > 1 else {
        FileHandle.standardError.write(Data(holdUsage.utf8))
        return 2
    }
    let command = Array(arguments.dropFirst())

    if let warning = HoldWarning.message(
        appRunning: HoldAppState.isAppRunning(),
        paused: HoldAppState.isPaused()
    ) {
        FileHandle.standardError.write(Data((warning + "\n").utf8))
    }

    // Ignore the terminal's interrupt and quit here before spawning, so the
    // command alone decides what they do. The child gets default handlers.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for sig in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, sig) }
    var noMask = sigset_t()
    sigemptyset(&noMask)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setsigmask(&attributes, &noMask)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    let cArguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    defer { cArguments.forEach { free($0) } }
    var child: pid_t = 0
    let spawnError = posix_spawnp(&child, command[0], nil, &attributes, cArguments, environ)
    guard spawnError == 0 else {
        let reason = spawnError == ENOENT ? "command not found" : String(cString: strerror(spawnError))
        FileHandle.standardError.write(Data("letitbrew: \(command[0]): \(reason)\n".utf8))
        return spawnError == ENOENT ? 127 : 126
    }

    // A signal meant for this process is passed on to the command; the
    // command's exit then ends this process normally.
    let forwarders = [SIGTERM, SIGHUP].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { kill(child, sig) }
        source.resume()
        return source
    }
    defer { forwarders.forEach { $0.cancel() } }

    try? storage.write(HoldRecord(
        pid: child,
        label: HoldRecord.label(for: command),
        startedAt: Date()
    ))
    defer { storage.remove(pid: child) }

    var status: Int32 = 0
    while waitpid(child, &status, 0) == -1 {
        guard errno == EINTR else { return 1 }
    }
    let signalNumber = status & 0x7f
    return signalNumber == 0 ? (status >> 8) & 0xff : 128 + signalNumber
}

/// What the app would do with a hold right now, read without AppKit: this
/// binary is also the per-tool-call agent hook, so it stays light.
enum HoldAppState {
    private static let appExecutableSuffix = "/Contents/MacOS/LetItBrew"
    private static let pauseKey = "letitbrewPaused"

    static func isAppRunning() -> Bool {
        if let forced = testOverride("LETITBREW_TEST_APP_RUNNING") { return forced }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return true }
        return pids.prefix(Int(filled)).contains { pid in
            pid > 0 && ProcessAncestry.executablePath(of: pid)?
                .hasSuffix(appExecutableSuffix) == true
        }
    }

    static func isPaused() -> Bool {
        if let forced = testOverride("LETITBREW_TEST_APP_PAUSED") { return forced }
        return UserDefaults(suiteName: appBundleIdentifier)?.bool(forKey: pauseKey) ?? false
    }

    /// The CLI's bundle ID is the app's plus ".cli", for release and dev.
    private static var appBundleIdentifier: String {
        let cli = Bundle.main.bundleIdentifier ?? ""
        return cli.hasSuffix(".cli") ? String(cli.dropLast(4)) : "com.ruban24.letitbrew"
    }

    private static func testOverride(_ name: String) -> Bool? {
        switch ProcessInfo.processInfo.environment[name] {
        case "1": true
        case "0": false
        default: nil
        }
    }
}
