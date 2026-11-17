import Foundation
import Testing
@testable import LetItBrewAppCore

/// A disposable stand-in for `/`: `usr/local/bin`, `opt/homebrew` and an app
/// bundle whose path contains spaces, like `/Applications/Let It Brew.app`.
private struct FakeMac {
    let root: URL
    let locations: CommandLineToolLocations

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        let cli = root.appendingPathComponent("Applications/Let It Brew.app/Contents/Helpers/letitbrew")
        try FileManager.default.createDirectory(
            at: cli.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        locations = CommandLineToolLocations(bundledCLI: cli.path, root: root.path)
    }

    var cli: String { locations.bundledCLI }

    func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    func link(_ relative: String, to destination: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path(relative) as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: path(relative), withDestinationPath: destination
        )
    }

    func file(_ relative: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path(relative) as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path(relative)))
    }

    func directory(_ relative: String) throws {
        try FileManager.default.createDirectory(
            atPath: path(relative), withIntermediateDirectories: true
        )
    }

    var state: CommandLineToolState { CommandLineTool.state(at: locations) }

    func destination(_ relative: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path(relative))
    }

    func exists(_ relative: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path(relative))) != nil
    }

    /// Runs a generated privileged command as this user, against the fake root.
    @discardableResult
    func run(_ command: String?) throws -> Int32 {
        let command = try #require(command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

// MARK: State

@Test func nothingAtEitherLinkIsNotInstalled() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    try mac.directory("usr/local/bin")

    #expect(mac.state == .notInstalled)
}

@Test func missingUsrLocalBinIsNotInstalled() throws {
    let mac = try FakeMac()
    defer { mac.remove() }

    #expect(mac.state == .notInstalled)
}

@Test func ourLinkInUsrLocalBinIsInstalled() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    try mac.link("usr/local/bin/letitbrew", to: mac.cli)

    #expect(mac.state == .installed)
}

@Test func linkToAnotherCopyOfLetItBrewIsStillOurs() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    try mac.link(
        "usr/local/bin/letitbrew",
        to: "/Applications/Let It Brew.app/Contents/Helpers/letitbrew"
    )

    #expect(mac.state == .installed)
}

@Test func appleSiliconHomebrewLinkIsInstalledByHomebrew() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    // The cask's `binary` links straight at the app bundle.
    try mac.link(
        "opt/homebrew/bin/letitbrew",
        to: "/Applications/Let It Brew.app/Contents/Helpers/letitbrew"
    )
    try mac.directory("opt/homebrew/Caskroom/letitbrew/2.0.0")

    #expect(mac.state == .installedByHomebrew)
}

@Test func intelHomebrewLinkIsToldApartFromOursByTheCaskroom() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    try mac.link(
        "usr/local/bin/letitbrew",
        to: "/Applications/Let It Brew.app/Contents/Helpers/letitbrew"
    )
    try mac.directory("usr/local/Caskroom/letitbrew/2.0.0")

    #expect(mac.state == .installedByHomebrew)
}

@Test func linkIntoHomebrewsCaskroomIsInstalledByHomebrew() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    try mac.link(
        "usr/local/bin/letitbrew",
        to: "/usr/local/Caskroom/letitbrew/2.0.0/Let It Brew.app/Contents/Helpers/letitbrew"
    )

    #expect(mac.state == .installedByHomebrew)
}

@Test func ourLinkWinsOverHomebrewsSoItCanStillBeRemoved() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    try mac.link("usr/local/bin/letitbrew", to: mac.cli)
    try mac.link(
        "opt/homebrew/bin/letitbrew",
        to: "/Applications/Let It Brew.app/Contents/Helpers/letitbrew"
    )
    try mac.directory("opt/homebrew/Caskroom/letitbrew/2.0.0")

    #expect(mac.state == .installed)
}

@Test func anotherAppsFileOrLinkBlocksInstall() throws {
    let file = try FakeMac()
    defer { file.remove() }
    try file.file("usr/local/bin/letitbrew")
    #expect(file.state == .blocked)

    let link = try FakeMac()
    defer { link.remove() }
    try link.link("usr/local/bin/letitbrew", to: "/opt/other/bin/letitbrew")
    #expect(link.state == .blocked)

    let dangling = try FakeMac()
    defer { dangling.remove() }
    try dangling.link("usr/local/bin/letitbrew", to: dangling.path("nowhere/letitbrew"))
    #expect(dangling.state == .blocked)
}

@Test func homebrewInstallIsShownEvenWhenAnotherAppOwnsUsrLocalBin() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    try mac.file("usr/local/bin/letitbrew")
    try mac.link(
        "opt/homebrew/bin/letitbrew",
        to: "/Applications/Let It Brew.app/Contents/Helpers/letitbrew"
    )

    #expect(mac.state == .installedByHomebrew)
}

@Test func unrelatedHomebrewFormulaIsNotOurs() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    try mac.link("opt/homebrew/bin/letitbrew", to: "../Cellar/letitbrew/1.0/bin/letitbrew")

    #expect(mac.state == .notInstalled)
}

// MARK: Install and remove

@Test func installLinksUsrLocalBinToTheBundledCLI() throws {
    let mac = try FakeMac()
    defer { mac.remove() }

    #expect(try mac.run(CommandLineTool.installCommand(at: mac.locations)) == 0)

    #expect(mac.destination("usr/local/bin/letitbrew") == mac.cli)
    #expect(mac.state == .installed)
}

