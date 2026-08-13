public enum DaemonRegistrationErrorDisposition: Equatable, Sendable {
    case approvalRequired
    case alreadyRegistered
    case alreadyUnregistered
    case other
}

public enum DaemonRegistrationErrorClassifier {
    public static func disposition(
        domain: String,
        code: Int,
        launchDeniedByUserCode: Int,
        jobNotFoundCode: Int,
        alreadyRegisteredCode: Int
    ) -> DaemonRegistrationErrorDisposition {
        if domain == "SMAppServiceErrorDomain", code == 1 {
            return .approvalRequired
        }

        let serviceDomains = [
            "SMAppServiceErrorDomain",
            "kSMErrorDomainFramework",
            "kSMErrorDomainLaunchd",
        ]
        guard serviceDomains.contains(domain) else { return .other }

        if code == launchDeniedByUserCode {
            return .approvalRequired
        }
        if code == jobNotFoundCode {
            return .alreadyUnregistered
        }
        if code == alreadyRegisteredCode {
            return .alreadyRegistered
        }
        return .other
    }
}
