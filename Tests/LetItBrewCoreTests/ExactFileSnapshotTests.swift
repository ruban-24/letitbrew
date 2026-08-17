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
@Test func snapshotRejectsSymlinkSubstitution() throws {
    let url = try snapshotFile("one"); defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("link")) }
    let snapshot = try ExactFileSnapshot.capture(at: url); let link = url.appendingPathExtension("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    #expect(throws: ExactFileSnapshotError.self) { try ExactFileSnapshot.capture(at: link) }
    try snapshot.verify()
}
