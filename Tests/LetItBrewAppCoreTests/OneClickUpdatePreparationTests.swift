import Foundation
import Testing
@testable import LetItBrewAppCore

private enum PreparationFixtureError: Error {
    case injected(String)
}

private func preparationFailed(_ result: Result<Void, OneClickUpdateFailure>) -> Bool {
    if case .failure = result { return true }
    return false
}

private final class RecordingPreparationOperations:
    OneClickUpdatePreparationOperations,
    @unchecked Sendable
{
    let digest = String(repeating: "a", count: 64)
    let workspace: OneClickUpdateWorkspace
    var events: [String] = []
    var throwAt: String?
    var checksumDigest: String
    var dmgDigest: String
    var mountedCandidate: VerifiedUpdateCandidate
    var stagedCandidate: VerifiedUpdateCandidate
    var mountedPointOverride: URL?
    var cleanupCount = 0
    var detachCount = 0

    init() {
        let root = URL(fileURLWithPath: "/private/tmp/LetItBrewUpdateFixture")
        workspace = OneClickUpdateWorkspace(
            root: root,
            checksumFile: root.appendingPathComponent("Checksums"),
            diskImage: root.appendingPathComponent("Update.dmg"),
            mountPoint: root.appendingPathComponent("Mount"),
            stagedApp: root.appendingPathComponent("Candidate/Let It Brew.app"),
            updateSupportDirectory: root.appendingPathComponent("UpdateSupport"),
            resultFile: root.appendingPathComponent("result.json"),
            logFile: root.appendingPathComponent("update.log")
        )
        checksumDigest = digest
        dmgDigest = digest
        mountedCandidate = VerifiedUpdateCandidate(
            version: StableUpdateVersion("0.5.0")!,
            build: 15,
            executableSHA256: digest
        )
        stagedCandidate = mountedCandidate
    }

    func createPrivateWorkspace(for release: StableUpdateRelease) throws
        -> OneClickUpdateWorkspace {
        try record("createWorkspace")
        return workspace
    }

    func download(_ asset: UpdateAsset, to destination: URL) async throws {
        try record(asset.name.hasSuffix("SHA256SUMS") ? "downloadChecksums" : "downloadDiskImage")
    }

    func readSmallFile(at url: URL, maximumBytes: Int64) throws -> Data {
        try record("readChecksums")
        return Data("\(digest)  LetItBrew-0.5.0.dmg\n".utf8)
    }

    func sha256(of url: URL) throws -> String {
        if url == workspace.checksumFile {
            try record("digestChecksums")
            return checksumDigest
        }
        try record("digestDiskImage")
        return dmgDigest
    }

    func verifyDiskImage(at url: URL) throws {
        try record("verifyDiskImage")
    }

    func mountDiskImageReadOnly(at url: URL, mountPoint: URL) throws
        -> MountedUpdateImage {
        try record("mountDiskImage")
        let actualMount = mountedPointOverride ?? mountPoint
        return MountedUpdateImage(
            mountPoint: actualMount,
            appBundle: actualMount.appendingPathComponent("Let It Brew.app")
        )
    }

    func verifyCandidate(at appBundle: URL, location: UpdateCandidateLocation) throws
        -> VerifiedUpdateCandidate {
        try record(location == .mounted ? "verifyMountedCandidate" : "verifyStagedCandidate")
        return location == .mounted ? mountedCandidate : stagedCandidate
    }

    func copyCandidate(from source: URL, to destination: URL) throws {
        try record("stageCandidate")
    }

    func detachDiskImage(_ image: MountedUpdateImage) throws {
        detachCount += 1
        try record("detachDiskImage")
    }

    func copySignedUpdateSupport(to destination: URL) throws {
        try record("copySignedSupport")
    }

    func launchDetachedRunner(
        supportDirectory: URL,
        candidate: URL,
        resultFile: URL,
        logFile: URL
    ) throws {
        try record("launchRunner")
    }

    func cleanFailedWorkspace(_ workspace: OneClickUpdateWorkspace) {
        events.append("cleanup")
        cleanupCount += 1
    }

    private func record(_ event: String) throws {
        events.append(event)
        if throwAt == event { throw PreparationFixtureError.injected(event) }
    }
}

