import Foundation
import IOKit.pwr_mgt

/// Holds the "prevent idle system sleep" assertion.
///
/// Note this does **not** cover lid-closed sleep: clamshell sleep ignores
/// power assertions entirely, which is why `OsascriptSleepWatchdog` exists.
public protocol PowerAsserting: AnyObject, Sendable {
    /// Idempotent: safe to call every tick with the same value. Returns
    /// whether the assertion ends this call in the requested state — the
    /// uninstall `releaseHolds` gate relies on this to notice a real
    /// `IOPMAssertionRelease` failure instead of it being silently discarded.
    @discardableResult
    func setSystemHold(_ on: Bool, reason: String) -> Bool
}

public final class IOKitPowerAssertion: PowerAsserting, @unchecked Sendable {
    private let lock = NSLock()
    // Visibility (not the state machine) relaxed to `internal` so tests can
    // force a genuine release failure by releasing the real assertion out
    // from under this class, then observe that `held` stayed true — see
    // `releaseFailureKeepsHeldTrueForTheNextTickToRetry` in
    // PowerAssertionsTests.swift. Setters stay private; only the getters are
    // testable.
    private(set) var assertionID: IOPMAssertionID = 0
    private(set) var held = false
    // The reason last applied to the live assertion's name — either at
    // creation or via a subsequent `IOPMAssertionSetProperty`. Tracked so the
    // property is only written when `reason` actually changed: this runs
    // once a second and a syscall every tick regardless would be wasted
    // churn.
    private var appliedReason = ""

    public init() {}

    @discardableResult
    public func setSystemHold(_ on: Bool, reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if on, !held {
            var newID: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &newID
            )
            // Leave `held` false on failure so a later tick retries instead
            // of the object believing it holds something it doesn't.
            guard status == kIOReturnSuccess else { return false }
            assertionID = newID
            held = true
            appliedReason = reason
        } else if on, held, reason != appliedReason {
            // The hold already exists; only its label is stale. Update the
            // name IN PLACE rather than releasing and recreating — a
            // release+recreate would leave a real window with no assertion
            // held at all, which is exactly the gap this class exists to
            // prevent. This matters because `pmset -g assertions` is the
            // canonical way a user answers "what's keeping my Mac awake";
            // leaving the name frozen at whatever was true when the hold was
            // first taken reports something actively false there.
            guard IOPMAssertionSetProperty(
                assertionID, kIOPMAssertionNameKey as CFString, reason as CFString
            ) == kIOReturnSuccess else {
                // Keep the assertion and `held` true either way — a stale
                // label is bad, but dropping the hold over a failed rename
                // would be far worse. Leave `appliedReason` alone so the
                // next tick retries the rename instead of believing it
                // already happened. The hold itself is still up, so this is
                // not a failure to report to the caller.
                return true
            }
            appliedReason = reason
        } else if !on, held {
            // IMPORTANT 3: only clear `held` on a CONFIRMED release. If the
            // release fails while the assertion is still valid, clearing
            // `held` anyway would make the watcher believe it let go when it
            // didn't, and nothing would ever retry — the assertion (and the
            // sleep-prevention it holds) would leak for the life of the
            // process.
            guard IOPMAssertionRelease(assertionID) == kIOReturnSuccess else { return false }
            assertionID = 0
            held = false
            appliedReason = ""
        }
        return held == on
    }

    deinit {
        if held { IOPMAssertionRelease(assertionID) }
    }
}
