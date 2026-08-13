import Testing
@testable import LetItBrewAppCore

@Test func modernServiceManagementApprovalErrorRequiresApproval() {
    let disposition = DaemonRegistrationErrorClassifier.disposition(
        domain: "SMAppServiceErrorDomain",
        code: 1,
        launchDeniedByUserCode: 11,
        jobNotFoundCode: 6,
        alreadyRegisteredCode: 10
    )

    #expect(disposition == .approvalRequired)
}

@Test func modernApprovalCodeDoesNotLeakAcrossErrorDomains() {
    let disposition = DaemonRegistrationErrorClassifier.disposition(
        domain: "kSMErrorDomainFramework",
        code: 1,
        launchDeniedByUserCode: 11,
        jobNotFoundCode: 6,
        alreadyRegisteredCode: 10
    )

    #expect(disposition == .other)
}

@Test(arguments: [
    (11, DaemonRegistrationErrorDisposition.approvalRequired),
    (6, DaemonRegistrationErrorDisposition.alreadyUnregistered),
    (10, DaemonRegistrationErrorDisposition.alreadyRegistered),
])
func legacyServiceManagementErrorsKeepTheirDisposition(
    code: Int,
    expected: DaemonRegistrationErrorDisposition
) {
    let disposition = DaemonRegistrationErrorClassifier.disposition(
        domain: "kSMErrorDomainFramework",
        code: code,
        launchDeniedByUserCode: 11,
        jobNotFoundCode: 6,
        alreadyRegisteredCode: 10
    )

    #expect(disposition == expected)
}
