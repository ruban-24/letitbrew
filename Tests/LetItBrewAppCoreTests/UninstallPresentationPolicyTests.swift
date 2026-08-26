import Testing
@testable import LetItBrewAppCore

private func presentationFailure(_ step: UninstallStep) -> UninstallFailure {
    UninstallFailure(step: step, message: "blocked", diagnostic: "diagnostic")
}

@Test func confirmationIsVisibleOnlyWhileIdleAtAwaitingConfirmation() {
    #expect(UninstallConfirmationPresentationPolicy.isPresented(
        state: .awaitingConfirmation,
        inProgress: false
    ))
    #expect(!UninstallConfirmationPresentationPolicy.isPresented(
        state: .awaitingConfirmation,
        inProgress: true
    ))
    #expect(!UninstallConfirmationPresentationPolicy.isPresented(
        state: .idle,
        inProgress: false
    ))
}

@Test func dismissalCancelsOnlyAnUnconfirmedAwaitingState() {
    #expect(UninstallConfirmationPresentationPolicy.shouldCancel(
        presented: false,
        state: .awaitingConfirmation,
        inProgress: false
    ))
    #expect(!UninstallConfirmationPresentationPolicy.shouldCancel(
        presented: true,
        state: .awaitingConfirmation,
        inProgress: false
    ))
    #expect(!UninstallConfirmationPresentationPolicy.shouldCancel(
        presented: false,
        state: .blocked(
            presentationFailure(.unregisterDaemon),
            offersDiagnostic: true
        ),
        inProgress: false
    ))
    #expect(!UninstallConfirmationPresentationPolicy.shouldCancel(
        presented: false,
        state: .awaitingConfirmation,
        inProgress: true
    ))
}

@Test func safeCancellationRestoresOnlyAPreviouslyActiveApp() {
    #expect(UninstallPauseRestorationPolicy.shouldResumeAfterCancellation(
        wasPausedBeforeUninstall: false
    ))
    #expect(!UninstallPauseRestorationPolicy.shouldResumeAfterCancellation(
        wasPausedBeforeUninstall: true
    ))
    #expect(!UninstallPauseRestorationPolicy.shouldResumeAfterCancellation(
        wasPausedBeforeUninstall: nil
    ))
}

@Test func onlyAnIdleUninstallCanCaptureTheOriginalPauseState() {
    #expect(UninstallPauseRestorationPolicy.canBegin(state: .idle))
    #expect(!UninstallPauseRestorationPolicy.canBegin(
        state: .blocked(
            presentationFailure(.reconcileDaemon),
            offersDiagnostic: false
        )
    ))
    #expect(!UninstallPauseRestorationPolicy.canBegin(
        state: .awaitingConfirmation
    ))
}

@Test func theStatusItemRemainsARecoveryRouteUntilTheReportIsVisible() {
    #expect(UninstallStatusItemPresentationPolicy.isInserted(
        state: .idle,
        reportIsPresented: false
    ))
    #expect(UninstallStatusItemPresentationPolicy.isInserted(
        state: .blocked(
            presentationFailure(.reconcileDaemon),
            offersDiagnostic: false
        ),
        reportIsPresented: false
    ))
    #expect(UninstallStatusItemPresentationPolicy.isInserted(
        state: .report(leftovers: [presentationFailure(.disableLaunchAtLogin)]),
        reportIsPresented: false
    ))
    #expect(!UninstallStatusItemPresentationPolicy.isInserted(
        state: .report(leftovers: [presentationFailure(.disableLaunchAtLogin)]),
        reportIsPresented: true
    ))
    #expect(UninstallStatusItemPresentationPolicy.isInserted(
        state: .finished,
        reportIsPresented: false
    ))
}

@Test func reportedRetainedBundleStepsNeverConfirmRemoval() {
    #expect(UninstallStep.retainBundleForHookRetry.retainsBundleWhenReported)
    #expect(UninstallStep.trashBundle.retainsBundleWhenReported)
    #expect(!UninstallStep.removeCodexHooks.retainsBundleWhenReported)
    #expect(!UninstallStep.deleteUserData.retainsBundleWhenReported)
}
