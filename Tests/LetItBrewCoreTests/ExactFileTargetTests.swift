import Foundation
import Testing
@testable import LetItBrewCore
import Darwin

private func anchoredRoot() throws -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("exact-target-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }

/// Changes a file's bytes in place while deliberately putting the original
/// nanosecond mtime back.  This proves the descriptor publication path does
/// not reduce exact evidence to a size/mtime check.
private func overwriteInPlacePreservingModificationTime(_ url: URL, with data: Data) throws {
    let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var prior = stat()
    guard fstat(fd, &prior) == 0 else { throw POSIXError(.EIO) }
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = pwrite(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, off_t(offset))
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
    }
    guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    var timestamps = [prior.st_atimespec, prior.st_mtimespec]
    guard utimensat(AT_FDCWD, url.path, &timestamps, 0) == 0 else { throw POSIXError(.EIO) }
}

private func recoveryContents(in root: URL, marker: String) throws -> String? {
    guard let name = try FileManager.default.contentsOfDirectory(atPath: root.path).first(where: { $0.contains(marker) }) else { return nil }
    return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
}

private func replaceNamedEntry(in root: URL, name: String, with contents: String) throws {
    let entry = root.appendingPathComponent(name)
    try FileManager.default.removeItem(at: entry)
    try Data(contents.utf8).write(to: entry)
}

private func changedExpectedCapture(_ captured: CapturedExactFile, snapshot: ExactFileSnapshot? = nil, data: Data? = nil) -> CapturedExactFile {
    CapturedExactFile(
        target: captured.target,
        capture: ExactFileCapture(snapshot: snapshot ?? captured.snapshot, data: data ?? captured.data),
        parent: captured.parent,
        name: captured.name,
        permissions: captured.permissions)
}

@Test func anchorRejectsMissingNonDirectoryAndSymlinkRoots() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: Error.self) { try DirectoryAnchor.openNoFollow(at: root.appendingPathComponent("missing")) }
    let file = root.appendingPathComponent("file"); try Data().write(to: file)
    #expect(throws: Error.self) { try DirectoryAnchor.openNoFollow(at: file) }
    let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    #expect(throws: Error.self) { try DirectoryAnchor.openNoFollow(at: link) }
}

@Test func anchorCapturesOneDescriptorBeneathRootAndRefusesParentSymlink() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("a/b"); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let file = parent.appendingPathComponent("config.json"); try Data("value".utf8).write(to: file)
    let anchor = try DirectoryAnchor.openNoFollow(at: root)
    let observed = try anchor.target(atAbsoluteURL: file).capture()
    #expect(observed.data == Data("value".utf8)); #expect(observed.snapshot.path == file.standardizedFileURL.path)
    let outside = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.removeItem(at: parent)
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
    #expect(throws: Error.self) { try anchor.target(atAbsoluteURL: file).capture() }
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("config.json").path))
}

@Test func descriptorWriteAndRemoveUseTheCapturedParent() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("old".utf8).write(to: file)
    let target = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file)
    let observed = try target.capture()
    let published = try AtomicFile.write(Data("new".utf8), replacing: observed)
    #expect(published.data == Data("new".utf8))
    try AtomicFile.remove(published, expectedData: Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func descriptorWritePreservesCapturedModeAndDefaultsNewFilesToPrivate() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let existing = root.appendingPathComponent("existing"); try Data("old".utf8).write(to: existing)
    guard chmod(existing.path, 0o640) == 0 else { throw POSIXError(.EIO) }
    let existingCapture = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: existing).capture()
    _ = try AtomicFile.write(Data("new".utf8), replacing: existingCapture)
    var existingInfo = stat(); guard lstat(existing.path, &existingInfo) == 0 else { throw POSIXError(.EIO) }
    #expect(existingInfo.st_mode & 0o7777 == 0o640)

    let fresh = root.appendingPathComponent("fresh")
    let freshCapture = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: fresh).capture()
    _ = try AtomicFile.write(Data("new".utf8), replacing: freshCapture)
    var freshInfo = stat(); guard lstat(fresh.path, &freshInfo) == 0 else { throw POSIXError(.EIO) }
    #expect(freshInfo.st_mode & 0o7777 == 0o600)
}

