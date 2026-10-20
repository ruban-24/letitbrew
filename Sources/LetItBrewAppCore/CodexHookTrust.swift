import Foundation

/// The runtime state Codex reports for Let It Brew's configured hooks. This is
/// intentionally separate from the on-disk install report: a valid hooks.json
/// is still inert until Codex trusts each current hook definition.
public enum CodexHookTrustResult: Equatable, Sendable {
    case trusted
    case approvalRequired
    case couldNotVerify
}

public enum CodexHookTrust {
    private struct Response: Decodable {
        struct Result: Decodable {
            struct Entry: Decodable {
                struct ErrorInfo: Decodable {
                    let message: String
                    let path: String
                }

                struct Hook: Decodable {
                    let command: String?
                    let enabled: Bool
                    let eventName: String
                    let sourcePath: String
                    let trustStatus: String
                }

                let errors: [ErrorInfo]
                let hooks: [Hook]
            }

            let data: [Entry]
        }

        let id: Int
        let result: Result?
    }

    /// Classifies the supported `hooks/list` app-server response. Let It Brew never
    /// reads or writes Codex's undocumented trust storage; only Codex's own
    /// runtime view can establish that installed hooks are actually runnable.
    /// `optionalEvents` are expected events an older Codex may leave out of
    /// its runtime view; when reported, they must be trusted like the rest.
    public static func classify(
        responseData: Data,
        expectedEvents: Set<String>,
        optionalEvents: Set<String> = [],
        expectedSourcePath: String,
        ownershipSuffix: String
    ) -> CodexHookTrustResult {
        guard let response = try? JSONDecoder().decode(Response.self, from: responseData),
              response.id == 2,
              let result = response.result,
              result.data.count == 1,
              result.data[0].errors.isEmpty
        else { return .couldNotVerify }

        let expectedSource = URL(fileURLWithPath: expectedSourcePath).standardizedFileURL.path
        let owned = result.data[0].hooks.filter { hook in
            guard let command = hook.command, command.hasSuffix(ownershipSuffix) else { return false }
            return URL(fileURLWithPath: hook.sourcePath).standardizedFileURL.path == expectedSource
        }

        let grouped = Dictionary(grouping: owned, by: \.eventName)
        let reported = Set(grouped.keys)
        guard reported.isSubset(of: expectedEvents),
              expectedEvents.subtracting(optionalEvents).isSubset(of: reported),
              grouped.values.allSatisfy({ $0.count == 1 })
        else { return .couldNotVerify }

        var needsApproval = false
        for hook in owned {
            guard hook.enabled else {
                needsApproval = true
                continue
            }
            switch hook.trustStatus {
            case "trusted", "managed":
                break
            case "untrusted", "modified":
                needsApproval = true
            default:
                return .couldNotVerify
            }
        }
        return needsApproval ? .approvalRequired : .trusted
    }

    /// App-server emits newline-delimited JSON and may answer initialization
    /// before `hooks/list`. Select the response carrying Let It Brew's request id
    /// instead of depending on response order or treating another response as
    /// a trust failure.
    public static func classifyAppServerOutput(
        _ output: Data,
        expectedEvents: Set<String>,
        optionalEvents: Set<String> = [],
        expectedSourcePath: String,
        ownershipSuffix: String
    ) -> CodexHookTrustResult {
        for line in output.split(separator: 0x0A) {
            let data = Data(line)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == 2
            else { continue }
            return classify(
                responseData: data,
                expectedEvents: expectedEvents,
                optionalEvents: optionalEvents,
                expectedSourcePath: expectedSourcePath,
                ownershipSuffix: ownershipSuffix
            )
        }
        return .couldNotVerify
    }
}
