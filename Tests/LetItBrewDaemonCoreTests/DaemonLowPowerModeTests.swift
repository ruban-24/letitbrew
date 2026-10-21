import Foundation
import Testing
import LetItBrewCore
@testable import LetItBrewDaemonCore

private final class MemorySleepDebtStore: DaemonSleepDebtStoring {
    var state: DaemonSleepDebtState = .none

    func load() -> DaemonSleepDebtState { state }

    func save(_ debt: DaemonSleepDebt) -> Bool {
        state = .valid(debt)
        return true
    }

    func remove() -> Bool {
        state = .none
        return true
    }
}

private final class MemorySleepControl: DaemonSleepSettingControlling {
    var live = false

    func readDisabled() -> Bool? { live }

    func writeDisabled(_ disabled: Bool) -> Bool {
        live = disabled
        return true
    }
}

private final class FakePowerModeDebtStore: DaemonPowerModeDebtStoring {
    var state: DaemonPowerModeDebtState
    var saveSucceeds = true
    var removeSucceeds = true

    init(state: DaemonPowerModeDebtState = .none) {
        self.state = state
    }

    func load() -> DaemonPowerModeDebtState { state }

    func save(_ debt: DaemonPowerModeDebt) -> Bool {
        guard saveSucceeds else { return false }
        state = .valid(debt)
        return true
    }

    func remove() -> Bool {
        guard removeSucceeds else { return false }
        state = .none
        return true
    }
}

private final class FakePowerModeControl: DaemonPowerModeControlling {
    var live: PowerModeSnapshot?
    var failingWrites: Set<PowerModeSource> = []
    var writesStick = true
    var writes: [String] = []

    init(live: PowerModeSnapshot?) {
        self.live = live
    }

    func readPowerModes() -> PowerModeSnapshot? { live }

    func writePowerMode(_ value: PowerModeValue, for source: PowerModeSource) -> Bool {
        writes.append("\(source.rawValue):\(value.key)=\(value.value)")
        guard !failingWrites.contains(source) else { return false }
        if writesStick { live?[source] = value }
        return true
    }
}

private func mode(_ value: Int, key: String = "powermode") -> PowerModeValue {
    PowerModeValue(key: key, value: value)
}

private let laptop = PowerModeSnapshot(battery: mode(0), charger: mode(2))

private struct Harness {
    let sleepDebt = MemorySleepDebtStore()
    let sleep = MemorySleepControl()
    let debt: FakePowerModeDebtStore
    let power: FakePowerModeControl
    let coordinator: DaemonHoldCoordinator

    init(live: PowerModeSnapshot? = laptop, debt: DaemonPowerModeDebtState = .none) {
        self.debt = FakePowerModeDebtStore(state: debt)
        power = FakePowerModeControl(live: live)
        coordinator = DaemonHoldCoordinator(
            debtStore: sleepDebt,
            sleepControl: sleep,
            powerModeDebtStore: self.debt,
            powerModeControl: power,
            now: { Date(timeIntervalSince1970: 50) }
        )
    }
}

@Test func lowPowerModeRequiresTheClientsOwnLidClosedHold() {
    let harness = Harness()
    let client = UUID()
    let other = UUID()

    #expect(harness.coordinator.setLowPowerMode(true, for: client)
        == .failed("Low Power Mode requires this client's lid-closed hold."))
    #expect(harness.power.writes.isEmpty)

    #expect(harness.coordinator.setHold(true, for: other) == .applied)
    #expect(harness.coordinator.setLowPowerMode(true, for: client) != .applied(personalSources: []))
    #expect(harness.power.live == laptop)
}

@Test func lowPowerModeRecordsEachSourceBeforeSwitchingAndRestoresItExactly() {
    let harness = Harness()
    let client = UUID()

    #expect(harness.coordinator.setHold(true, for: client) == .applied)
    #expect(harness.coordinator.setLowPowerMode(true, for: client) == .applied(personalSources: []))
    #expect(harness.debt.state == .valid(DaemonPowerModeDebt(
        prior: laptop, setAt: Date(timeIntervalSince1970: 50)
    )))
    #expect(harness.power.live == PowerModeSnapshot(battery: mode(1), charger: mode(1)))
    #expect(harness.coordinator.lowPowerHoldCount == 1)

    #expect(harness.coordinator.setLowPowerMode(false, for: client) == .applied(personalSources: []))
    #expect(harness.power.live == laptop)
    #expect(harness.debt.state == .none)
    // The lid-closed hold is untouched by the nested release.
    #expect(harness.coordinator.holdCount == 1)
    #expect(harness.sleep.live)
}

