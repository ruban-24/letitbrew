import Foundation
import IOKit.ps

/// Reads battery and thermal state for the decision function.
public struct IOKitPowerSource: Sendable {
    public init() {}

    public func current() -> PowerState {
        let thermal = ProcessInfo.processInfo.thermalState

        // A desktop Mac (Mac mini, Mac Studio) has no battery, so the power
        // sources list is empty. That must read as "plugged in at 100%", not
        // "0% on battery" — the latter would make `decide` release the hold
        // immediately on exactly the headless machines this app targets.
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                  as? [CFTypeRef]
        else {
            // IMPORTANT 4: the API call itself failed here — this is not a
            // confirmed "no battery exists" (that's an empty `sources`
            // below), it's "battery state cannot be trusted". Reporting a
            // plugged-in/100% default un-flagged would bypass the battery
            // floor entirely on a laptop with a real, possibly draining
            // battery. Refuse rather than guess: mark untrusted and let
            // `decide()` take the conservative branch instead.
            return PowerState(onBattery: false, batteryPercent: 100, thermal: thermal, trusted: false)
        }

        if sources.isEmpty {
            // Confirmed empty: the OS reports no power sources at all, the
            // normal and trustworthy state on a desktop Mac. Keep the
            // default `trusted: true` — this is the case the plugged-in/100%
            // fallback exists for.
            return PowerState(onBattery: false, batteryPercent: 100, thermal: thermal)
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            // Validate state, capacity, and maximum together, not
            // independently: a missing/non-string state, a missing/
            // non-numeric capacity or maximum, a zero or negative maximum,
            // or a capacity outside [0, maximum] all mean this entry is
            // malformed, not that it's plugged-in-at-some-percentage. Skip
            // to the next source instead of returning a nonsense (possibly
            // negative, possibly >100, possibly trap-on-convert, or
            // wrongly-plugged-in) reading.
            guard let state = description[kIOPSPowerSourceStateKey] as? String,
                  state == kIOPSACPowerValue || state == kIOPSBatteryPowerValue
                      || state == kIOPSOffLineValue,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0,
                  0...maximum ~= capacity
            else { continue }

            let onBattery = state == kIOPSBatteryPowerValue
            // capacity/maximum are validated above (0 <= capacity <= maximum,
            // maximum > 0), so this ratio is always in [0, 1] and the Int
            // conversion can never trap. The clamp is belt-and-braces.
            let ratio = Double(capacity) / Double(maximum)
            let percent = min(100, max(0, Int((ratio * 100).rounded())))

            return PowerState(onBattery: onBattery, batteryPercent: percent, thermal: thermal)
        }

        // IMPORTANT 4: the OS reported at least one power source, but none
        // of them decoded. Unlike the empty-list case above, this is NOT a
        // confirmed "no battery" — it's a laptop (or similar) whose battery
        // entry exists but couldn't be read, which is precisely the
        // cannot-be-trusted case this fix exists to catch.
        return PowerState(onBattery: false, batteryPercent: 100, thermal: thermal, trusted: false)
    }
}
