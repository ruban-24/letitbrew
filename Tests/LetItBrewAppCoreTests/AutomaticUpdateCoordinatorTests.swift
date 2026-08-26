import Foundation
import Testing
@testable import LetItBrewAppCore

private final class AutomaticUpdateStore: AutomaticUpdatePersisting, @unchecked Sendable {
    var snapshot = AutomaticUpdateSnapshot(lastAttemptAt: nil, availableRelease: nil)

    func load() -> AutomaticUpdateSnapshot { snapshot }
    func save(_ snapshot: AutomaticUpdateSnapshot) { self.snapshot = snapshot }
}

private final class UpdateEnvironment: OneClickUpdateEnvironment, @unchecked Sendable {
    var fetchResult: Result<StableUpdateRelease, OneClickUpdateFailure>
    var fetchCount = 0

    init(fetchResult: Result<StableUpdateRelease, OneClickUpdateFailure>) {
        self.fetchResult = fetchResult
    }

    func fetchLatestStableRelease() async -> Result<StableUpdateRelease, OneClickUpdateFailure> {
        fetchCount += 1
        return fetchResult
    }

    func prepareAndLaunchInstaller(
        for release: StableUpdateRelease
    ) async -> Result<Void, OneClickUpdateFailure> {
        .success(())
    }
}

private actor SuspendedUpdateEnvironment: OneClickUpdateEnvironment {
    let release: StableUpdateRelease
    private var fetching = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(release: StableUpdateRelease) {
        self.release = release
    }

    func fetchLatestStableRelease() async -> Result<StableUpdateRelease, OneClickUpdateFailure> {
        fetching = true
        await withCheckedContinuation { continuation = $0 }
        return .success(release)
    }

    func prepareAndLaunchInstaller(
        for release: StableUpdateRelease
    ) async -> Result<Void, OneClickUpdateFailure> {
        .success(())
    }

    func isFetching() -> Bool { fetching }

    func resumeFetch() {
        continuation?.resume()
        continuation = nil
    }
}

private func release(version: String) -> StableUpdateRelease? {
    guard let version = StableUpdateVersion(version) else { return nil }
    let root = "https://github.com/ruban-24/letitbrew/releases/download/v\(version)"
    return StableUpdateRelease(
        version: version,
        dmg: UpdateAsset(
            name: "LetItBrew-\(version).dmg",
            downloadURL: URL(string: "\(root)/LetItBrew-\(version).dmg")!,
            size: 10,
            githubSHA256: nil
        ),
        checksums: UpdateAsset(
            name: "LetItBrew-\(version)-SHA256SUMS",
            downloadURL: URL(string: "\(root)/LetItBrew-\(version)-SHA256SUMS")!,
            size: 10,
            githubSHA256: nil
        )
    )
}

@Test func automaticSnapshotRoundTripsReleaseMetadata() throws {
    let cachedRelease = try #require(release(version: "0.6.6"))
    let snapshot = AutomaticUpdateSnapshot(
        lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_000),
        availableRelease: cachedRelease
    )

    #expect(try JSONDecoder().decode(
        AutomaticUpdateSnapshot.self,
        from: JSONEncoder().encode(snapshot)
    ) == snapshot)
}

@Test @MainActor func cancelledAutomaticCheckCannotRestoreClearedPreferences() async throws {
    let store = AutomaticUpdateStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let environment = SuspendedUpdateEnvironment(
        release: try #require(release(version: "0.6.6"))
    )
    let coordinator = AutomaticUpdateCoordinator(
        installedVersion: try #require(StableUpdateVersion("0.6.5")),
        environment: environment,
        persistence: store
    )

    let check = Task { @MainActor in await coordinator.runIfDue(at: now) }
    while !(await environment.isFetching()) { await Task.yield() }
    #expect(store.snapshot.lastAttemptAt == now)

    check.cancel()
    store.snapshot = AutomaticUpdateSnapshot(lastAttemptAt: nil, availableRelease: nil)
    await environment.resumeFetch()
    await check.value

    #expect(coordinator.availableRelease == nil)
    #expect(store.snapshot == AutomaticUpdateSnapshot(
        lastAttemptAt: nil,
        availableRelease: nil
    ))
}