@Test func installIsOfferedOnlyWhenNothingIsThere() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    try mac.link("usr/local/bin/letitbrew", to: mac.cli)
    #expect(CommandLineTool.installCommand(at: mac.locations) == nil)

    let blocked = try FakeMac()
    defer { blocked.remove() }
    try blocked.file("usr/local/bin/letitbrew")
    #expect(CommandLineTool.installCommand(at: blocked.locations) == nil)

    let homebrew = try FakeMac()
    defer { homebrew.remove() }
    try homebrew.link("opt/homebrew/bin/letitbrew", to: homebrew.cli)
    #expect(CommandLineTool.installCommand(at: homebrew.locations) == nil)
}

@Test func installNeverReplacesSomethingThatAppearedAfterTheCheck() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    let command = CommandLineTool.installCommand(at: mac.locations)
    try mac.link("usr/local/bin/letitbrew", to: "/opt/other/bin/letitbrew")

    #expect(try mac.run(command) != 0)
    #expect(mac.destination("usr/local/bin/letitbrew") == "/opt/other/bin/letitbrew")

    let directory = try FakeMac()
    defer { directory.remove() }
    let intoDirectory = CommandLineTool.installCommand(at: directory.locations)
    try directory.directory("usr/local/bin/letitbrew")
    #expect(try directory.run(intoDirectory) != 0)
    #expect(!directory.exists("usr/local/bin/letitbrew/letitbrew"))
}

@Test func removeDeletesOurLinkAndNothingElse() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    try mac.link("usr/local/bin/letitbrew", to: mac.cli)
    try mac.file("usr/local/bin/other")

    #expect(try mac.run(CommandLineTool.removeCommand(at: mac.locations)) == 0)

    #expect(!mac.exists("usr/local/bin/letitbrew"))
    #expect(mac.exists("usr/local/bin/other"))
    #expect(mac.exists("Applications/Let It Brew.app/Contents/Helpers/letitbrew"))
    #expect(mac.state == .notInstalled)
}

@Test func removeIsNeverOfferedForHomebrewOrAnotherAppsFile() throws {
    let intel = try FakeMac()
    defer { intel.remove() }
    try intel.link("usr/local/bin/letitbrew", to: intel.cli)
    try intel.directory("usr/local/Caskroom/letitbrew/2.0.0")
    #expect(CommandLineTool.removeCommand(at: intel.locations) == nil)

    let blocked = try FakeMac()
    defer { blocked.remove() }
    try blocked.link("usr/local/bin/letitbrew", to: "/opt/other/bin/letitbrew")
    #expect(CommandLineTool.removeCommand(at: blocked.locations) == nil)

    let missing = try FakeMac()
    defer { missing.remove() }
    #expect(CommandLineTool.removeCommand(at: missing.locations) == nil)
}

@Test func removeLeavesALinkThatWasReplacedAfterTheCheck() throws {
    let mac = try FakeMac()
    defer { mac.remove() }
    try mac.link("usr/local/bin/letitbrew", to: mac.cli)
    let command = CommandLineTool.removeCommand(at: mac.locations)
    try FileManager.default.removeItem(atPath: mac.path("usr/local/bin/letitbrew"))
    try mac.link("usr/local/bin/letitbrew", to: "/opt/other/bin/letitbrew")

    #expect(try mac.run(command) != 0)
    #expect(mac.destination("usr/local/bin/letitbrew") == "/opt/other/bin/letitbrew")
}

// MARK: Administrator prompt

@Test func privilegedCommandRunsThroughAnAdministratorAppleScript() {
    #expect(
        CommandLineTool.administratorAppleScript(running: #"/bin/rm '/a "b"\c'"#)
            == #"do shell script "/bin/rm '/a \"b\"\\c'" with administrator privileges"#
    )
}

@Test func cancellingThePasswordPromptIsNotAnError() {
    #expect(
        CommandLineToolAuthorization.outcome(
            status: 1, output: "0:79: execution error: User canceled. (-128)\n"
        ) == .cancelled
    )
    #expect(CommandLineToolAuthorization.outcome(status: 0, output: "") == .succeeded)
    #expect(
        CommandLineToolAuthorization.outcome(
            status: 1, output: "0:120: execution error: ln: /usr/local/bin/letitbrew: File exists (1)\n"
        ) == .failed("ln: /usr/local/bin/letitbrew: File exists (1)")
    )
}

// MARK: Settings wording

@Test func settingsWordingForEachState() {
    let notInstalled = CommandLineToolPresentation(state: .notInstalled)
    #expect(notInstalled.detail == "Not installed")
    #expect(!notInstalled.showsInstalledDot)
    #expect(notInstalled.action == .install)
    #expect(notInstalled.action?.title == "Install…")
    #expect(notInstalled.footer == "Lets you run `letitbrew hold` in any terminal. Adds a link in /usr/local/bin and asks for your password.")

    let installed = CommandLineToolPresentation(state: .installed)
    #expect(installed.detail == "Installed in /usr/local/bin")
    #expect(installed.showsInstalledDot)
    #expect(installed.action == .remove)
    #expect(installed.action?.title == "Remove…")
    #expect(installed.footer == nil)

    let homebrew = CommandLineToolPresentation(state: .installedByHomebrew)
    #expect(homebrew.detail == "Installed by Homebrew")
    #expect(homebrew.showsInstalledDot)
    #expect(homebrew.action == nil)
    #expect(homebrew.footer == nil)

    let blocked = CommandLineToolPresentation(state: .blocked)
    #expect(blocked.detail == "/usr/local/bin/letitbrew belongs to another app. Let It Brew won't replace it.")
    #expect(!blocked.showsInstalledDot)
    #expect(blocked.action == nil)
    #expect(blocked.footer == nil)
}
