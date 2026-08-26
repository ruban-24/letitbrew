import Foundation
import Testing
@testable import LetItBrewAppCore

private func releaseJSON(
    tag: String = "v0.4.0",
    draft: Bool = false,
    prerelease: Bool = false,
    assets: String? = nil
) -> Data {
    let defaultAssets = """
    [
      {
        "name": "LetItBrew-0.4.0.dmg",
        "browser_download_url": "https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/LetItBrew-0.4.0.dmg",
        "size": 4587712,
        "digest": "sha256:2cd5bc9e91a9130fda426e19e4598227fb3f0af13ddc7c9bee2966dd594108f3"
      },
      {
        "name": "LetItBrew-0.4.0-SHA256SUMS",
        "browser_download_url": "https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/LetItBrew-0.4.0-SHA256SUMS",
        "size": 181,
        "digest": null
      }
    ]
    """
    return Data("""
    {
      "tag_name": "\(tag)",
      "draft": \(draft),
      "prerelease": \(prerelease),
      "assets": \(assets ?? defaultAssets)
    }
    """.utf8)
}

@Test func stableVersionsCompareNumerically() {
    #expect(StableUpdateVersion("0.10.0")! > StableUpdateVersion("0.9.9")!)
    #expect(StableUpdateVersion("1.0.0")! > StableUpdateVersion("0.99.99")!)
    #expect(StableUpdateVersion("1.2.3")?.description == "1.2.3")
}

@Test func malformedOrNonStableVersionsAreRejected() {
    for value in ["1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "1.2.-3", "1.2.3-beta"] {
        #expect(StableUpdateVersion(value) == nil)
    }
}

@Test func aValidStableReleaseParsesExactAssetsAndDigest() throws {
    let release = try StableUpdateReleaseParser.parse(releaseJSON())
    #expect(release.version == StableUpdateVersion("0.4.0"))
    #expect(release.dmg.name == "LetItBrew-0.4.0.dmg")
    #expect(release.dmg.githubSHA256 == "2cd5bc9e91a9130fda426e19e4598227fb3f0af13ddc7c9bee2966dd594108f3")
    #expect(release.checksums.name == "LetItBrew-0.4.0-SHA256SUMS")
}

@Test func draftsPrereleasesAndMalformedTagsFailClosed() {
    #expect(throws: UpdateReleaseValidationFailure.draftRelease) {
        try StableUpdateReleaseParser.parse(releaseJSON(draft: true))
    }
    #expect(throws: UpdateReleaseValidationFailure.prerelease) {
        try StableUpdateReleaseParser.parse(releaseJSON(prerelease: true))
    }
    #expect(throws: UpdateReleaseValidationFailure.invalidStableTag("0.4.0")) {
        try StableUpdateReleaseParser.parse(releaseJSON(tag: "0.4.0"))
    }
}

@Test func missingDuplicateAndUntrustedAssetsFailClosed() {
    #expect(throws: UpdateReleaseValidationFailure.missingAsset("LetItBrew-0.4.0-SHA256SUMS")) {
        try StableUpdateReleaseParser.parse(releaseJSON(assets: """
        [{"name":"LetItBrew-0.4.0.dmg","browser_download_url":"https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/LetItBrew-0.4.0.dmg","size":10,"digest":null}]
        """))
    }
    let duplicate = """
    [
      {"name":"LetItBrew-0.4.0.dmg","browser_download_url":"https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/a","size":10,"digest":null},
      {"name":"LetItBrew-0.4.0.dmg","browser_download_url":"https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/b","size":10,"digest":null},
      {"name":"LetItBrew-0.4.0-SHA256SUMS","browser_download_url":"https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/sums","size":10,"digest":null}
    ]
    """
    #expect(throws: UpdateReleaseValidationFailure.duplicateAsset("LetItBrew-0.4.0.dmg")) {
        try StableUpdateReleaseParser.parse(releaseJSON(assets: duplicate))
    }
    let untrusted = """
    [
      {"name":"LetItBrew-0.4.0.dmg","browser_download_url":"https://example.com/LetItBrew-0.4.0.dmg","size":10,"digest":null},
      {"name":"LetItBrew-0.4.0-SHA256SUMS","browser_download_url":"https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/sums","size":10,"digest":null}
    ]
    """
    #expect(throws: UpdateReleaseValidationFailure.invalidAssetURL("LetItBrew-0.4.0.dmg")) {
        try StableUpdateReleaseParser.parse(releaseJSON(assets: untrusted))
    }
    let deceptivePath = """
    [
      {"name":"LetItBrew-0.4.0.dmg","browser_download_url":"https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/LetItBrew-0.4.0.dmg/extra","size":10,"digest":null},
      {"name":"LetItBrew-0.4.0-SHA256SUMS","browser_download_url":"https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/LetItBrew-0.4.0-SHA256SUMS","size":10,"digest":null}
    ]
    """
    #expect(throws: UpdateReleaseValidationFailure.invalidAssetURL("LetItBrew-0.4.0.dmg")) {
        try StableUpdateReleaseParser.parse(releaseJSON(assets: deceptivePath))
    }
}

