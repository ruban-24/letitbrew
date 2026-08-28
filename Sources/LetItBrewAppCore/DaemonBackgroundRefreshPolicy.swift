public enum DaemonBackgroundRefreshAction: Equatable, Sendable {
    case none
    case synchronizeHold
    case recover
}

public enum DaemonBackgroundRefreshPolicy {
    public static func action(
        recoveryInFlight: Bool,
        handshakeInFlight: Bool,
        holdRequestInFlight: Bool,
        daemonAvailable: Bool
    ) -> DaemonBackgroundRefreshAction {
        guard !recoveryInFlight,
              !handshakeInFlight,
              !holdRequestInFlight
        else { return .none }

        return daemonAvailable ? .synchronizeHold : .recover
    }
}