@Test func releasingTheLidClosedHoldReleasesItsLowPowerModeFirst() {
    let harness = Harness()
    let client = UUID()
    _ = harness.coordinator.setHold(true, for: client)
    _ = harness.coordinator.setLowPowerMode(true, for: client)

    #expect(harness.coordinator.setHold(false, for: client) == .applied)
    #expect(harness.power.live == laptop)
    #expect(harness.debt.state == .none)
    #expect(!harness.sleep.live)
    #expect(harness.coordinator.lowPowerHoldCount == 0)
}

@Test func aDisconnectRestoresTheEnergyMode() {
    let harness = Harness()
    let client = UUID()
    _ = harness.coordinator.setHold(true, for: client)
    _ = harness.coordinator.setLowPowerMode(true, for: client)

    harness.coordinator.connectionInvalidated(client)
    #expect(harness.power.live == laptop)
    #expect(harness.debt.state == .none)
}

@Test func lowPowerHoldsUnionAcrossClientsAndTheLastRestores() {
    let harness = Harness()
    let first = UUID()
    let second = UUID()
    for client in [first, second] {
        _ = harness.coordinator.setHold(true, for: client)
        #expect(harness.coordinator.setLowPowerMode(true, for: client) == .applied(personalSources: []))
    }
    #expect(harness.power.writes.count == 2)

    _ = harness.coordinator.setLowPowerMode(false, for: first)
    #expect(harness.power.live?.isLowPowerEverywhere == true)
    _ = harness.coordinator.setLowPowerMode(false, for: second)
    #expect(harness.power.live == laptop)
}

@Test func alreadyLowSourcesAreNotRewrittenAndStayLowAfterRelease() {
    let personal = PowerModeSnapshot(
        battery: mode(1, key: "lowpowermode"), charger: mode(0, key: "lowpowermode")
    )
    let harness = Harness(live: personal)
    let client = UUID()
    _ = harness.coordinator.setHold(true, for: client)
    #expect(harness.coordinator.setLowPowerMode(true, for: client)
        == .applied(personalSources: [.battery]))
    #expect(harness.power.writes == ["charger:lowpowermode=1"])
    // A later client learns the same personal sources from the record.
    let second = UUID()
    _ = harness.coordinator.setHold(true, for: second)
    #expect(harness.coordinator.setLowPowerMode(true, for: second)
        == .applied(personalSources: [.battery]))

    _ = harness.coordinator.setLowPowerMode(false, for: client)
    _ = harness.coordinator.setLowPowerMode(false, for: second)
    #expect(harness.power.live == personal)
}

@Test func aDesktopSwitchesOnlyItsChargerSource() {
    let desktop = PowerModeSnapshot(charger: mode(0))
    let harness = Harness(live: desktop)
    let client = UUID()
    _ = harness.coordinator.setHold(true, for: client)
    #expect(harness.coordinator.setLowPowerMode(true, for: client) == .applied(personalSources: []))
    #expect(harness.power.writes == ["charger:powermode=1"])
}

@Test func unreadableOrUnsupportedEnergyModesAreRefusedWithoutWriting() {
    for live in [nil, PowerModeSnapshot()] as [PowerModeSnapshot?] {
        let harness = Harness(live: live)
        let client = UUID()
        _ = harness.coordinator.setHold(true, for: client)
        #expect(harness.coordinator.setLowPowerMode(true, for: client) != .applied(personalSources: []))
        #expect(harness.power.writes.isEmpty)
        #expect(harness.debt.state == .none)
        #expect(harness.coordinator.holdCount == 1)
    }
}

@Test func anUnsavedRestoreRecordPreventsAnySwitch() {
    let harness = Harness()
    harness.debt.saveSucceeds = false
    let client = UUID()
    _ = harness.coordinator.setHold(true, for: client)
    #expect(harness.coordinator.setLowPowerMode(true, for: client)
        == .failed("Could not persist the energy mode restore record."))
    #expect(harness.power.writes.isEmpty)
}

@Test func aPartialSwitchIsRolledBackFromTheRecord() {
    let harness = Harness()
    harness.power.failingWrites = [.charger]
    let client = UUID()
    _ = harness.coordinator.setHold(true, for: client)

    #expect(harness.coordinator.setLowPowerMode(true, for: client)
        == .failed("Could not switch to Low Power Mode."))
    #expect(harness.power.live == laptop)
    #expect(harness.debt.state == .none)
    #expect(harness.coordinator.lowPowerHoldCount == 0)
    // Low Power Mode failures never cost the lid-closed hold.
    #expect(harness.coordinator.holdCount == 1)
    #expect(harness.sleep.live)
}

