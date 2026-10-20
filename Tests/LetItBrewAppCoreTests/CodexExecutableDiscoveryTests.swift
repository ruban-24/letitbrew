import Foundation
import Testing
@testable import LetItBrewAppCore

@Test func discoveryIncludesCommonUserInstallLocationsWithoutShellProfiles() {
    let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
    let candidates = CodexExecutableDiscovery.candidateURLs(
        home: home,
        environment: ["PATH": "/custom/bin:/second/bin"],
        applicationURLs: [URL(fileURLWithPath: "/Applications/ChatGPT.app")]
    ).map(\.path)

    #expect(candidates.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
    #expect(candidates.contains("/tmp/test-home/.local/bin/codex"))
    #expect(candidates.contains("/tmp/test-home/.volta/bin/codex"))
    #expect(candidates.contains("/tmp/test-home/Library/pnpm/codex"))
    #expect(candidates.contains("/custom/bin/codex"))
}

@Test func discoveryFindsAnNVMInstallFromATemporaryHome() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let executable = home.appendingPathComponent(
        ".nvm/versions/node/v22.0.0/bin/codex"
    )
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path
    )
    defer { try? FileManager.default.removeItem(at: home) }

    let located = CodexExecutableDiscovery.locate(
        home: home,
        environment: [:],
        applicationURLs: [],
        isExecutable: {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                == executable.resolvingSymlinksInPath()
        }
    )

    #expect(located?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath())
}

@Test(arguments: ["Codex.app", "ChatGPT.app"], [
    "Contents/Resources/codex",
    "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "Contents/Resources/codex-cli/bin/codex",
])
func discoveryFindsBundledCodexWithoutShellProfiles(
    applicationName: String,
    executablePath: String
) throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let application = home.appendingPathComponent("custom/\(applicationName)")
    let executable = application.appendingPathComponent(executablePath)
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path
    )

    let located = CodexExecutableDiscovery.locate(
        home: home,
        environment: [:],
        applicationURLs: [application],
        isExecutable: {
            $0.hasPrefix(home.path + "/")
                && FileManager.default.isExecutableFile(atPath: $0)
        }
    )

    #expect(located == executable)
}

@Test(arguments: [
    "/Applications/Codex.app",
    "/Applications/ChatGPT.app",
    "/tmp/test-home/Applications/Codex.app",
    "/tmp/test-home/Applications/ChatGPT.app",
], [
    "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "Contents/Resources/codex-cli/bin/codex",
])
func discoveryFindsNewLayoutsInKnownApplicationLocations(
    applicationPath: String,
    executablePath: String
) {
    let executable = URL(fileURLWithPath: applicationPath)
        .appendingPathComponent(executablePath)
    let located = CodexExecutableDiscovery.locate(
        home: URL(fileURLWithPath: "/tmp/test-home"),
        environment: [:],
        applicationURLs: [],
        isExecutable: { $0 == executable.path }
    )

    #expect(located == executable)
}

@Test func discoverySkipsNonExecutablePackageEntrypointAndFindsNativeCodex() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let application = home.appendingPathComponent("ChatGPT.app")
    let nativeExecutable = application.appendingPathComponent(
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    )
    let wrapper = application.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
    for executable in [nativeExecutable, wrapper] {
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable == nativeExecutable ? 0o700 : 0o600],
            ofItemAtPath: executable.path
        )
    }
    defer { try? FileManager.default.removeItem(at: home) }

    let located = CodexExecutableDiscovery.locate(
        home: home,
        environment: [:],
        applicationURLs: [application],
        isExecutable: {
            $0.hasPrefix(home.path + "/")
                && FileManager.default.isExecutableFile(atPath: $0)
        }
    )

    #expect(located == nativeExecutable)
}

@Test func discoveryPreservesLegacyAndApplicationPrioritiesWithoutDuplicateCandidates() {
    let application = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    let legacyExecutable = application.appendingPathComponent("Contents/Resources/codex")
    let nativeExecutable = application.appendingPathComponent(
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    )
    let wrapper = application.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
    let shellExecutable = URL(fileURLWithPath: "/tmp/test-home/.local/bin/codex")
    let available = Set([legacyExecutable.path, nativeExecutable.path, wrapper.path, shellExecutable.path])
    let candidates = CodexExecutableDiscovery.candidateURLs(
        home: URL(fileURLWithPath: "/tmp/test-home"),
        environment: ["PATH": "/tmp/test-home/.local/bin"],
        applicationURLs: [application, application]
    ).map(\.path)

    #expect(candidates.count == Set(candidates).count)
    #expect(Array(candidates.prefix(3)) == [legacyExecutable.path, wrapper.path, nativeExecutable.path])
    #expect(CodexExecutableDiscovery.locate(
        home: URL(fileURLWithPath: "/tmp/test-home"),
        environment: [:],
        applicationURLs: [application],
        isExecutable: { available.contains($0) }
    ) == legacyExecutable)
    #expect(CodexExecutableDiscovery.locate(
        home: URL(fileURLWithPath: "/tmp/test-home"),
        environment: [:],
        applicationURLs: [application],
        isExecutable: { $0 != legacyExecutable.path && available.contains($0) }
    ) == wrapper)
    #expect(CodexExecutableDiscovery.locate(
        home: URL(fileURLWithPath: "/tmp/test-home"),
        environment: [:],
        applicationURLs: [application],
        isExecutable: {
            $0 != legacyExecutable.path && $0 != wrapper.path && available.contains($0)
        }
    ) == nativeExecutable)
}