@Test func anchoredAbsentCaptureCreatesMissingParentsOnlyDuringDescriptorPublication() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let targetURL = root.appendingPathComponent("Library/Application Support/LetItBrew/registry.json")
    let target = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: targetURL)
    let absent = try target.capture()
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
    let published = try AtomicFile.write(Data("registry".utf8), replacing: absent, permissions: .exact(0o600))
    #expect(published.snapshot.path == targetURL.standardizedFileURL.path)
    #expect(published.data == Data("registry".utf8))
    #expect(try String(contentsOf: targetURL, encoding: .utf8) == "registry")
}

@Test func anchoredMissingParentEEXISTAcceptsRealDirectoryAndRefusesSymlink() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let targetURL = root.appendingPathComponent("a/b/registry.json")
    let target = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: targetURL)
    let real = try target.captureForWrite(hooks: .init(afterComponentReportedMissingBeforeMkdir: { index in
        if index == 0 { try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: false) }
    }))
    #expect(!real.snapshot.exists)

    let secondRoot = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: secondRoot) }
    let outside = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: outside) }
    let secondURL = secondRoot.appendingPathComponent("a/b/registry.json")
    let second = try DirectoryAnchor.openNoFollow(at: secondRoot).target(atAbsoluteURL: secondURL)
    #expect(throws: Error.self) {
        _ = try second.captureForWrite(hooks: .init(afterComponentReportedMissingBeforeMkdir: { index in
            if index == 0 { try FileManager.default.createSymbolicLink(at: secondRoot.appendingPathComponent("a"), withDestinationURL: outside) }
        }))
    }
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("b/registry.json").path))
}

@Test func descriptorWriteRefusesComponentSwapAfterCaptureWithoutTouchingDestination() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("a/b"); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let file = parent.appendingPathComponent("registry.json"); try Data("old".utf8).write(to: file)
    let target = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file)
    let observed = try target.capture()
    let outside = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.removeItem(at: root.appendingPathComponent("a"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a"), withDestinationURL: outside)
    #expect(throws: Error.self) { _ = try AtomicFile.write(Data("new".utf8), replacing: observed) }
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("b/registry.json").path))
}

@Test func descriptorRemoveRefusesComponentSwapAfterCaptureWithoutTouchingDestination() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("a/b"); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let file = parent.appendingPathComponent("settings.json"); try Data("owned".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    let outside = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.removeItem(at: root.appendingPathComponent("a"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a"), withDestinationURL: outside)
    #expect(throws: Error.self) { try AtomicFile.remove(observed, expectedData: Data("owned".utf8)) }
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("b/settings.json").path))
}

@Test func descriptorWriteKeepsOriginalAnchoredRootWhenDisplayPathIsReplaced() throws {
    let container = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: container) }
    let root = container.appendingPathComponent("root"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("registry.json"); try Data("old".utf8).write(to: file)
    let target = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file)
    let observed = try target.capture()
    let retainedRoot = container.appendingPathComponent("retained-root")
    let outside = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.moveItem(at: root, to: retainedRoot)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
    _ = try AtomicFile.write(Data("new".utf8), replacing: observed)
    #expect(try String(contentsOf: retainedRoot.appendingPathComponent("registry.json"), encoding: .utf8) == "new")
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("registry.json").path))
}

@Test func anchoredRegistryTargetRefusesSymlinkAtEveryParentPosition() throws {
    for swapped in ["Library", "Application Support", "LetItBrew"] {
        let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Library/Application Support/LetItBrew")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let registry = parent.appendingPathComponent("agent-hook-targets.json")
        try Data("registry".utf8).write(to: registry)
        let components = ["Library", "Application Support", "LetItBrew"]
        let index = components.firstIndex(of: swapped)!
        let componentURL = components.prefix(index + 1).reduce(root) { $0.appendingPathComponent($1) }
        let outside = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: componentURL)
        try FileManager.default.createSymbolicLink(at: componentURL, withDestinationURL: outside)
        let target = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: registry)
        #expect(throws: Error.self, "\(swapped)") { _ = try target.capture() }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("agent-hook-targets.json").path))
    }
}

