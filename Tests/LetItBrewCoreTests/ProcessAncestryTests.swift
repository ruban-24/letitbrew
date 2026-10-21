import Darwin
import Testing
@testable import LetItBrewCore

private func table(_ rows: [(Int32, Int32, String)]) -> ProcessAncestry.Lookup {
    let byPID = Dictionary(uniqueKeysWithValues: rows.map {
        ($0.0, ProcessIdentity(pid: $0.0, parentPID: $0.1, name: $0.2))
    })
    return { byPID[$0] }
}

@Test func theHookAgentIsTheFirstAncestorPastShellWrappers() {
    let lookup = table([
        (40, 30, "sh"), (30, 20, "env"), (20, 10, "claude"), (10, 1, "zsh"),
    ])
    #expect(ProcessAncestry.hookAgentPID(startingAt: 40, lookup: lookup) == 20)
    // A helper spawned without a shell names its agent directly.
    #expect(ProcessAncestry.hookAgentPID(startingAt: 20, lookup: lookup) == 20)
}

@Test func anUnreadableOrRootAncestryHasNoAgent() {
    #expect(ProcessAncestry.hookAgentPID(startingAt: 40, lookup: table([])) == nil)
    #expect(ProcessAncestry.hookAgentPID(
        startingAt: 40, lookup: table([(40, 1, "bash")])
    ) == nil)
    #expect(ProcessAncestry.hookAgentPID(startingAt: 1, lookup: table([])) == nil)
}

@Test func lineageStopsAtLaunchdAndCycles() {
    let lookup = table([(5, 4, "claude"), (4, 3, "zsh"), (3, 5, "loop")])
    #expect(ProcessAncestry.lineage(of: 5, lookup: lookup).map(\.pid) == [5, 4, 3])
    let rooted = table([(5, 4, "claude"), (4, 1, "Terminal")])
    #expect(ProcessAncestry.lineage(of: 5, lookup: rooted).map(\.name) == ["claude", "Terminal"])
}

@Test func theLiveLookupReadsThisProcess() {
    let identity = ProcessAncestry.liveIdentity(getpid())
    #expect(identity?.pid == getpid())
    #expect(identity?.parentPID == getppid())
    #expect(identity?.name.isEmpty == false)
}

@Test func aNestedHelperResolvesToItsOutermostApp() {
    #expect(ProcessAncestry.outermostAppBundle(
        containing: "/Applications/Orca.app/Contents/Frameworks/Orca Helper.app/Contents/MacOS/Orca Helper"
    ) == "/Applications/Orca.app")
    #expect(ProcessAncestry.outermostAppBundle(
        containing: "/Users/me/Library/Application Support/orca/Orca Terminal Host.app/Contents/MacOS/orca-terminal-host"
    ) == "/Users/me/Library/Application Support/orca/Orca Terminal Host.app")
    #expect(ProcessAncestry.outermostAppBundle(containing: "/opt/homebrew/bin/tmux") == nil)
    #expect(ProcessAncestry.outermostAppBundle(containing: "/usr/bin/login") == nil)
}

@Test func theLiveLookupReadsThisExecutablePath() {
    let path = ProcessAncestry.executablePath(of: getpid())
    #expect(path?.hasPrefix("/") == true)
    #expect(ProcessAncestry.executablePath(of: -1) == nil)
}
