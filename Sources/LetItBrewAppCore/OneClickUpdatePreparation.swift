import Foundation

public struct OneClickUpdateWorkspace: Equatable, Sendable {
    public let root: URL
    public let checksumFile: URL
    public let diskImage: URL
    public let mountPoint: URL
    public let stagedApp: URL
    public let updateSupportDirectory: URL
    public let resultFile: URL
    public let logFile: URL

    public init(
        root: URL,
        checksumFile: URL,
        diskImage: URL,
        mountPoint: URL,
        stagedApp: URL,
        updateSupportDirectory: URL,
        resultFile: URL,
        logFile: URL
    ) {
        self.root = root
        self.checksumFile = checksumFile
        self.diskImage = diskImage
        self.mountPoint = mountPoint
        self.stagedApp = stagedApp
        self.updateSupportDirectory = updateSupportDirectory
        self.resultFile = resultFile
        self.logFile = logFile
    }
}

public struct MountedUpdateImage: Equatable, Sendable {
    public let mountPoint: URL
    public let appBundle: URL

    public init(mountPoint: URL, appBundle: URL) {
        self.mountPoint = mountPoint
        self.appBundle = appBundle
    }
}

public struct VerifiedUpdateCandidate: Equatable, Sendable {
    public let version: StableUpdateVersion
    public let build: UInt64
    public let executableSHA256: String

    public init(
        version: StableUpdateVersion,
        build: UInt64,
        executableSHA256: String
    ) {
        self.version = version
        self.build = build
        self.executableSHA256 = executableSHA256
    }
}

public enum UpdateCandidateLocation: String, Equatable, Sendable {
    case mounted
    case staged
}

public enum DiskImageGatekeeperCommandSpecification {
    public static func arguments(for diskImage: URL) -> [String] {
        [
            "--assess", "--verbose=4", "--type", "open",
            "--context", "context:primary-signature", diskImage.path,
        ]
    }
}

public enum OneClickUpdatePreparationStage: String, Equatable, Sendable {
    case createWorkspace
    case downloadChecksums
    case verifyChecksums
    case downloadDiskImage
    case verifyDiskImageDigest
    case verifyDiskImage
    case mountDiskImage
    case verifyMountedCandidate
    case stageCandidate
    case verifyStagedCandidate
    case detachDiskImage
    case copySignedSupport
    case launchRunner
}

/// Side effects stay behind this boundary so the ordered safety transaction is
/// exercised by SwiftPM even though the live macOS adapter belongs to the app.
public protocol OneClickUpdatePreparationOperations: AnyObject, Sendable {
    func createPrivateWorkspace(for release: StableUpdateRelease) throws
        -> OneClickUpdateWorkspace
    func download(_ asset: UpdateAsset, to destination: URL) async throws
    func readSmallFile(at url: URL, maximumBytes: Int64) throws -> Data
    func sha256(of url: URL) throws -> String
    func verifyDiskImage(at url: URL) throws
    func mountDiskImageReadOnly(at url: URL, mountPoint: URL) throws
        -> MountedUpdateImage
    func verifyCandidate(
        at appBundle: URL,
        location: UpdateCandidateLocation
    ) throws -> VerifiedUpdateCandidate
    func copyCandidate(from source: URL, to destination: URL) throws
    func detachDiskImage(_ image: MountedUpdateImage) throws
    func copySignedUpdateSupport(to destination: URL) throws
    func launchDetachedRunner(
        supportDirectory: URL,
        candidate: URL,
        resultFile: URL,
        logFile: URL
    ) throws
    func cleanFailedWorkspace(_ workspace: OneClickUpdateWorkspace)
}

private struct UpdatePreparationValidationError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

public struct OneClickUpdatePreparationWorkflow: Sendable {
    private let installedBuild: UInt64
    private let operations: any OneClickUpdatePreparationOperations

    public init(
        installedBuild: UInt64,
        operations: any OneClickUpdatePreparationOperations
    ) {
        self.installedBuild = installedBuild
        self.operations = operations
    }

