import Testing
import IOKit.pwr_mgt
@testable import LetItBrewCore

@Test func displayAndSystemAssertionsHaveIndependentLifecycles() {
    let assertion = IOKitPowerAssertion()
    #expect(assertion.setSystemHold(true, reason: "system"))
    #expect(assertion.setDisplayHold(true, reason: "display"))
    #expect(assertion.held)
    #expect(assertion.displayHeld)

    #expect(assertion.setDisplayHold(false, reason: "display release"))
    #expect(assertion.held)
    #expect(!assertion.displayHeld)

    #expect(assertion.setSystemHold(false, reason: "system release"))
    #expect(!assertion.held)
}

@Test func displayHoldIsIdempotent() {
    let assertion = IOKitPowerAssertion()
    #expect(assertion.setDisplayHold(true, reason: "first"))
    let id = assertion.displayAssertionID
    #expect(assertion.setDisplayHold(true, reason: "second"))
    #expect(assertion.displayAssertionID == id)
    #expect(assertion.setDisplayHold(false, reason: "cleanup"))
}

// MARK: - Important 3: a failed IOPMAssertionRelease must not be ignored

@Test func releaseFailureKeepsHeldTrueForTheNextTickToRetry() {
    let assertion = IOKitPowerAssertion()
    assertion.setSystemHold(true, reason: "regression test")
    #expect(assertion.held)

    // Force a REAL, deterministic IOKit release failure: release the
    // OS-level assertion out from under the class first (an ordinary,
    // unprivileged call — assertions are per-process and need no special
    // rights), so the class's own release of the SAME (now already-freed)
    // id fails for real, rather than simulating a failure through a mock.
    let id = assertion.assertionID
    #expect(IOPMAssertionRelease(id) == kIOReturnSuccess)

    assertion.setSystemHold(false, reason: "regression test")
    #expect(assertion.held)  // must stay true — nothing was silently forgotten
}

@Test func successfulReleaseClearsHeldNormally() {
    // Sanity check alongside the failure case above: the common path must
    // still work exactly as before.
    let assertion = IOKitPowerAssertion()
    assertion.setSystemHold(true, reason: "regression test")
    #expect(assertion.held)

    assertion.setSystemHold(false, reason: "regression test")
    #expect(!assertion.held)
}

@Test func setSystemHoldIsIdempotentWhenAlreadyHeld() {
    let assertion = IOKitPowerAssertion()
    assertion.setSystemHold(true, reason: "first")
    let id = assertion.assertionID
    assertion.setSystemHold(true, reason: "second")
    #expect(assertion.assertionID == id)  // no new assertion created

    assertion.setSystemHold(false, reason: "cleanup")
}
