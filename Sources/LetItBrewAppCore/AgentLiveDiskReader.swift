import Foundation
import LetItBrewCore

/// Live counterpart to `AgentDiskInspection`.  All reads are one exact
/// capture: the registry and recorded name use `O_NOFOLLOW`; only an
/// unrecorded JSON first-connect target may resolve its final symlink once.
public enum AgentLiveDiskReader {
    public static func readRegistry(at registryURL: URL) -> AgentDiskRegistry {
        do {
            let capture = try ExactFileCapture.capture(at: registryURL)
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
        helperPath: String
    ) -> AgentDiskInspectionResult {
        inspect(agent: agent, registry: readRegistry(at: registryURL), defaultTarget: defaultTarget, helperPath: helperPath)
    }

    public static func inspect(
        agent: AgentID,
        registry: AgentDiskRegistry,
        defaultTarget: URL,
        helperPath: String
    ) -> AgentDiskInspectionResult {
        return AgentDiskInspection.inspect(
            agent: agent,
            registry: registry,
            defaultTarget: defaultTarget,
            helperPath: helperPath,
            readExactTarget: { requested, recorded in
                if !recorded, agent != .opencode,
                   (try? FileManager.default.destinationOfSymbolicLink(atPath: requested.path)) != nil,
                   !FileManager.default.fileExists(atPath: requested.resolvingSymlinksInPath().path) {
                    return .invalid(resolvedURL: requested, reason: "Let It Brew will not follow a dangling configuration symlink.")
                }
                let target = recorded || agent == .opencode
                    ? requested
                    : requested.resolvingSymlinksInPath().standardizedFileURL
                do {
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
