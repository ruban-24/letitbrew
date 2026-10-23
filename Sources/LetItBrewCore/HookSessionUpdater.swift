import Foundation

public enum HookSessionUpdater {
    public static func apply(
        event: String,
        payload: HookPayload,
        agent: AgentID,
        agentPID: Int32?,
        observedAt: Date,
        storage: SessionStorage
    ) throws {
        guard let sessionID = payload.recordID(agent: agent, event: event) else { return }
        guard let effect = HookReducer.reduce(
            agent: agent,
            event: event,
            toolName: payload.toolName,
            notificationType: payload.notificationType,
            source: payload.source,
            trigger: payload.trigger,
            backgroundWork: payload.backgroundWork,
            errorRecoverable: payload.errorRecoverable
        ) else { return }

        if agent.tracksSubagentFamilies,
           let identity = HookRecordID(encoded: sessionID),
           let parent = HookRecordID(agent: agent, parentID: identity.parentID) {
            try storage.withHookFamilyLock(parentID: parent.encoded) {
                let endedAt = try storage.terminalObservation(id: parent.encoded)
                if identity.childID != nil {
                    // Even a previously unseen child cannot outlive its ended
                    // parent. A fresh SessionStart/UserPromptSubmit reopens it.
                    guard endedAt == nil else { return }
                    if let cutoff = storage.load(id: parent.encoded)?.childCutoff,
                       observedAt.timeIntervalSince1970 < cutoff { return }
                } else if endedAt != nil,
                          !["SessionStart", "UserPromptSubmit", "SessionEnd"].contains(event) {
                    return
                }

                func familyChildren() -> [SessionRecord] {
                    storage.loadAll().filter { record in
                        guard let child = HookRecordID(encoded: record.id) else { return false }
                        return child.agent == agent && child.parentID == identity.parentID
                            && child.childID != nil
                    }
                }

                let children: [SessionRecord]
                var staleChildCutoff: TimeInterval?
                var prunesUnlistedChildren = false
                if event == "SessionEnd", identity.childID == nil {
                    children = familyChildren()
                    // A newer child edge also makes this a stale family end.
                    // Otherwise the parent's terminal marker would freeze that
                    // surviving child's subsequent completion hooks.
                    guard !children.contains(where: {
                        ($0.eventObservedAt ?? $0.updatedAt.timeIntervalSince1970)
                            > observedAt.timeIntervalSince1970
                    }) else { return }
                } else if agent == .codex, ["Stop", "Interrupt"].contains(event),
                          identity.childID == nil,
                          let turn = storage.load(id: parent.encoded), turn.state.isInTurn,
                          let turnStartedAt = turn.promptObservedAt
                              ?? turn.stateChangedAt?.timeIntervalSince1970 {
                    // Codex can omit a child's SubagentStop. A child silent for
                    // the parent's whole turn, ended by Stop or Interrupt, is not
                    // running; one heard during this turn may be, so it waits for
                    // a later turn's end or SessionEnd.
                    // The latest prompt starts the turn even when an earlier one
                    // ended without a hook and left the parent Working. A wait and
                    // its answer move stateChangedAt inside the turn, so the prompt
                    // wins whenever it is known. Legacy records fall back to
                    // stateChangedAt, which persists rounded down to whole seconds:
                    // that can only keep a child longer.
                    // The parent keeps the cutoff, which reads and later child
                    // hooks honor, so an interrupted deletion below is only tidying.
                    // Each deletion is ordered at the cutoff, not this edge: a child
                    // hook observed after the cutoff but applied after this edge
                    // proves the child is still running and must recreate it.
                    staleChildCutoff = turnStartedAt
                    children = familyChildren().filter {
                        ($0.eventObservedAt ?? $0.updatedAt.timeIntervalSince1970) < turnStartedAt
                    }
                } else if agent == .claude, event == "Stop", identity.childID == nil,
                          let listed = payload.runningBackgroundTaskIDs {
                    // Claude's Stop snapshot inventories every task still in
                    // flight for the session, and a running subagent is listed
                    // under its own agent_id. A child the complete inventory
                    // omits has finished even if its SubagentStop never came.
                    // A snapshot with an unidentified entry proves nothing.
                    prunesUnlistedChildren = true
                    children = familyChildren().filter { child in
                        guard let childID = HookRecordID(encoded: child.id)?.childID
                        else { return false }
                        return !listed.contains(childID)
                    }
                } else {
                    children = []
                }

                try applyRecord(
                    id: sessionID, effect: effect, event: event, payload: payload,
                    agent: agent, agentPID: agentPID, observedAt: observedAt, storage: storage,
                    reopenedAt: endedAt != nil && identity.childID == nil
                        ? observedAt.timeIntervalSince1970 : nil,
                    staleChildCutoff: staleChildCutoff
                )

                if event == "SessionEnd", identity.childID == nil,
                   try storage.terminalObservation(id: parent.encoded) == observedAt.timeIntervalSince1970 {
                    for record in children {
                        try storage.mutate(id: record.id, observedAt: observedAt.timeIntervalSince1970) { _ in
                            .delete
                        }
                    }
                } else if let staleChildCutoff,
                          storage.load(id: parent.encoded)?.eventObservedAt
                              == observedAt.timeIntervalSince1970 {
                    for record in children {
                        try storage.mutate(id: record.id, observedAt: staleChildCutoff) { previous in
                            guard let previous,
                                  (previous.eventObservedAt ?? previous.updatedAt.timeIntervalSince1970)
                                      < staleChildCutoff
                            else { return .keep }
                            return .delete
                        }
                    }
                } else if prunesUnlistedChildren,
                          storage.load(id: parent.encoded)?.eventObservedAt
                              == observedAt.timeIntervalSince1970 {
                    // Only the Stop that became the parent's latest edge may
                    // prune, and a child heard after it is still running.
                    for record in children {
                        try storage.mutate(id: record.id, observedAt: observedAt.timeIntervalSince1970) { previous in
                            guard let previous,
                                  (previous.eventObservedAt ?? previous.updatedAt.timeIntervalSince1970)
                                      < observedAt.timeIntervalSince1970
                            else { return .keep }
                            return .delete
                        }
                    }
                } else if event == "SubagentStop", payload.hasBackgroundTaskSnapshot {
                    // The snapshot is scoped to the parent and, for a
                    // backgrounded child, still lists the child that is
                    // stopping right now. Judge the parent without it.
                    try reconcileStoppedParent(
                        id: parent.encoded,
                        remainingWork: payload.backgroundWork(excludingTaskID: identity.childID),
                        observedAt: observedAt, storage: storage
                    )
                }
            }
        } else {
            try applyRecord(
                id: sessionID, effect: effect, event: event, payload: payload,
                agent: agent, agentPID: agentPID, observedAt: observedAt, storage: storage
            )
        }
    }

