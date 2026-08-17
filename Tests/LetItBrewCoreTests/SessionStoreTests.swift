import Testing
import Foundation
@testable import LetItBrewCore

private func record(
    _ id: String,
    tool: String = "claude",
    pid: Int32? = nil,
    ageSeconds: TimeInterval,
    now: Date
) -> SessionRecord {
    SessionRecord(
        id: id, tool: tool, state: .working, detail: nil, cwd: "/tmp/\(id)",
        pid: pid, updatedAt: now.addingTimeInterval(-ageSeconds)
    )
}

@Test func recentSessionsUseOnlyHookAgeAndIgnoreLegacyPID() {
    let now = Date(timeIntervalSince1970: 1_000)
    let live = record("v1|6:claude|4:live|0:", pid: 999_999, ageSeconds: 10, now: now)
    let stale = record("v1|6:claude|5:stale|0:", ageSeconds: 43_201, now: now)

    #expect(SessionStore.recent(
        records: [stale, live], now: now, ttl: 43_200
    ).map(\.id) == ["v1|6:claude|4:live|0:"])
}

@Test func preV06BareIDsRemainDecodableButCannotDriveActivity() throws {
    let data = Data(#"{"id":"legacy","tool":"claude","state":"working","detail":null,"cwd":"/tmp","pid":null,"updatedAt":1000}"#.utf8)
    let legacy = try JSONDecoder().decode(SessionRecord.self, from: data)

    #expect(legacy.id == "legacy")
    #expect(SessionStore.recent(
        records: [legacy], now: Date(timeIntervalSince1970: 1_001), ttl: 43_200
    ).isEmpty)
}

@Test func recentRejectsMalformedOrMismatchedHookRecordIDs() {
    let now = Date(timeIntervalSince1970: 1_000)
    let invalidIDs = [
        "v1|6:claude|4:live|", // truncated child field
        "v1|6:claude|5:live|0:", // wrong parent byte length
        "v1|6:claude|4:live|0:extra", // suffix
        "v1|7:unknown|4:live|0:", // unknown agent
        "v1|6:claude|0:|0:", // empty parent
        "legacy",
    ]
    let records = invalidIDs.map { record($0, ageSeconds: 10, now: now) }
        + [record("v1|5:codex|4:live|0:", tool: "claude", ageSeconds: 10, now: now)]

    #expect(SessionStore.recent(records: records, now: now, ttl: 43_200).isEmpty)
}

@Test func recentSessionsSortByRecency() {
    let now = Date(timeIntervalSince1970: 1_000)
    let records = [
        record("v1|6:claude|3:old|0:", ageSeconds: 300, now: now),
        record("v1|6:claude|3:new|0:", ageSeconds: 5, now: now),
        record("v1|6:claude|3:mid|0:", ageSeconds: 60, now: now),
    ]

    #expect(SessionStore.recent(records: records, now: now, ttl: 43_200)
        .map(\.id) == ["v1|6:claude|3:new|0:", "v1|6:claude|3:mid|0:", "v1|6:claude|3:old|0:"])
}

// MARK: - KillZeroLiveness against the real kernel
//
// Agent-session activity is hook-only. These kernel checks remain because
// the closed-lid watchdog validates ownership of its own app-process lease.

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