@Test func descriptorSuccessivePublicationsUseReturnedBoundBaselineAndDisplayPath() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("registry.json")
    let target = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: url)
    var baseline = try target.capture()
    baseline = try AtomicFile.write(Data("one".utf8), replacing: baseline, permissions: .exact(0o600))
    baseline = try AtomicFile.write(Data("two".utf8), replacing: baseline, permissions: .exact(0o600))
    #expect(baseline.snapshot.path == url.standardizedFileURL.path)
    #expect(!baseline.snapshot.path.contains("/dev/fd/"))
    #expect(try String(contentsOf: url, encoding: .utf8) == "two")
}

@Test func anchoredJSONFinalSymlinkResolvesOnceToRegularTarget() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let configured = root.appendingPathComponent(".claude/settings.json")
    let final = root.appendingPathComponent("managed/settings.json")
    try FileManager.default.createDirectory(at: configured.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: final)
    try FileManager.default.createSymbolicLink(at: configured, withDestinationURL: URL(fileURLWithPath: "../managed/settings.json", relativeTo: configured.deletingLastPathComponent()))
    let resolved = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: configured).resolvingAnchoredFinalSymlink()
    #expect(resolved.displayPath == final.standardizedFileURL.path)
    #expect(try resolved.capture().data == Data("{}".utf8))
}

@Test func anchoredJSONFinalSymlinkRefusesDanglingOutsideAndLoopTargets() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent(".claude"); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let anchor = try DirectoryAnchor.openNoFollow(at: root)
    let dangling = parent.appendingPathComponent("dangling.json")
    try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: URL(fileURLWithPath: "missing.json", relativeTo: parent))
    #expect(throws: Error.self) { _ = try anchor.target(atAbsoluteURL: dangling).resolvingAnchoredFinalSymlink() }
    let outside = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: outside) }
    let outsideLink = parent.appendingPathComponent("outside.json")
    try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: outside.appendingPathComponent("settings.json"))
    #expect(throws: Error.self) { _ = try anchor.target(atAbsoluteURL: outsideLink).resolvingAnchoredFinalSymlink() }
    let loop = parent.appendingPathComponent("loop.json")
    try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: URL(fileURLWithPath: "loop.json", relativeTo: parent))
    #expect(throws: Error.self) { _ = try anchor.target(atAbsoluteURL: loop).resolvingAnchoredFinalSymlink(maximumHops: 2) }
}

@Test func anchoredOpenCodeFinalSymlinkIsRefusedWithoutJSONResolution() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let plugin = root.appendingPathComponent(".config/opencode/plugin/letitbrew.ts")
    try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
    let final = root.appendingPathComponent("foreign.ts"); try Data("foreign".utf8).write(to: final)
    try FileManager.default.createSymbolicLink(at: plugin, withDestinationURL: final)
    #expect(throws: Error.self) { _ = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: plugin).capture() }
    #expect(try String(contentsOf: final, encoding: .utf8) == "foreign")
}

@Test func anchoredTraversalRefusesEveryParentPositionForAllFiveVendorTargets() throws {
    let targets: [[String]] = [
        [".claude", "settings.json"],
        [".codex", "hooks.json"],
        [".cursor", "hooks.json"],
        [".config", "opencode", "plugins", "letitbrew.js"],
        [".copilot", "hooks", "letitbrew.json"]
    ]
    for components in targets {
        for parentCount in 1..<components.count {
            let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let targetURL = components.reduce(root) { $0.appendingPathComponent($1) }
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("owned".utf8).write(to: targetURL)
            let swapped = components.prefix(parentCount).reduce(root) { $0.appendingPathComponent($1) }
            let outside = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.removeItem(at: swapped)
            try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: outside)
            let target = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: targetURL)
            #expect(throws: Error.self, "\(components.joined(separator: "/")) parent \(parentCount)") { _ = try target.capture() }
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent(components.last!).path))
        }
    }
}