    /// Whether a Working record holds only for background work its `Stop`
    /// reported. Records written before detail tokens existed carry `Stop`
    /// as their latest edge instead.
    static func isWaitingOnBackgroundWork(_ record: SessionRecord) -> Bool {
        record.state == .working && (
            record.lastEvent == "Stop"
                || record.detail == SessionWorkDetail.backgroundShell
                || record.detail == SessionWorkDetail.backgroundAgent
        )
    }

    private static func reconcileStoppedParent(
        id: String, remainingWork: HookPayload.BackgroundWork,
        observedAt: Date, storage: SessionStorage
    ) throws {
        try storage.mutate(id: id, observedAt: observedAt.timeIntervalSince1970) { previous in
            // A foreground turn may have continued since Stop. Only the parent
            // whose latest edge was Stop can be waiting solely on background work.
            guard var record = previous, isWaitingOnBackgroundWork(record) else { return .keep }
            switch remainingWork {
            case .agent:
                return .keep
            case .shellOnly:
                // Bound the hold from this edge. An existing shell-only hold
                // keeps its earlier start.
                guard record.detail != SessionWorkDetail.backgroundShell else { return .keep }
                record.detail = SessionWorkDetail.backgroundShell
                record.lastEvent = "SubagentStop"
                record.updatedAt = observedAt
                record.eventObservedAt = observedAt.timeIntervalSince1970
                return .replace(record)
            case .none:
                let transition = SessionStateTransition.resolve(
                    previous: record, newState: .idle, now: observedAt
                )
                record.accumulatedWorkingTime = SessionTimeline.accumulatedWorkingTime(
                    previous: record, now: observedAt
                )
                record.state = .idle
                record.detail = nil
                record.lastEvent = "SubagentStop"
                record.updatedAt = observedAt
                record.eventObservedAt = observedAt.timeIntervalSince1970
                record.stateChangedAt = transition.changedAt
                record.stateTransitionID = transition.id
                return .replace(record)
            }
        }
    }

    private static func applyRecord(
        id: String, effect: HookEffect, event: String, payload: HookPayload,
        agent: AgentID, agentPID: Int32?, observedAt: Date, storage: SessionStorage,
        reopenedAt: TimeInterval? = nil, staleChildCutoff: TimeInterval? = nil
    ) throws {
        try storage.mutate(
            id: id,
            observedAt: observedAt.timeIntervalSince1970
        ) { previous in
            if let previousObservedAt = previous?.eventObservedAt,
               previousObservedAt > observedAt.timeIntervalSince1970 {
                return .keep
            }

            // Copilot may run its independent hook commands out of lifecycle
            // order. A delayed SessionStart is still a creation edge, not
            // evidence that a prompt already in its turn became idle.
            if agent == .copilot,
               event == "SessionStart",
               previous?.state.isInTurn == true {
                return .keep
            }

            // Stop stays Working only while it reports background work. A
            // manual compact at that prompt does not end the work; only the
            // work's own completion edge may release the hold.
            if agent == .claude,
               event == "PostCompact",
               let previous, isWaitingOnBackgroundWork(previous) {
                return .keep
            }

            switch effect {
            case .end:
                return .delete
            case .set(let state, let detail):
                let transition = SessionStateTransition.resolve(
                    previous: previous,
                    newState: state,
                    now: observedAt
                )
                return .replace(SessionRecord(
                    id: id,
                    tool: agent.rawValue,
                    state: state,
                    detail: detail,
                    cwd: payload.cwd ?? FileManager.default.currentDirectoryPath,
                    // A hook whose ancestry walk failed keeps the known agent,
                    // but this hook proves the agent is alive right now, so a
                    // carried PID that has exited belonged to an earlier
                    // process of a resumed session and must not be trusted.
                    pid: agentPID ?? previous?.pid.flatMap {
                        KillZeroLiveness().isAlive(pid: $0) ? $0 : nil
                    },
                    updatedAt: observedAt,
                    lastEvent: event,
                    startedAt: SessionTimeline.startedAt(previous: previous, now: observedAt),
                    accumulatedWorkingTime: SessionTimeline.accumulatedWorkingTime(
                        previous: previous,
                        now: observedAt
                    ),
                    stateChangedAt: transition.changedAt,
                    stateTransitionID: transition.id,
                    eventObservedAt: observedAt.timeIntervalSince1970,
                    reopenedAt: reopenedAt ?? previous?.reopenedAt,
                    promptObservedAt: event == "UserPromptSubmit"
                        ? observedAt.timeIntervalSince1970 : previous?.promptObservedAt,
                    staleChildCutoff: staleChildCutoff ?? previous?.staleChildCutoff
                ))
            }
        }
    }
}
