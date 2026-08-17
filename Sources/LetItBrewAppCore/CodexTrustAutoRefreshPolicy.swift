public enum CodexTrustAutoRefreshPolicy {
    public static func shouldRefresh(
        state: AgentConnectionState,
        disposition: AgentConnectionDisposition,
        isCodexSelected: Bool
    ) -> Bool {
        guard isCodexSelected, disposition == .managed else { return false }
        return state == .actionNeeded || state == .couldNotConnect
    }
}
