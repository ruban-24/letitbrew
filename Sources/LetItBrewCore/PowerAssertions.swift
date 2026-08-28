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

    @discardableResult
    func setDisplayHold(_ on: Bool, reason: String) -> Bool
}

private struct AssertionSlot {
    var id: IOPMAssertionID = 0
    var held = false
    var appliedReason = ""
}

public final class IOKitPowerAssertion: PowerAsserting, @unchecked Sendable {
    private let lock = NSLock()
    // Visibility (not the state machine) relaxed to `internal` so tests can
    // force a genuine release failure by releasing the real assertion out
    // from under this class, then observe that `held` stayed true — see
    // `releaseFailureKeepsHeldTrueForTheNextTickToRetry` in
    // PowerAssertionsTests.swift. Setters stay private; only the getters are
    // testable.
    private var systemSlot = AssertionSlot()
    private var displaySlot = AssertionSlot()

    var assertionID: IOPMAssertionID { systemSlot.id }
    var held: Bool { systemSlot.held }
    var displayAssertionID: IOPMAssertionID { displaySlot.id }
    var displayHeld: Bool { displaySlot.held }

    public init() {}

    @discardableResult
    public func setSystemHold(_ on: Bool, reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return Self.setHold(
            on,
            reason: reason,
            assertionType: kIOPMAssertPreventUserIdleSystemSleep as CFString,
            slot: &systemSlot
        )
    }

    @discardableResult
    public func setDisplayHold(_ on: Bool, reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return Self.setHold(
            on,
            reason: reason,
            assertionType: kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            slot: &displaySlot
        )
    }

    private static func setHold(
        _ on: Bool,
        reason: String,
        assertionType: CFString,
        slot: inout AssertionSlot
    ) -> Bool {
        if on, !slot.held {
            var newID: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                assertionType,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &newID
            )
            // Leave `held` false on failure so a later tick retries instead
            // of the object believing it holds something it doesn't.
            guard status == kIOReturnSuccess else { return false }
            slot.id = newID
            slot.held = true
            slot.appliedReason = reason
        } else if on, slot.held, reason != slot.appliedReason {
            // The hold already exists; only its label is stale. Update the
            // name IN PLACE rather than releasing and recreating — a
            // release+recreate would leave a real window with no assertion
            // held at all, which is exactly the gap this class exists to
            // prevent. This matters because `pmset -g assertions` is the
            // canonical way a user answers "what's keeping my Mac awake";
            // leaving the name frozen at whatever was true when the hold was
            // first taken reports something actively false there.
            guard IOPMAssertionSetProperty(
                slot.id, kIOPMAssertionNameKey as CFString, reason as CFString
            ) == kIOReturnSuccess else {
                // Keep the assertion and `held` true either way — a stale
                // label is bad, but dropping the hold over a failed rename
                // would be far worse. Leave `appliedReason` alone so the
                // next tick retries the rename instead of believing it
                // already happened. The hold itself is still up, so this is
                // not a failure to report to the caller.
                return true
            }
            slot.appliedReason = reason
        } else if !on, slot.held {
            // IMPORTANT 3: only clear `held` on a CONFIRMED release. If the
            // release fails while the assertion is still valid, clearing
            // `held` anyway would make the watcher believe it let go when it
            // didn't, and nothing would ever retry — the assertion (and the
            // sleep-prevention it holds) would leak for the life of the
            // process.
            guard IOPMAssertionRelease(slot.id) == kIOReturnSuccess else { return false }
            slot.id = 0
            slot.held = false
            slot.appliedReason = ""
        }
        return slot.held == on
    }

    deinit {
        if systemSlot.held { IOPMAssertionRelease(systemSlot.id) }
        if displaySlot.held { IOPMAssertionRelease(displaySlot.id) }
    }
}
