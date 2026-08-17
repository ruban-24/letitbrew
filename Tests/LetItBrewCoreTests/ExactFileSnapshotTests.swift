import Foundation
import Testing
@testable import LetItBrewCore

private func snapshotFile(_ data: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)")
    try Data(data.utf8).write(to: url); return url
}
@Test func exactSnapshotVerifiesSameFile() throws { let url = try snapshotFile("one"); defer { try? FileManager.default.removeItem(at: url) }; let snapshot = try ExactFileSnapshot.capture(at: url); try snapshot.verify() }
@Test func exactSnapshotRejectsReplacementEvenWithIdenticalBytes() throws { let url = try snapshotFile("one"); defer { try? FileManager.default.removeItem(at: url) }; let snapshot = try ExactFileSnapshot.capture(at: url); let moved = url.appendingPathExtension("old"); try FileManager.default.moveItem(at: url, to: moved); try Data("one".utf8).write(to: url); #expect(throws: ExactFileSnapshotError.self) { try snapshot.verify() } }
@Test func absentSnapshotRejectsAppearance() throws { let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-absent-\(UUID().uuidString)"); let snapshot = try ExactFileSnapshot.capture(at: url); try Data("now here".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }; #expect(throws: ExactFileSnapshotError.self) { try snapshot.verify() } }
@Test func snapshotRejectsInvalidDigestEvidence() throws {
    let json = "{\"path\":\"/tmp/x\",\"exists\":true,\"deviceID\":1,\"inode\":1,\"byteCount\":0,\"modificationSeconds\":0,\"modificationNanoseconds\":1000000000,\"sha256\":\"not-a-digest\"}"
    #expect(throws: Error.self) { _ = try JSONDecoder().decode(ExactFileSnapshot.self, from: Data(json.utf8)) }
}
@Test func snapshotRejectsUnknownWireFields() throws {
    let complete = "{\"path\":\"/tmp/x\",\"exists\":false,\"deviceID\":null,\"inode\":null,\"byteCount\":null,\"modificationSeconds\":null,\"modificationNanoseconds\":null,\"sha256\":null,\"extra\":1}"
    #expect(throws: Error.self) { _ = try JSONDecoder().decode(ExactFileSnapshot.self, from: Data(complete.utf8)) }
}
@Test func snapshotRejectsSymlinkSubstitution() throws {
    let url = try snapshotFile("one"); defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("link")) }
    let snapshot = try ExactFileSnapshot.capture(at: url); let link = url.appendingPathExtension("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    #expect(throws: ExactFileSnapshotError.self) { try ExactFileSnapshot.capture(at: link) }
    try snapshot.verify()
}

@Test func snapshotRejectsDisappearanceAndSameSizeEditWithRestoredMTime() throws {
    let missing = try snapshotFile("one")
    let missingSnapshot = try ExactFileSnapshot.capture(at: missing)
    try FileManager.default.removeItem(at: missing)
    #expect(throws: ExactFileSnapshotError.self) { try missingSnapshot.verify() }

    let edited = try snapshotFile("one")
    defer { try? FileManager.default.removeItem(at: edited) }
    let original = try ExactFileSnapshot.capture(at: edited)
    var prior = stat(); guard lstat(edited.path, &prior) == 0 else { throw POSIXError(.EIO) }
    let fd = open(edited.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    _ = "two".withCString { Darwin.write(fd, $0, 3) }
    guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    var timestamps = [prior.st_atimespec, prior.st_mtimespec]
    guard utimensat(AT_FDCWD, edited.path, &timestamps, 0) == 0 else { throw POSIXError(.EIO) }
    #expect(throws: ExactFileSnapshotError.self) { try original.verify() }
}

@Test func snapshotVerificationRejectsEveryMetadataField() throws {
    let url = try snapshotFile("one"); defer { try? FileManager.default.removeItem(at: url) }
    let snapshot = try ExactFileSnapshot.capture(at: url)
    typealias Change = (ExactFileSnapshot) throws -> ExactFileSnapshot
    let changes: [Change] = [
        { try ExactFileSnapshot(path: $0.path, exists: true, deviceID: $0.deviceID! + 1, inode: $0.inode, byteCount: $0.byteCount, modificationSeconds: $0.modificationSeconds, modificationNanoseconds: $0.modificationNanoseconds, sha256: $0.sha256) },
        { try ExactFileSnapshot(path: $0.path, exists: true, deviceID: $0.deviceID, inode: $0.inode! + 1, byteCount: $0.byteCount, modificationSeconds: $0.modificationSeconds, modificationNanoseconds: $0.modificationNanoseconds, sha256: $0.sha256) },
        { try ExactFileSnapshot(path: $0.path, exists: true, deviceID: $0.deviceID, inode: $0.inode, byteCount: $0.byteCount! + 1, modificationSeconds: $0.modificationSeconds, modificationNanoseconds: $0.modificationNanoseconds, sha256: $0.sha256) },
        { try ExactFileSnapshot(path: $0.path, exists: true, deviceID: $0.deviceID, inode: $0.inode, byteCount: $0.byteCount, modificationSeconds: $0.modificationSeconds! + 1, modificationNanoseconds: $0.modificationNanoseconds, sha256: $0.sha256) },
        { try ExactFileSnapshot(path: $0.path, exists: true, deviceID: $0.deviceID, inode: $0.inode, byteCount: $0.byteCount, modificationSeconds: $0.modificationSeconds, modificationNanoseconds: ($0.modificationNanoseconds! + 1) % 1_000_000_000, sha256: $0.sha256) },
        { try ExactFileSnapshot(path: $0.path, exists: true, deviceID: $0.deviceID, inode: $0.inode, byteCount: $0.byteCount, modificationSeconds: $0.modificationSeconds, modificationNanoseconds: $0.modificationNanoseconds, sha256: String(repeating: "0", count: 64)) }
    ]
    for change in changes {
        #expect(throws: ExactFileSnapshotError.self) { try change(snapshot).verify() }
    }
}

@Test func exactReadRetriesEINTRAndRejectsShortCount() throws {
    var interruptedCalls = 0
    let bytes = try readExactFileBytes(from: -1, expectedSize: 3, path: "/tmp/read", reader: { _, buffer, _ in
        interruptedCalls += 1
        if interruptedCalls == 1 { errno = EINTR; return -1 }
        if interruptedCalls == 2 {
            buffer[0] = 97; buffer[1] = 98; buffer[2] = 99
            return 3
        }
        return 0
    })
    #expect(bytes == Data("abc".utf8))
    #expect(interruptedCalls == 3)
    var shortCalls = 0
    #expect(throws: ExactFileSnapshotError.self) {
        _ = try readExactFileBytes(from: -1, expectedSize: 3, path: "/tmp/read", reader: { _, buffer, _ in
            shortCalls += 1
            guard shortCalls == 1 else { return 0 }
            buffer[0] = 97; return 1
        })
    }
}
