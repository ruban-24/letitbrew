import Foundation
import Testing
@testable import LetItBrewAppCore

@Suite struct MountedUpdatePayloadValidatorTests {
    private struct ReleaseDMGPayloadContract {
        let topLevelEntries: [String]
        let backgroundEntry: String
        let applicationsDestination: String
    }

    private func loadReleaseDMGPayloadContract() throws -> ReleaseDMGPayloadContract {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contractURL = repositoryRoot.appendingPathComponent(
            "scripts/dmg-payload-contract.sh"
        )
        let source = try String(contentsOf: contractURL, encoding: .utf8)

        func value(named key: String) throws -> String {
            let prefix = "\(key)='"
            guard let line = source.split(separator: "\n").first(where: {
                $0.hasPrefix(prefix) && $0.hasSuffix("'")
            }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return String(line.dropFirst(prefix.count).dropLast())
        }

        return try ReleaseDMGPayloadContract(
            topLevelEntries: value(named: "LETITBREW_DMG_TOP_LEVEL_ENTRIES")
                .split(separator: ",")
                .map(String.init),
            backgroundEntry: value(named: "LETITBREW_DMG_BACKGROUND_ENTRY"),
            applicationsDestination: value(named: "LETITBREW_DMG_APPLICATIONS_SYMLINK")
        )
    }

    private func makeLegacyPayload() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LetItBrewMountedPayload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Let It Brew.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Applications").path,
            withDestinationPath: "/Applications"
        )
        return root
    }

    private func addGuidedPresentation(to root: URL) throws {
        let background = root.appendingPathComponent(".background", isDirectory: true)
        try FileManager.default.createDirectory(at: background, withIntermediateDirectories: false)
        try Data("finder layout\n".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try Data("volume icon\n".utf8).write(to: root.appendingPathComponent(".VolumeIcon.icns"))
        try Data("background\n".utf8).write(
            to: background.appendingPathComponent("dmg-background.png")
        )
    }

    @Test func acceptsTheFrozenLegacyTwoEntryPayload() throws {
        let root = try makeLegacyPayload()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(MountedUpdatePayloadValidator.validate(at: root) == .valid(.legacy))
    }

    @Test func acceptsTheCanonicalReleasePackagingContract() throws {
        let contract = try loadReleaseDMGPayloadContract()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LetItBrewReleasePayload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        for entry in contract.topLevelEntries {
            let destination = root.appendingPathComponent(entry)
            switch entry {
            case "Applications":
                try FileManager.default.createSymbolicLink(
                    atPath: destination.path,
                    withDestinationPath: contract.applicationsDestination
                )
            case "Let It Brew.app", ".background":
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
            default:
                try Data("release presentation\n".utf8).write(to: destination)
            }
        }
        try Data("release background\n".utf8).write(
            to: root.appendingPathComponent(contract.backgroundEntry)
        )

        #expect(MountedUpdatePayloadValidator.validate(at: root) == .valid(.guided))
    }

    @Test func acceptsOnlyTheExactGuidedFiveEntryPayload() throws {
        let root = try makeLegacyPayload()
        defer { try? FileManager.default.removeItem(at: root) }
        try addGuidedPresentation(to: root)

        #expect(MountedUpdatePayloadValidator.validate(at: root) == .valid(.guided))

        try Data("unexpected\n".utf8).write(to: root.appendingPathComponent("unexpected.txt"))
        #expect(MountedUpdatePayloadValidator.validate(at: root) == .invalidInventory)
    }

    @Test func rejectsUnsafeOrInexactGuidedPresentationAssets() throws {
        let root = try makeLegacyPayload()
        defer { try? FileManager.default.removeItem(at: root) }
        try addGuidedPresentation(to: root)

        let icon = root.appendingPathComponent(".VolumeIcon.icns")
        try FileManager.default.removeItem(at: icon)
        try FileManager.default.createSymbolicLink(
            atPath: icon.path,
            withDestinationPath: ".background/dmg-background.png"
        )
        #expect(MountedUpdatePayloadValidator.validate(at: root) == .invalidPresentation)

        try FileManager.default.removeItem(at: icon)
        try Data("volume icon\n".utf8).write(to: icon)
        try Data("extra\n".utf8).write(
            to: root.appendingPathComponent(".background/extra.png")
        )
        #expect(MountedUpdatePayloadValidator.validate(at: root) == .invalidPresentation)
    }

    @Test func rejectsUnsafeAppAndApplicationsEntries() throws {
        let wrongApplications = try makeLegacyPayload()
        defer { try? FileManager.default.removeItem(at: wrongApplications) }
        let applications = wrongApplications.appendingPathComponent("Applications")
        try FileManager.default.removeItem(at: applications)
        try FileManager.default.createSymbolicLink(
            atPath: applications.path,
            withDestinationPath: "/System/Applications"
        )
        #expect(
            MountedUpdatePayloadValidator.validate(at: wrongApplications)
                == .invalidApplicationsLink
        )

        let symlinkedApp = try makeLegacyPayload()
        defer { try? FileManager.default.removeItem(at: symlinkedApp) }
        let app = symlinkedApp.appendingPathComponent("Let It Brew.app")
        try FileManager.default.removeItem(at: app)
        try FileManager.default.createSymbolicLink(
            atPath: app.path,
            withDestinationPath: "/Applications/Let It Brew.app"
        )
        #expect(MountedUpdatePayloadValidator.validate(at: symlinkedApp) == .invalidAppBundle)
    }
}
