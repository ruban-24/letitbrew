import Foundation
import ServiceManagement
import LetItBrewAppCore
import LetItBrewDaemonCore

enum DaemonRegistrationFailure: LocalizedError {
    case ineligibleLocation
    case missingBundleIdentifier
    case invalidSigningIdentity(String)

    var errorDescription: String? {
        switch self {
        case .ineligibleLocation:
            "Refusing to manage the daemon unless this signed app is installed directly in /Applications."
        case .missingBundleIdentifier:
            "The app bundle identifier is missing."
        case .invalidSigningIdentity(let message):
            "Let It Brew's signing identity could not be verified: \(message)"
        }
    }
}

/// The only place in the codebase allowed to construct an `SMAppService`.
/// Do not add a status query here: Background Task Management treats even a
/// read as contact from this app copy and may repoint its persistent record.
enum DaemonRegistration {
    static func register(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws {
        let service = try eligibleService(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier
        )
        try service.register()
    }

    static func unregister(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws {
        let service = try eligibleService(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier
        )
        try service.unregister()
    }

    /// Waits for Service Management's completion callback, which is delivered
    /// only after a running daemon has been killed. The synchronous API returns
    /// before the process is reaped and is therefore insufficient before a
    /// re-registration or bundle replacement.
    static func unregisterAndWait(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) async throws {
        let service = try eligibleService(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            service.unregister { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// One serialized refresh transaction for a proven app-build migration.
    /// An absent old job is safe to continue from; every other unregister
    /// failure remains a refusal.
    static func refresh(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) async throws {
        do {
            try await unregisterAndWait(
                bundleURL: bundleURL,
                bundleIdentifier: bundleIdentifier
            )
        } catch where disposition(of: error) == .alreadyUnregistered {
            // The intended postcondition is already true.
        }
        try register(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier)
    }

    static func disposition(of error: Error) -> DaemonRegistrationErrorDisposition {
        let error = error as NSError
        return DaemonRegistrationErrorClassifier.disposition(
            domain: error.domain,
            code: error.code,
            launchDeniedByUserCode: Int(kSMErrorLaunchDeniedByUser),
            jobNotFoundCode: Int(kSMErrorJobNotFound),
            alreadyRegisteredCode: Int(kSMErrorAlreadyRegistered)
        )
    }

    private static func eligibleService(
        bundleURL: URL,
        bundleIdentifier: String?
    ) throws -> SMAppService {
        let signingIdentity: RuntimeSigningIdentity
        do {
            signingIdentity = try RuntimeSigningIdentity.validatedCurrent()
        } catch {
            throw DaemonRegistrationFailure.invalidSigningIdentity(
                error.localizedDescription
            )
        }
        guard BackgroundServiceEligibility.mayManageBackgroundServices(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            signingIdentity: signingIdentity
        ) else {
            throw DaemonRegistrationFailure.ineligibleLocation
        }
        guard let bundleIdentifier else {
            throw DaemonRegistrationFailure.missingBundleIdentifier
        }

        // This construction happens only after the location/identity guard.
        // The matching plist is embedded at Contents/Library/LaunchDaemons.
        return SMAppService.daemon(
            plistName: bundleIdentifier + ".daemon.plist"
        )
    }
}
