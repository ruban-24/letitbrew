import Testing
import Foundation
@testable import LetItBrewCore

private struct FakeLiveness: ProcessLiveness {
    var alive: Set<Int32>
    func isAlive(pid: Int32) -> Bool { alive.contains(pid) }
}

private func record(_ id: String, pid: Int32?, ageSeconds: TimeInterval,
                    now: Date, state: SessionState = .working) -> SessionRecord {
    SessionRecord(id: id, tool: "claude", state: state, detail: nil, cwd: "/tmp/\(id)",
                  pid: pid, updatedAt: now.addingTimeInterval(-ageSeconds))
}

@Test func keepsSessionsWhoseProcessIsAlive() {
    let now = Date()
    let records = [record("a", pid: 100, ageSeconds: 10, now: now)]
    let live = SessionStore.live(records: records, now: now, ttl: 43_200,
                                 liveness: FakeLiveness(alive: [100]))
    #expect(live.map(\.id) == ["a"])
}

@Test func evictsSessionsWhoseProcessIsGone() {
    let now = Date()
    let records = [record("a", pid: 100, ageSeconds: 10, now: now),
                   record("b", pid: 200, ageSeconds: 10, now: now)]
    let live = SessionStore.live(records: records, now: now, ttl: 43_200,
                                 liveness: FakeLiveness(alive: [100]))
    #expect(live.map(\.id) == ["a"])
}

@Test func keepsALongSilentButLiveSession() {
    // The case a SHORT freshness timeout would get wrong: a session running
    // a 40-minute build emits one event (PreToolUse) and then nothing until
    // it finishes. Liveness, not freshness, decides. The 12-hour TTL used
    // below survives only as the pid-reuse backstop, not as the primary
    // eviction signal — it is far longer than any real build.
    let now = Date()
    let records = [record("build", pid: 100, ageSeconds: 2_400, now: now)]
    let live = SessionStore.live(records: records, now: now, ttl: 43_200,
                                 liveness: FakeLiveness(alive: [100]))
    #expect(live.map(\.id) == ["build"])
}

@Test func evictsNilPidSessionsOnlyByTTL() {
    let now = Date()
    let records = [record("young", pid: nil, ageSeconds: 60, now: now),
                   record("ancient", pid: nil, ageSeconds: 50_000, now: now)]
    let live = SessionStore.live(records: records, now: now, ttl: 43_200,
                                 liveness: FakeLiveness(alive: []))
    #expect(live.map(\.id) == ["young"])
}

@Test func ttlAlsoEvictsALiveButAncientSession() {
    // Backstop against pid reuse: a recycled pid could look alive forever.
    let now = Date()
    let records = [record("stale", pid: 100, ageSeconds: 50_000, now: now)]
    let live = SessionStore.live(records: records, now: now, ttl: 43_200,
                                 liveness: FakeLiveness(alive: [100]))
    #expect(live.isEmpty)
}

@Test func resultIsSortedByRecencyForStableDisplay() {
    let now = Date()
    let records = [record("old", pid: 1, ageSeconds: 300, now: now),
                   record("new", pid: 2, ageSeconds: 5, now: now),
                   record("mid", pid: 3, ageSeconds: 60, now: now)]
    let live = SessionStore.live(records: records, now: now, ttl: 43_200,
                                 liveness: FakeLiveness(alive: [1, 2, 3]))
    #expect(live.map(\.id) == ["new", "mid", "old"])
}

// MARK: - KillZeroLiveness against the real kernel
//
// Every test above injects `FakeLiveness`, which proves `SessionStore.live`'s
// filtering logic but says nothing about whether `KillZeroLiveness` itself
// talks to the kernel correctly. This project already shipped one defect
// that looked correct against a scripted table and only broke against real
// process data (reading `p_comm`, a version string, instead of argv[0]) —
// these tests exercise the real `kill(2)` syscall instead of a
// fake, so a regression in the non-positive-pid guard or the ESRCH/EPERM
// handling shows up here rather than staying hidden behind a green suite.

@Test func killZeroRejectsNonPositivePids() {
    // kill(0, 0) signals the caller's entire process group; kill(-1, 0)
    // signals every process the caller can reach. Neither is a liveness
    // check of one specific pid, so both must be rejected before any kill()
    // call is made.
    let liveness = KillZeroLiveness()
    #expect(liveness.isAlive(pid: 0) == false)
    #expect(liveness.isAlive(pid: -1) == false)
}

@Test func killZeroReportsTheCurrentProcessAlive() {
    #expect(KillZeroLiveness().isAlive(pid: getpid()) == true)
}

@Test func killZeroReportsAReapedChildDead() throws {
    // The ESRCH path: spawn a short-lived real process, wait for it to exit
    // and be reaped, then confirm its now-dead pid no longer reports alive.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try task.run()
    let pid = task.processIdentifier
    task.waitUntilExit()
    #expect(KillZeroLiveness().isAlive(pid: pid) == false)
}

@Test func killZeroReportsAnotherUsersProcessAlive() {
    // The EPERM path: pid 1 (launchd) exists but is owned by root, so for a
    // non-root caller kill(1, 0) fails with EPERM, and that must still read
    // as alive. Note: this test passes trivially if run as root, since
    // kill() would then succeed outright rather than exercising EPERM — the
    // reaped-child test above is what proves the ESRCH branch on its own.
    #expect(KillZeroLiveness().isAlive(pid: 1) == true)
}
