import Darwin
import Foundation

public enum SessionStorageMutation: Sendable {
    case keep
    case replace(SessionRecord)
    case delete
}

public enum SessionStorageMutationError: Error, Equatable, Sendable {
    case lockTimedOut
    case posix(operation: String, code: Int32)
}

/// One crash-consistent value at either the active session path or its hidden
/// per-ID terminal path. A terminal event first replaces the visible active
/// record with `.terminal`, then moves that committed entry below `.locks` so
/// completed sessions never accumulate in the one-second scan namespace.
private enum SessionStorageEntry: Codable {
    case active(SessionRecord)
    case terminal(id: String, observedAt: TimeInterval)

    private enum Kind: String, Codable {
        case active
        case terminal
    }

    private enum CodingKeys: String, CodingKey {
        case kind, record, id
        case observedAt = "observed_at"
    }

    private struct Discriminator: Decodable {
        let isTagged: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isTagged = container.contains(.kind)
        }
    }

    static func decodeCompatible(from data: Data, using decoder: JSONDecoder) throws -> Self {
        let discriminator = try decoder.decode(Discriminator.self, from: data)
        if discriminator.isTagged {
            return try decoder.decode(Self.self, from: data)
        }
        return .active(try decoder.decode(SessionRecord.self, from: data))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .active:
            self = .active(try container.decode(SessionRecord.self, forKey: .record))
        case .terminal:
            let id = try container.decode(String.self, forKey: .id)
            let observedAt = try container.decode(TimeInterval.self, forKey: .observedAt)
            guard observedAt.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .observedAt,
                    in: container,
                    debugDescription: "terminal observation time must be finite"
                )
            }
            self = .terminal(id: id, observedAt: observedAt)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .active(let record):
            try container.encode(Kind.active, forKey: .kind)
            try container.encode(record, forKey: .record)
        case .terminal(let id, let observedAt):
            try container.encode(Kind.terminal, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(observedAt, forKey: .observedAt)
        }
    }

    var id: String {
        switch self {
        case .active(let record): record.id
        case .terminal(let id, _): id
        }
    }

    var activeRecord: SessionRecord? {
        guard case .active(let record) = self else { return nil }
        return record
    }

    var observedAt: TimeInterval? {
        switch self {
        case .active(let record): record.eventObservedAt
        case .terminal(_, let observedAt): observedAt
        }
    }
}

public enum WorkingActivity: String, Codable, Equatable, Sendable {
    case activeToolCall = "active_tool_call"
    case silent
}

/// One agent session, as written by the hook CLI and read by the watcher.
public struct SessionRecord: Codable, Equatable, Sendable {
    public var id: String
    /// The agent binary name, "claude" or "codex".
    public var tool: String
    public var state: SessionState
    /// Semantic activity token, never English prose.
    public var detail: String?
    public var cwd: String
    /// The agent process, found by the ancestry walk. Nil when the walk could
    /// not identify one; such a session is evicted by TTL alone.
    public var pid: Int32?
    public var updatedAt: Date
    /// Unix seconds captured at the same hook edge as `updatedAt`, retaining
    /// sub-second ordering that JSONEncoder's ISO-8601 strategy otherwise
    /// rounds away. Optional for records written before Build 8.
    public var eventObservedAt: TimeInterval?
    /// When this agent session began. Optional so records written by older
    /// Let It Brew versions continue to decode. Consumers should use
    /// `effectiveStartedAt` when presenting elapsed session time.
    public var startedAt: Date?
    /// Completed working intervals accumulated before `updatedAt`. Optional
    /// so records written by older Let It Brew versions continue to decode.
    /// A currently-working interval is added at presentation time.
    public var accumulatedWorkingTime: TimeInterval?
    /// Exact hook event that produced this snapshot. Optional so records from
    /// older Let It Brew versions continue to decode safely.
    public var lastEvent: String?
    /// When the session most recently entered its current state. Optional so
    /// records written by older Let It Brew versions remain valid.
    public var stateChangedAt: Date?
    /// Stable identity for the current state edge. Repeated hooks that leave
    /// the state unchanged retain this value, which lets consumers dedupe
    /// effects without tying them to the hook polling cadence.
    public var stateTransitionID: String?
    enum CodingKeys: String, CodingKey {
        case id, tool, state, detail, cwd, pid
        case updatedAt = "updated_at"
        case legacyUpdatedAt = "updatedAt"
        case eventObservedAt = "event_observed_at"
        case startedAt = "started_at"
        case accumulatedWorkingTime = "accumulated_working_time"
        case lastEvent = "last_event"
        case stateChangedAt = "state_changed_at"
        case stateTransitionID = "state_transition_id"
    }