private func preparationRelease(
    checksumGitHubDigest: String? = nil,
    dmgGitHubDigest: String? = nil
) -> StableUpdateRelease {
    let version = StableUpdateVersion("0.5.0")!
    return StableUpdateRelease(
        version: version,
        dmg: UpdateAsset(
            name: "LetItBrew-0.5.0.dmg",
            downloadURL: URL(string: "https://github.com/ruban-24/letitbrew/releases/download/v0.5.0/LetItBrew-0.5.0.dmg")!,
            size: 10,
            githubSHA256: dmgGitHubDigest
        ),
        checksums: UpdateAsset(
            name: "LetItBrew-0.5.0-SHA256SUMS",
            downloadURL: URL(string: "https://github.com/ruban-24/letitbrew/releases/download/v0.5.0/LetItBrew-0.5.0-SHA256SUMS")!,
            size: 10,
            githubSHA256: checksumGitHubDigest
        )
    )
}

@Test func diskImageGatekeeperAssessmentSuppliesPrimarySignatureContext() {
    let diskImage = URL(fileURLWithPath: "/private/tmp/LetItBrew.dmg")

    #expect(DiskImageGatekeeperCommandSpecification.arguments(for: diskImage) == [
        "--assess", "--verbose=4", "--type", "open",
        "--context", "context:primary-signature", diskImage.path,
    ])
}

@Test func diskImageAttachRequestsMachineReadableOutput() {
    let diskImage = URL(fileURLWithPath: "/private/tmp/LetItBrew.dmg")
    let mountPoint = URL(fileURLWithPath: "/private/tmp/LetItBrewMount")

    #expect(DiskImageAttachCommandSpecification.arguments(
        for: diskImage,
        mountPoint: mountPoint
    ) == [
        "attach", "-readonly", "-nobrowse", "-noautoopen",
        "-mountpoint", mountPoint.path, "-plist", diskImage.path,
    ])
}

@Test func preparationRunsEveryGateBeforeLaunching() async {
    let operations = RecordingPreparationOperations()
    let workflow = OneClickUpdatePreparationWorkflow(
        installedBuild: 14,
        operations: operations
    )

    let result = await workflow.prepareAndLaunch(release: preparationRelease())
    #expect(!preparationFailed(result))
    #expect(operations.events == [
        "createWorkspace",
        "downloadChecksums", "digestChecksums", "readChecksums",
        "downloadDiskImage", "digestDiskImage", "verifyDiskImage",
        "mountDiskImage", "verifyMountedCandidate", "stageCandidate",
        "verifyStagedCandidate", "detachDiskImage", "copySignedSupport",
        "launchRunner",
    ])
    #expect(operations.cleanupCount == 0)
    #expect(operations.detachCount == 1)
}

@Test func publishedAndGitHubDigestsMustAllAgree() async {
    let mismatch = String(repeating: "b", count: 64)
    for (checksumGitHub, dmgGitHub, expectedStage) in [
        (mismatch, nil, "verifyChecksums"),
        (nil, mismatch, "verifyDiskImageDigest"),
    ] {
        let operations = RecordingPreparationOperations()
        let workflow = OneClickUpdatePreparationWorkflow(installedBuild: 14, operations: operations)
        let result = await workflow.prepareAndLaunch(release: preparationRelease(
            checksumGitHubDigest: checksumGitHub,
            dmgGitHubDigest: dmgGitHub
        ))
        guard case .failure(let failure) = result else {
            Issue.record("expected digest refusal")
            continue
        }
        #expect(failure.diagnostic.hasPrefix("\(expectedStage):"))
        #expect(!operations.events.contains("launchRunner"))
        #expect(operations.cleanupCount == 1)
    }

    let operations = RecordingPreparationOperations()
    operations.dmgDigest = mismatch
    let result = await OneClickUpdatePreparationWorkflow(
        installedBuild: 14,
        operations: operations
    ).prepareAndLaunch(release: preparationRelease())
    guard case .failure(let failure) = result else {
        Issue.record("expected published checksum refusal")
        return
    }
    #expect(failure.diagnostic.hasPrefix("verifyDiskImageDigest:"))
    #expect(!operations.events.contains("verifyDiskImage"))
}

