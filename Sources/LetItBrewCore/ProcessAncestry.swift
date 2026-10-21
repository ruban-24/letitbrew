import Darwin
import Foundation

/// One process as `sysctl` reports it: no arguments, environment, or paths.
public struct ProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    /// The kernel's short command name, truncated to 16 bytes.
    public let name: String

    public init(pid: Int32, parentPID: Int32, name: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
    }
}

/// Walks process parents to find the agent that ran a hook, and later the app
/// that hosts that agent. Used only to bring the right app forward when the
/// person clicks a session; it never decides whether the Mac stays awake.
public enum ProcessAncestry {
    public typealias Lookup = @Sendable (Int32) -> ProcessIdentity?

    /// Agents run hook commands through a shell or `env`. These wrappers are
    /// skipped; the first other ancestor is the agent.
    static let wrapperNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "tcsh", "csh", "env",
    ]

    /// Bounds every walk so a corrupt or cyclic table cannot spin.
    static let maximumDepth = 32

    /// The agent process for the hook running in this process: the nearest
    /// ancestor that is not a shell wrapper. Nil when the walk cannot read a
    /// parent or reaches launchd.
    public static func hookAgentPID(
        startingAt parentPID: Int32 = getppid(),
        lookup: Lookup = liveIdentity
    ) -> Int32? {
        var pid = parentPID
        for _ in 0..<maximumDepth {
            guard pid > 1, let identity = lookup(pid) else { return nil }
            guard wrapperNames.contains(identity.name) else { return identity.pid }
            pid = identity.parentPID
        }
        return nil
    }

    /// The process and its ancestors, nearest first, stopping before launchd.
    public static func lineage(
        of pid: Int32,
        lookup: Lookup = liveIdentity
    ) -> [ProcessIdentity] {
        var result: [ProcessIdentity] = []
        var current = pid
        for _ in 0..<maximumDepth {
            guard current > 1,
                  let identity = lookup(current),
                  !result.contains(where: { $0.pid == identity.pid })
            else { break }
            result.append(identity)
            current = identity.parentPID
        }
        return result
    }

    @Sendable
    public static func liveIdentity(_ pid: Int32) -> ProcessIdentity? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid
        else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessIdentity(pid: pid, parentPID: info.kp_eproc.e_ppid, name: name)
    }

    /// The process's executable path. Read only while bringing a session's
    /// app forward, to find the app bundle of a host that runs detached from
    /// its app; never stored.
    public static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The outermost `.app` bundle containing an executable, so a helper
    /// nested inside an app resolves to that app rather than to itself.
    public static func outermostAppBundle(containing executablePath: String) -> String? {
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return components[...index].joined(separator: "/")
    }
}
