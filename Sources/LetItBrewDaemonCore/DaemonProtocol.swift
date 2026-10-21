import Foundation

/// Increment only for an incompatible wire change. The app must handshake
/// before requesting a hold because launchd can keep serving an older daemon
/// image briefly after an app update.
public enum LetItBrewDaemonProtocolVersion {
    public static let current = 1
}

/// Identifies the exact signed daemon image in addition to its human-readable
/// product version and build. The Code Directory hash comes from the live code
/// object, not from the executable path, which may already name a replacement
/// bundle while launchd is still serving the previous image.
public struct LetItBrewDaemonBuildIdentity: Equatable, Sendable {
    public let marketingVersion: String
    public let buildVersion: String
    public let codeDirectoryHash: String

    public init?(
        marketingVersion: String?,
        buildVersion: String?,
        codeDirectoryHash: String?
    ) {
        guard let marketingVersion = Self.nonempty(marketingVersion),
              let buildVersion = Self.nonempty(buildVersion),
              let codeDirectoryHash = Self.normalizedHash(codeDirectoryHash)
        else {
            return nil
        }
        self.marketingVersion = marketingVersion
        self.buildVersion = buildVersion
        self.codeDirectoryHash = codeDirectoryHash
    }

    public var versionDescription: String {
        "\(marketingVersion) (\(buildVersion))"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedHash(_ value: String?) -> String? {
        guard let value = nonempty(value) else { return nil }
        let normalized = value.lowercased()
        guard normalized.count.isMultiple(of: 2),
              normalized.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 97...102: true
                  default: false
                  }
              })
        else {
            return nil
        }
        return normalized
    }
}

/// Pure result of comparing an authenticated daemon handshake with the exact
/// daemon embedded in the app. Reconciliation failure takes precedence: an
/// updater must not replace a daemon while its prior power state is unresolved.
public enum LetItBrewDaemonHandshakeCompatibility: Equatable, Sendable {
    case compatible
    case reconciliationBlocked(String)
    case incompatibleProtocol(expected: Int, received: Int)
    case legacyOrUnidentified(receivedProtocol: Int)
    case staleBuild(
        expected: LetItBrewDaemonBuildIdentity,
        received: LetItBrewDaemonBuildIdentity
    )

    public static func evaluate(
        expectedProtocol: Int = LetItBrewDaemonProtocolVersion.current,
        expectedBuild: LetItBrewDaemonBuildIdentity,
        receivedProtocol: Int,
        receivedMarketingVersion: String?,
        receivedBuildVersion: String?,
        receivedCodeDirectoryHash: String?,
        reconciliationReady: Bool,
        reconciliationMessage: String?
    ) -> Self {
        guard reconciliationReady else {
            let message = reconciliationMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty {
                return .reconciliationBlocked(message)
            }
            return .reconciliationBlocked(
                "The daemon could not reconcile its prior sleep state."
            )
        }
        guard receivedProtocol == expectedProtocol else {
            return .incompatibleProtocol(
                expected: expectedProtocol,
                received: receivedProtocol
            )
        }
        guard let receivedBuild = LetItBrewDaemonBuildIdentity(
            marketingVersion: receivedMarketingVersion,
            buildVersion: receivedBuildVersion,
            codeDirectoryHash: receivedCodeDirectoryHash
        ) else {
            return .legacyOrUnidentified(receivedProtocol: receivedProtocol)
        }
        guard receivedBuild == expectedBuild else {
            return .staleBuild(expected: expectedBuild, received: receivedBuild)
        }
        return .compatible
    }
}

/// The complete privileged surface. It intentionally exposes named,
/// reversible switches rather than an arbitrary command runner.
@objc public protocol LetItBrewDaemonXPCProtocol {
    func protocolVersion(withReply reply: @escaping (Int) -> Void)
    /// Additive protocol-v1 handshake. Every reply value is an XPC-safe scalar:
    /// protocol, marketing version, build, Code Directory hash, reconciliation
    /// readiness, and an optional readiness failure message, in that order.
    func daemonHandshake(
        withReply reply: @escaping (
            Int, String?, String?, String?, Bool, String?
        ) -> Void
    )
    /// Prepares the daemon to be stopped for a bundle upgrade. A successful
    /// reply contains the exact readable SleepDisabled baseline as 0 or 1;
    /// failures use -1 and never guess a baseline.
    func prepareForUpgrade(
        withReply reply: @escaping (Bool, String?, Int) -> Void
    )
    func setLidClosedHold(
        _ enabled: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    )
    /// Additive protocol-v1 switch, accepted only while this connection owns
    /// a lid-closed hold. Releasing that hold or disconnecting restores the
    /// recorded energy mode. The app sends it only after its handshake proved
    /// the exact matching daemon build. The reply carries success, an optional
    /// failure message, and a bitmask of the sources already in Low Power Mode
    /// before the switch (1 battery, 2 charger), or -1 on failure.
    func setLowPowerModeHold(
        _ enabled: Bool,
        withReply reply: @escaping (Bool, String?, Int) -> Void
    )
}