@Test @MainActor func automaticCheckRunsOnlyWhenDueAndCachesNewerRelease() async throws {
    let store = AutomaticUpdateStore()
    let newest = try #require(release(version: "0.6.6"))
    let environment = UpdateEnvironment(fetchResult: .success(newest))
    let coordinator = AutomaticUpdateCoordinator(
        installedVersion: try #require(StableUpdateVersion("0.6.5")),
        environment: environment,
        persistence: store
    )
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    await coordinator.runIfDue(at: now)

    #expect(environment.fetchCount == 1)
    #expect(coordinator.availableRelease == newest)
    #expect(store.snapshot.lastAttemptAt == now)
    await coordinator.runIfDue(at: now.addingTimeInterval(
        AutomaticUpdateCoordinator.throttleInterval - 1
    ))
    #expect(environment.fetchCount == 1)
    await coordinator.runIfDue(at: now.addingTimeInterval(
        AutomaticUpdateCoordinator.throttleInterval
    ))
    #expect(environment.fetchCount == 2)
}

@Test @MainActor func automaticFailureIsSilentAndPreservesCachedRelease() async throws {
    let cached = try #require(release(version: "0.6.6"))
    let store = AutomaticUpdateStore()
    store.snapshot = AutomaticUpdateSnapshot(lastAttemptAt: nil, availableRelease: cached)
    let environment = UpdateEnvironment(fetchResult: .failure(
        OneClickUpdateFailure(
            kind: .discovery,
            message: "offline",
            diagnostic: "network unavailable"
        )
    ))
    let coordinator = AutomaticUpdateCoordinator(
        installedVersion: try #require(StableUpdateVersion("0.6.5")),
        environment: environment,
        persistence: store
    )

    await coordinator.runIfDue(at: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(coordinator.availableRelease == cached)
    #expect(store.snapshot.availableRelease == cached)
}

@Test @MainActor func automaticCheckClearsCachedReleaseWhenLatestIsNotNewer() async throws {
    let cached = try #require(release(version: "0.6.6"))
    let store = AutomaticUpdateStore()
    store.snapshot = AutomaticUpdateSnapshot(lastAttemptAt: nil, availableRelease: cached)
    let environment = UpdateEnvironment(fetchResult: .success(try #require(release(version: "0.6.5"))))
    let coordinator = AutomaticUpdateCoordinator(
        installedVersion: try #require(StableUpdateVersion("0.6.5")),
        environment: environment,
        persistence: store
    )

    await coordinator.runIfDue(at: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(coordinator.availableRelease == nil)
    #expect(store.snapshot.availableRelease == nil)
}

@Test @MainActor func initializationDiscardsAlreadyInstalledCachedRelease() throws {
    let store = AutomaticUpdateStore()
    let installedRelease = try #require(release(version: "0.6.5"))
    store.snapshot = AutomaticUpdateSnapshot(
        lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_000),
        availableRelease: installedRelease
    )
    let environment = UpdateEnvironment(fetchResult: .success(try #require(release(version: "0.6.6"))))
    let coordinator = AutomaticUpdateCoordinator(
        installedVersion: try #require(StableUpdateVersion("0.6.5")),
        environment: environment,
        persistence: store
    )

    #expect(coordinator.availableRelease == nil)
    #expect(store.snapshot.availableRelease == nil)
}

@Test @MainActor func interactiveUpdateStateKeepsAvailabilityInSync() throws {
    let store = AutomaticUpdateStore()
    let available = try #require(release(version: "0.6.6"))
    let environment = UpdateEnvironment(fetchResult: .success(available))
    let coordinator = AutomaticUpdateCoordinator(
        installedVersion: try #require(StableUpdateVersion("0.6.5")),
        environment: environment,
        persistence: store
    )

    coordinator.recordInteractiveState(.available(available))
    #expect(coordinator.availableRelease == available)
    #expect(store.snapshot.availableRelease == available)
    coordinator.recordInteractiveState(.upToDate(StableUpdateVersion("0.6.5")!))
    #expect(coordinator.availableRelease == nil)
    #expect(store.snapshot.availableRelease == nil)
    coordinator.recordInteractiveState(.available(try #require(release(version: "0.6.5"))))
    #expect(coordinator.availableRelease == nil)
    #expect(store.snapshot.availableRelease == nil)
}
