import CryptoKit
import Darwin
import Foundation

final class OwnedFD {
    let rawValue: Int32
    init(taking rawValue: Int32) { self.rawValue = rawValue }
    deinit { Darwin.close(rawValue) }
}

public struct TraversalRaceHooks {
    public var afterComponentOpenBeforeRouteValidation: ((Int) throws -> Void)?
    public init(afterComponentOpenBeforeRouteValidation: ((Int) throws -> Void)? = nil) {
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
    fileprivate func parent(for components: [String], hooks: TraversalRaceHooks) throws -> (OwnedFD, String) {
        guard let leaf = components.last else { throw ExactFileSnapshotError.invalidPath(displayURL.path) }
        let duplicated = fcntl(fd.rawValue, F_DUPFD_CLOEXEC, 0); guard duplicated >= 0 else { throw ExactFileSnapshotError.unreadable(displayURL.path) }
        var current = OwnedFD(taking: duplicated)
        for (index, component) in components.dropLast().enumerated() {
            let next = component.withCString { openat(current.rawValue, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else {
                if errno == ENOENT { throw ExactFileSnapshotError.unreadable(displayURL.appendingPathComponent(component).path) }
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
    public static func ordinary(_ url: URL) -> ExactFileTarget { ExactFileTarget(displayPath: url.standardizedFileURL.path, root: nil, relative: nil) }
    fileprivate init(displayPath: String, root: DirectoryAnchor?, relative: [String]?) { self.displayPath = displayPath; self.root = root; self.relative = relative }
    public func capture(hooks: TraversalRaceHooks = TraversalRaceHooks()) throws -> CapturedExactFile {
        if let root, let relative { let (parent, name) = try root.parent(for: relative, hooks: hooks); return try CapturedExactFile.capture(parent: parent, name: name, displayPath: displayPath) }
        return CapturedExactFile(target: self, capture: try ExactFileCapture.capture(at: URL(fileURLWithPath: displayPath)), parent: nil, name: nil)
    }
}

public struct CapturedExactFile {
    public let target: ExactFileTarget
    public let capture: ExactFileCapture
    fileprivate let parent: OwnedFD?
    fileprivate let name: String?
    public var data: Data? { capture.data }
    public var snapshot: ExactFileSnapshot { capture.snapshot }
    fileprivate static func capture(parent: OwnedFD, name: String, displayPath: String) throws -> CapturedExactFile {
        let opened = name.withCString { openat(parent.rawValue, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        if opened < 0 { if errno == ENOENT { return CapturedExactFile(target: ExactFileTarget(displayPath: displayPath, root: nil, relative: nil), capture: try ExactFileCapture(snapshot: ExactFileSnapshot(path: displayPath, exists: false), data: nil), parent: parent, name: name) }; throw ExactFileSnapshotError.unreadable(displayPath) }
        defer { close(opened) }
        var before = stat(); guard fstat(opened, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw ExactFileSnapshotError.notRegular(displayPath) }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true { let count = read(opened, &buffer, buffer.count); if count < 0 { throw ExactFileSnapshotError.unreadable(displayPath) }; if count == 0 { break }; bytes.append(buffer, count: Int(count)) }
        var after = stat(); guard fstat(opened, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ExactFileSnapshotError.changed(displayPath) }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let snapshot = try ExactFileSnapshot(path: displayPath, exists: true, deviceID: Int64(before.st_dev), inode: UInt64(before.st_ino), byteCount: Int64(before.st_size), modificationSeconds: Int64(before.st_mtimespec.tv_sec), modificationNanoseconds: Int64(before.st_mtimespec.tv_nsec), sha256: digest)
        return CapturedExactFile(target: ExactFileTarget(displayPath: displayPath, root: nil, relative: nil), capture: ExactFileCapture(snapshot: snapshot, data: bytes), parent: parent, name: name)
    }
}
