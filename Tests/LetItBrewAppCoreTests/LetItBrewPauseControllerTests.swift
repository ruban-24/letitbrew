import Testing
@testable import LetItBrewAppCore

private final class PauseStore: LetItBrewPausePersisting, @unchecked Sendable {
    var storedValue: Bool

    init(_ storedValue: Bool = false) {
        self.storedValue = storedValue
    }

    func loadPause() -> Bool {
        storedValue
    }

    func savePause(_ isPaused: Bool) {
        storedValue = isPaused
    }
}

@Test func automaticHoldsPassThroughWhileLetItBrewIsRunning() {
    let controller = LetItBrewPauseController(persistence: PauseStore())

    #expect(!controller.isPaused)
    #expect(controller.resolve(systemHold: true, lidClosedHold: true, displayHold: true)
            == LetItBrewHoldIntent(system: true, lidClosed: true, display: true))
    #expect(controller.resolve(systemHold: true, lidClosedHold: false)
            == LetItBrewHoldIntent(system: true, lidClosed: false, display: false))
}

@Test func allowingSleepSuppressesAllHoldsAndPersistsAcrossRelaunch() {
    let store = PauseStore()
    var controller = LetItBrewPauseController(persistence: store)

    controller.pause()

    #expect(controller.isPaused)
    #expect(store.storedValue)
    for _ in 0..<5 {
        #expect(controller.resolve(systemHold: true, lidClosedHold: true, displayHold: true)
                == LetItBrewHoldIntent(system: false, lidClosed: false, display: false))
    }

    let relaunched = LetItBrewPauseController(persistence: store)
    #expect(relaunched.isPaused)
    #expect(relaunched.resolve(systemHold: true, lidClosedHold: true, displayHold: true)
            == LetItBrewHoldIntent(system: false, lidClosed: false, display: false))
}

@Test func explicitResumeClearsThePersistedPauseAndRestoresCurrentWorkHolds() {
    let store = PauseStore(true)
    var controller = LetItBrewPauseController(persistence: store)

    #expect(controller.resolve(systemHold: true, lidClosedHold: true)
            == LetItBrewHoldIntent(system: false, lidClosed: false, display: false))

    controller.resume()

    #expect(!controller.isPaused)
    #expect(!store.storedValue)
    #expect(controller.resolve(systemHold: true, lidClosedHold: true)
            == LetItBrewHoldIntent(system: true, lidClosed: true, display: false))

    let relaunched = LetItBrewPauseController(persistence: store)
    #expect(!relaunched.isPaused)
}

@Test func pauseSuppressesDisplayHoldToo() {
    let store = PauseStore()
    var controller = LetItBrewPauseController(persistence: store)
    controller.pause()

    #expect(controller.resolve(
        systemHold: true,
        lidClosedHold: true,
        displayHold: true
    ) == LetItBrewHoldIntent(system: false, lidClosed: false, display: false))
}