@Test func invalidSizesAndDigestsFailClosed() {
    let invalidSize = """
    [
      {"name":"LetItBrew-0.4.0.dmg","browser_download_url":"https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/LetItBrew-0.4.0.dmg","size":0,"digest":null},
      {"name":"LetItBrew-0.4.0-SHA256SUMS","browser_download_url":"https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/LetItBrew-0.4.0-SHA256SUMS","size":10,"digest":null}
    ]
    """
    #expect(throws: UpdateReleaseValidationFailure.invalidAssetSize("LetItBrew-0.4.0.dmg")) {
        try StableUpdateReleaseParser.parse(releaseJSON(assets: invalidSize))
    }
    let invalidDigest = """
    [
      {"name":"LetItBrew-0.4.0.dmg","browser_download_url":"https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/LetItBrew-0.4.0.dmg","size":10,"digest":"sha256:nope"},
      {"name":"LetItBrew-0.4.0-SHA256SUMS","browser_download_url":"https://github.com/ruban-24/letitbrew/releases/download/v0.4.0/LetItBrew-0.4.0-SHA256SUMS","size":10,"digest":null}
    ]
    """
    #expect(throws: UpdateReleaseValidationFailure.invalidAssetDigest("LetItBrew-0.4.0.dmg")) {
        try StableUpdateReleaseParser.parse(releaseJSON(assets: invalidDigest))
    }
}

@Test func checksumParserFindsTheExactPublishedDMGLine() throws {
    let data = Data("""
    2cd5bc9e91a9130fda426e19e4598227fb3f0af13ddc7c9bee2966dd594108f3  LetItBrew-0.4.0.dmg
    498e4e6c8053ee2d26d229325d66956ecec39bec61228bbd04c6c49bc720f958  LetItBrew-0.4.0-13.manifest
    """.utf8)
    #expect(try UpdateChecksumParser.sha256(for: "LetItBrew-0.4.0.dmg", in: data) ==
        "2cd5bc9e91a9130fda426e19e4598227fb3f0af13ddc7c9bee2966dd594108f3")
}

@Test func checksumParserRejectsMalformedMissingDuplicateAndUnsafeEntries() {
    #expect(throws: UpdateChecksumFailure.malformedLine(1)) {
        try UpdateChecksumParser.sha256(
            for: "LetItBrew-0.4.0.dmg",
            in: Data("not-a-checksum\n".utf8)
        )
    }
    let digest = String(repeating: "a", count: 64)
    #expect(throws: UpdateChecksumFailure.missingFilename("LetItBrew-0.4.0.dmg")) {
        try UpdateChecksumParser.sha256(for: "LetItBrew-0.4.0.dmg", in: Data("\(digest)  other\n".utf8))
    }
    #expect(throws: UpdateChecksumFailure.duplicateFilename("LetItBrew-0.4.0.dmg")) {
        try UpdateChecksumParser.sha256(
            for: "LetItBrew-0.4.0.dmg",
            in: Data("\(digest)  LetItBrew-0.4.0.dmg\n\(digest)  LetItBrew-0.4.0.dmg\n".utf8)
        )
    }
    #expect(throws: UpdateChecksumFailure.unsafeFilename(1)) {
        try UpdateChecksumParser.sha256(
            for: "LetItBrew-0.4.0.dmg",
            in: Data("\(digest)  ../LetItBrew-0.4.0.dmg\n".utf8)
        )
    }
}