    public init(id: String, tool: String, state: SessionState, detail: String?,
                cwd: String, pid: Int32?, updatedAt: Date, lastEvent: String? = nil,
                startedAt: Date? = nil,
                accumulatedWorkingTime: TimeInterval? = nil,
                stateChangedAt: Date? = nil, stateTransitionID: String? = nil,
                eventObservedAt: TimeInterval? = nil) {
        self.id = id
        self.tool = tool
        self.state = state
        self.detail = detail
        self.cwd = cwd
        self.pid = pid
        self.updatedAt = updatedAt
        self.eventObservedAt = eventObservedAt
        self.startedAt = startedAt
        self.accumulatedWorkingTime = accumulatedWorkingTime
        self.lastEvent = lastEvent
        self.stateChangedAt = stateChangedAt
        self.stateTransitionID = stateTransitionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        tool = try container.decode(String.self, forKey: .tool)
        state = try container.decode(SessionState.self, forKey: .state)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        cwd = try container.decode(String.self, forKey: .cwd)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? container.decode(Date.self, forKey: .legacyUpdatedAt)
        eventObservedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .eventObservedAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        accumulatedWorkingTime = try container.decodeIfPresent(
            TimeInterval.self, forKey: .accumulatedWorkingTime
        )
        lastEvent = try container.decodeIfPresent(String.self, forKey: .lastEvent)
        stateChangedAt = try container.decodeIfPresent(Date.self, forKey: .stateChangedAt)
        stateTransitionID = try container.decodeIfPresent(String.self, forKey: .stateTransitionID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tool, forKey: .tool)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(eventObservedAt, forKey: .eventObservedAt)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(accumulatedWorkingTime, forKey: .accumulatedWorkingTime)
        try container.encodeIfPresent(lastEvent, forKey: .lastEvent)
        try container.encodeIfPresent(stateChangedAt, forKey: .stateChangedAt)
        try container.encodeIfPresent(stateTransitionID, forKey: .stateTransitionID)
    }

    /// What the board shows: the directory name people actually think in.
    public var repoName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Stable grouping identity for sessions launched from the same working
    /// directory. The full path prevents same-named folders from collapsing.
    public var repositoryID: String {
        URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    /// Best available session-start estimate for backward-compatible records.
    /// `stateChangedAt` predates `updatedAt` when old data contains both.
    public var effectiveStartedAt: Date {
        startedAt ?? min(stateChangedAt ?? updatedAt, updatedAt)
    }

    /// Accumulated active work through `now`. Completed intervals live in the
    /// record; the current interval advances locally between hook events.
    public func activeWorkingTime(at now: Date) -> TimeInterval {
        let accumulated = max(0, accumulatedWorkingTime ?? 0)
        guard state == .working else { return accumulated }
        return accumulated + max(0, now.timeIntervalSince(updatedAt))
    }

    /// Evidence-based working presentation. A recent unmatched PreToolUse is
    /// active; every other working snapshot is silent. This never changes the
    /// hold decision—long legitimate work remains protected.
    public func workingActivity(
        at now: Date,
        silentAfter: TimeInterval
    ) -> WorkingActivity? {
        guard state == .working else { return nil }
        let age = max(0, now.timeIntervalSince(updatedAt))
        if lastEvent == "PreToolUse", age < silentAfter {
            return .activeToolCall
        }
        return .silent
    }
}

/// Resolves a durable state edge from a previous record and a new snapshot.
/// The hook CLI uses this before replacing a record so repeated state events
/// share one identity while a leave-and-re-enter cycle receives a new one.
public struct SessionStateTransition: Equatable, Sendable {
    public var changedAt: Date
    public var id: String

    public init(changedAt: Date, id: String) {
        self.changedAt = changedAt
        self.id = id
    }

