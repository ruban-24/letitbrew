import CryptoKit
import Darwin
import Foundation

/// Immutable evidence for one exact filesystem name.  This is intentionally
/// stronger than a modification date: a same-size edit with a restored mtime,
/// or an inode replacement containing identical bytes, is still refused.
public struct ExactFileSnapshot: Codable, Equatable, Sendable {
    public let path: String
    public let exists: Bool
    public let deviceID: Int64?
    public let inode: UInt64?
    public let byteCount: Int64?
    public let modificationSeconds: Int64?
    public let modificationNanoseconds: Int64?
    public let sha256: String?

    public init(path: String, exists: Bool, deviceID: Int64? = nil, inode: UInt64? = nil,
                byteCount: Int64? = nil, modificationSeconds: Int64? = nil,
                modificationNanoseconds: Int64? = nil, sha256: String? = nil) throws {
        guard path.hasPrefix("/") else { throw ExactFileSnapshotError.invalidPath(path) }
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.exists = exists
        if exists {
            guard deviceID != nil, inode != nil, byteCount != nil, modificationSeconds != nil,
                  modificationNanoseconds != nil, sha256 != nil else { throw ExactFileSnapshotError.invalidEvidence }
            guard byteCount! >= 0, modificationNanoseconds! >= 0, modificationNanoseconds! < 1_000_000_000,
                  sha256!.count == 64, sha256!.allSatisfy({ $0.isHexDigit }) else { throw ExactFileSnapshotError.invalidEvidence }
        } else if [deviceID.map { _ in 1 }, inode.map { _ in 1 }, byteCount.map { _ in 1 }, modificationSeconds.map { _ in 1 }, modificationNanoseconds.map { _ in 1 }, sha256.map { _ in 1 }].contains(where: { $0 != nil }) {
            throw ExactFileSnapshotError.invalidEvidence
        }
        self.deviceID = deviceID; self.inode = inode; self.byteCount = byteCount
        self.modificationSeconds = modificationSeconds; self.modificationNanoseconds = modificationNanoseconds; self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case path, exists, deviceID, inode, byteCount, modificationSeconds, modificationNanoseconds, sha256 }
    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyExactCodingKey.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw ExactFileSnapshotError.invalidEvidence
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(path: try c.decode(String.self, forKey: .path),
                      exists: try c.decode(Bool.self, forKey: .exists),
                      deviceID: try c.decodeIfPresent(Int64.self, forKey: .deviceID),
                      inode: try c.decodeIfPresent(UInt64.self, forKey: .inode),
                      byteCount: try c.decodeIfPresent(Int64.self, forKey: .byteCount),
                      modificationSeconds: try c.decodeIfPresent(Int64.self, forKey: .modificationSeconds),
                      modificationNanoseconds: try c.decodeIfPresent(Int64.self, forKey: .modificationNanoseconds),
                      sha256: try c.decodeIfPresent(String.self, forKey: .sha256))
    }

    public static func capture(at url: URL) throws -> ExactFileSnapshot {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { throw ExactFileSnapshotError.invalidPath(path) }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return try ExactFileSnapshot(path: path, exists: false) }
            throw ExactFileSnapshotError.unreadable(path)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ExactFileSnapshotError.notRegular(path) }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true { let n = read(fd, &buffer, buffer.count); if n < 0 { throw ExactFileSnapshotError.unreadable(path) }; if n == 0 { break }; bytes.append(buffer, count: Int(n)) }
        return try ExactFileSnapshot(path: path, exists: true, deviceID: Int64(info.st_dev), inode: UInt64(info.st_ino), byteCount: Int64(info.st_size), modificationSeconds: Int64(info.st_mtimespec.tv_sec), modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    public func verify() throws {
        guard try ExactFileSnapshot.capture(at: URL(fileURLWithPath: path)) == self else { throw ExactFileSnapshotError.changed(path) }
    }
}

struct AnyExactCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

/// Bytes and identity captured from one `O_NOFOLLOW` descriptor.  Callers
/// derive their pure replacement exclusively from `data`, then carry this
/// value into the compare-and-publish operation; no path re-read is needed
/// between preflight and persistence.
public struct ExactFileCapture: Equatable, Sendable {
    public let snapshot: ExactFileSnapshot
    public let data: Data?
    public static func capture(at url: URL) throws -> ExactFileCapture {
        let path = url.standardizedFileURL.path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return ExactFileCapture(snapshot: try ExactFileSnapshot(path: path, exists: false), data: nil) }; throw ExactFileSnapshotError.unreadable(path) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw ExactFileSnapshotError.notRegular(path) }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true { let n = read(fd, &buffer, buffer.count); if n < 0 { throw ExactFileSnapshotError.unreadable(path) }; if n == 0 { break }; bytes.append(buffer, count: Int(n)) }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ExactFileSnapshotError.changed(path) }
        let snapshot = try ExactFileSnapshot(path: path, exists: true, deviceID: Int64(before.st_dev), inode: UInt64(before.st_ino), byteCount: Int64(before.st_size), modificationSeconds: Int64(before.st_mtimespec.tv_sec), modificationNanoseconds: Int64(before.st_mtimespec.tv_nsec), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        return ExactFileCapture(snapshot: snapshot, data: bytes)
    }
}

public enum ExactFileSnapshotError: Error, Equatable { case invalidPath(String), invalidEvidence, unreadable(String), notRegular(String), changed(String) }
