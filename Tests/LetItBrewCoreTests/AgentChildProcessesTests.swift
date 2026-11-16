import Darwin
import Foundation
import Testing
@testable import LetItBrewCore

/// Starts `/bin/sleep` as a child of this test process, optionally leading its
/// own process group as agents run approved commands.
private func spawnSleep(ownGroup: Bool) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    if ownGroup {
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
    }
    let arguments: [UnsafeMutablePointer<CChar>?] = ["/bin/sleep", "30"].map { (argument: String) in
        strdup(argument)
    }
    defer { arguments.forEach { free($0) } }
    let argv = arguments + [nil]
    let environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    let status = posix_spawn(&pid, "/bin/sleep", nil, &attributes, argv, environment)
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EINVAL) }
    return pid
}

private func stop(_ pid: pid_t) {
    kill(pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
}

@Test func readsAnAgentsChildrenWithTheirProcessGroupsAndStartTimes() throws {
    let before = Date().addingTimeInterval(-1)
    let command = try spawnSleep(ownGroup: true)
    defer { stop(command) }
    let helper = try spawnSleep(ownGroup: false)
    defer { stop(helper) }

    let children = try #require(AgentChildProcesses().current(of: [getpid()]))
    let started = try #require(children.first { $0.pid == command })
    #expect(started.parentPID == getpid())
    #expect(started.processGroup == command)
    #expect(started.startedAt >= before)
    #expect(started.startedAt <= Date().addingTimeInterval(1))
    let inherited = try #require(children.first { $0.pid == helper })
    #expect(inherited.processGroup == getpgrp())
}

@Test func readsNothingWhenNoAgentNeedsIt() {
    #expect(AgentChildProcesses().current(of: []) == [])
}
