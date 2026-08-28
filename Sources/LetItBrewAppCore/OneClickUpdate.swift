import Foundation

public struct StableUpdateVersion: Comparable, CustomStringConvertible, Codable, Equatable, Sendable {
    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var parsed: [UInt64] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  part == "0" || part.first != "0",
                  let component = UInt64(part)
            else { return nil }
            parsed.append(component)
        }
        major = parsed[0]
        minor = parsed[1]
        patch = parsed[2]
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public struct UpdateAsset: Codable, Equatable, Sendable {
    public let name: String
    public let downloadURL: URL
    public let size: Int64
    public let githubSHA256: String?

    public init(
        name: String,
        downloadURL: URL,
        size: Int64,
        githubSHA256: String?
    ) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.githubSHA256 = githubSHA256
    }
}

public struct StableUpdateRelease: Codable, Equatable, Sendable {
    public let version: StableUpdateVersion
    public let dmg: UpdateAsset
    public let checksums: UpdateAsset

    public init(
        version: StableUpdateVersion,
        dmg: UpdateAsset,
        checksums: UpdateAsset
    ) {
        self.version = version
        self.dmg = dmg
        self.checksums = checksums
    }
}

public enum UpdateReleaseValidationFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case draftRelease
    case prerelease
    case invalidStableTag(String)
    case missingAsset(String)
    case duplicateAsset(String)
    case invalidAssetURL(String)
    case invalidAssetSize(String)
    case invalidAssetDigest(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "GitHub returned update information Let It Brew could not read."
        case .draftRelease:
            "GitHub's latest Let It Brew release is still a draft."
        case .prerelease:
            "GitHub's latest Let It Brew release is not a published update."
        case .invalidStableTag(let tag):
            "GitHub's latest Let It Brew tag '\(tag)' is not a supported numeric version."
        case .missingAsset(let name):
            "The latest Let It Brew release is missing \(name)."
        case .duplicateAsset(let name):
            "The latest Let It Brew release contains more than one \(name)."
        case .invalidAssetURL(let name):
            "The latest Let It Brew release has an untrusted URL for \(name)."
        case .invalidAssetSize(let name):
            "The latest Let It Brew release has an invalid size for \(name)."
        case .invalidAssetDigest(let name):
            "The latest Let It Brew release has an invalid digest for \(name)."
        }
    }
}

public enum StableUpdateReleaseParser {
    public static let endpoint = URL(
        string: "https://api.github.com/repos/ruban-24/letitbrew/releases/latest"
    )!
    public static let maximumDMGSize: Int64 = 128 * 1_024 * 1_024
    public static let maximumChecksumSize: Int64 = 1_024 * 1_024

    public static func parse(_ data: Data) throws -> StableUpdateRelease {
        let response: GitHubReleaseResponse
        do {
            response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        } catch {
            throw UpdateReleaseValidationFailure.invalidResponse
        }
        guard !response.draft else { throw UpdateReleaseValidationFailure.draftRelease }
        guard !response.prerelease else { throw UpdateReleaseValidationFailure.prerelease }
        guard response.tagName.first == "v",
              let version = StableUpdateVersion(String(response.tagName.dropFirst()))
        else {
            throw UpdateReleaseValidationFailure.invalidStableTag(response.tagName)
        }

        let dmgName = "LetItBrew-\(version).dmg"
        let checksumName = "LetItBrew-\(version)-SHA256SUMS"
        let dmg = try asset(
            named: dmgName,
            in: response.assets,
            maximumSize: maximumDMGSize,
            releaseTag: response.tagName
        )
        let checksums = try asset(
            named: checksumName,
            in: response.assets,
            maximumSize: maximumChecksumSize,
            releaseTag: response.tagName
        )
        return StableUpdateRelease(version: version, dmg: dmg, checksums: checksums)
    }

    public static func validated(
        _ release: StableUpdateRelease
    ) throws -> StableUpdateRelease {
        let releaseTag = "v\(release.version)"
        try validate(
            release.dmg,
            named: "LetItBrew-\(release.version).dmg",
            maximumSize: maximumDMGSize,
            releaseTag: releaseTag
        )
        try validate(
            release.checksums,
            named: "LetItBrew-\(release.version)-SHA256SUMS",
            maximumSize: maximumChecksumSize,
            releaseTag: releaseTag
        )
        return release
    }

