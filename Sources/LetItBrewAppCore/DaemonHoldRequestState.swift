import Foundation

/// Identifies one hold request on one daemon connection generation.
public struct DaemonHoldRequestToken: Equatable, Sendable {
    fileprivate let connectionGeneration: UInt64
    fileprivate let requestID: UInt64
}

private struct DaemonHoldRequest: Sendable {
    let token: DaemonHoldRequestToken
    let desiredHold: Bool
    let startedAt: Date
}

/// Tracks the single allowed in-flight hold request without letting a late
/// completion from a replaced XPC connection disturb its replacement.
public struct DaemonHoldRequestState: Sendable {
    private var connectionGeneration: UInt64 = 0
    private var nextRequestID: UInt64 = 0
    private var currentRequest: DaemonHoldRequest?

    public private(set) var confirmedHold: Bool?
    public private(set) var releaseConfirmationRequired = false

    public init() {}

    public var isInFlight: Bool {
        currentRequest != nil
    }

    /// A successful explicit false response is the only daemon release
    /// confirmation. Failures, timeouts, and replaced connections cannot
    /// manufacture one.
    public var isReleaseConfirmed: Bool {
        confirmedHold == false && !releaseConfirmationRequired
    }

    /// Invalidates the old connection's request and permits the replacement
    /// to send immediately. Any late old completion retains its old token and
    /// is therefore ignored by `complete(_:)`.
    public mutating func replaceConnection() {
        if currentRequest != nil {
            releaseConfirmationRequired = true
        }
        connectionGeneration &+= 1
        currentRequest = nil
        confirmedHold = nil
    }

    /// Starts a request only when the current connection has none in flight.
    public mutating func beginRequest(
        desiredHold: Bool,
        at startedAt: Date
    ) -> DaemonHoldRequestToken? {
        guard currentRequest == nil else { return nil }
        nextRequestID &+= 1
        let token = DaemonHoldRequestToken(
            connectionGeneration: connectionGeneration,
            requestID: nextRequestID
        )
        currentRequest = DaemonHoldRequest(
            token: token,
            desiredHold: desiredHold,
            startedAt: startedAt
        )
        if desiredHold || confirmedHold != false {
            releaseConfirmationRequired = true
        }
        return token
    }

    /// Completes only the currently tracked request. A stale token cannot
    /// clear a newer connection's in-flight latch.
    @discardableResult
    public mutating func complete(
        _ token: DaemonHoldRequestToken,
        succeeded: Bool
    ) -> Bool {
        guard let request = currentRequest, request.token == token else { return false }
        currentRequest = nil
        guard succeeded else {
            confirmedHold = nil
            releaseConfirmationRequired = true
            return true
        }
        confirmedHold = request.desiredHold
        releaseConfirmationRequired = request.desiredHold
        return true
    }

    /// Expires a request through the caller's existing reconciliation cadence.
    /// Its token stays stale even if the same connection starts a retry.
    @discardableResult
    public mutating func expireRequestIfTimedOut(
        at now: Date,
        timeout: TimeInterval
    ) -> Bool {
        guard let request = currentRequest,
              now.timeIntervalSince(request.startedAt) >= timeout
        else { return false }
        currentRequest = nil
        confirmedHold = nil
        releaseConfirmationRequired = true
        return true
    }

    /// Prepares an attended release retry without disturbing a fresh request.
    /// Returns true only when the connection should be replaced: the current
    /// request timed out, or a prior failure still needs release confirmation.
    public mutating func prepareReleaseRetry(
        at now: Date,
        timeout: TimeInterval
    ) -> Bool {
        if currentRequest != nil {
            return expireRequestIfTimedOut(at: now, timeout: timeout)
        }
        return releaseConfirmationRequired
    }
}
