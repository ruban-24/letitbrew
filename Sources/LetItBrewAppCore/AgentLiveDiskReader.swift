import Foundation
import LetItBrewCore

/// Live counterpart to `AgentDiskInspection`.  All reads are one exact
/// capture: the registry and recorded name use `O_NOFOLLOW`; only an
/// unrecorded JSON first-connect target may resolve its final symlink once.
public enum AgentLiveDiskReader {
    public struct RegistryHooks {
        public var afterExactCapture: ((ExactFileCapture) -> Void)?
        public init(afterExactCapture: ((ExactFileCapture) -> Void)? = nil) {
            self.afterExactCapture = afterExactCapture
        }
    }
    /// A deterministic seam immediately before the production exact capture.
    /// It exists only to prove that a route replacement is terminal: callers
    /// cannot use it to substitute an alternate target or trigger a fallback.
    public struct CaptureHooks {
        public var beforeExactCapture: ((URL, Bool, AgentID) throws -> Void)?
        public init(beforeExactCapture: ((URL, Bool, AgentID) throws -> Void)? = nil) {
            self.beforeExactCapture = beforeExactCapture
        }
    }
    public static func readRegistry(at registryURL: URL, hooks: RegistryHooks = .init()) -> AgentDiskRegistry {
        do {
            let capture = try ExactFileCapture.capture(at: registryURL)
            hooks.afterExactCapture?(capture)
            return if let data = capture.data {
                .valid(try JSONDecoder().decode(AgentInstallRegistry.self, from: data))
            } else {
                .valid(nil)
            }
        } catch {
            return .invalid("the target registry is not valid JSON")
        }
    }

    public static func inspect(
        agent: AgentID,
        registryURL: URL,
        defaultTarget: URL,
        helperPath: String,
        registryReader: ((URL) -> AgentDiskRegistry)? = nil,
        readExactTarget: ((URL, Bool, AgentID) -> AgentExactTargetRead)? = nil,
        registryHooks: RegistryHooks = .init(),
        hooks: CaptureHooks = .init()
    ) -> AgentDiskInspectionResult {
        inspect(
            agent: agent,
            registry: registryReader?(registryURL) ?? readRegistry(at: registryURL, hooks: registryHooks),
            defaultTarget: defaultTarget,
            helperPath: helperPath,
            readExactTarget: readExactTarget,
            hooks: hooks
        )
    }

    public static func inspect(
        agent: AgentID,
        registry: AgentDiskRegistry,
        defaultTarget: URL,
        helperPath: String,
        readExactTarget: ((URL, Bool, AgentID) -> AgentExactTargetRead)? = nil,
        hooks: CaptureHooks = .init()
    ) -> AgentDiskInspectionResult {
        return AgentDiskInspection.inspect(
            agent: agent,
            registry: registry,
            defaultTarget: defaultTarget,
            helperPath: helperPath,
            readExactTarget: { requested, recorded in
                if let readExactTarget {
                    return readExactTarget(requested, recorded, agent)
                }
                if !recorded, agent != .opencode,
                   (try? FileManager.default.destinationOfSymbolicLink(atPath: requested.path)) != nil,
                   !FileManager.default.fileExists(atPath: requested.resolvingSymlinksInPath().path) {
                    return .invalid(resolvedURL: requested, reason: "Let It Brew will not follow a dangling configuration symlink.")
                }
                let target = recorded || agent == .opencode
                    ? requested
                    : requested.resolvingSymlinksInPath().standardizedFileURL
                do {
                    try hooks.beforeExactCapture?(target, recorded, agent)
                    let capture = try ExactFileCapture.capture(at: target)
                    return if let data = capture.data {
                        .regular(capture.snapshot, data)
                    } else {
                        .absent(capture.snapshot)
                    }
                } catch {
                    return .invalid(resolvedURL: target, reason: "Let It Brew could not safely read this target.")
                }
            }
        )
    }
}