    private static func asset(
        named name: String,
        in assets: [GitHubAssetResponse],
        maximumSize: Int64,
        releaseTag: String
    ) throws -> UpdateAsset {
        let matches = assets.filter { $0.name == name }
        guard !matches.isEmpty else {
            throw UpdateReleaseValidationFailure.missingAsset(name)
        }
        guard matches.count == 1, let match = matches.first else {
            throw UpdateReleaseValidationFailure.duplicateAsset(name)
        }
        let digest: String?
        if let githubDigest = match.digest {
            let prefix = "sha256:"
            guard githubDigest.hasPrefix(prefix) else {
                throw UpdateReleaseValidationFailure.invalidAssetDigest(name)
            }
            let candidate = String(githubDigest.dropFirst(prefix.count)).lowercased()
            guard isSHA256(candidate) else {
                throw UpdateReleaseValidationFailure.invalidAssetDigest(name)
            }
            digest = candidate
        } else {
            digest = nil
        }
        let asset = UpdateAsset(
            name: name,
            downloadURL: match.downloadURL,
            size: match.size,
            githubSHA256: digest
        )
        try validate(
            asset,
            named: name,
            maximumSize: maximumSize,
            releaseTag: releaseTag
        )
        return asset
    }

    private static func validate(
        _ asset: UpdateAsset,
        named name: String,
        maximumSize: Int64,
        releaseTag: String
    ) throws {
        guard asset.name == name else {
            throw UpdateReleaseValidationFailure.missingAsset(name)
        }
        guard trustedReleaseAssetURL(
            asset.downloadURL,
            releaseTag: releaseTag,
            assetName: name
        ) else {
            throw UpdateReleaseValidationFailure.invalidAssetURL(name)
        }
        guard asset.size > 0, asset.size <= maximumSize else {
            throw UpdateReleaseValidationFailure.invalidAssetSize(name)
        }
        guard asset.githubSHA256.map(isSHA256) ?? true else {
            throw UpdateReleaseValidationFailure.invalidAssetDigest(name)
        }
    }

    private static func trustedReleaseAssetURL(
        _ url: URL,
        releaseTag: String,
        assetName: String
    ) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else { return false }
        return url.path == "/ruban-24/letitbrew/releases/download/\(releaseTag)/\(assetName)"
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum UpdateChecksumFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidEncoding
    case malformedLine(Int)
    case unsafeFilename(Int)
    case duplicateFilename(String)
    case missingFilename(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "The update checksum file is not valid UTF-8."
        case .malformedLine(let line):
            "The update checksum file has a malformed line at \(line)."
        case .unsafeFilename(let line):
            "The update checksum file has an unsafe filename at line \(line)."
        case .duplicateFilename(let filename):
            "The update checksum file lists \(filename) more than once."
        case .missingFilename(let filename):
            "The update checksum file does not list \(filename)."
        }
    }
}

public enum UpdateChecksumParser {
    public static func sha256(for expectedFilename: String, in data: Data) throws -> String {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw UpdateChecksumFailure.invalidEncoding
        }
        var values: [String: String] = [:]
        var lines = contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        )
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        for (offset, rawLine) in lines.enumerated() {
            guard !rawLine.isEmpty else {
                throw UpdateChecksumFailure.malformedLine(offset + 1)
            }
            let bytes = Array(rawLine.utf8)
            guard bytes.count > 66,
                  bytes[64] == 32,
                  bytes[65] == 32
            else {
                throw UpdateChecksumFailure.malformedLine(offset + 1)
            }
            let digest = String(decoding: bytes[0..<64], as: UTF8.self).lowercased()
            guard digest.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }) else {
                throw UpdateChecksumFailure.malformedLine(offset + 1)
            }
            guard let filename = String(bytes: bytes[66...], encoding: .utf8),
                  !filename.isEmpty
            else {
                throw UpdateChecksumFailure.malformedLine(offset + 1)
            }
            guard filename == URL(fileURLWithPath: filename).lastPathComponent,
                  filename != ".",
                  filename != "..",
                  !filename.contains("\\")
            else {
                throw UpdateChecksumFailure.unsafeFilename(offset + 1)
            }
            guard values[filename] == nil else {
                throw UpdateChecksumFailure.duplicateFilename(filename)
            }
            values[filename] = digest
        }
        guard let value = values[expectedFilename] else {
            throw UpdateChecksumFailure.missingFilename(expectedFilename)
        }
        return value
    }
}

public struct OneClickUpdateFailure: Error, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case discovery
        case download
        case verification
        case replacement
        case relaunch
    }

    public let kind: Kind
    public let message: String
    public let diagnostic: String

    public init(kind: Kind, message: String, diagnostic: String) {
        self.kind = kind
        self.message = message
        self.diagnostic = diagnostic
    }
}

