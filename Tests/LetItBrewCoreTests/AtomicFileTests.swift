import Testing
import Foundation
@testable import LetItBrewCore

/// `AtomicFile.write` guards a config file (Claude Code's `settings.json`,
/// Codex's `hooks.json`) against an edit landing between a caller's read and
/// its write. Important 3: the guard must cover the FULL write, including
/// the time spent writing the temporary file, not just the moment before
/// that write starts.

@Test func writeSucceedsAndReplacesContentWhenNothingRaced() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("atomic-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")
    try Data("original".utf8).write(to: url)

    let priorModified = AtomicFile.modificationDate(of: url)
    try AtomicFile.write(Data("updated".utf8), to: url, ifUnchangedSince: priorModified)

    #expect(try String(contentsOf: url, encoding: .utf8) == "updated")
}

@Test func writeCreatesAFreshFileWhenNoPriorExisted() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("atomic-file-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("nested/settings.json")

    try AtomicFile.write(Data("fresh".utf8), to: url, ifUnchangedSince: nil)

    #expect(try String(contentsOf: url, encoding: .utf8) == "fresh")
}

@Test func writeRefusesWhenTheFileAlreadyChangedBeforeWritingEvenStarted() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("atomic-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")
    try Data("original".utf8).write(to: url)

    let staleModified = AtomicFile.modificationDate(of: url)!.addingTimeInterval(-3600)

    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.write(Data("updated".utf8), to: url, ifUnchangedSince: staleModified)
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == "original")  // untouched
}

// MARK: - Important 3: the guard must reach the internal rename, not just
// the moment before the write starts.

@Test func writeCatchesAnEditThatLandsWhileTheTemporaryFileIsBeingWritten() throws {
    // Before the fix, the modification-date check ran once, before the
    // ENTIRE write (including the time spent writing the temp file), so an
    // edit landing during that window was silently clobbered by the final
    // rename. `beforeRename` is the test seam that lands a "concurrent"
    // write deterministically inside exactly that window — after the top
    // check passed and the temp file exists, but before the rename that
    // would otherwise blow the concurrent edit away.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("atomic-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")
    try Data("original".utf8).write(to: url)
    let priorModified = AtomicFile.modificationDate(of: url)

    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.write(
            Data("our update".utf8), to: url, ifUnchangedSince: priorModified,
            beforeRename: {
                try? Data("concurrent edit".utf8).write(to: url)
            })
    }
    // The concurrent edit survived — our write must NOT have clobbered it
    // via the rename.
    #expect(try String(contentsOf: url, encoding: .utf8) == "concurrent edit")
}

private func ownedTemporaryFile(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atomic-remove-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("owned")
    try Data(contents.utf8).write(to: url)
    return url
}

@Test func removeDeletesAnUnchangedOwnedFile() throws {
    let url = try ownedTemporaryFile("owned"); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try AtomicFile.remove(url, ifUnchangedFrom: Data("owned".utf8))
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func quarantinedRemovalPreservesAReplacementAtTheOriginalPath() throws {
    let url = try ownedTemporaryFile("owned"); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try AtomicFile.remove(url, ifUnchangedFrom: Data("owned".utf8), afterQuarantine: { _ in try Data("foreign replacement".utf8).write(to: url) })
    #expect(try String(contentsOf: url, encoding: .utf8) == "foreign replacement")
}

@Test func quarantineMismatchRestoresTheOriginal() throws {
    let url = try ownedTemporaryFile("owned"); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(throws: ConcurrentModification.self) { try AtomicFile.remove(url, ifUnchangedFrom: Data("different".utf8)) }
    #expect(try String(contentsOf: url, encoding: .utf8) == "owned")
}

@Test func postValidationQuarantineReplacementIsNeverUnlinked() throws {
    let url = try ownedTemporaryFile("owned"); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var recoveryURL: URL?; var replacementURL: URL?
    #expect(throws: ConcurrentModification.self) {
        try AtomicFile.remove(url, ifUnchangedFrom: Data("owned".utf8), afterValidation: { quarantine in
            let recovery = quarantine.appendingPathExtension("recovery")
            try FileManager.default.moveItem(at: quarantine, to: recovery)
            try Data("foreign quarantine replacement".utf8).write(to: quarantine)
            recoveryURL = recovery; replacementURL = quarantine
        })
    }
    #expect(try String(contentsOf: #require(recoveryURL), encoding: .utf8) == "owned")
    #expect(try String(contentsOf: #require(replacementURL), encoding: .utf8) == "foreign quarantine replacement")
}