    public func prepareAndLaunch(
        release: StableUpdateRelease
    ) async -> Result<Void, OneClickUpdateFailure> {
        var stage = OneClickUpdatePreparationStage.createWorkspace
        var workspace: OneClickUpdateWorkspace?
        var mountedImage: MountedUpdateImage?

        do {
            let created = try operations.createPrivateWorkspace(for: release)
            workspace = created

            stage = .downloadChecksums
            try await operations.download(release.checksums, to: created.checksumFile)

            stage = .verifyChecksums
            let checksumDigest = try normalizedSHA256(
                operations.sha256(of: created.checksumFile),
                context: release.checksums.name
            )
            if let githubDigest = release.checksums.githubSHA256,
               checksumDigest != githubDigest {
                throw UpdatePreparationValidationError(
                    detail: "GitHub's checksum-file digest did not match the download."
                )
            }
            let checksumData = try operations.readSmallFile(
                at: created.checksumFile,
                maximumBytes: StableUpdateReleaseParser.maximumChecksumSize
            )
            let publishedDMGDigest = try UpdateChecksumParser.sha256(
                for: release.dmg.name,
                in: checksumData
            )

            stage = .downloadDiskImage
            try await operations.download(release.dmg, to: created.diskImage)

            stage = .verifyDiskImageDigest
            let downloadedDMGDigest = try normalizedSHA256(
                operations.sha256(of: created.diskImage),
                context: release.dmg.name
            )
            guard downloadedDMGDigest == publishedDMGDigest else {
                throw UpdatePreparationValidationError(
                    detail: "The disk image did not match the published checksum."
                )
            }
            if let githubDigest = release.dmg.githubSHA256,
               downloadedDMGDigest != githubDigest {
                throw UpdatePreparationValidationError(
                    detail: "GitHub's disk-image digest did not match the download."
                )
            }

            stage = .verifyDiskImage
            try operations.verifyDiskImage(at: created.diskImage)

            stage = .mountDiskImage
            let mounted = try operations.mountDiskImageReadOnly(
                at: created.diskImage,
                mountPoint: created.mountPoint
            )
            // Record the successful attachment before validating its reported
            // location so even a surprising mount is detached on refusal.
            mountedImage = mounted
            guard mounted.mountPoint.standardizedFileURL == created.mountPoint.standardizedFileURL
            else {
                throw UpdatePreparationValidationError(
                    detail: "The disk image mounted somewhere unexpected."
                )
            }
            stage = .verifyMountedCandidate
            let mountedCandidate = try operations.verifyCandidate(
                at: mounted.appBundle,
                location: .mounted
            )
            try validateCandidate(mountedCandidate, release: release)

            stage = .stageCandidate
            try operations.copyCandidate(
                from: mounted.appBundle,
                to: created.stagedApp
            )

            stage = .verifyStagedCandidate
            let stagedCandidate = try operations.verifyCandidate(
                at: created.stagedApp,
                location: .staged
            )
            try validateCandidate(stagedCandidate, release: release)
            guard stagedCandidate == mountedCandidate else {
                throw UpdatePreparationValidationError(
                    detail: "The staged app did not exactly match the verified mounted app."
                )
            }

            stage = .detachDiskImage
            try operations.detachDiskImage(mounted)
            mountedImage = nil

            stage = .copySignedSupport
            try operations.copySignedUpdateSupport(to: created.updateSupportDirectory)

            stage = .launchRunner
            try operations.launchDetachedRunner(
                supportDirectory: created.updateSupportDirectory,
                candidate: created.stagedApp,
                resultFile: created.resultFile,
                logFile: created.logFile
            )
            return .success(())
        } catch {
            if let mountedImage {
                try? operations.detachDiskImage(mountedImage)
            }
            if let workspace {
                operations.cleanFailedWorkspace(workspace)
            }
            return .failure(OneClickUpdateFailure(
                message: "Let It Brew couldn't prepare this update. Nothing was changed.",
                diagnostic: "\(stage.rawValue): \(error.localizedDescription)"
            ))
        }
    }

    private func validateCandidate(
        _ candidate: VerifiedUpdateCandidate,
        release: StableUpdateRelease
    ) throws {
        guard candidate.version == release.version else {
            throw UpdatePreparationValidationError(
                detail: "The app version did not match release \(release.version)."
            )
        }
        guard candidate.build > installedBuild else {
            throw UpdatePreparationValidationError(
                detail: "The update build was not newer than the installed build."
            )
        }
        _ = try normalizedSHA256(
            candidate.executableSHA256,
            context: "Let It Brew executable"
        )
    }

    private func normalizedSHA256(_ value: String, context: String) throws -> String {
        let normalized = value.lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else {
            throw UpdatePreparationValidationError(
                detail: "The SHA-256 for \(context) was malformed."
            )
        }
        return normalized
    }
}
