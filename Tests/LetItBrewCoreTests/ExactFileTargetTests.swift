import Foundation
import Testing
@testable import LetItBrewCore

private func anchoredRoot() throws -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("exact-target-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }

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
