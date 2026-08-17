import Foundation
import Darwin

/// Thrown when the target file changed between a caller's read and this
/// write — another process or a hand edit landed in that window. With no
/// lock file and no diffing, refusing is the only safe option; overwriting
/// could silently discard whatever the other write just did.
public struct ConcurrentModification: Error {
    public let path: String
    public init(path: String) { self.path = path }
}

/// An atomic, concurrent-edit-aware file write, shared by every command that
/// rewrites a user's config file (Claude Code's `settings.json`, Codex's
/// `hooks.json`).
public enum AtomicFile {
    /// The modification date of `url`, or `nil` if it does not exist (or any
    /// other stat failure — folded into `nil` the same way a missing file
    /// is, since a `nil` prior can never accidentally equal a later real
    /// date, so it always demands the concurrent-edit check below rather
    /// than risking a false "unchanged" match).
    public static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Writes `data` to `url`, but refuses if `url`'s modification date no
    /// longer matches `priorModified` — captured by the caller at read time.
    ///
    /// The check runs TWICE: once up front (fails fast, before doing any
    /// I/O, for the common case where nothing raced) and once again
    /// immediately before the rename that actually replaces `url` — after
    /// the new content has already been written to a temporary file on the
    /// same volume. Checking only up front, before the whole write, leaves
    /// the entire duration of that write as an unguarded window: an edit
    /// landing while the temp file is being written would still be silently
    /// overwritten by the rename. Re-checking right before the rename
    /// narrows that window to as small as it can be made without a lock
    /// file — just the time between the second read and the rename itself.
    ///
    /// `beforeRename` is a test-only seam (default a no-op) that runs after
    /// the temp file is written but before the second check, letting a test
    /// deterministically land a "concurrent" edit exactly inside the window
    /// this fix closes, without relying on real thread timing.
    public static func write(
        _ data: Data, to url: URL, ifUnchangedSince priorModified: Date?,
        beforeRename: () -> Void = {}
    ) throws {
        guard modificationDate(of: url) == priorModified else {
            throw ConcurrentModification(path: url.path)
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)

        beforeRename()

        guard modificationDate(of: url) == priorModified else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ConcurrentModification(path: url.path)
        }
        if priorModified == nil {
            try FileManager.default.moveItem(at: tempURL, to: url)
        } else {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        }
    }

    /// Descriptor-capture aware variant used by agent configuration and the
    /// registry.  It compares bytes, identity, size and nanosecond mtime
    /// immediately before publication instead of accepting a later mtime.
    public static func write(_ data: Data, to url: URL, ifUnchangedFrom capture: ExactFileCapture) throws {
        guard capture.snapshot.path == url.standardizedFileURL.path else { throw ConcurrentModification(path: url.path) }
        try capture.snapshot.verify()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        guard (try ExactFileCapture.capture(at: url)).snapshot == capture.snapshot else { try? FileManager.default.removeItem(at: tempURL); throw ConcurrentModification(path: url.path) }
        if capture.snapshot.exists { _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL) }
        else { try FileManager.default.moveItem(at: tempURL, to: url) }
    }

    /// Removes an owned regular file without ever unlinking the active name.
    /// The name is first moved aside, then the opened quarantine inode is
    /// validated and unlinked only if it is still that same inode.  This is
    /// deliberately a separate primitive from `write`: uninstall must not
    /// turn a concurrent replacement into an accidental deletion.
    public static func remove(
        _ url: URL,
        ifUnchangedFrom expectedData: Data,
        afterQuarantine: (URL) throws -> Void = { _ in },
        afterValidation: (URL) throws -> Void = { _ in }
    ) throws {
        let parent = url.deletingLastPathComponent()
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ConcurrentModification(path: url.path) }
        defer { close(fd) }
        let name = url.lastPathComponent
        var sourceStat = stat()
        let sourceResult = name.withCString { fstatat(fd, $0, &sourceStat, AT_SYMLINK_NOFOLLOW) }
        guard sourceResult == 0, (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw ConcurrentModification(path: url.path)
        }
        let quarantineName = ".\(name).\(UUID().uuidString).letitbrew-quarantine"
        let renamed = name.withCString { oldName in
            quarantineName.withCString { newName in
                renameatx_np(fd, oldName, fd, newName, UInt32(RENAME_EXCL))
            }
        }
        guard renamed == 0 else { throw ConcurrentModification(path: url.path) }
        let quarantine = parent.appendingPathComponent(quarantineName)
        do {
            try afterQuarantine(quarantine)
            let qfd = quarantineName.withCString { openat(fd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard qfd >= 0 else { throw ConcurrentModification(path: quarantine.path) }
            defer { close(qfd) }
            var captured = stat()
            guard fstat(qfd, &captured) == 0, (captured.st_mode & S_IFMT) == S_IFREG else {
                throw ConcurrentModification(path: quarantine.path)
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(qfd, &buffer, buffer.count)
                if count < 0 { throw ConcurrentModification(path: quarantine.path) }
                if count == 0 { break }
                data.append(buffer, count: Int(count))
            }
            try afterValidation(quarantine)
            func isCaptured() -> Bool {
                var current = stat()
                return quarantineName.withCString {
                    fstatat(fd, $0, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
                    current.st_dev == captured.st_dev && current.st_ino == captured.st_ino
                }
            }
            guard isCaptured() else { throw ConcurrentModification(path: quarantine.path) }
            if data != expectedData {
                // Restore only into an absent original name.  If something
                // appeared there, retain the quarantine as recovery evidence.
                let restored = quarantineName.withCString { oldName in
                    name.withCString { newName in renameatx_np(fd, oldName, fd, newName, UInt32(RENAME_EXCL)) }
                }
                if restored != 0 {
                    throw ConcurrentModification(path: "\(url.path) (recovery preserved at \(quarantine.path))")
                }
                throw ConcurrentModification(path: url.path)
            }
            guard isCaptured(), quarantineName.withCString({ unlinkat(fd, $0, 0) }) == 0 else {
                throw ConcurrentModification(path: quarantine.path)
            }
        } catch {
            throw error
        }
    }
}
