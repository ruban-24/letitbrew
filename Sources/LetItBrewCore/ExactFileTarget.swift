import CryptoKit
import Darwin
import Foundation

final class OwnedFD {
    let rawValue: Int32
    init(taking rawValue: Int32) { self.rawValue = rawValue }
    deinit { Darwin.close(rawValue) }
}

/// A retained parent directory together with the identity used to prove a
/// fresh anchored traversal still reaches this very directory before a later
/// mutation.  The descriptor remains the authority for all `*at` calls.
final class BoundParent {
    let descriptor: OwnedFD
    let device: dev_t
    let inode: ino_t
    init(taking descriptor: OwnedFD) throws {
        var info = stat()
        guard fstat(descriptor.rawValue, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ExactFileSnapshotError.unreadable("bound parent")
        }
        self.descriptor = descriptor; device = info.st_dev; inode = info.st_ino
    }
}

public struct TraversalRaceHooks {
    public var afterComponentReportedMissingBeforeMkdir: ((Int) throws -> Void)?
    public var afterComponentOpenBeforeRouteValidation: ((Int) throws -> Void)?
    public init(afterComponentReportedMissingBeforeMkdir: ((Int) throws -> Void)? = nil, afterComponentOpenBeforeRouteValidation: ((Int) throws -> Void)? = nil) {
        self.afterComponentReportedMissingBeforeMkdir = afterComponentReportedMissingBeforeMkdir
        self.afterComponentOpenBeforeRouteValidation = afterComponentOpenBeforeRouteValidation
    }
}