@Test func candidateVersionBuildAndStagedIdentityMustMatch() async {
    let digest = String(repeating: "a", count: 64)
    let changedDigest = String(repeating: "c", count: 64)
    let cases: [(RecordingPreparationOperations) -> Void] = [
        { $0.mountedCandidate = VerifiedUpdateCandidate(
            version: StableUpdateVersion("0.6.0")!, build: 15, executableSHA256: digest
        ) },
        { $0.mountedCandidate = VerifiedUpdateCandidate(
            version: StableUpdateVersion("0.5.0")!, build: 14, executableSHA256: digest
        ) },
        { $0.stagedCandidate = VerifiedUpdateCandidate(
            version: StableUpdateVersion("0.5.0")!, build: 15, executableSHA256: changedDigest
        ) },
    ]
    for configure in cases {
        let operations = RecordingPreparationOperations()
        configure(operations)
        let result = await OneClickUpdatePreparationWorkflow(
            installedBuild: 14,
            operations: operations
        ).prepareAndLaunch(release: preparationRelease())
        guard case .failure = result else {
            Issue.record("expected candidate identity refusal")
            continue
        }
        #expect(!operations.events.contains("copySignedSupport"))
        #expect(!operations.events.contains("launchRunner"))
        #expect(operations.cleanupCount == 1)
        #expect(operations.detachCount == 1)
    }
}

@Test func unexpectedMountAndMalformedHashesFailClosed() async {
    let unexpectedMount = RecordingPreparationOperations()
    unexpectedMount.mountedPointOverride = URL(fileURLWithPath: "/Volumes/Unexpected")
    let mountResult = await OneClickUpdatePreparationWorkflow(
        installedBuild: 14,
        operations: unexpectedMount
    ).prepareAndLaunch(release: preparationRelease())
    #expect(preparationFailed(mountResult))
    #expect(unexpectedMount.detachCount == 1)

    let malformed = RecordingPreparationOperations()
    malformed.checksumDigest = "not-a-digest"
    let hashResult = await OneClickUpdatePreparationWorkflow(
        installedBuild: 14,
        operations: malformed
    ).prepareAndLaunch(release: preparationRelease())
    #expect(preparationFailed(hashResult))
    #expect(!malformed.events.contains("downloadDiskImage"))
}

@Test func everyInjectedFailureCleansAndNeverLaunchesPrematurely() async {
    for event in [
        "createWorkspace", "downloadChecksums", "digestChecksums", "readChecksums",
        "downloadDiskImage", "digestDiskImage", "verifyDiskImage", "mountDiskImage",
        "verifyMountedCandidate", "stageCandidate", "verifyStagedCandidate",
        "detachDiskImage", "copySignedSupport", "launchRunner",
    ] {
        let operations = RecordingPreparationOperations()
        operations.throwAt = event
        let result = await OneClickUpdatePreparationWorkflow(
            installedBuild: 14,
            operations: operations
        ).prepareAndLaunch(release: preparationRelease())
        guard case .failure = result else {
            Issue.record("expected injected failure at \(event)")
            continue
        }
        if event == "createWorkspace" {
            #expect(operations.cleanupCount == 0)
        } else {
            #expect(operations.cleanupCount == 1)
        }
        if event != "launchRunner" {
            #expect(!operations.events.contains("launchRunner"))
        }
    }
}
