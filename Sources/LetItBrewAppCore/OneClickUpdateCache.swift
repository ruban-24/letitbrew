import Foundation

/// Filesystem layout for one-click update workspaces under the user Caches
/// directory. Kept in AppCore so its idempotency contract is unit-testable
/// without the installed-app gates in the live operations.
public enum OneClickUpdateCache {
    /// Creates the persistent `Updates` base directory inside `appCache`,
    /// returning it. Owner-only (0700).
    ///
    /// The base lives at `<Caches>/com.ruban24.letitbrew/Updates` and persists
    /// across updates — `cleanFailedWorkspace` only removes the inner
    /// `Update.XXXXXX` workspace, never this parent. Creation therefore MUST
    /// tolerate an already-existing directory: `withIntermediateDirectories:
    /// false` here regressed into a 2nd-update failure
    /// ("The file "Updates" couldn't be saved ... a file with the same name
    /// already exists"). Callers harden ownership/mode after this returns.
    public static func prepareUpdatesBase(
        inAppCache appCache: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = appCache.appendingPathComponent("Updates", isDirectory: true)
        try fileManager.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return base
    }
}
