import Foundation

public enum ExactTargetExpectedState: String, Codable, Sendable { case absent, healthyOwned, repairableOwned }

public struct ExactTargetPreparation: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public let version: Int
    public let agent: AgentID
    public let snapshot: ExactFileSnapshot
    public let expectedState: ExactTargetExpectedState
    public init(agent: AgentID, snapshot: ExactFileSnapshot, expectedState: ExactTargetExpectedState, version: Int = schemaVersion) throws {
        guard version == Self.schemaVersion else { throw ExactTargetPreparationError.unsupportedVersion }
        self.version = version; self.agent = agent; self.snapshot = snapshot; self.expectedState = expectedState
    }
    enum CodingKeys: String, CodingKey { case version, agent, snapshot, expectedState }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(agent: try c.decode(AgentID.self, forKey: .agent), snapshot: try c.decode(ExactFileSnapshot.self, forKey: .snapshot), expectedState: try c.decode(ExactTargetExpectedState.self, forKey: .expectedState), version: try c.decode(Int.self, forKey: .version))
    }
}
public enum ExactTargetPreparationError: Error { case unsupportedVersion }
