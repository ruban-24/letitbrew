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
    public enum Permissions { case preserveExisting(defaultMode: mode_t), exact(mode_t) }
    public struct RaceHooks {
        public var beforeQuarantine: (() throws -> Void)?
        public var afterQuarantineMoveBeforeValidation: ((String) throws -> Void)?
        public var afterQuarantineValidationBeforePublish: (() throws -> Void)?
        public var beforeAbsentPublish: (() throws -> Void)?
        public var beforePublish: ((String) throws -> Void)?
        public var beforeQuarantineCleanup: ((String) throws -> Void)?
        public var beforeTempCleanup: ((String) throws -> Void)?
        /// Runs after the exclusive rename but before the final active-name
        /// identity proof.  It makes the otherwise tiny rename-to-proof race
        /// deterministic without weakening the production protocol.
        public var afterPublish: (() throws -> Void)?
        /// Test-only deterministic name sources. Production keeps UUID names;
        /// retries make a hostile/colliding directory entry harmless.
        public var temporaryName: ((Int) -> String)?
        public var quarantineName: ((Int) -> String)?
        /// A narrow failure seam for the required directory durability sync.
        public var beforeParentSync: (() throws -> Void)?
        public init(beforeQuarantine: (() throws -> Void)? = nil, afterQuarantineMoveBeforeValidation: ((String) throws -> Void)? = nil, afterQuarantineValidationBeforePublish: (() throws -> Void)? = nil, beforeAbsentPublish: (() throws -> Void)? = nil, beforePublish: ((String) throws -> Void)? = nil, beforeQuarantineCleanup: ((String) throws -> Void)? = nil, beforeTempCleanup: ((String) throws -> Void)? = nil, afterPublish: (() throws -> Void)? = nil, temporaryName: ((Int) -> String)? = nil, quarantineName: ((Int) -> String)? = nil, beforeParentSync: (() throws -> Void)? = nil) {
            self.beforeQuarantine = beforeQuarantine
            self.afterQuarantineMoveBeforeValidation = afterQuarantineMoveBeforeValidation
            self.afterQuarantineValidationBeforePublish = afterQuarantineValidationBeforePublish
            self.beforeAbsentPublish = beforeAbsentPublish
            self.beforePublish = beforePublish
            self.beforeQuarantineCleanup = beforeQuarantineCleanup
            self.beforeTempCleanup = beforeTempCleanup
            self.afterPublish = afterPublish
            self.temporaryName = temporaryName
            self.quarantineName = quarantineName
            self.beforeParentSync = beforeParentSync
        }
    }

    /// Narrow test-only action for the command's active-replacement race.
    /// It deliberately publishes a foreign active name through the retained
    /// parent descriptor, after route revalidation, so a swapped lexical
    /// component cannot redirect the test seam outside an anchored test home.
    public static func testOnlyPublishActiveReplacement(_ captured: CapturedExactFile, data: Data) throws {
        guard let parent = captured.parent, let name = captured.name,
              try captured.target.revalidates(parent) else {
            throw ConcurrentModification(path: captured.snapshot.path)
        }
        let descriptor = name.withCString {
            openat(parent.descriptor.rawValue, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw ConcurrentModification(path: captured.snapshot.path) }
        defer { close(descriptor) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ConcurrentModification(path: captured.snapshot.path) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw ConcurrentModification(path: captured.snapshot.path) }
    }

    /// Descriptor-native publication for an anchored target.  The retained
    /// parent descriptor is the only namespace used for temp/quarantine names.
    @discardableResult public static func write(_ data: Data, replacing input: CapturedExactFile, permissions: Permissions = .preserveExisting(defaultMode: 0o600), hooks: RaceHooks = RaceHooks()) throws -> CapturedExactFile {
        let captured: CapturedExactFile
        if input.parent != nil, input.name != nil {
            captured = input
        } else {
            guard !input.snapshot.exists else { throw ConcurrentModification(path: input.snapshot.path) }
            captured = try input.target.captureForWrite()
            guard !captured.snapshot.exists else { throw ConcurrentModification(path: captured.snapshot.path) }
        }
        guard let parent = captured.parent, let name = captured.name else { throw ConcurrentModification(path: captured.snapshot.path) }
        guard try captured.target.revalidates(parent) else { throw ConcurrentModification(path: captured.snapshot.path) }
        let mode: mode_t = {
            switch permissions {
            case .exact(let value): return value
            case .preserveExisting(let defaultMode): return captured.permissions ?? defaultMode
            }
        }()
        func namedPath(_ entry: String) -> String {
            URL(fileURLWithPath: captured.snapshot.path).deletingLastPathComponent().appendingPathComponent(entry).path
        }
        func stillNames(_ fileName: String, _ expected: stat) -> Bool {
            var current = stat()
            return fileName.withCString { fstatat(parent.descriptor.rawValue, $0, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
                current.st_dev == expected.st_dev && current.st_ino == expected.st_ino && (current.st_mode & S_IFMT) == S_IFREG }
        }
        func sameSnapshotIdentity(_ fileName: String, _ snapshot: ExactFileSnapshot) -> Bool {
            guard snapshot.exists, let device = snapshot.deviceID, let inode = snapshot.inode else { return false }
            var current = stat()
            return fileName.withCString { fstatat(parent.descriptor.rawValue, $0, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
                Int64(current.st_dev) == device && UInt64(current.st_ino) == inode && (current.st_mode & S_IFMT) == S_IFREG }
        }
        func synchronizeParent() throws {
            try hooks.beforeParentSync?()
            guard fsync(parent.descriptor.rawValue) == 0 else { throw ConcurrentModification(path: captured.snapshot.path) }
        }
        func makeTemp() throws -> (String, Int32, stat) {
            for attempt in 0..<16 {
                let candidate = hooks.temporaryName?(attempt) ?? ".\(name).\(UUID().uuidString).exact"
                let opened = candidate.withCString { openat(parent.descriptor.rawValue, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode) }
                if opened < 0 && errno == EEXIST { continue }
                guard opened >= 0 else { throw ConcurrentModification(path: captured.snapshot.path) }
                var info = stat()
                guard fstat(opened, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(opened); throw ConcurrentModification(path: captured.snapshot.path) }
                return (candidate, opened, info)
            }
            throw ConcurrentModification(path: captured.snapshot.path)
        }
        func restore(_ quarantine: String, opened: CapturedExactFile) -> ConcurrentModification {
            guard sameSnapshotIdentity(quarantine, opened.snapshot) else {
                return ConcurrentModification(path: "\(captured.snapshot.path) (recovery preserved at \(namedPath(quarantine)))")
            }
            let restored = quarantine.withCString { from in
                name.withCString { to in renameatx_np(parent.descriptor.rawValue, from, parent.descriptor.rawValue, to, UInt32(RENAME_EXCL)) }
            }
            guard restored == 0 else {
                return ConcurrentModification(path: "\(captured.snapshot.path) (recovery preserved at \(namedPath(quarantine)))")
            }
            // The caller still receives the conflict, but the configured name
            // is no longer missing after a detected hand edit.
            _ = fsync(parent.descriptor.rawValue)
            return ConcurrentModification(path: captured.snapshot.path)
        }
        let (temp, tempFD, initialTempInfo) = try makeTemp()
        defer { close(tempFD) }
        guard fchmod(tempFD, mode) == 0 else { throw ConcurrentModification(path: captured.snapshot.path) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(tempFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ConcurrentModification(path: captured.snapshot.path) }
                offset += written
            }
        }
        guard fsync(tempFD) == 0 else { throw ConcurrentModification(path: captured.snapshot.path) }
        var temporaryInfo = stat()
        guard fstat(tempFD, &temporaryInfo) == 0, temporaryInfo.st_dev == initialTempInfo.st_dev, temporaryInfo.st_ino == initialTempInfo.st_ino else { throw ConcurrentModification(path: captured.snapshot.path) }
        func cleanup() {
            try? hooks.beforeTempCleanup?(temp)
            guard stillNames(temp, temporaryInfo) else { return }
            temp.withCString { _ = unlinkat(parent.descriptor.rawValue, $0, 0) }
        }
        if !captured.snapshot.exists {
            try hooks.beforeAbsentPublish?()
            try hooks.beforePublish?(temp)
            guard stillNames(temp, temporaryInfo) else { cleanup(); throw ConcurrentModification(path: "\(captured.snapshot.path) (foreign temporary preserved)") }
            let result = temp.withCString { from in name.withCString { to in renameatx_np(parent.descriptor.rawValue, from, parent.descriptor.rawValue, to, UInt32(RENAME_EXCL)) } }
            guard result == 0 else { cleanup(); throw ConcurrentModification(path: captured.snapshot.path) }
            try hooks.afterPublish?()
            guard stillNames(name, temporaryInfo) else { throw ConcurrentModification(path: "\(captured.snapshot.path) (published name replaced)") }
            try synchronizeParent()
            return try CapturedExactFile.captureFromOpenFile(target: captured.target, parent: parent, name: name, displayPath: captured.snapshot.path, opened: tempFD)
        }
        try hooks.beforeQuarantine?()
        guard sameSnapshotIdentity(name, captured.snapshot) else { cleanup(); throw ConcurrentModification(path: captured.snapshot.path) }
        var quarantine: String?
        for attempt in 0..<16 {
            let candidate = hooks.quarantineName?(attempt) ?? ".\(name).\(UUID().uuidString).quarantine"
            let moved = name.withCString { from in candidate.withCString { to in renameatx_np(parent.descriptor.rawValue, from, parent.descriptor.rawValue, to, UInt32(RENAME_EXCL)) } }
            if moved == 0 { quarantine = candidate; break }
            if errno != EEXIST { break }
        }
        guard let quarantine else { cleanup(); throw ConcurrentModification(path: captured.snapshot.path) }
        try hooks.afterQuarantineMoveBeforeValidation?(quarantine)
        let quarantined = try CapturedExactFile.captureFromParent(target: captured.target, parent: parent, name: quarantine, displayPath: captured.snapshot.path)
        guard quarantined.capture == captured.capture else { cleanup(); throw restore(quarantine, opened: quarantined) }
        try hooks.afterQuarantineValidationBeforePublish?()
        try hooks.beforePublish?(temp)
        guard stillNames(temp, temporaryInfo) else { cleanup(); throw ConcurrentModification(path: "\(captured.snapshot.path) (foreign temporary preserved)") }
        let published = temp.withCString { from in name.withCString { to in renameatx_np(parent.descriptor.rawValue, from, parent.descriptor.rawValue, to, UInt32(RENAME_EXCL)) } }
        guard published == 0 else { cleanup(); throw ConcurrentModification(path: "\(captured.snapshot.path) (recovery preserved)") }
        try hooks.afterPublish?()
        guard stillNames(name, temporaryInfo) else { throw ConcurrentModification(path: "\(captured.snapshot.path) (published name replaced; recovery preserved at \(namedPath(quarantine)))") }
        try synchronizeParent()
        try hooks.beforeQuarantineCleanup?(quarantine)
        var quarantineInfo = stat()
        guard quarantine.withCString({ fstatat(parent.descriptor.rawValue, $0, &quarantineInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
              Int64(quarantineInfo.st_dev) == quarantined.snapshot.deviceID,
              UInt64(quarantineInfo.st_ino) == quarantined.snapshot.inode else { throw ConcurrentModification(path: "\(captured.snapshot.path) (quarantine recovery preserved)") }
        guard quarantine.withCString({ unlinkat(parent.descriptor.rawValue, $0, 0) }) == 0 else { throw ConcurrentModification(path: captured.snapshot.path) }
        try synchronizeParent()
        return try CapturedExactFile.captureFromOpenFile(target: captured.target, parent: parent, name: name, displayPath: captured.snapshot.path, opened: tempFD)
    }

    public static func remove(_ captured: CapturedExactFile, expectedData: Data, hooks: RaceHooks = RaceHooks()) throws {
        guard let parent = captured.parent, let name = captured.name, captured.data == expectedData, try captured.target.revalidates(parent) else { throw ConcurrentModification(path: captured.snapshot.path) }
        func namedPath(_ entry: String) -> String {
            URL(fileURLWithPath: captured.snapshot.path).deletingLastPathComponent().appendingPathComponent(entry).path
        }
        func matches(_ entry: String, _ snapshot: ExactFileSnapshot) -> Bool {
            guard snapshot.exists, let device = snapshot.deviceID, let inode = snapshot.inode else { return false }
            var info = stat()
            return entry.withCString { fstatat(parent.descriptor.rawValue, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
                Int64(info.st_dev) == device && UInt64(info.st_ino) == inode && (info.st_mode & S_IFMT) == S_IFREG }
        }
        func restore(_ quarantine: String, observed: CapturedExactFile) -> ConcurrentModification {
            guard matches(quarantine, observed.snapshot) else {
                return ConcurrentModification(path: "\(captured.snapshot.path) (recovery preserved at \(namedPath(quarantine)))")
            }
            let restored = quarantine.withCString { from in name.withCString { to in renameatx_np(parent.descriptor.rawValue, from, parent.descriptor.rawValue, to, UInt32(RENAME_EXCL)) } }
            guard restored == 0 else {
                return ConcurrentModification(path: "\(captured.snapshot.path) (recovery preserved at \(namedPath(quarantine)))")
            }
            _ = fsync(parent.descriptor.rawValue)
            return ConcurrentModification(path: captured.snapshot.path)
        }
        try hooks.beforeQuarantine?()
        guard matches(name, captured.snapshot) else { throw ConcurrentModification(path: captured.snapshot.path) }
        var quarantine: String?
        for attempt in 0..<16 {
            let candidate = hooks.quarantineName?(attempt) ?? ".\(name).\(UUID().uuidString).remove-quarantine"
            let moved = name.withCString { from in candidate.withCString { to in renameatx_np(parent.descriptor.rawValue, from, parent.descriptor.rawValue, to, UInt32(RENAME_EXCL)) } }
            if moved == 0 { quarantine = candidate; break }
            if errno != EEXIST { break }
        }
        guard let quarantine else { throw ConcurrentModification(path: captured.snapshot.path) }
        try hooks.afterQuarantineMoveBeforeValidation?(quarantine)
        let observed = try CapturedExactFile.captureFromParent(target: captured.target, parent: parent, name: quarantine, displayPath: captured.snapshot.path)
        guard observed.capture == captured.capture, observed.data == expectedData else { throw restore(quarantine, observed: observed) }
        try hooks.afterQuarantineValidationBeforePublish?()
        try hooks.beforeQuarantineCleanup?(quarantine)
        var info = stat()
        guard quarantine.withCString({ fstatat(parent.descriptor.rawValue, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
              Int64(info.st_dev) == observed.snapshot.deviceID,
              UInt64(info.st_ino) == observed.snapshot.inode else { throw ConcurrentModification(path: "\(captured.snapshot.path) (quarantine recovery preserved)") }
        guard quarantine.withCString({ unlinkat(parent.descriptor.rawValue, $0, 0) }) == 0 else { throw ConcurrentModification(path: captured.snapshot.path) }
        try hooks.beforeParentSync?()
        guard fsync(parent.descriptor.rawValue) == 0 else { throw ConcurrentModification(path: captured.snapshot.path) }
    }
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
    public static func write(
        _ data: Data, to url: URL, ifUnchangedFrom capture: ExactFileCapture,
        afterFinalValidation: () throws -> Void = {}, privateMode: Bool = false
    ) throws {
        guard capture.snapshot.path == url.standardizedFileURL.path else { throw ConcurrentModification(path: url.path) }
        let parent = url.deletingLastPathComponent(); let name = url.lastPathComponent
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { throw ConcurrentModification(path: url.path) }
        defer { close(parentFD) }
        let temporaryName = ".\(name).\(UUID().uuidString).letitbrew-write"
        let temporary = parent.appendingPathComponent(temporaryName)
        try data.write(to: temporary, options: .atomic)
        if privateMode { guard chmod(temporary.path, S_IRUSR | S_IWUSR) == 0 else { try? FileManager.default.removeItem(at: temporary); throw ConcurrentModification(path: temporary.path) } }
        func cleanupTemp() { try? FileManager.default.removeItem(at: temporary) }
        func matches(_ fileName: String) -> Bool {
            var info = stat()
            return fileName.withCString { fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
                capture.snapshot.exists && Int64(info.st_dev) == capture.snapshot.deviceID && UInt64(info.st_ino) == capture.snapshot.inode &&
                Int64(info.st_size) == capture.snapshot.byteCount && Int64(info.st_mtimespec.tv_sec) == capture.snapshot.modificationSeconds && Int64(info.st_mtimespec.tv_nsec) == capture.snapshot.modificationNanoseconds }
        }
        if !capture.snapshot.exists {
            let published = temporaryName.withCString { from in name.withCString { to in renameatx_np(parentFD, from, parentFD, to, UInt32(RENAME_EXCL)) } }
            guard published == 0 else { cleanupTemp(); throw ConcurrentModification(path: url.path) }
            return
        }
        guard matches(name) else { cleanupTemp(); throw ConcurrentModification(path: url.path) }
        let quarantineName = ".\(name).\(UUID().uuidString).letitbrew-write-quarantine"
        let moved = name.withCString { from in quarantineName.withCString { to in renameatx_np(parentFD, from, parentFD, to, UInt32(RENAME_EXCL)) } }
        guard moved == 0, matches(quarantineName) else {
            cleanupTemp(); throw ConcurrentModification(path: url.path)
        }
        do { try afterFinalValidation() } catch { cleanupTemp(); throw error }
        let published = temporaryName.withCString { from in name.withCString { to in renameatx_np(parentFD, from, parentFD, to, UInt32(RENAME_EXCL)) } }
        guard published == 0 else { cleanupTemp(); throw ConcurrentModification(path: "\(url.path) (recovery preserved at \(parent.appendingPathComponent(quarantineName).path))") }
        guard quarantineName.withCString({ unlinkat(parentFD, $0, 0) }) == 0 else { throw ConcurrentModification(path: parent.appendingPathComponent(quarantineName).path) }
    }

    /// Removes an owned regular file without ever unlinking the active name.
    /// The name is first moved aside, then the opened quarantine inode is
    /// validated and unlinked only if it is still that same inode.  This is
    /// deliberately a separate primitive from `write`: uninstall must not
    /// turn a concurrent replacement into an accidental deletion.
    public static func remove(
        _ url: URL,
        ifUnchangedFrom expectedData: Data,
        beforeQuarantine: () throws -> Void = {},
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
        // Test seam for the otherwise tiny fstatat-to-rename window.  The
        // quarantine descriptor is compared back to `sourceStat` below, so a
        // replacement that wins this race is retained rather than unlinked.
        try beforeQuarantine()
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
            guard fstat(qfd, &captured) == 0, (captured.st_mode & S_IFMT) == S_IFREG,
                  captured.st_dev == sourceStat.st_dev, captured.st_ino == sourceStat.st_ino else {
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
