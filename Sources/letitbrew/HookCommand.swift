import Foundation
import LetItBrewCore

/// `letitbrew hook <agent> <event>`: read the payload on stdin, reduce it, update the
/// session record.
///
/// Returns 0 unconditionally, whatever happens. This runs on every tool call
/// of every agent turn; a non-zero exit is treated by Claude Code as a
/// blocking hook failure, so a bug here would break the user's agent rather
/// than merely fail to keep their Mac awake.
func runHook(
    agent: AgentID,
    event: String,
    storage: SessionStorage = SessionStorage()
) -> Int32 {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let payload = (try? JSONDecoder().decode(HookPayload.self, from: input)) ?? HookPayload()

    try? HookSessionUpdater.apply(
        event: event,
        payload: payload,
        agent: agent,
        agentPID: nil,
        observedAt: Date(),
        storage: storage
    )
    return 0
}