    public static func resolve(
        previous: SessionRecord?,
        newState: SessionState,
        now: Date,
        makeID: () -> String = { UUID().uuidString }
    ) -> SessionStateTransition {
        guard let previous, previous.state == newState else {
            return SessionStateTransition(changedAt: now, id: makeID())
        }

        return SessionStateTransition(
            changedAt: previous.stateChangedAt ?? previous.updatedAt,
            id: previous.stateTransitionID ?? makeID()
        )
    }
}

/// Resolves a session's durable start across hook updates. Keeping this
/// separate from state transitions prevents a new tool call or input wait
/// from resetting the elapsed session time shown in the menu.
public enum SessionTimeline {
    public static func startedAt(previous: SessionRecord?, now: Date) -> Date {
        previous?.effectiveStartedAt ?? now
    }

    /// Carries completed working time into the next hook snapshot. Only the
    /// interval after a working record's last event is active time; idle
    /// intervals leave the accumulator unchanged.
    public static func accumulatedWorkingTime(
        previous: SessionRecord?,
        now: Date
    ) -> TimeInterval {
        guard let previous else { return 0 }
        let accumulated = max(0, previous.accumulatedWorkingTime ?? 0)
        guard previous.state == .working else { return accumulated }
        return accumulated + max(0, now.timeIntervalSince(previous.updatedAt))
    }

}

/// Reads and writes session records as one file each.
///
/// Deliberately files and not a socket: a hook sits in the critical path of
/// the user's own work, so it must never require another process to be
/// running. Writes are atomic, and same-session read/modify/write mutations
/// use a bounded per-ID lock. `loadAll()` and `delete(id:)` swallow their
/// failures internally; throwing operations must be suppressed deliberately
/// at the hook boundary so storage can never break an agent session.
public struct SessionStorage: Sendable {
    private let directory: URL

    /// The longest sanitized filename stem (excluding ".json") this type
    /// ever produces or accepts.
    private static let maxStemLength = 128
    /// FNV-1a 64-bit renders as exactly 16 lowercase hex digits.
    private static let digestHexLength = 16
    /// Constant suffix outside the sanitized stem. The full hidden filename is
    /// therefore bounded by the 128-character stem, ".json", and this suffix.
    private static let tombstoneSuffix = ".tombstone"

    public init(directory: URL = SessionStorage.sessionsDirectory) {
        self.directory = directory
    }

    public static var applicationSupportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return applicationSupportDirectory(in: base)
    }

    public static func applicationSupportDirectory(in base: URL) -> URL {
        base.appendingPathComponent("LetItBrew", isDirectory: true)
    }

    public static var sessionsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Maps a session id to a filename that cannot escape the directory.
    /// `session_id` comes from another tool and is untrusted input.
    ///
    /// ASCII-only allowlist on purpose: `CharacterSet.alphanumerics` admits
    /// non-ASCII letters and digits (Cyrillic homoglyphs and the like), and
    /// APFS normalizes Unicode on write, so a name generated from one of
    /// those can be *stored* under a different byte sequence than the one
    /// generated here — silently breaking `delete(id:)` and any later
    /// lookup by the same id. Any changed, empty, or truncated ID receives a
    /// digest of the original UTF-8 bytes so distinct untrusted IDs cannot
    /// collapse onto one record or lock. This intentionally does not guess at
    /// ambiguous filenames written by the pre-digest format: there were no
    /// users to migrate, and a collision cannot be attributed safely.
    public static func safeFilename(for id: String) -> String {
        let cleaned = String(id.unicodeScalars.map { isAllowedScalar($0) ? Character($0) : "_" })
        let base = cleaned.isEmpty ? "unnamed" : cleaned
        let needsDigest = id.isEmpty || cleaned != id || cleaned.count > maxStemLength
        let stem: String
        if needsDigest {
            // Must be deterministic across processes (the hook CLI writes, a
            // separate watcher process reads), so no seeded Hasher/hashValue.
            // Hash the original ID, not the lossy cleaned value: `a/b` and
            // `a?b` must retain distinct identities after sanitization.
            let digest = fnv1a64Hex(id)
            let suffix = "-" + digest
            let keep = maxStemLength - suffix.count
            stem = String(base.prefix(keep)) + suffix
        } else {
            stem = base
        }
        return stem + ".json"
    }

