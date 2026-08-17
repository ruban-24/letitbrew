import Foundation
import Testing
@testable import LetItBrewCore

private struct TransactionFilesystemFailure: Error {}

private func transactionFile(_ name: String, contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-transaction-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: file)
    return file
}

@Test func persistenceFailureLeavesVendorBytesUntouched() throws {
    let vendor = try transactionFile("vendor.json", contents: "original")
    defer { try? FileManager.default.removeItem(at: vendor.deletingLastPathComponent()) }
    #expect(throws: TransactionFilesystemFailure.self) {
        try AgentInstallTransaction.install(
            preflightPureTransform: { (try ExactFileCapture.capture(at: vendor), Data("replacement".utf8)) },
            persistExactTarget: { _ in throw TransactionFilesystemFailure() },
            commitVendorMutation: { capture, replacement in try AtomicFile.write(replacement, to: vendor, ifUnchangedFrom: capture) }
        )
    }
    #expect(try String(contentsOf: vendor, encoding: .utf8) == "original")
}

@Test func vendorFailureLeavesDurableRegistryRecord() throws {
    let vendor = try transactionFile("vendor.json", contents: "original")
    let registry = vendor.deletingLastPathComponent().appendingPathComponent("registry.json")
    defer { try? FileManager.default.removeItem(at: vendor.deletingLastPathComponent()) }
    #expect(throws: TransactionFilesystemFailure.self) {
        try AgentInstallTransaction.install(
            preflightPureTransform: { 1 },
            persistExactTarget: { _ in try Data("recorded-target".utf8).write(to: registry) },
            commitVendorMutation: { _ in throw TransactionFilesystemFailure() }
        )
    }
    #expect(try String(contentsOf: registry, encoding: .utf8) == "recorded-target")
    #expect(try String(contentsOf: vendor, encoding: .utf8) == "original")
}

@Test func registryPersistThenVendorComponentSwapRetainsRecordAndNeverTouchesOutside() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("descriptor-transaction-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vendor = root.appendingPathComponent(".claude/settings.json")
    try FileManager.default.createDirectory(at: vendor.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: vendor)
    let registry = root.appendingPathComponent("Library/Application Support/LetItBrew/agent-hook-targets.json")
    let anchor = try DirectoryAnchor.openNoFollow(at: root)
    let vendorObserved = try anchor.target(atAbsoluteURL: vendor).capture()
    var registryObserved = try anchor.target(atAbsoluteURL: registry).capture()
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("descriptor-outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    #expect(throws: Error.self) {
        try AgentInstallTransaction.install(
            preflightPureTransform: { vendorObserved },
            persistExactTarget: { _ in
                registryObserved = try AtomicFile.write(Data("recorded".utf8), replacing: registryObserved, permissions: .exact(0o600))
                try FileManager.default.removeItem(at: vendor.deletingLastPathComponent())
                try FileManager.default.createSymbolicLink(at: vendor.deletingLastPathComponent(), withDestinationURL: outside)
            },
            commitVendorMutation: { observed in _ = try AtomicFile.write(Data("updated".utf8), replacing: observed) })
    }
    #expect(try String(contentsOf: registry, encoding: .utf8) == "recorded")
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("settings.json").path))
}

@Test func removalFailureRetainsRegistryAndQuarantineReplacementSurvives() throws {
    let vendor = try transactionFile("owned", contents: "owned")
    let registry = vendor.deletingLastPathComponent().appendingPathComponent("registry.json")
    try Data("recorded-target".utf8).write(to: registry)
    defer { try? FileManager.default.removeItem(at: vendor.deletingLastPathComponent()) }
    #expect(throws: TransactionFilesystemFailure.self) {
        try AgentInstallTransaction.uninstall(
            removeOwnedOrProveAbsent: {
                try AtomicFile.remove(vendor, ifUnchangedFrom: Data("owned".utf8), afterQuarantine: { _ in
                    try Data("foreign replacement".utf8).write(to: vendor)
                    throw TransactionFilesystemFailure()
                })
            },
            clearExactTarget: { try FileManager.default.removeItem(at: registry) }
        )
    }
    #expect(try String(contentsOf: registry, encoding: .utf8) == "recorded-target")
    #expect(try String(contentsOf: vendor, encoding: .utf8) == "foreign replacement")
}

@Test func clearFailureLeavesStaleRecordThenAbsentRetryClearsWithoutVendorRewrite() throws {
    let vendor = try transactionFile("owned", contents: "owned")
    let registry = vendor.deletingLastPathComponent().appendingPathComponent("registry.json")
    try Data("recorded-target".utf8).write(to: registry)
    defer { try? FileManager.default.removeItem(at: vendor.deletingLastPathComponent()) }
    #expect(throws: TransactionFilesystemFailure.self) {
        try AgentInstallTransaction.uninstall(
            removeOwnedOrProveAbsent: { try AtomicFile.remove(vendor, ifUnchangedFrom: Data("owned".utf8)) },
            clearExactTarget: { throw TransactionFilesystemFailure() }
        )
    }
    #expect(!FileManager.default.fileExists(atPath: vendor.path))
    #expect(try String(contentsOf: registry, encoding: .utf8) == "recorded-target")
    try AgentInstallTransaction.uninstall(
        removeOwnedOrProveAbsent: { #expect(!FileManager.default.fileExists(atPath: vendor.path)) },
        clearExactTarget: { try FileManager.default.removeItem(at: registry) }
    )
    #expect(!FileManager.default.fileExists(atPath: registry.path))
}
