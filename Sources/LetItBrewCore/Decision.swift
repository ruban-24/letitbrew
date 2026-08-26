import Foundation

public struct Settings: Equatable, Sendable {
    /// Release below this charge, on battery only.
    public var batteryFloor: Int = 20
    public var onlyWhileConnectedToPower = false
    public var respectLowPowerMode = true
    public var allowDisplaysToSleep = true
    /// Whether lid-closed mode follows the session automatically.
    public var lidClosedFollowsSession: Bool = true
    /// Backstop eviction age for session records.
    public var staleTTL: TimeInterval = 12 * 3_600
    /// A working session with no newer hook event is presented as silent
    /// after this interval. Presentation only: it still holds the Mac awake.
    public var workingSilenceThreshold: TimeInterval = 120

    public init() {}
}

public struct PowerState: Equatable, Sendable {
    public var onBattery: Bool
    public var batteryPercent: Int
    public var thermal: ProcessInfo.ThermalState
    public var lowPowerModeEnabled: Bool
    /// False means this reading itself could not be trusted — an IOKit call
    /// FAILED outright, not "this machine confirmed it has no battery".
    /// Defaults to true so every plugged-in/100% reading (a confirmed-empty
    /// desktop source list, and every existing call site/test) is
    /// unaffected; only a genuine API failure sets it false. See IMPORTANT 4:
    /// `decide()` must not bypass the battery floor on an unknown reading.
    public var trusted: Bool

    public init(
        onBattery: Bool,
        batteryPercent: Int,
        thermal: ProcessInfo.ThermalState,
        lowPowerModeEnabled: Bool = false,
        trusted: Bool = true
    ) {
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermal = thermal
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.trusted = trusted
    }
}

public struct Decision: Equatable, Sendable {
    public var holdSystem: Bool
    public var holdLidClosed: Bool
    public var holdDisplay: Bool
    /// Human-readable explanation, shown in the menu and the status output.
    public var reason: String

    public init(holdSystem: Bool, holdLidClosed: Bool, holdDisplay: Bool = false, reason: String) {
        self.holdSystem = holdSystem
        self.holdLidClosed = holdLidClosed
        self.holdDisplay = holdDisplay
        self.reason = reason
    }
}

/// Decides whether to hold the Mac awake right now.
///
/// Pure on purpose: no clock, no IOKit, no file access. The caller supplies a
/// snapshot of real inputs once a second; tests use scripted sessions and
/// cover every rule without hardware or real waiting.
///
/// Precedence: safety guards first, then active work. Idle states never hold
/// the Mac awake.
public func decide(
    sessions: [SessionRecord],
    now: Date,
    settings: Settings,
    power: PowerState
) -> Decision {
    // 0. IMPORTANT 4: an untrusted reading must never be treated as a
    // confirmed "plugged in at 100%" — that would bypass the battery floor
    // below entirely. The standing rule is refuse-rather-than-guess, and the
    // safe direction here is the one that does NOT keep a laptop awake on an
    // unknown battery, so this takes precedence over everything else,
    // including active sessions.
    if !power.trusted {
        return Decision(holdSystem: false, holdLidClosed: false, reason: "battery state unknown")
    }

    // 1. Connected-only mode releases on any battery level.
    if settings.onlyWhileConnectedToPower, power.onBattery {
        return Decision(holdSystem: false, holdLidClosed: false, reason: "battery power")
    }

    // 2. Never flatten the battery, even mid-run.
    if power.onBattery, power.batteryPercent <= settings.batteryFloor {
        return Decision(holdSystem: false, holdLidClosed: false,
                        reason: "battery \(power.batteryPercent)%")
    }

    if settings.respectLowPowerMode, power.lowPowerModeEnabled {
        return Decision(holdSystem: false, holdLidClosed: false, reason: "low power mode")
    }

    // 3. A shut lid traps heat with no airflow, so thermal pressure wins.
    if power.thermal == .serious || power.thermal == .critical {
        return Decision(holdSystem: false, holdLidClosed: false,
                        reason: "thermal pressure")
    }

    // 3. Working sessions hold.
    let working = sessions.count { $0.state == .working }
    if working > 0 {
        return Decision(
            holdSystem: true,
            holdLidClosed: settings.lidClosedFollowsSession,
            holdDisplay: !settings.allowDisplaysToSleep,
            reason: "\(working) working"
        )
    }

    // 4. Completion has no grace period. The app applies this snapshot on its
    // existing one-second poll, so Stop/SessionEnd releases on the next poll.
    guard !sessions.isEmpty else {
        return Decision(holdSystem: false, holdLidClosed: false, reason: "no agent sessions")
    }
    return Decision(holdSystem: false, holdLidClosed: false, reason: "all agents idle")
}
