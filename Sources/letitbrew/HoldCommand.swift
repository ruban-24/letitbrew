import Darwin
import Foundation
import LetItBrewCore

let holdUsage = """
Usage: letitbrew hold -- <command> [args...]
       letitbrew hold --pid <pid>
       letitbrew hold

"""

/// `letitbrew hold`, in three forms:
///
/// - `hold -- <command> [args...]` holds while the command runs and exits
///   with its status.
/// - `hold --pid <pid>` holds until that process exits, then exits 0. Stopped
///   first by Ctrl-C, SIGTERM, or SIGHUP, it exits 128 + signal, so
///   `hold --pid N && next` runs `next` only after N is done.
/// - bare `hold` holds until Ctrl-C, SIGTERM, or SIGHUP, which is how it is
///   meant to end, so it exits 0.
func runHold(arguments: [String], storage: HoldStorage = HoldStorage()) -> Int32 {
    switch arguments.first {
    case "--" where arguments.count > 1:
        return runHold(command: Array(arguments.dropFirst()), storage: storage)
    case "--pid" where arguments.count == 2:
        // 0 and negative PIDs name process groups, not a process.
        guard let pid = Int32(arguments[1]), pid > 0 else { break }
        // EPERM: the process exists but belongs to another user.
        guard kill(pid, 0) == 0 || errno == EPERM else {
            FileHandle.standardError.write(Data("letitbrew: no process with PID \(pid)\n".utf8))
            return 1
        }
        printHoldWarning(anyway: "Holding anyway.")
        return holdUntilStopped(exitOf: pid, label: HoldRecord.processLabel(pid: pid), storage: storage)
    case nil:
        printHoldWarning(anyway: "Holding anyway.")
        return holdUntilStopped(exitOf: nil, label: HoldRecord.terminalLabel, storage: storage)
    default:
        break
    }
    FileHandle.standardError.write(Data(holdUsage.utf8))
    return 2
}

/// Prints the one-line warning when Let It Brew cannot hold the Mac awake.
private func printHoldWarning(anyway: String) {
    if let warning = HoldWarning.message(
        appRunning: HoldAppState.isAppRunning(),
        paused: HoldAppState.isPaused(),
        anyway: anyway
    ) {
        FileHandle.standardError.write(Data((warning + "\n").utf8))
    }
}

/// Holds for this process's own life, so a killed CLI's record is pruned
/// like any other, until `pid` exits or a stop signal arrives.
private func holdUntilStopped(exitOf pid: pid_t?, label: String, storage: HoldStorage) -> Int32 {
    let queue = kqueue()
    guard queue >= 0 else {
        FileHandle.standardError.write(Data("letitbrew: \(String(cString: strerror(errno)))\n".utf8))
        return 1
    }
    defer { close(queue) }

    // Signals and the exit watch are armed before the record is written, so
    // a stop that comes as soon as the hold shows up is never missed. An
    // ignored signal is still reported to the kqueue.
    let stopSignals = [SIGINT, SIGTERM, SIGHUP]
    for sig in stopSignals {
        signal(sig, SIG_IGN)
        var change = kevent(
            ident: UInt(sig), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD),
            fflags: 0, data: 0, udata: nil
        )
        kevent(queue, &change, 1, nil, 0, nil)
    }
    if let pid {
        var change = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT, data: 0, udata: nil
        )
        if kevent(queue, &change, 1, nil, 0, nil) == -1 {
            // ESRCH: it exited after the existence check, so the wait is over.
            guard errno == ESRCH else {
                FileHandle.standardError.write(Data(
                    "letitbrew: can't watch PID \(pid): \(String(cString: strerror(errno)))\n".utf8
                ))
                return 1
            }
            return 0
        }
    }

    try? storage.write(HoldRecord(pid: getpid(), label: label, startedAt: Date()))
    defer { storage.remove(pid: getpid()) }

    var event = kevent()
    while true {
        switch kevent(queue, nil, 0, &event, 1, nil) {
        case 1:
            if event.filter == Int16(EVFILT_PROC) { return 0 }
            return pid == nil ? 0 : 128 + Int32(event.ident)
        case -1 where errno != EINTR:
            return 1
        default:
            continue
        }
    }
}

/// `letitbrew hold -- <command> [args...]`: keeps the Mac awake while the
/// command runs.
///
/// The command shares this terminal: same stdin, stdout, stderr, and process
/// group, so Ctrl-C reaches it straight from the terminal. This process
/// ignores Ctrl-C itself and outlives the command to remove its hold record,
/// forwards termination signals, and exits with the command's status, or
/// 128 + signal when a signal ended it.
private func runHold(command: [String], storage: HoldStorage) -> Int32 {
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