@Test func aSwitchThatDoesNotStickIsRefused() {
    let harness = Harness()
    harness.power.writesStick = false
    let client = UUID()
    _ = harness.coordinator.setHold(true, for: client)
    #expect(harness.coordinator.setLowPowerMode(true, for: client)
        == .failed("Could not confirm Low Power Mode."))
    #expect(harness.debt.state == .none)
}

@Test func aFailedRestoreKeepsTheRecordAndTheNextHandshakeRetries() {
    let harness = Harness()
    let client = UUID()
    _ = harness.coordinator.setHold(true, for: client)
    _ = harness.coordinator.setLowPowerMode(true, for: client)

    harness.power.failingWrites = [.battery]
    #expect(harness.coordinator.setHold(false, for: client) == .applied)
    #expect(!harness.sleep.live)
    guard case .valid = harness.debt.state else {
        Issue.record("The restore record must survive a failed restore")
        return
    }

    harness.power.failingWrites = []
    #expect(harness.coordinator.reconciliationReadiness() == .ready)
    #expect(harness.power.live == laptop)
    #expect(harness.debt.state == .none)
}

@Test func thePeriodicReleaseConfirmationRetriesAFailedRestore() {
    let harness = Harness()
    let client = UUID()
    _ = harness.coordinator.setHold(true, for: client)
    _ = harness.coordinator.setLowPowerMode(true, for: client)
    harness.power.failingWrites = [.charger]
    _ = harness.coordinator.setHold(false, for: client)
    #expect(harness.power.live?.charger == mode(1))

    harness.power.failingWrites = []
    #expect(harness.coordinator.setHold(false, for: client) == .applied)
    #expect(harness.power.live == laptop)
    #expect(harness.debt.state == .none)
}

@Test func anExplicitLowPowerReleaseReportsAndRetriesAFailedRestore() {
    let harness = Harness()
    let client = UUID()
    _ = harness.coordinator.setHold(true, for: client)
    _ = harness.coordinator.setLowPowerMode(true, for: client)
    harness.power.failingWrites = [.battery]
    #expect(harness.coordinator.setLowPowerMode(false, for: client)
        == .failed("Could not restore the energy mode; the restore record remains."))

    harness.power.failingWrites = []
    #expect(harness.coordinator.setLowPowerMode(false, for: client) == .applied(personalSources: []))
    #expect(harness.power.live == laptop)
}

@Test func anotherClientsReleaseCannotRestoreAnActiveSwitch() {
    let harness = Harness()
    let owner = UUID()
    _ = harness.coordinator.setHold(true, for: owner)
    _ = harness.coordinator.setLowPowerMode(true, for: owner)
    #expect(harness.coordinator.setLowPowerMode(false, for: UUID()) == .applied(personalSources: []))
    #expect(harness.coordinator.setHold(false, for: UUID()) == .applied)
    #expect(harness.power.live?.isLowPowerEverywhere == true)
    #expect(harness.coordinator.lowPowerHoldCount == 1)
}

@Test func launchRestoresARecordedEnergyMode() {
    let debt = DaemonPowerModeDebt(prior: laptop, setAt: Date(timeIntervalSince1970: 1))
    let harness = Harness(
        live: PowerModeSnapshot(battery: mode(1), charger: mode(1)), debt: .valid(debt)
    )
    #expect(harness.coordinator.reconcilePowerModeAtLaunch() == .restored(priorValue: false))
    #expect(harness.power.live == laptop)
    #expect(harness.debt.state == .none)
}

@Test func launchClearsARecordWhosePriorValuesAreAlreadyLive() {
    let debt = DaemonPowerModeDebt(prior: laptop, setAt: Date(timeIntervalSince1970: 1))
    let harness = Harness(live: laptop, debt: .valid(debt))
    #expect(harness.coordinator.reconcilePowerModeAtLaunch()
        == .clearedAlreadyRestored(priorValue: false))
    #expect(harness.power.writes.isEmpty)
}

@Test func anUnreadableEnergyRecordIsClearedWithoutGuessingAValue() {
    let harness = Harness(
        live: PowerModeSnapshot(battery: mode(1), charger: mode(1)), debt: .unreadable
    )
    #expect(harness.coordinator.reconcilePowerModeAtLaunch()
        == .clearedAlreadyRestored(priorValue: false))
    #expect(harness.power.writes.isEmpty)
    #expect(harness.debt.state == .none)
}

