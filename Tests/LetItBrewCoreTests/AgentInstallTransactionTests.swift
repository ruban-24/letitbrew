import Testing
@testable import LetItBrewCore
@Test func transactionOrdersInstallBoundaries() throws { var calls: [String] = []; try AgentInstallTransaction.install(preflightPureTransform: { calls.append("preflight"); return 1 }, persistExactTarget: { _ in calls.append("persist") }, commitVendorMutation: { _ in calls.append("commit") }); #expect(calls == ["preflight", "persist", "commit"]) }
@Test func transactionDoesNotCommitAfterPersistenceFailure() { var committed = false; #expect(throws: TestFailure.self) { try AgentInstallTransaction.install(preflightPureTransform: { 1 }, persistExactTarget: { _ in throw TestFailure() }, commitVendorMutation: { _ in committed = true }) }; #expect(!committed) }
@Test func transactionOrdersUninstallBoundaries() throws { var calls: [String] = []; try AgentInstallTransaction.uninstall(removeOwnedOrProveAbsent: { calls.append("remove") }, clearExactTarget: { calls.append("clear") }); #expect(calls == ["remove", "clear"]) }
private struct TestFailure: Error {}
