import Foundation
import Testing
@testable import LetItBrewAppCore

@Suite struct OneClickUpdateCacheTests {
    private func makeAppCache() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LetItBrewCache-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("com.ruban24.letitbrew", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    @Test func createsUpdatesBaseAtOwnerOnlyMode() throws {
        let appCache = try makeAppCache()
        defer { try? FileManager.default.removeItem(at: appCache.deletingLastPathComponent()) }

        let base = try OneClickUpdateCache.prepareUpdatesBase(inAppCache: appCache)

        #expect(base.lastPathComponent == "Updates")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let mode = try FileManager.default.attributesOfItem(atPath: base.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o700)
    }

    // Regression: `Updates` persists across updates, so the 2nd update must not
    // fail creating a base that already exists (was withIntermediateDirectories: false).
    @Test func secondPreparationSucceedsWhenBaseAlreadyExists() throws {
        let appCache = try makeAppCache()
        defer { try? FileManager.default.removeItem(at: appCache.deletingLastPathComponent()) }

        let first = try OneClickUpdateCache.prepareUpdatesBase(inAppCache: appCache)
        let second = try OneClickUpdateCache.prepareUpdatesBase(inAppCache: appCache)

        #expect(first == second)
    }
}