public enum DetachedUpdateOutcome: String, Equatable, Sendable {
    case success
    case failure
}

public struct DetachedUpdateResult: Equatable, Sendable {
    public let outcome: DetachedUpdateOutcome
    public let exitCode: Int

    public init(outcome: DetachedUpdateOutcome, exitCode: Int) {
        self.outcome = outcome
        self.exitCode = exitCode
    }
}

public enum DetachedUpdateResultFailure: Error, Equatable, LocalizedError, Sendable {
    case malformed
    case inconsistent

    public var errorDescription: String? {
        switch self {
        case .malformed:
            "The detached updater result was malformed."
        case .inconsistent:
            "The detached updater result contradicted its exit code."
        }
    }
}

public enum DetachedUpdateResultParser {
    public static func parse(_ data: Data) throws -> DetachedUpdateResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["status", "exitCode"],
              let status = object["status"] as? String,
              let outcome = DetachedUpdateOutcome(rawValue: status),
              let number = object["exitCode"] as? NSNumber,
              integerNumberTypes.contains(String(cString: number.objCType))
        else {
            throw DetachedUpdateResultFailure.malformed
        }
        let exitCode = number.intValue
        guard (0...255).contains(exitCode) else {
            throw DetachedUpdateResultFailure.malformed
        }
        guard (outcome == .success && exitCode == 0)
                || (outcome == .failure && exitCode != 0)
        else {
            throw DetachedUpdateResultFailure.inconsistent
        }
        return DetachedUpdateResult(outcome: outcome, exitCode: exitCode)
    }

    private static let integerNumberTypes: Set<String> = [
        "s", "i", "l", "q", "S", "I", "L", "Q",
    ]
}

public enum OneClickUpdateRetry: Equatable, Sendable {
    case check
    case install(StableUpdateRelease)
}

public enum OneClickUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(StableUpdateVersion)
    case available(StableUpdateRelease)
    case installing(StableUpdateRelease)
    case readyToQuit(StableUpdateVersion)
    case failed(OneClickUpdateFailure, retry: OneClickUpdateRetry)
}

public protocol OneClickUpdateEnvironment: AnyObject, Sendable {
    func fetchLatestStableRelease() async -> Result<StableUpdateRelease, OneClickUpdateFailure>
    func prepareAndLaunchInstaller(
        for release: StableUpdateRelease
    ) async -> Result<Void, OneClickUpdateFailure>
}

@MainActor
public final class OneClickUpdateCoordinator {
    public private(set) var state: OneClickUpdateState = .idle

    private let installedVersion: StableUpdateVersion
    private let environment: any OneClickUpdateEnvironment

    public init(
        installedVersion: StableUpdateVersion,
        environment: any OneClickUpdateEnvironment
    ) {
        self.installedVersion = installedVersion
        self.environment = environment
    }

    public func check() async {
        guard !isBusy else { return }
        state = .checking
        switch await environment.fetchLatestStableRelease() {
        case .success(let release):
            state = release.version > installedVersion
                ? .available(release)
                : .upToDate(installedVersion)
        case .failure(let failure):
            state = .failed(failure, retry: .check)
        }
    }

    public func present(_ release: StableUpdateRelease) {
        guard !isBusy, release.version > installedVersion else { return }
        state = .available(release)
    }

    public func confirmInstall() async {
        guard case .available(let release) = state else { return }
        state = .installing(release)
        switch await environment.prepareAndLaunchInstaller(for: release) {
        case .success:
            state = .readyToQuit(release.version)
        case .failure(let failure):
            state = .failed(failure, retry: .install(release))
        }
    }

    public func cancelInstall() {
        guard case .available = state else { return }
        state = .idle
    }

    public func retry() async {
        guard case .failed(_, let retry) = state else { return }
        switch retry {
        case .check:
            await check()
        case .install(let release):
            state = .available(release)
            await confirmInstall()
        }
    }

    public func dismissStatus() {
        guard !isBusy else { return }
        state = .idle
    }

    private var isBusy: Bool {
        switch state {
        case .checking, .installing, .readyToQuit:
            true
        case .idle, .upToDate, .available, .failed:
            false
        }
    }
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubAssetResponse]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubAssetResponse: Decodable {
    let name: String
    let downloadURL: URL
    let size: Int64
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
        case digest
    }
}