@Test func ordinaryTargetsPreserveProductionParentSymlinkCompatibility() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let realParent = root.appendingPathComponent("real"); try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
    let final = realParent.appendingPathComponent("settings.json"); try Data("{}".utf8).write(to: final)
    let linkedParent = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
    let ordinary = ExactFileTarget.ordinary(linkedParent.appendingPathComponent("settings.json"))
    #expect(try ordinary.capture().data == Data("{}".utf8))
}

@Test func descriptorAbsentAppearanceSurvivesExclusivePublish() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); let target = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file)
    let observed = try target.capture()
    #expect(throws: ConcurrentModification.self) { try AtomicFile.write(Data("ours".utf8), replacing: observed, hooks: .init(beforeAbsentPublish: { try Data("foreign".utf8).write(to: file) })) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "foreign")
}

@Test func descriptorPreQuarantineReplacementSurvives() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    #expect(throws: ConcurrentModification.self) { try AtomicFile.write(Data("ours".utf8), replacing: observed, hooks: .init(beforeQuarantine: { try FileManager.default.removeItem(at: file); try Data("foreign".utf8).write(to: file) })) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "foreign")
}

@Test func descriptorPostQuarantineReplacementPreservesRecovery() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    #expect(throws: ConcurrentModification.self) { try AtomicFile.write(Data("ours".utf8), replacing: observed, hooks: .init(afterQuarantineValidationBeforePublish: { try Data("foreign".utf8).write(to: file) })) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "foreign")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("quarantine") })
}

@Test func descriptorRemovePreQuarantineReplacementIsRetainedAsRecovery() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.remove(observed, expectedData: Data("original".utf8), hooks: .init(beforeQuarantine: {
            try FileManager.default.removeItem(at: file)
            try Data("foreign".utf8).write(to: file)
        }))
    }
    #expect(try recoveryContents(in: root, marker: "remove-quarantine") == "foreign")
}

@Test func descriptorRemoveAfterValidationRetainsActiveReplacement() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    try AtomicFile.remove(observed, expectedData: Data("original".utf8), hooks: .init(afterQuarantineValidationBeforePublish: {
        try Data("foreign".utf8).write(to: file)
    }))
    #expect(try String(contentsOf: file, encoding: .utf8) == "foreign")
    #expect(try recoveryContents(in: root, marker: "remove-quarantine") == nil)
}

@Test func descriptorWriteRejectsSameInodeSameSizeRestoredMTimeByBytesAndDigest() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.write(Data("ours".utf8), replacing: observed, hooks: .init(beforeQuarantine: {
            try overwriteInPlacePreservingModificationTime(file, with: Data("foreign!".utf8))
        }))
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try recoveryContents(in: root, marker: "quarantine") == "foreign!")
}

@Test func descriptorRemoveRejectsSameInodeSameSizeRestoredMTimeByBytesAndDigest() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.remove(observed, expectedData: Data("original".utf8), hooks: .init(beforeQuarantine: {
            try overwriteInPlacePreservingModificationTime(file, with: Data("foreign!".utf8))
        }))
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try recoveryContents(in: root, marker: "remove-quarantine") == "foreign!")
}

