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
