import LetItBrewAppCore
import Foundation

final class LiveOneClickUpdateEnvironment: OneClickUpdateEnvironment, @unchecked Sendable {
    private let bundle: Bundle
    private let installedBuild: UInt64?
    private let operations: LiveOneClickUpdateOperations

    init(
        bundle: Bundle = .main,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.bundle = bundle
        installedBuild = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap(UInt64.init)
        operations = LiveOneClickUpdateOperations(
            installedBundle: bundle,
            appProcessIdentifier: processIdentifier
        )
    }

    func fetchLatestStableRelease() async -> Result<StableUpdateRelease, OneClickUpdateFailure> {
        do {
            var request = URLRequest(url: StableUpdateReleaseParser.endpoint)
            request.httpMethod = "GET"
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let data = try await BoundedHTTPSResource.load(
                request: request,
                maximumBytes: 1_024 * 1_024,
                expectedBytes: nil,
                destination: nil
            )
            return .success(try StableUpdateReleaseParser.parse(data))
        } catch {
            return .failure(OneClickUpdateFailure(
                kind: .discovery,
                message: "Let It Brew couldn't check for updates.",
                diagnostic: "fetchLatestStableRelease: \(error.localizedDescription)"
            ))
        }
    }

    func prepareAndLaunchInstaller(
        for release: StableUpdateRelease
    ) async -> Result<Void, OneClickUpdateFailure> {
        guard let installedBuild else {
            return .failure(OneClickUpdateFailure(
                kind: .replacement,
                message: "Let It Brew couldn't identify the installed build. Nothing was changed.",
                diagnostic: "CFBundleVersion is missing or is not an unsigned decimal integer"
            ))
        }
        return await OneClickUpdatePreparationWorkflow(
            installedBuild: installedBuild,
            operations: operations
        ).prepareAndLaunch(release: release)
    }

    private var userAgent: String {
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        return "LetItBrew/\(version) (macOS; +https://github.com/ruban-24/letitbrew)"
    }
}