@Test func anUnresolvedEnergyRecordNeverBlocksTheLidClosedHold() {
    let debt = DaemonPowerModeDebt(prior: laptop, setAt: Date(timeIntervalSince1970: 1))
    let harness = Harness(live: nil, debt: .valid(debt))
    #expect(harness.coordinator.reconcilePowerModeAtLaunch() != .clean)
    let client = UUID()
    #expect(harness.coordinator.reconciliationReadiness() == .ready)
    #expect(harness.coordinator.setHold(true, for: client) == .applied)
    #expect(harness.sleep.live)
    #expect(harness.coordinator.setLowPowerMode(true, for: client) != .applied(personalSources: []))
}

@Test func upgradePreparationRestoresOrRefusesALeftoverEnergyMode() {
    let debt = DaemonPowerModeDebt(prior: laptop, setAt: Date(timeIntervalSince1970: 1))
    let restorable = Harness(
        live: PowerModeSnapshot(battery: mode(1), charger: mode(1)), debt: .valid(debt)
    )
    #expect(restorable.coordinator.prepareForUpgrade() == .ready(baseline: false))
    #expect(restorable.power.live == laptop)

    // A restore that still fails never blocks an upgrade or uninstall; the
    // record stays for the next daemon's launch.
    let stuck = Harness(live: nil, debt: .valid(debt))
    #expect(stuck.coordinator.prepareForUpgrade() == .ready(baseline: false))
    #expect(stuck.debt.state == .valid(debt))
}

@Test func aRecordSavedUnderTheOlderNameRestoresAfterARename() {
    let older = PowerModeSnapshot(
        battery: mode(0, key: "lowpowermode"), charger: mode(0, key: "lowpowermode")
    )
    let debt = DaemonPowerModeDebt(prior: older, setAt: Date(timeIntervalSince1970: 1))
    let harness = Harness(
        live: PowerModeSnapshot(battery: mode(1), charger: mode(1)), debt: .valid(debt)
    )
    #expect(harness.coordinator.reconcilePowerModeAtLaunch() == .restored(priorValue: false))
    #expect(harness.power.writes == ["battery:powermode=0", "charger:powermode=0"])
    #expect(harness.power.live == PowerModeSnapshot(battery: mode(0), charger: mode(0)))
    #expect(harness.debt.state == .none)
}

@Test func aRenamedSettingWithTheRecordedValueNeedsNoWrite() {
    let older = PowerModeSnapshot(battery: mode(0, key: "lowpowermode"))
    let debt = DaemonPowerModeDebt(prior: older, setAt: Date(timeIntervalSince1970: 1))
    let harness = Harness(live: PowerModeSnapshot(battery: mode(0)), debt: .valid(debt))
    #expect(harness.coordinator.reconcilePowerModeAtLaunch()
        == .clearedAlreadyRestored(priorValue: false))
    #expect(harness.power.writes.isEmpty)
}

@Test func lowPowerRepliesEncodePersonalSourcesForXPC() {
    #expect(DaemonLowPowerHoldResult.applied(personalSources: []).reply.personalSources == 0)
    #expect(DaemonLowPowerHoldResult.applied(personalSources: [.battery]).reply.personalSources == 1)
    #expect(DaemonLowPowerHoldResult.applied(personalSources: [.battery, .charger])
        .reply.personalSources == 3)
    #expect(DaemonLowPowerHoldResult.failed("no").reply == (false, "no", -1))
    #expect(PowerModeSource.sources(fromMask: 2) == [.charger])
    #expect(PowerModeSource.sources(fromMask: -1) == [])
}

@Test func quiescingRefusesNewLowPowerModeHolds() {
    let harness = Harness()
    #expect(harness.coordinator.prepareForUpgrade() == .ready(baseline: false))
    #expect(harness.coordinator.setLowPowerMode(true, for: UUID())
        == .failed("The daemon is quiescing for an upgrade and cannot switch to Low Power Mode."))
}

@Test func aDaemonWithoutPowerModeControlRefusesTheSwitch() {
    let coordinator = DaemonHoldCoordinator(
        debtStore: MemorySleepDebtStore(), sleepControl: MemorySleepControl()
    )
    let client = UUID()
    _ = coordinator.setHold(true, for: client)
    #expect(coordinator.setLowPowerMode(true, for: client)
        == .failed("This daemon cannot change Low Power Mode."))
}

@Test func powerModeRecordsRoundTripThroughTheFileStore() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-power-debt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileDaemonPowerModeDebtStore(url: directory.appendingPathComponent("debt.json"))
    #expect(store.load() == .none)

    let debt = DaemonPowerModeDebt(prior: laptop, setAt: Date(timeIntervalSince1970: 7))
    #expect(store.save(debt))
    #expect(store.load() == .valid(debt))
    let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    try Data("{}".utf8).write(to: store.url)
    #expect(store.load() == .unreadable)
    #expect(store.remove())
    #expect(store.remove())
}
