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
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(targets: try c.decode([AgentID: String].self, forKey: .targets), version: try c.decode(Int.self, forKey: .version))
    }
}
public enum AgentInstallRegistryError: Error, Equatable { case unsupportedVersion, invalidPath(String) }
