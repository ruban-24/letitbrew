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
            hasBackgroundTasks: payload.hasBackgroundTasks,
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
                    if let reopenedAt = storage.load(id: parent.encoded)?.reopenedAt,
                       observedAt.timeIntervalSince1970 < reopenedAt { return }
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
                if event == "SessionEnd", identity.childID == nil {
                    children = familyChildren()
                    // A newer child edge also makes this a stale family end.
                    // Otherwise the parent's terminal marker would freeze that
                    // surviving child's subsequent completion hooks.
                    guard !children.contains(where: {
                        ($0.eventObservedAt ?? $0.updatedAt.timeIntervalSince1970)
                            > observedAt.timeIntervalSince1970
                    }) else { return }
                } else if agent == .codex, event == "Stop", identity.childID == nil,
                          let turn = storage.load(id: parent.encoded), turn.state == .working,
                          let turnStartedAt = [
                              turn.promptObservedAt, turn.stateChangedAt?.timeIntervalSince1970,
                          ].compactMap({ $0 }).max() {
                    // Codex can omit a child's SubagentStop. A child silent for
                    // the parent's whole turn is not running; one heard during
                    // this turn may be, so it waits for a later Stop or SessionEnd.
                    // The latest prompt starts the turn even when an earlier one
                    // ended without a hook and left the parent Working. Legacy
                    // records fall back to stateChangedAt, which persists rounded
                    // down to whole seconds: that can only keep a child longer.
                    staleChildCutoff = turnStartedAt
                    children = familyChildren().filter {
                        ($0.eventObservedAt ?? $0.updatedAt.timeIntervalSince1970) < turnStartedAt
                    }
                } else {
                    children = []
                }

                try applyRecord(
                    id: sessionID, effect: effect, event: event, payload: payload,
                    agent: agent, agentPID: agentPID, observedAt: observedAt, storage: storage,
                    reopenedAt: endedAt != nil && identity.childID == nil
                        ? observedAt.timeIntervalSince1970 : nil
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
                        try storage.mutate(id: record.id, observedAt: observedAt.timeIntervalSince1970) { previous in
                            guard let previous,
                                  (previous.eventObservedAt ?? previous.updatedAt.timeIntervalSince1970)
                                      < staleChildCutoff
                            else { return .keep }
                            return .delete
                        }
                    }
                } else if event == "SubagentStop", payload.hasBackgroundTaskSnapshot,
                          !payload.hasBackgroundTasks {
                    try reconcileStoppedParent(
                        id: parent.encoded, observedAt: observedAt, storage: storage
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

    private static func reconcileStoppedParent(
        id: String, observedAt: Date, storage: SessionStorage
    ) throws {
        try storage.mutate(id: id, observedAt: observedAt.timeIntervalSince1970) { previous in
            // A foreground turn may have continued since Stop. Only the parent
            // whose latest edge was Stop can be waiting solely on background work.
            guard var record = previous, record.state == .working,
                  record.lastEvent == "Stop" else { return .keep }
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

    private static func applyRecord(
        id: String, effect: HookEffect, event: String, payload: HookPayload,
        agent: AgentID, agentPID: Int32?, observedAt: Date, storage: SessionStorage,
        reopenedAt: TimeInterval? = nil
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
            // evidence that an already-working prompt became idle.
            if agent == .copilot,
               event == "SessionStart",
               previous?.state == .working {
                return .keep
            }

            // Stop stays Working only while it reports background work. A
            // manual compact at that prompt does not end the work; only the
            // work's own completion edge may release the hold.
            if agent == .claude,
               event == "PostCompact",
               previous?.state == .working,
               previous?.lastEvent == "Stop" {
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
                    pid: agentPID,
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
                        ? observedAt.timeIntervalSince1970 : previous?.promptObservedAt
                ))
            }
        }
    }
}
