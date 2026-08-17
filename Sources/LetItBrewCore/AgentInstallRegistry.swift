import Foundation

/// The durable record of the exact file a connection owns.  Resolution is
/// intentionally not repeated after this point: environment variables can
/// move, while uninstall must remain bounded to the original target.
public struct AgentInstallRegistry: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public let version: Int
    public var targets: [AgentID: String]
    public init(targets: [AgentID: String] = [:], version: Int = schemaVersion) throws {
        guard version == Self.schemaVersion else { throw AgentInstallRegistryError.unsupportedVersion }
        for path in targets.values where !path.hasPrefix("/") { throw AgentInstallRegistryError.invalidPath(path) }
        self.version = version
        self.targets = Dictionary(uniqueKeysWithValues: targets.map { ($0.key, URL(fileURLWithPath: $0.value).standardizedFileURL.path) })
    }
    enum CodingKeys: String, CodingKey { case version, targets }
    struct TargetKey: CodingKey { var stringValue: String; init?(stringValue: String) { self.stringValue = stringValue }; var intValue: Int? { nil }; init?(intValue: Int) { nil } }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        var targetsContainer = c.nestedContainer(keyedBy: TargetKey.self, forKey: .targets)
        for agent in AgentID.allCases where targets[agent] != nil {
            try targetsContainer.encode(targets[agent]!, forKey: TargetKey(stringValue: agent.rawValue)!)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(c.allKeys) == Set([.version, .targets]) else { throw AgentInstallRegistryError.invalidSchema }
        let t = try c.nestedContainer(keyedBy: TargetKey.self, forKey: .targets)
        var values: [AgentID: String] = [:]
        for key in t.allKeys {
            guard let agent = AgentID(rawValue: key.stringValue) else { throw AgentInstallRegistryError.invalidAgent(key.stringValue) }
            values[agent] = try t.decode(String.self, forKey: key)
        }
        try self.init(targets: values, version: try c.decode(Int.self, forKey: .version))
    }
}
public enum AgentInstallRegistryError: Error, Equatable { case unsupportedVersion, invalidPath(String), invalidSchema, invalidAgent(String) }
