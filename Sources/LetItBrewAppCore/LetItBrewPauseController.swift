/// Persists the user's explicit choice to let the Mac sleep. The pause is
/// intentionally durable: Let It Brew must not silently resume after a relaunch.
public protocol LetItBrewPausePersisting: Sendable {
    func loadPause() -> Bool
    func savePause(_ isPaused: Bool)
}

/// The sleep holds Let It Brew may request after automatic policy and the
/// user's pause choice have both been applied.
public struct LetItBrewHoldIntent: Equatable, Sendable {
    public let system: Bool
    public let lidClosed: Bool
    public let display: Bool

    public init(system: Bool, lidClosed: Bool, display: Bool = false) {
        self.system = system
        self.lidClosed = lidClosed
        self.display = display
    }
}

/// Applies a persisted manual pause without affecting session observation.
/// Callers continue collecting and presenting sessions while this controller
/// suppresses only Let It Brew's two sleep holds.
public struct LetItBrewPauseController: Sendable {
    private let persistence: any LetItBrewPausePersisting
    public private(set) var isPaused: Bool

    public init(persistence: any LetItBrewPausePersisting) {
        self.persistence = persistence
        isPaused = persistence.loadPause()
    }

    public mutating func pause() {
        isPaused = true
        persistence.savePause(true)
    }

    public mutating func resume() {
        isPaused = false
        persistence.savePause(false)
    }

    public func resolve(
        systemHold: Bool,
        lidClosedHold: Bool,
        displayHold: Bool = false
    ) -> LetItBrewHoldIntent {
        guard !isPaused else {
            return LetItBrewHoldIntent(
                system: false,
                lidClosed: false,
                display: false
            )
        }
        return LetItBrewHoldIntent(
            system: systemHold,
            lidClosed: lidClosedHold,
            display: displayHold
        )
    }
}