    /// The exact alphabet `safeFilename(for:)` ever emits: ASCII letters,
    /// digits, `-`, and `_`. Shared with `loadAll()`'s grammar check so both
    /// sides of the boundary agree on what a legitimate filename looks like.
    private static func isAllowedScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", "_":
            return true
        default:
            return false
        }
    }

    /// Deterministic 64-bit FNV-1a over the UTF-8 bytes of `string`,
    /// rendered as 16 lowercase hex digits. Deliberately not `Hasher`: Swift
    /// seeds its hashing per process, so the hook CLI and the watcher would
    /// compute different digests for the same id.
    private static func fnv1a64Hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hexDigits = Array("0123456789abcdef")
        var chars = [Character](repeating: "0", count: digestHexLength)
        var value = hash
        for index in stride(from: digestHexLength - 1, through: 0, by: -1) {
            chars[index] = hexDigits[Int(value & 0xF)]
            value >>= 4
        }
        return String(chars)
    }

    /// True for exactly the filenames `safeFilename(for:)` can produce:
    /// a non-empty, bounded, allowlisted stem plus ".json". `loadAll()`
    /// checks this before ever opening a directory entry.
    private static func isValidFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        guard !stem.isEmpty, stem.count <= maxStemLength else { return false }
        return stem.unicodeScalars.allSatisfy(isAllowedScalar)
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent(Self.safeFilename(for: id))
    }

    private static func tombstoneFilename(for id: String) -> String {
        safeFilename(for: id) + tombstoneSuffix
    }

    private func tombstoneURL(for id: String) -> URL {
        directory
            .appendingPathComponent(".locks", isDirectory: true)
            .appendingPathComponent(Self.tombstoneFilename(for: id))
    }

    public func write(_ record: SessionRecord) throws {
        try writeEntry(.active(record))
    }

    public func delete(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    public func mutate(
        id: String,
        timeout: TimeInterval = 0.25,
        _ transform: (SessionRecord?) -> SessionStorageMutation
    ) throws {
        try withSessionLock(id: id, timeout: timeout) { _ in
            try applyMutation(id: id, transform(load(id: id)))
        }
    }

    /// Hook-only ordered mutation. A crash-intermediate terminal may remain at
    /// the active path; normal completion moves it below `.locks`. Both paths
    /// are read strictly under the same per-ID lock. On equal timestamps the
    /// active path wins, preserving the existing equal-arrival replacement
    /// rule after a crash during hidden-tombstone cleanup.
    func mutate(
        id: String,
        observedAt: TimeInterval,
        timeout: TimeInterval = 0.25,
        _ transform: (SessionRecord?) -> SessionStorageMutation
    ) throws {
        guard observedAt.isFinite else {
            throw SessionStorageMutationError.posix(
                operation: "validate observation time",
                code: EINVAL
            )
        }

        try withSessionLock(id: id, timeout: timeout) { lockDirectoryFD in
            let previousEntry = try loadOrderedEntry(id: id)
            if let previousObservedAt = previousEntry?.observedAt,
               previousObservedAt > observedAt {
                return
            }

            switch transform(previousEntry?.activeRecord) {
            case .keep:
                break
            case .replace(let record):
                try writeEntry(.active(record))
                try deleteHiddenTombstone(id: id, lockDirectoryFD: lockDirectoryFD)
            case .delete:
                try writeEntry(.terminal(id: id, observedAt: observedAt))
                try moveTerminalToHiddenPath(id: id, lockDirectoryFD: lockDirectoryFD)
            }
        }
    }

    private func withSessionLock<Result>(
        id: String,
        timeout: TimeInterval,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        let lockDirectoryFD = try openLockDirectory()
        defer { close(lockDirectoryFD) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
        let lockName = Self.safeFilename(for: id) + ".lock"
        let lockFD: Int32
        while true {
            let candidate = lockName.withCString { name in
                openat(
                    lockDirectoryFD,
                    name,
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if candidate >= 0 {
                lockFD = candidate
                break
            }

            let code = errno
            guard code == EINTR || code == ENOENT else {
                throw SessionStorageMutationError.posix(
                    operation: "open session lock",
                    code: code
                )
            }
            guard clock.now < deadline else {
                throw SessionStorageMutationError.lockTimedOut
            }
            usleep(1_000)
        }
        defer { close(lockFD) }

        var lockStatus = stat()
        guard fstat(lockFD, &lockStatus) == 0 else {
            throw SessionStorageMutationError.posix(
                operation: "inspect session lock",
                code: errno
            )
        }
        guard lockStatus.st_mode & S_IFMT == S_IFREG else {
            throw SessionStorageMutationError.posix(
                operation: "validate session lock",
                code: EINVAL
            )
        }
        guard fchmod(lockFD, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw SessionStorageMutationError.posix(
                operation: "secure session lock",
                code: errno
            )
        }

        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                throw SessionStorageMutationError.posix(
                    operation: "acquire session lock",
                    code: code
                )
            }
            guard clock.now < deadline else {
                throw SessionStorageMutationError.lockTimedOut
            }
            usleep(1_000)
        }
        defer { flock(lockFD, LOCK_UN) }

        return try body(lockDirectoryFD)
    }

    private func applyMutation(
        id: String,
        _ mutation: SessionStorageMutation
    ) throws {
        switch mutation {
        case .keep:
            break
        case .replace(let record):
            try writeEntry(.active(record))
        case .delete:
            try deleteThrowing(id: id)
        }
    }

    private func deleteThrowing(id: String) throws {
        if unlink(url(for: id).path) != 0, errno != ENOENT {
            throw SessionStorageMutationError.posix(
                operation: "delete session record",
                code: errno
            )
        }
    }

    private func loadOrderedEntry(id: String) throws -> SessionStorageEntry? {
        let active = try loadEntry(id: id)
        let hidden = try loadHiddenTombstone(id: id)
        guard let active else { return hidden }
        guard let hidden else { return active }

        guard let hiddenObservedAt = hidden.observedAt else {
            throw SessionStorageMutationError.posix(
                operation: "validate hidden terminal observation",
                code: EINVAL
            )
        }
        guard let activeObservedAt = active.observedAt else {
            return hidden
        }
        return activeObservedAt >= hiddenObservedAt ? active : hidden
    }

    private func loadHiddenTombstone(id: String) throws -> SessionStorageEntry? {
        let entry = try loadEntry(
            at: tombstoneURL(for: id),
            expectedName: Self.tombstoneFilename(for: id),
            expectedID: id,
            isHidden: true
        )
        guard let entry else { return nil }
        guard case .terminal = entry else {
            throw SessionStorageMutationError.posix(
                operation: "validate hidden terminal entry",
                code: EINVAL
            )
        }
        return entry
    }

    private func moveTerminalToHiddenPath(
        id: String,
        lockDirectoryFD: Int32
    ) throws {
        let activeURL = url(for: id)
        let activeFD = open(
            activeURL.path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard activeFD >= 0 else {
            throw SessionStorageMutationError.posix(
                operation: "open committed terminal entry",
                code: errno
            )
        }
        defer { close(activeFD) }

        var activeStatus = stat()
        guard fstat(activeFD, &activeStatus) == 0 else {
            throw SessionStorageMutationError.posix(
                operation: "inspect committed terminal entry",
                code: errno
            )
        }
        guard activeStatus.st_mode & S_IFMT == S_IFREG else {
            throw SessionStorageMutationError.posix(
                operation: "validate committed terminal entry",
                code: EINVAL
            )
        }
        guard fchmod(activeFD, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw SessionStorageMutationError.posix(
                operation: "secure committed terminal entry",
                code: errno
            )
        }

        let tombstoneName = Self.tombstoneFilename(for: id)
        let renameResult = activeURL.path.withCString { activePath in
            tombstoneName.withCString { hiddenName in
                renameat(AT_FDCWD, activePath, lockDirectoryFD, hiddenName)
            }
        }
        guard renameResult == 0 else {
            throw SessionStorageMutationError.posix(
                operation: "move committed terminal entry",
                code: errno
            )
        }

        var hiddenStatus = stat()
        let inspectResult = tombstoneName.withCString { hiddenName in
            fstatat(lockDirectoryFD, hiddenName, &hiddenStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard inspectResult == 0 else {
            throw SessionStorageMutationError.posix(
                operation: "inspect hidden terminal entry",
                code: errno
            )
        }
        guard hiddenStatus.st_mode & S_IFMT == S_IFREG,
              hiddenStatus.st_mode & 0o777 == mode_t(S_IRUSR | S_IWUSR)
        else {
            throw SessionStorageMutationError.posix(
                operation: "validate hidden terminal entry",
                code: EINVAL
            )
        }
    }

    private func deleteHiddenTombstone(
        id: String,
        lockDirectoryFD: Int32
    ) throws {
        let name = Self.tombstoneFilename(for: id)
        let result = name.withCString { unlinkat(lockDirectoryFD, $0, 0) }
        if result != 0, errno != ENOENT {
            throw SessionStorageMutationError.posix(
                operation: "delete hidden terminal entry",
                code: errno
            )
        }
    }

    private func openLockDirectory() throws -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch let error as NSError {
            throw SessionStorageMutationError.posix(
                operation: "create session directory",
                code: Int32(error.code)
            )
        }

        let lockDirectory = directory.appendingPathComponent(".locks", isDirectory: true)
        if mkdir(lockDirectory.path, mode_t(S_IRWXU)) != 0, errno != EEXIST {
            throw SessionStorageMutationError.posix(
                operation: "create lock directory",
                code: errno
            )
        }

        let descriptor = open(
            lockDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SessionStorageMutationError.posix(
                operation: "open lock directory",
                code: errno
            )
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            close(descriptor)
            throw SessionStorageMutationError.posix(
                operation: "inspect lock directory",
                code: code
            )
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw SessionStorageMutationError.posix(
                operation: "validate lock directory",
                code: ENOTDIR
            )
        }
        guard fchmod(descriptor, mode_t(S_IRWXU)) == 0 else {
            let code = errno
            close(descriptor)
            throw SessionStorageMutationError.posix(
                operation: "secure lock directory",
                code: code
            )
        }
        return descriptor
    }

    /// Loads one record without following symlinks or trusting the decoded id.
    /// The same filename and record checks as `loadAll()` apply.
    public func load(id: String) -> SessionRecord? {
        try? loadEntry(id: id)?.activeRecord
    }

    /// Every readable record. A corrupt or half-written file is skipped, never
    /// fatal: one bad file must not blind the watcher to every other session.
    ///
    /// Three checks guard against a hostile or tampered directory entry:
    /// the filename must match the exact grammar this type generates, the
    /// entry must not be a symlink (never followed), and the decoded
    /// record's id must sanitize back to the filename it was read from.
    public func loadAll() -> [SessionRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names.compactMap { name -> SessionRecord? in
            guard Self.isValidFilename(name) else { return nil }
            return load(filename: name)
        }
    }

    private func load(filename name: String, expectedID: String? = nil) -> SessionRecord? {
        try? loadEntry(filename: name, expectedID: expectedID)?.activeRecord
    }

    private func writeEntry(_ entry: SessionStorageEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: url(for: entry.id), options: .atomic)
    }

    private func loadEntry(id: String) throws -> SessionStorageEntry? {
        let name = Self.safeFilename(for: id)
        return try loadEntry(
            at: directory.appendingPathComponent(name),
            expectedName: name,
            expectedID: id,
            isHidden: false
        )
    }

    private func loadEntry(
        filename name: String,
        expectedID: String? = nil
    ) throws -> SessionStorageEntry? {
        guard Self.isValidFilename(name) else { return nil }
        return try loadEntry(
            at: directory.appendingPathComponent(name),
            expectedName: name,
            expectedID: expectedID,
            isHidden: false
        )
    }

    private func loadEntry(
        at fileURL: URL,
        expectedName: String,
        expectedID: String?,
        isHidden: Bool
    ) throws -> SessionStorageEntry? {
        var status = stat()
        guard lstat(fileURL.path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw SessionStorageMutationError.posix(
                operation: "inspect session entry",
                code: errno
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw SessionStorageMutationError.posix(
                operation: "validate session entry",
                code: EINVAL
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError {
            throw SessionStorageMutationError.posix(
                operation: "read session entry",
                code: Int32(error.code)
            )
        }

        let entry: SessionStorageEntry
        do {
            // A present `kind` commits the file to strict tagged decoding;
            // malformed tombstones must never fall back to looking active.
            // Only untagged direct SessionRecord JSON uses legacy decoding.
            entry = try SessionStorageEntry.decodeCompatible(from: data, using: decoder)
        } catch {
            throw SessionStorageMutationError.posix(
                operation: "decode session entry",
                code: EINVAL
            )
        }

        let generatedName = Self.safeFilename(for: entry.id)
            + (isHidden ? Self.tombstoneSuffix : "")
        guard expectedName == generatedName,
              expectedID == nil || entry.id == expectedID
        else {
            throw SessionStorageMutationError.posix(
                operation: "validate session entry identity",
                code: EINVAL
            )
        }
        return entry
    }
}
