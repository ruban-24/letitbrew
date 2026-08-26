import Foundation

public struct AutomaticUpdateSnapshot: Codable, Equatable, Sendable {
    public var lastAttemptAt: Date?
    public var availableRelease: StableUpdateRelease?

    public init(lastAttemptAt: Date?, availableRelease: StableUpdateRelease?) {
        self.lastAttemptAt = lastAttemptAt
        self.availableRelease = availableRelease
    }
}

public protocol AutomaticUpdatePersisting: AnyObject, Sendable {
    func load() -> AutomaticUpdateSnapshot
    func save(_ snapshot: AutomaticUpdateSnapshot)
}

@MainActor
public final class AutomaticUpdateCoordinator {
    public static let launchDelay: Duration = .seconds(30)
    public static let throttleInterval: TimeInterval = 24 * 60 * 60
    public private(set) var availableRelease: StableUpdateRelease?

    private let installedVersion: StableUpdateVersion
    private let environment: any OneClickUpdateEnvironment
    private let persistence: any AutomaticUpdatePersisting
    private var snapshot: AutomaticUpdateSnapshot

    public init(
        installedVersion: StableUpdateVersion,
        environment: any OneClickUpdateEnvironment,
        persistence: any AutomaticUpdatePersisting
    ) {
        self.installedVersion = installedVersion
        self.environment = environment
        self.persistence = persistence
        snapshot = persistence.load()
        if let release = snapshot.availableRelease, release.version > installedVersion {
            availableRelease = release
        } else if snapshot.availableRelease != nil {
            snapshot.availableRelease = nil
            persistence.save(snapshot)
        }
    }

    public func runIfDue(at now: Date) async {
        guard snapshot.lastAttemptAt.map({ now.timeIntervalSince($0) >= Self.throttleInterval }) ?? true
        else { return }

        snapshot.lastAttemptAt = now
        persistence.save(snapshot)
        let result = await environment.fetchLatestStableRelease()
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let release):
            snapshot.availableRelease = release.version > installedVersion ? release : nil
            availableRelease = snapshot.availableRelease
            persistence.save(snapshot)
        case .failure:
            break
        }
    }

    public func recordInteractiveState(_ state: OneClickUpdateState) {
        switch state {
        case .available(let release):
            snapshot.availableRelease = release.version > installedVersion ? release : nil
            availableRelease = snapshot.availableRelease
        case .upToDate, .readyToQuit:
            snapshot.availableRelease = nil
            availableRelease = nil
        case .idle, .checking, .installing, .failed:
            return
        }
        persistence.save(snapshot)
    }
}