@Test func detachedRunnerResultIsStrictAndInternallyConsistent() throws {
    #expect(try DetachedUpdateResultParser.parse(Data(
        #"{"status":"success","exitCode":0}"#.utf8
    )) == DetachedUpdateResult(outcome: .success, exitCode: 0))
    #expect(try DetachedUpdateResultParser.parse(Data(
        #"{"status":"failure","exitCode":7}"#.utf8
    )) == DetachedUpdateResult(outcome: .failure, exitCode: 7))

    for malformed in [
        #"{"status":"success","exitCode":0,"extra":true}"#,
        #"{"status":"unknown","exitCode":1}"#,
        #"{"status":"failure","exitCode":true}"#,
        #"{"status":"failure","exitCode":1.5}"#,
        #"{"status":"failure","exitCode":256}"#,
    ] {
        #expect(throws: DetachedUpdateResultFailure.malformed) {
            try DetachedUpdateResultParser.parse(Data(malformed.utf8))
        }
    }
    for inconsistent in [
        #"{"status":"success","exitCode":1}"#,
        #"{"status":"failure","exitCode":0}"#,
    ] {
        #expect(throws: DetachedUpdateResultFailure.inconsistent) {
            try DetachedUpdateResultParser.parse(Data(inconsistent.utf8))
        }
    }
}

private final class RecordingUpdateEnvironment: OneClickUpdateEnvironment, @unchecked Sendable {
    var fetched: Result<StableUpdateRelease, OneClickUpdateFailure>
    var installed: Result<Void, OneClickUpdateFailure> = .success(())
    var fetchCount = 0
    var installCount = 0

    init(release: StableUpdateRelease) {
        fetched = .success(release)
    }

    func fetchLatestStableRelease() async -> Result<StableUpdateRelease, OneClickUpdateFailure> {
        fetchCount += 1
        return fetched
    }

    func prepareAndLaunchInstaller(
        for release: StableUpdateRelease
    ) async -> Result<Void, OneClickUpdateFailure> {
        installCount += 1
        return installed
    }
}

private actor BlockingUpdateEnvironment: OneClickUpdateEnvironment {
    let release: StableUpdateRelease
    private var fetching = false
    private var installing = false
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var installContinuation: CheckedContinuation<Void, Never>?

    init(release: StableUpdateRelease) {
        self.release = release
    }

    func fetchLatestStableRelease() async -> Result<StableUpdateRelease, OneClickUpdateFailure> {
        fetching = true
        await withCheckedContinuation { fetchContinuation = $0 }
        return .success(release)
    }

    func prepareAndLaunchInstaller(
        for release: StableUpdateRelease
    ) async -> Result<Void, OneClickUpdateFailure> {
        installing = true
        await withCheckedContinuation { installContinuation = $0 }
        return .success(())
    }

    func isFetching() -> Bool { fetching }
    func isInstalling() -> Bool { installing }

    func resumeFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }

    func resumeInstall() {
        installContinuation?.resume()
        installContinuation = nil
    }
}

private func parsedRelease(_ version: String) throws -> StableUpdateRelease {
    try StableUpdateReleaseParser.parse(releaseJSON(tag: "v\(version)").replacingOccurrences(
        of: "0.4.0",
        with: version
    ))
}

private extension Data {
    func replacingOccurrences(of target: String, with replacement: String) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(
            of: target,
            with: replacement
        ).utf8)
    }
}

