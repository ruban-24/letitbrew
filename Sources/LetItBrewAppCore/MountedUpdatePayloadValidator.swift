import Darwin
import Foundation

public enum MountedUpdatePayloadLayout: Equatable, Sendable {
    case legacy
    case guided
}

public enum MountedUpdatePayloadValidation: Equatable, Sendable {
    case valid(MountedUpdatePayloadLayout)
    case invalidInventory
    case invalidAppBundle
    case invalidApplicationsLink
    case invalidPresentation
}

public enum MountedUpdatePayloadValidator {
    private static let legacyNames: Set<String> = [
        "Applications",
        "Let It Brew.app",
    ]
    private static let guidedNames: Set<String> = [
        ".DS_Store",
        ".VolumeIcon.icns",
        ".background",
        "Applications",
        "Let It Brew.app",
    ]

    public static func validate(
        at mountPoint: URL,
        fileManager: FileManager = .default
    ) -> MountedUpdatePayloadValidation {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: mountPoint,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            return .invalidInventory
        }

        let names = Set(entries.map(\.lastPathComponent))
        let layout: MountedUpdatePayloadLayout
        if entries.count == legacyNames.count, names == legacyNames {
            layout = .legacy
        } else if entries.count == guidedNames.count, names == guidedNames {
            layout = .guided
        } else {
            return .invalidInventory
        }

        let app = mountPoint.appendingPathComponent("Let It Brew.app", isDirectory: true)
        guard isOrdinaryDirectory(app) else { return .invalidAppBundle }

        let applications = mountPoint.appendingPathComponent("Applications")
        guard isSymbolicLink(applications),
              (try? fileManager.destinationOfSymbolicLink(atPath: applications.path))
                == "/Applications"
        else {
            return .invalidApplicationsLink
        }

        guard layout == .guided else { return .valid(.legacy) }
        let background = mountPoint.appendingPathComponent(".background", isDirectory: true)
        guard isOrdinaryFile(mountPoint.appendingPathComponent(".DS_Store")),
              isOrdinaryFile(mountPoint.appendingPathComponent(".VolumeIcon.icns")),
              isOrdinaryDirectory(background)
        else {
            return .invalidPresentation
        }
        let backgroundEntries: [URL]
        do {
            backgroundEntries = try fileManager.contentsOfDirectory(
                at: background,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            return .invalidPresentation
        }
        guard backgroundEntries.count == 1,
              backgroundEntries.first?.lastPathComponent == "dmg-background.png",
              isOrdinaryFile(background.appendingPathComponent("dmg-background.png"))
        else {
            return .invalidPresentation
        }
        return .valid(.guided)
    }

    private static func fileType(at url: URL) -> mode_t? {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return nil }
        return status.st_mode & S_IFMT
    }

    private static func isOrdinaryFile(_ url: URL) -> Bool {
        fileType(at: url) == S_IFREG
    }

    private static func isOrdinaryDirectory(_ url: URL) -> Bool {
        fileType(at: url) == S_IFDIR
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        fileType(at: url) == S_IFLNK
    }
}