public final class DirectoryAnchor {
    public let displayURL: URL
    private let fd: OwnedFD
    private init(url: URL, fd: Int32) { displayURL = url; self.fd = OwnedFD(taking: fd) }
    public static func openNoFollow(at url: URL) throws -> DirectoryAnchor {
        let path = url.standardizedFileURL.path
        let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw ExactFileSnapshotError.unreadable(path) }
        var info = stat(); guard fstat(opened, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { close(opened); throw ExactFileSnapshotError.notRegular(path) }
        return DirectoryAnchor(url: URL(fileURLWithPath: path), fd: opened)
    }
    public func target(atAbsoluteURL url: URL) throws -> ExactFileTarget {
        let root = displayURL.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.count > root.count, Array(target.prefix(root.count)) == root else { throw ExactFileSnapshotError.invalidPath(url.path) }
        let relative = Array(target.dropFirst(root.count))
        guard relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }) else { throw ExactFileSnapshotError.invalidPath(url.path) }
        return ExactFileTarget(displayPath: url.standardizedFileURL.path, root: self, relative: relative)
    }
    fileprivate func parent(for components: [String], creating: Bool, hooks: TraversalRaceHooks) throws -> (OwnedFD, String)? {
        guard let leaf = components.last else { throw ExactFileSnapshotError.invalidPath(displayURL.path) }
        let duplicated = fcntl(fd.rawValue, F_DUPFD_CLOEXEC, 0); guard duplicated >= 0 else { throw ExactFileSnapshotError.unreadable(displayURL.path) }
        var current = OwnedFD(taking: duplicated)
        for (index, component) in components.dropLast().enumerated() {
            let next = component.withCString { openat(current.rawValue, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else {
                if errno == ENOENT && !creating { return nil }
                if errno == ENOENT && creating {
                    try hooks.afterComponentReportedMissingBeforeMkdir?(index)
                    let created = component.withCString { mkdirat(current.rawValue, $0, 0o700) }
                    guard created == 0 || errno == EEXIST else { throw ExactFileSnapshotError.unreadable(displayURL.appendingPathComponent(component).path) }
                    let retried = component.withCString { openat(current.rawValue, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                    guard retried >= 0 else { throw ExactFileSnapshotError.unreadable(displayURL.appendingPathComponent(component).path) }
                    current = OwnedFD(taking: retried)
                    try hooks.afterComponentOpenBeforeRouteValidation?(index)
                    var info = stat(); guard fstat(current.rawValue, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw ExactFileSnapshotError.unreadable(displayURL.path) }
                    continue
                }
                throw ExactFileSnapshotError.unreadable(displayURL.path)
            }
            current = OwnedFD(taking: next)
            try hooks.afterComponentOpenBeforeRouteValidation?(index)
            var info = stat(); guard fstat(current.rawValue, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw ExactFileSnapshotError.unreadable(displayURL.path) }
        }
        return (current, leaf)
    }
}

public struct ExactFileTarget {
    public let displayPath: String
    private let root: DirectoryAnchor?
    private let relative: [String]?
    fileprivate init(displayPath: String, root: DirectoryAnchor?, relative: [String]?) { self.displayPath = displayPath; self.root = root; self.relative = relative }
    public func capture(hooks: TraversalRaceHooks = TraversalRaceHooks()) throws -> CapturedExactFile {
        if let root, let relative {
            guard let (parent, name) = try root.parent(for: relative, creating: false, hooks: hooks) else {
                return CapturedExactFile(target: self, capture: try ExactFileCapture(snapshot: ExactFileSnapshot(path: displayPath, exists: false), data: nil), parent: nil, name: nil, permissions: nil)
            }
            let bound = try BoundParent(taking: parent)
            let captured = try CapturedExactFile.captureFromParent(target: self, parent: bound, name: name, displayPath: displayPath)
            guard try revalidates(bound) else { throw ExactFileSnapshotError.changed(displayPath) }
            return captured
        }
        let url = URL(fileURLWithPath: displayPath)
        let parentURL = url.deletingLastPathComponent()
        let fd = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 && errno == ENOENT {
            return CapturedExactFile(target: self, capture: try ExactFileCapture(snapshot: ExactFileSnapshot(path: displayPath, exists: false), data: nil), parent: nil, name: nil, permissions: nil)
        }
        guard fd >= 0 else { throw ExactFileSnapshotError.unreadable(displayPath) }
        return try CapturedExactFile.captureFromParent(target: self, parent: BoundParent(taking: OwnedFD(taking: fd)), name: url.lastPathComponent, displayPath: displayPath)
    }
    /// Resolves only final-name JSON links beneath an anchored root.  The
    /// link identity brackets `readlinkat`, and every destination is fed back
    /// through the same structural anchor rather than a pathname prefix check.
    public func resolvingAnchoredFinalSymlink(maximumHops: Int = 32) throws -> ExactFileTarget {
        guard let root, relative != nil else { return self }
        var current = self; var hops = 0
        while true {
            guard let components = current.relative,
                  let (parentFD, name) = try root.parent(for: components, creating: false, hooks: TraversalRaceHooks()) else {
                if hops == 0 { return current }
                throw ExactFileSnapshotError.unreadable(current.displayPath)
            }
            let parent = try BoundParent(taking: parentFD)
            var before = stat()
            let stated = name.withCString { fstatat(parent.descriptor.rawValue, $0, &before, AT_SYMLINK_NOFOLLOW) }
            if stated != 0 {
                if errno == ENOENT && hops == 0 { return current }
                throw ExactFileSnapshotError.unreadable(current.displayPath)
            }
            if (before.st_mode & S_IFMT) != S_IFLNK {
                guard (before.st_mode & S_IFMT) == S_IFREG else { throw ExactFileSnapshotError.notRegular(current.displayPath) }
                return current
            }
            hops += 1; guard hops <= maximumHops else { throw ExactFileSnapshotError.changed(current.displayPath) }
            let capacity = max(Int(before.st_size) + 1, 4097)
            var destination = [CChar](repeating: 0, count: capacity)
            let read = name.withCString { readlinkat(parent.descriptor.rawValue, $0, &destination, destination.count - 1) }
            guard read >= 0 else { throw ExactFileSnapshotError.unreadable(current.displayPath) }
            var after = stat()
            guard name.withCString({ fstatat(parent.descriptor.rawValue, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0,
                  after.st_dev == before.st_dev, after.st_ino == before.st_ino, after.st_size == before.st_size,
                  (after.st_mode & S_IFMT) == S_IFLNK else { throw ExactFileSnapshotError.changed(current.displayPath) }
            let text = String(decoding: destination.prefix(Int(read)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let parentURL = URL(fileURLWithPath: current.displayPath).deletingLastPathComponent()
            let nextURL = URL(fileURLWithPath: text, relativeTo: parentURL).standardizedFileURL
            current = try root.target(atAbsoluteURL: nextURL)
        }
    }
    func captureForWrite(hooks: TraversalRaceHooks = TraversalRaceHooks()) throws -> CapturedExactFile {
        if let root, let relative {
            guard let (parent, name) = try root.parent(for: relative, creating: true, hooks: hooks) else { throw ExactFileSnapshotError.unreadable(displayPath) }
            let bound = try BoundParent(taking: parent)
            guard try revalidates(bound) else { throw ExactFileSnapshotError.changed(displayPath) }
            return try CapturedExactFile.captureFromParent(target: self, parent: bound, name: name, displayPath: displayPath)
        }
        let url = URL(fileURLWithPath: displayPath)
        let parentURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let fd = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ExactFileSnapshotError.unreadable(displayPath) }
        return try CapturedExactFile.captureFromParent(target: self, parent: BoundParent(taking: OwnedFD(taking: fd)), name: url.lastPathComponent, displayPath: displayPath)
    }
    func revalidates(_ bound: BoundParent) throws -> Bool {
        guard let root, let relative else { return true }
        guard let (fresh, _) = try root.parent(for: relative, creating: false, hooks: TraversalRaceHooks()) else { return false }
        var info = stat()
        guard fstat(fresh.rawValue, &info) == 0 else { return false }
        return info.st_dev == bound.device && info.st_ino == bound.inode
    }
}

public struct CapturedExactFile {
    public let target: ExactFileTarget
    public let capture: ExactFileCapture
    let parent: BoundParent?
    let name: String?
    let permissions: mode_t?
    public var data: Data? { capture.data }
    public var snapshot: ExactFileSnapshot { capture.snapshot }
    static func captureFromParent(target: ExactFileTarget, parent: BoundParent, name: String, displayPath: String) throws -> CapturedExactFile {
        let opened = name.withCString { openat(parent.descriptor.rawValue, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        if opened < 0 { if errno == ENOENT { return CapturedExactFile(target: target, capture: try ExactFileCapture(snapshot: ExactFileSnapshot(path: displayPath, exists: false), data: nil), parent: parent, name: name, permissions: nil) }; throw ExactFileSnapshotError.unreadable(displayPath) }
        defer { close(opened) }
        return try captureFromOpenFile(target: target, parent: parent, name: name, displayPath: displayPath, opened: opened)
    }
    static func captureFromOpenFile(target: ExactFileTarget, parent: BoundParent, name: String, displayPath: String, opened: Int32) throws -> CapturedExactFile {
        guard lseek(opened, 0, SEEK_SET) >= 0 else { throw ExactFileSnapshotError.unreadable(displayPath) }
        var before = stat(); guard fstat(opened, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw ExactFileSnapshotError.notRegular(displayPath) }
        let bytes = try readExactFileBytes(from: opened, expectedSize: before.st_size, path: displayPath)
        var after = stat(); guard fstat(opened, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ExactFileSnapshotError.changed(displayPath) }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let snapshot = try ExactFileSnapshot(path: displayPath, exists: true, deviceID: Int64(before.st_dev), inode: UInt64(before.st_ino), byteCount: Int64(before.st_size), modificationSeconds: Int64(before.st_mtimespec.tv_sec), modificationNanoseconds: Int64(before.st_mtimespec.tv_nsec), sha256: digest)
        return CapturedExactFile(target: target, capture: ExactFileCapture(snapshot: snapshot, data: bytes), parent: parent, name: name, permissions: before.st_mode & 0o7777)
    }
}
