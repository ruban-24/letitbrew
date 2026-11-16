import Darwin
import Foundation

/// A process an agent started, as `sysctl` reports it: no arguments,
/// environment, or paths.
public struct AgentChildProcess: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let processGroup: Int32
    public let startedAt: Date

    public init(pid: Int32, parentPID: Int32, processGroup: Int32, startedAt: Date) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroup = processGroup
        self.startedAt = startedAt
    }
}

/// Reads the direct children of agent processes from the kernel's process
/// table. Read only while an approval wait needs it; see `RunningApprovals`.
public struct AgentChildProcesses: Sendable {
    public init() {}

    /// The children of these agents. Nil when the table is unreadable.
    public func current(of agents: Set<Int32>) -> [AgentChildProcess]? {
        guard !agents.isEmpty else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        // The table can grow between sizing and reading it.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            size += size / 8
            var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            guard sysctl(&mib, u_int(mib.count), &table, &size, nil, 0) == 0 else {
                if errno == ENOMEM { continue }
                return nil
            }
            return table.prefix(size / stride).compactMap { info in
                guard agents.contains(info.kp_eproc.e_ppid) else { return nil }
                let start = info.kp_proc.p_un.__p_starttime
                return AgentChildProcess(
                    pid: info.kp_proc.p_pid,
                    parentPID: info.kp_eproc.e_ppid,
                    processGroup: info.kp_eproc.e_pgid,
                    startedAt: Date(timeIntervalSince1970: TimeInterval(start.tv_sec)
                        + TimeInterval(start.tv_usec) / 1_000_000)
                )
            }
        }
        return nil
    }
}