@Test @MainActor func currentOrOlderReleaseDoesNotInstall() async throws {
    for version in ["0.4.0", "0.3.9"] {
        let environment = RecordingUpdateEnvironment(release: try parsedRelease(version))
        let coordinator = OneClickUpdateCoordinator(
            installedVersion: StableUpdateVersion("0.4.0")!,
            environment: environment
        )
        await coordinator.check()
        #expect(coordinator.state == .upToDate(StableUpdateVersion("0.4.0")!))
        #expect(environment.installCount == 0)
    }
}

@Test @MainActor func aNewerReleaseRequiresConfirmationThenBecomesReadyToQuit() async throws {
    let release = try parsedRelease("0.5.0")
    let environment = RecordingUpdateEnvironment(release: release)
    let coordinator = OneClickUpdateCoordinator(
        installedVersion: StableUpdateVersion("0.4.0")!,
        environment: environment
    )

    await coordinator.check()
    #expect(coordinator.state == .available(release))
    #expect(environment.installCount == 0)
    await coordinator.confirmInstall()
    #expect(coordinator.state == .readyToQuit(StableUpdateVersion("0.5.0")!))
    #expect(environment.installCount == 1)
}

@Test @MainActor func cancellingAnAvailableUpdateChangesNothing() async throws {
    let release = try parsedRelease("0.5.0")
    let environment = RecordingUpdateEnvironment(release: release)
    let coordinator = OneClickUpdateCoordinator(
        installedVersion: StableUpdateVersion("0.4.0")!,
        environment: environment
    )
    await coordinator.check()
    coordinator.cancelInstall()
    #expect(coordinator.state == .idle)
    #expect(environment.installCount == 0)
}

@Test @MainActor func checkAndInstallFailuresRememberTheRightRetry() async throws {
    let release = try parsedRelease("0.5.0")
    let failure = OneClickUpdateFailure(
        kind: .discovery,
        message: "Could not update.",
        diagnostic: "offline"
    )
    let environment = RecordingUpdateEnvironment(release: release)
    let coordinator = OneClickUpdateCoordinator(
        installedVersion: StableUpdateVersion("0.4.0")!,
        environment: environment
    )
    environment.fetched = .failure(failure)
    await coordinator.check()
    #expect(coordinator.state == .failed(failure, retry: .check))

    environment.fetched = .success(release)
    await coordinator.retry()
    environment.installed = .failure(failure)
    await coordinator.confirmInstall()
    #expect(coordinator.state == .failed(failure, retry: .install(release)))
}

@Test @MainActor func cachedReleasePresentationAcceptsOnlyNewerIdleRelease() async throws {
    let newer = try parsedRelease("0.5.0")
    let environment = RecordingUpdateEnvironment(release: newer)
    let coordinator = OneClickUpdateCoordinator(
        installedVersion: StableUpdateVersion("0.4.0")!,
        environment: environment
    )

    coordinator.present(try parsedRelease("0.4.0"))
    #expect(coordinator.state == .idle)
    coordinator.present(newer)
    #expect(coordinator.state == .available(newer))
}

@Test @MainActor func cachedReleasePresentationDoesNotInterruptBusyStates() async throws {
    let newer = try parsedRelease("0.5.0")
    let environment = BlockingUpdateEnvironment(release: newer)
    let coordinator = OneClickUpdateCoordinator(
        installedVersion: StableUpdateVersion("0.4.0")!,
        environment: environment
    )

    let check = Task { @MainActor in await coordinator.check() }
    while !(await environment.isFetching()) { await Task.yield() }
    coordinator.present(newer)
    #expect(coordinator.state == .checking)
    await environment.resumeFetch()
    await check.value

    let install = Task { @MainActor in await coordinator.confirmInstall() }
    while !(await environment.isInstalling()) { await Task.yield() }
    coordinator.present(newer)
    #expect(coordinator.state == .installing(newer))
    await environment.resumeInstall()
    await install.value
    coordinator.present(newer)
    #expect(coordinator.state == .readyToQuit(StableUpdateVersion("0.5.0")!))
}