@Test func descriptorQuarantineSubstitutionBeforeValidationPreservesBothFiles() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    var saved: URL?
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.write(Data("ours".utf8), replacing: observed, hooks: .init(afterQuarantineMoveBeforeValidation: { quarantine in
            let quarantineURL = root.appendingPathComponent(quarantine)
            let recovery = root.appendingPathComponent("original-recovery")
            try FileManager.default.moveItem(at: quarantineURL, to: recovery)
            try Data("foreign-quarantine".utf8).write(to: quarantineURL)
            saved = recovery
        }))
    }
    #expect(try String(contentsOf: #require(saved), encoding: .utf8) == "original")
    #expect(try recoveryContents(in: root, marker: "quarantine") == "foreign-quarantine")
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func descriptorRemoveQuarantineSubstitutionBeforeValidationPreservesBothFiles() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    var saved: URL?
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.remove(observed, expectedData: Data("original".utf8), hooks: .init(afterQuarantineMoveBeforeValidation: { quarantine in
            let quarantineURL = root.appendingPathComponent(quarantine)
            let recovery = root.appendingPathComponent("original-recovery")
            try FileManager.default.moveItem(at: quarantineURL, to: recovery)
            try Data("foreign-quarantine".utf8).write(to: quarantineURL)
            saved = recovery
        }))
    }
    #expect(try String(contentsOf: #require(saved), encoding: .utf8) == "original")
    #expect(try recoveryContents(in: root, marker: "remove-quarantine") == "foreign-quarantine")
}

@Test func descriptorQuarantineSubstitutionBeforeCleanupIsNeverUnlinked() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    var saved: URL?
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.write(Data("ours".utf8), replacing: observed, hooks: .init(beforeQuarantineCleanup: { quarantine in
            let quarantineURL = root.appendingPathComponent(quarantine)
            let recovery = root.appendingPathComponent("original-recovery")
            try FileManager.default.moveItem(at: quarantineURL, to: recovery)
            try Data("foreign-quarantine".utf8).write(to: quarantineURL)
            saved = recovery
        }))
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "ours")
    #expect(try String(contentsOf: #require(saved), encoding: .utf8) == "original")
    #expect(try recoveryContents(in: root, marker: "quarantine") == "foreign-quarantine")
}

@Test func descriptorRemoveQuarantineSubstitutionBeforeCleanupIsNeverUnlinked() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    var saved: URL?
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.remove(observed, expectedData: Data("original".utf8), hooks: .init(beforeQuarantineCleanup: { quarantine in
            let quarantineURL = root.appendingPathComponent(quarantine)
            let recovery = root.appendingPathComponent("original-recovery")
            try FileManager.default.moveItem(at: quarantineURL, to: recovery)
            try Data("foreign-quarantine".utf8).write(to: quarantineURL)
            saved = recovery
        }))
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try String(contentsOf: #require(saved), encoding: .utf8) == "original")
    #expect(try recoveryContents(in: root, marker: "remove-quarantine") == "foreign-quarantine")
}

@Test func descriptorTemporarySubstitutionBeforePublishIsNeverPublishedOrCleaned() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    var temporary: URL?
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.write(Data("ours".utf8), replacing: observed, hooks: .init(beforePublish: { temp in
            temporary = root.appendingPathComponent(temp)
            try replaceNamedEntry(in: root, name: temp, with: "foreign-temporary")
        }))
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try recoveryContents(in: root, marker: "quarantine") == "original")
    #expect(try String(contentsOf: #require(temporary), encoding: .utf8) == "foreign-temporary")
}

@Test func descriptorAbsentTemporarySubstitutionBeforePublishIsNeverPublishedOrCleaned() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target")
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    var temporary: URL?
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.write(Data("ours".utf8), replacing: observed, hooks: .init(beforePublish: { temp in
            temporary = root.appendingPathComponent(temp)
            try replaceNamedEntry(in: root, name: temp, with: "foreign-temporary")
        }))
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try String(contentsOf: #require(temporary), encoding: .utf8) == "foreign-temporary")
}

@Test func descriptorTemporarySubstitutionBeforeCleanupIsNeverUnlinked() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target")
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    var temporary: URL?
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.write(Data("ours".utf8), replacing: observed, hooks: .init(
            beforeAbsentPublish: { try Data("foreign-active".utf8).write(to: file) },
            beforeTempCleanup: { temp in
                temporary = root.appendingPathComponent(temp)
                try replaceNamedEntry(in: root, name: temp, with: "foreign-temporary")
            }))
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "foreign-active")
    #expect(try String(contentsOf: #require(temporary), encoding: .utf8) == "foreign-temporary")
}

