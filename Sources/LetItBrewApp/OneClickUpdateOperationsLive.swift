import LetItBrewAppCore
import CryptoKit
import Darwin
import Foundation

private enum LiveUpdateOperationError: LocalizedError {
    case unsafeInstalledApp
    case unsafePath(String)
    case filesystem(String)
    case process(String)
    case invalidDiskImage(String)
    case invalidCandidate(String)
    case runnerExited

    var errorDescription: String? {
        switch self {
        case .unsafeInstalledApp:
            "Run the signed Let It Brew app installed directly at /Applications/Let It Brew.app."
        case .unsafePath(let detail):
            "An update path was unsafe: \(detail)"
        case .filesystem(let detail):
            "An update file operation failed: \(detail)"
        case .process(let detail):
            "An update verification command failed: \(detail)"
        case .invalidDiskImage(let detail):
            "The update disk image was invalid: \(detail)"
        case .invalidCandidate(let detail):
            "The update app was invalid: \(detail)"
        case .runnerExited:
            "The detached updater stopped before Let It Brew could safely quit."
        }
    }
}

final class LiveOneClickUpdateOperations:
    OneClickUpdatePreparationOperations,
    @unchecked Sendable
{
    private static let installedApp = URL(fileURLWithPath: "/Applications/Let It Brew.app")
    private static let supportFiles: [String: Int] = [
        "run-update.sh": 0o755,
        "upgrade-installed-app.sh": 0o755,
        "verify-artifact.sh": 0o755,
        "verify-legal-resources.sh": 0o755,
        "lib-power-baseline.sh": 0o644,
    ]

    private let installedBundle: Bundle
    private let appProcessIdentifier: Int32
    private let fileManager = FileManager.default
    private let runnerLock = NSLock()
    private var detachedRunner: Process?

    init(installedBundle: Bundle, appProcessIdentifier: Int32) {
        self.installedBundle = installedBundle
        self.appProcessIdentifier = appProcessIdentifier
    }

    func createPrivateWorkspace(
        for release: StableUpdateRelease
    ) throws -> OneClickUpdateWorkspace {
        try requireSafeInstalledApp()
        guard let caches = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw LiveUpdateOperationError.filesystem("no user Caches directory")
        }
        let appCache = caches.appendingPathComponent(
            "com.ruban24.letitbrew",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: appCache,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try hardenOwnedDirectory(appCache)
        let base = appCache.appendingPathComponent("Updates", isDirectory: true)
        try fileManager.createDirectory(
            at: base,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try hardenOwnedDirectory(base)

        var template = Array(base.appendingPathComponent("Update.XXXXXX").path.utf8CString)
        let created: UnsafeMutablePointer<CChar>? = template.withUnsafeMutableBufferPointer {
            guard let address = $0.baseAddress else { return nil }
            return Darwin.mkdtemp(address)
        }
        guard created != nil else {
            throw LiveUpdateOperationError.filesystem("mkdtemp failed with errno \(errno)")
        }
        let rootPath = String(
            decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try requirePrivateOwnedDirectory(root)

        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let mount = root.appendingPathComponent("Mount", isDirectory: true)
        let candidate = root.appendingPathComponent("Candidate", isDirectory: true)
        for directory in [downloads, mount, candidate] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try requirePrivateOwnedDirectory(directory)
        }

        return OneClickUpdateWorkspace(
            root: root,
            checksumFile: downloads.appendingPathComponent(release.checksums.name),
            diskImage: downloads.appendingPathComponent(release.dmg.name),
            mountPoint: mount,
            stagedApp: candidate.appendingPathComponent("Let It Brew.app", isDirectory: true),
            updateSupportDirectory: root.appendingPathComponent("UpdateSupport", isDirectory: true),
            resultFile: root.appendingPathComponent("result.json"),
            logFile: root.appendingPathComponent("update.log")
        )
    }

    func download(_ asset: UpdateAsset, to destination: URL) async throws {
        try requirePrivateOwnedDirectory(destination.deletingLastPathComponent())
        var request = URLRequest(url: asset.downloadURL)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Let It Brew updater", forHTTPHeaderField: "User-Agent")
        let maximum = asset.name.hasSuffix(".dmg")
            ? StableUpdateReleaseParser.maximumDMGSize
            : StableUpdateReleaseParser.maximumChecksumSize
        _ = try await BoundedHTTPSResource.load(
            request: request,
            maximumBytes: maximum,
            expectedBytes: asset.size,
            destination: destination
        )
        guard try ordinaryFileMode(destination) == 0o600 else {
            throw LiveUpdateOperationError.unsafePath("download mode changed")
        }
    }

    func readSmallFile(at url: URL, maximumBytes: Int64) throws -> Data {
        try readOrdinaryFile(at: url, maximumBytes: maximumBytes)
    }

    func sha256(of url: URL) throws -> String {
        let handle = try openOrdinaryFile(at: url, maximumBytes: nil)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func verifyDiskImage(at url: URL) throws {
        _ = try runChecked(
            executable: "/usr/bin/hdiutil",
            arguments: ["verify", url.path],
            timeout: 120,
            context: "hdiutil verify"
        )
        _ = try runChecked(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--strict", "--verbose=4", url.path],
            timeout: 30,
            context: "disk-image signature"
        )
        _ = try runChecked(
            executable: "/usr/sbin/spctl",
            arguments: ["-a", "-vv", "-t", "open", url.path],
            timeout: 60,
            context: "disk-image Gatekeeper assessment"
        )
    }

    func mountDiskImageReadOnly(
        at url: URL,
        mountPoint: URL
    ) throws -> MountedUpdateImage {
        try requirePrivateOwnedDirectory(mountPoint)
        guard try fileManager.contentsOfDirectory(atPath: mountPoint.path).isEmpty else {
            throw LiveUpdateOperationError.unsafePath("disk-image mount point was not empty")
        }
        let result = try runChecked(
            executable: "/usr/bin/hdiutil",
            arguments: [
                "attach", "-readonly", "-nobrowse", "-noautoopen",
                "-quiet", "-mountpoint", mountPoint.path, "-plist", url.path,
            ],
            timeout: 60,
            context: "read-only disk-image attach"
        )
        let mounted = MountedUpdateImage(
            mountPoint: mountPoint,
            appBundle: mountPoint.appendingPathComponent("Let It Brew.app", isDirectory: true)
        )
        do {
            try validateAttachPlist(result, expectedMountPoint: mountPoint)
            try validateMountedPayload(mounted)
            return mounted
        } catch {
            try? detachDiskImage(mounted)
            throw error
        }
    }

    func verifyCandidate(
        at appBundle: URL,
        location: UpdateCandidateLocation
    ) throws -> VerifiedUpdateCandidate {
        guard try directoryIsOrdinary(appBundle) else {
            throw LiveUpdateOperationError.invalidCandidate("Let It Brew.app is missing or symlinked")
        }
        let verifier = installedBundle.bundleURL.appendingPathComponent(
            "Contents/Resources/UpdateSupport/verify-artifact.sh"
        )
        guard try ordinaryFileMode(verifier) == 0o755 else {
            throw LiveUpdateOperationError.unsafeInstalledApp
        }
        _ = try runChecked(
            executable: "/bin/bash",
            arguments: [verifier.path, appBundle.path, "--release"],
            timeout: 120,
            context: "\(location.rawValue) release verification"
        )
        _ = try runChecked(
            executable: "/usr/sbin/spctl",
            arguments: ["-a", "-vv", "-t", "execute", appBundle.path],
            timeout: 60,
            context: "\(location.rawValue) Gatekeeper assessment"
        )

        let info = appBundle.appendingPathComponent("Contents/Info.plist")
        let data = try readOrdinaryFile(at: info, maximumBytes: 1_024 * 1_024)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              let versionValue = plist["CFBundleShortVersionString"] as? String,
              let version = StableUpdateVersion(versionValue),
              let buildValue = plist["CFBundleVersion"] as? String,
              !buildValue.isEmpty,
              buildValue.allSatisfy(\.isNumber),
              let build = UInt64(buildValue)
        else {
            throw LiveUpdateOperationError.invalidCandidate("version or build metadata is malformed")
        }
        let executable = appBundle.appendingPathComponent("Contents/MacOS/LetItBrew")
        return VerifiedUpdateCandidate(
            version: version,
            build: build,
            executableSHA256: try sha256(of: executable)
        )
    }

    func copyCandidate(from source: URL, to destination: URL) throws {
        guard !fileManager.fileExists(atPath: destination.path),
              !isSymbolicLink(destination)
        else {
            throw LiveUpdateOperationError.unsafePath("candidate destination already exists")
        }
        _ = try runChecked(
            executable: "/usr/bin/ditto",
            arguments: [source.path, destination.path],
            timeout: 120,
            context: "candidate copy"
        )
        guard try directoryIsOrdinary(destination) else {
            throw LiveUpdateOperationError.invalidCandidate("staged app is missing or symlinked")
        }
    }

    func detachDiskImage(_ image: MountedUpdateImage) throws {
        var lastFailure: Error?
        for _ in 0..<5 {
            do {
                _ = try runChecked(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["detach", image.mountPoint.path],
                    timeout: 20,
                    context: "disk-image detach"
                )
                return
            } catch {
                lastFailure = error
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        throw lastFailure ?? LiveUpdateOperationError.process("disk-image detach failed")
    }

    func copySignedUpdateSupport(to destination: URL) throws {
        try requireSafeInstalledApp()
        _ = try runChecked(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", installedBundle.bundleURL.path],
            timeout: 30,
            context: "installed app signature"
        )
        let source = installedBundle.bundleURL.appendingPathComponent(
            "Contents/Resources/UpdateSupport",
            isDirectory: true
        )
        try requireExactSupportInventory(source)
        try requirePrivateOwnedDirectory(destination.deletingLastPathComponent())
        guard !fileManager.fileExists(atPath: destination.path),
              !isSymbolicLink(destination)
        else {
            throw LiveUpdateOperationError.unsafePath("UpdateSupport destination exists")
        }
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try requirePrivateOwnedDirectory(destination)

        var hashes: [String: String] = [:]
        for name in Self.supportFiles.keys.sorted() {
            let expectedMode = Self.supportFiles[name]!
            let sourceFile = source.appendingPathComponent(name)
            let destinationFile = destination.appendingPathComponent(name)
            let sourceHash = try sha256(of: sourceFile)
            _ = try runChecked(
                executable: "/usr/bin/install",
                arguments: ["-m", String(expectedMode, radix: 8), sourceFile.path, destinationFile.path],
                timeout: 10,
                context: "copy signed \(name)"
            )
            guard try ordinaryFileMode(destinationFile) == expectedMode,
                  try sha256(of: destinationFile) == sourceHash
            else {
                throw LiveUpdateOperationError.filesystem("copied support did not match \(name)")
            }
            hashes[name] = sourceHash
        }
        try requireExactSupportInventory(destination)
        let record = try JSONSerialization.data(
            withJSONObject: hashes,
            options: [.sortedKeys]
        )
        try writeExclusive(
            record + Data("\n".utf8),
            to: destination.deletingLastPathComponent().appendingPathComponent("support-sha256.json")
        )
    }

    func launchDetachedRunner(
        supportDirectory: URL,
        candidate: URL,
        resultFile: URL,
        logFile: URL
    ) throws {
        try requireExactSupportInventory(supportDirectory)
        try requirePrivateOwnedDirectory(supportDirectory.deletingLastPathComponent())
        try requireRecordedSupportHashes(supportDirectory)
        guard try directoryIsOrdinary(candidate),
              !fileManager.fileExists(atPath: resultFile.path),
              !isSymbolicLink(resultFile),
              !fileManager.fileExists(atPath: logFile.path),
              !isSymbolicLink(logFile)
        else {
            throw LiveUpdateOperationError.unsafePath("runner inputs changed before launch")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            supportDirectory.appendingPathComponent("run-update.sh").path,
            "--candidate", candidate.path,
            "--app-pid", String(appProcessIdentifier),
            "--result", resultFile.path,
            "--log", logFile.path,
        ]
        process.currentDirectoryURL = supportDirectory.deletingLastPathComponent()
        process.environment = safeProcessEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LiveUpdateOperationError.process("runner launch: \(error.localizedDescription)")
        }
        runnerLock.lock()
        detachedRunner = process
        runnerLock.unlock()
        Thread.sleep(forTimeInterval: 0.1)
        guard process.isRunning else {
            throw LiveUpdateOperationError.runnerExited
        }
    }

    func cleanFailedWorkspace(_ workspace: OneClickUpdateWorkspace) {
        guard let base = updateBaseURL,
              workspace.root.deletingLastPathComponent().standardizedFileURL == base,
              workspace.root.lastPathComponent.hasPrefix("Update."),
              (try? requirePrivateOwnedDirectory(workspace.root)) != nil
        else { return }
        try? fileManager.removeItem(at: workspace.root)
    }

    private var updateBaseURL: URL? {
        guard let caches = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return caches
            .appendingPathComponent("com.ruban24.letitbrew", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .standardizedFileURL
    }

    private func requireSafeInstalledApp() throws {
        let actual = installedBundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard actual == Self.installedApp,
              installedBundle.bundleIdentifier == "com.ruban24.letitbrew",
              try directoryIsOrdinary(installedBundle.bundleURL)
        else {
            throw LiveUpdateOperationError.unsafeInstalledApp
        }
    }

    private func validateAttachPlist(_ data: Data, expectedMountPoint: URL) throws {
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw LiveUpdateOperationError.invalidDiskImage("attach did not report the exact mount point")
        }
        let mountedEntities = entities.filter { $0["mount-point"] as? String != nil }
        guard mountedEntities.count == 1,
              let entity = mountedEntities.first,
              (entity["mount-point"] as? String) == expectedMountPoint.path,
              (entity["dev-entry"] as? String)?.hasPrefix("/dev/") == true
        else {
            throw LiveUpdateOperationError.invalidDiskImage("attach reported an ambiguous mount layout")
        }
    }

    private func validateMountedPayload(_ image: MountedUpdateImage) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: image.mountPoint,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard Set(entries.map(\.lastPathComponent)) == ["Applications", "Let It Brew.app"],
              entries.count == 2,
              try directoryIsOrdinary(image.appBundle)
        else {
            throw LiveUpdateOperationError.invalidDiskImage("payload is not exactly Let It Brew.app and Applications")
        }
        let applications = image.mountPoint.appendingPathComponent("Applications")
        guard isSymbolicLink(applications),
              try fileManager.destinationOfSymbolicLink(atPath: applications.path) == "/Applications"
        else {
            throw LiveUpdateOperationError.invalidDiskImage("Applications is not the expected symlink")
        }
    }

    private func requireExactSupportInventory(_ directory: URL) throws {
        guard try directoryIsOrdinary(directory) else {
            throw LiveUpdateOperationError.unsafePath("UpdateSupport is missing or symlinked")
        }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
        guard names == Self.supportFiles.keys.sorted() else {
            throw LiveUpdateOperationError.unsafePath("UpdateSupport inventory changed")
        }
        for (name, expectedMode) in Self.supportFiles {
            guard try ordinaryFileMode(directory.appendingPathComponent(name)) == expectedMode else {
                throw LiveUpdateOperationError.unsafePath("UpdateSupport mode changed for \(name)")
            }
        }
    }

    private func requireRecordedSupportHashes(_ supportDirectory: URL) throws {
        let recordURL = supportDirectory.deletingLastPathComponent()
            .appendingPathComponent("support-sha256.json")
        guard try ordinaryFileMode(recordURL) == 0o600,
              let object = try JSONSerialization.jsonObject(
                  with: readOrdinaryFile(at: recordURL, maximumBytes: 64 * 1_024)
              ) as? [String: String],
              Set(object.keys) == Set(Self.supportFiles.keys)
        else {
            throw LiveUpdateOperationError.unsafePath("signed-support hash record changed")
        }
        for name in Self.supportFiles.keys {
            guard let expected = object[name],
                  expected.utf8.count == 64,
                  expected.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (97...102).contains(byte)
                  }),
                  try sha256(of: supportDirectory.appendingPathComponent(name)) == expected
            else {
                throw LiveUpdateOperationError.unsafePath("signed-support hash changed for \(name)")
            }
        }
    }

    private func runChecked(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        context: String
    ) throws -> Data {
        let result = BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: safeProcessEnvironment,
            timeout: timeout,
            terminationGrace: 1
        )
        guard result.succeeded else {
            let output = String(decoding: result.output.suffix(8_192), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason: String
            if result.timedOut {
                reason = "timed out"
            } else if result.outputTruncated {
                reason = "output exceeded its capture limit"
            } else if let launchError = result.launchError {
                reason = launchError
            } else {
                reason = "status \(result.status)"
            }
            throw LiveUpdateOperationError.process(
                "\(context) \(reason)\(output.isEmpty ? "" : ": \(output)")"
            )
        }
        return result.output
    }

    private func readOrdinaryFile(at url: URL, maximumBytes: Int64) throws -> Data {
        let handle = try openOrdinaryFile(at: url, maximumBytes: maximumBytes)
        defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            guard Int64(result.count) + Int64(chunk.count) <= maximumBytes else {
                throw LiveUpdateOperationError.unsafePath(
                    "\(url.lastPathComponent) grew beyond its bound while being read"
                )
            }
            result.append(chunk)
        }
        return result
    }

    private func openOrdinaryFile(at url: URL, maximumBytes: Int64?) throws -> FileHandle {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw LiveUpdateOperationError.filesystem("could not open \(url.lastPathComponent), errno \(errno)")
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              maximumBytes.map({ status.st_size >= 0 && status.st_size <= $0 }) ?? true
        else {
            Darwin.close(descriptor)
            throw LiveUpdateOperationError.unsafePath("\(url.lastPathComponent) is not a bounded ordinary file")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func ordinaryFileMode(_ url: URL) throws -> Int {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFREG
        else {
            throw LiveUpdateOperationError.unsafePath("\(url.lastPathComponent) is not an ordinary file")
        }
        return Int(status.st_mode & 0o777)
    }

    private func directoryIsOrdinary(_ url: URL) throws -> Bool {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFDIR
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFLNK
    }

    private func requirePrivateOwnedDirectory(_ url: URL) throws {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == Darwin.getuid(),
              Int(status.st_mode & 0o077) == 0
        else {
            throw LiveUpdateOperationError.unsafePath("private workspace ownership or mode")
        }
    }

    private func hardenOwnedDirectory(_ url: URL) throws {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == Darwin.getuid()
        else {
            throw LiveUpdateOperationError.unsafePath("workspace parent ownership or type")
        }
        try setMode(0o700, at: url)
        try requirePrivateOwnedDirectory(url)
    }

    private var safeProcessEnvironment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = inherited[key], !value.isEmpty { result[key] = value }
        }
        return result
    }

    private func setMode(_ mode: mode_t, at url: URL) throws {
        guard url.path.withCString({ Darwin.chmod($0, mode) }) == 0 else {
            throw LiveUpdateOperationError.filesystem("chmod failed with errno \(errno)")
        }
    }

    private func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw LiveUpdateOperationError.filesystem("exclusive record creation failed with errno \(errno)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: url)
            throw LiveUpdateOperationError.filesystem(error.localizedDescription)
        }
    }
}
