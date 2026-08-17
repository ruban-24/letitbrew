import LetItBrewCore

public enum AgentLaunchPreparationRunner {
    public static func run(_ preparations: [AgentLaunchPreparation], runRecorded: (String) -> Void, runExact: (ExactTargetPreparation) -> Void) {
        for preparation in preparations {
            switch preparation {
            case .recordedTarget(let id): runRecorded(id)
            case .exactTarget(let id, let state, let snapshot):
                guard let agent = AgentID(rawValue: id), let request = try? ExactTargetPreparation(agent: agent, snapshot: snapshot, expectedState: state) else { continue }
                runExact(request)
            }
        }
    }
}