@Test func descriptorQuarantineInodeMismatchIsRetainedInsteadOfDeleted() throws {
    let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
    let observed = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
    var originalRecovery: URL?
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.write(Data("ours".utf8), replacing: observed, hooks: .init(afterQuarantineMoveBeforeValidation: { quarantine in
            let quarantineURL = root.appendingPathComponent(quarantine)
            let recovery = root.appendingPathComponent("inode-recovery")
            try FileManager.default.moveItem(at: quarantineURL, to: recovery)
            try Data("original".utf8).write(to: quarantineURL)
            originalRecovery = recovery
        }))
    }
    #expect(try String(contentsOf: #require(originalRecovery), encoding: .utf8) == "original")
    #expect(try recoveryContents(in: root, marker: "quarantine") == "original")
}

@Test func descriptorQuarantineEvidenceRejectsEveryField() throws {
    typealias Change = (CapturedExactFile) throws -> CapturedExactFile
    let changes: [(String, Change)] = [
        ("device", { capture in try changedExpectedCapture(capture, snapshot: ExactFileSnapshot(path: capture.snapshot.path, exists: true, deviceID: capture.snapshot.deviceID! + 1, inode: capture.snapshot.inode, byteCount: capture.snapshot.byteCount, modificationSeconds: capture.snapshot.modificationSeconds, modificationNanoseconds: capture.snapshot.modificationNanoseconds, sha256: capture.snapshot.sha256)) }),
        ("size", { capture in try changedExpectedCapture(capture, snapshot: ExactFileSnapshot(path: capture.snapshot.path, exists: true, deviceID: capture.snapshot.deviceID, inode: capture.snapshot.inode, byteCount: capture.snapshot.byteCount! + 1, modificationSeconds: capture.snapshot.modificationSeconds, modificationNanoseconds: capture.snapshot.modificationNanoseconds, sha256: capture.snapshot.sha256)) }),
        ("seconds", { capture in try changedExpectedCapture(capture, snapshot: ExactFileSnapshot(path: capture.snapshot.path, exists: true, deviceID: capture.snapshot.deviceID, inode: capture.snapshot.inode, byteCount: capture.snapshot.byteCount, modificationSeconds: capture.snapshot.modificationSeconds! + 1, modificationNanoseconds: capture.snapshot.modificationNanoseconds, sha256: capture.snapshot.sha256)) }),
        ("nanoseconds", { capture in try changedExpectedCapture(capture, snapshot: ExactFileSnapshot(path: capture.snapshot.path, exists: true, deviceID: capture.snapshot.deviceID, inode: capture.snapshot.inode, byteCount: capture.snapshot.byteCount, modificationSeconds: capture.snapshot.modificationSeconds, modificationNanoseconds: (capture.snapshot.modificationNanoseconds! + 1) % 1_000_000_000, sha256: capture.snapshot.sha256)) }),
        ("sha256", { capture in try changedExpectedCapture(capture, snapshot: ExactFileSnapshot(path: capture.snapshot.path, exists: true, deviceID: capture.snapshot.deviceID, inode: capture.snapshot.inode, byteCount: capture.snapshot.byteCount, modificationSeconds: capture.snapshot.modificationSeconds, modificationNanoseconds: capture.snapshot.modificationNanoseconds, sha256: String(repeating: "0", count: 64))) }),
        ("bytes", { capture in changedExpectedCapture(capture, data: Data("different".utf8)) })
    ]
    for (field, change) in changes {
        let root = try anchoredRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("target"); try Data("original".utf8).write(to: file)
        let actual = try DirectoryAnchor.openNoFollow(at: root).target(atAbsoluteURL: file).capture()
        let altered = try change(actual)
        #expect(throws: ConcurrentModification.self, "\(field) mismatch") { try AtomicFile.write(Data("ours".utf8), replacing: altered) }
        #expect(try recoveryContents(in: root, marker: "quarantine") == "original", "\(field) recovery")
    }
}
