import Foundation
import Testing
@testable import LetItBrewCore

@Test func openCodeConfigDirectorySelectsTheAdditionalPluginTarget() {
    let home = URL(fileURLWithPath: "/Users/me")
    #expect(OpenCodePlugin.pluginURL(home: home, environment: [:]).path
        == "/Users/me/.config/opencode/plugins/letitbrew.js")
    #expect(OpenCodePlugin.pluginURL(
        home: home, environment: ["OPENCODE_CONFIG_DIR": "/custom/opencode"]
    ).path == "/custom/opencode/plugins/letitbrew.js")
}

@Test func openCodeRefusesToOverwriteAnUnownedSameNamePlugin() {
    let foreign = Data("export const Foreign = async () => ({})\n".utf8)
    #expect(throws: OpenCodePlugin.UnownedExistingFile.self) {
        _ = try OpenCodePlugin.install(into: foreign, cliPath: "/opt/letitbrew")
    }
}

@Test func generatedPluginUsesOnlyLifecycleEventsAndContainsFailOpenBoundary() throws {
    let source = String(decoding: try OpenCodePlugin.install(
        into: nil, cliPath: "/Applications/Let It Brew.app/Contents/Helpers/letitbrew"
    ), as: UTF8.self)
    #expect(source.contains(OpenCodePlugin.marker))
    #expect(source.contains("session.created"))
    #expect(source.contains("session.status"))
    #expect(source.contains("session.idle"))
    #expect(source.contains("session.deleted"))
    #expect(source.contains("permission.updated"))
    #expect(source.contains("permission.asked"))
    #expect(source.contains("permission.replied"))
    #expect(source.contains("permission.v2.asked"))
    #expect(source.contains("permission.v2.replied"))
    #expect(source.contains("question.asked"))
    #expect(source.contains("question.replied"))
    #expect(source.contains("question.rejected"))
    #expect(source.contains("await emit(\"PermissionRequest\", sessionID, cwd)"))
    #expect(source.contains("await emit(\"UserInputRequested\", sessionID, cwd)"))
    #expect(source.contains("await emit(\"UserInputResolved\", sessionID, cwd)"))
    #expect(source.contains("Bun.spawn"))
    #expect(source.contains("child.kill"))
    #expect(source.contains("catch {}"))
    #expect(!source.contains("tool.execute.before"))
    #expect(!source.contains("process"))
}

@Test func openCodeOwnershipIsAnExactFirstLineMarker() throws {
    let owned = try OpenCodePlugin.install(into: nil, cliPath: "/opt/letitbrew")
    let source = String(decoding: owned, as: UTF8.self)
    #expect(source.firstLine == "// \(OpenCodePlugin.marker)")

    let markerAfterFirstLine = Data(("// foreign\n" + source).utf8)
    #expect(throws: OpenCodePlugin.UnownedExistingFile.self) {
        _ = try OpenCodePlugin.install(into: markerAfterFirstLine, cliPath: "/new/letitbrew")
    }
    #expect(throws: OpenCodePlugin.UnownedExistingFile.self) {
        _ = try OpenCodePlugin.remove(from: markerAfterFirstLine)
    }
}

@Test func openCodeReinstallRepairsTheBakedHelperPathAndReportClassifiesIt() throws {
    #expect(OpenCodePlugin.report(for: nil, cliPath: "/new/letitbrew").isAbsent)

    let stale = try OpenCodePlugin.install(into: nil, cliPath: "/old/letitbrew")
    let report = OpenCodePlugin.report(for: stale, cliPath: "/new/letitbrew")
    #expect(report.stale == ["plugin"])
    #expect(report.duplicated.isEmpty)
    #expect(report.orphaned.isEmpty)

    let repaired = try OpenCodePlugin.install(into: stale, cliPath: "/new/letitbrew")
    #expect(OpenCodePlugin.report(for: repaired, cliPath: "/new/letitbrew").isHealthy)
    #expect(String(decoding: repaired, as: UTF8.self).contains("new"))
    #expect(!String(decoding: repaired, as: UTF8.self).contains("old"))

    let reinstalled = try OpenCodePlugin.install(into: repaired, cliPath: "/new/letitbrew")
    #expect(reinstalled == repaired)
}

@Test func openCodeRemovalSignalsOnlyAnOwnedPluginCanBeDeleted() throws {
    let owned = try OpenCodePlugin.install(into: nil, cliPath: "/opt/letitbrew")
    #expect(try OpenCodePlugin.remove(from: owned) == nil)

    let foreign = Data("// another plugin\nexport {}\n".utf8)
    #expect(throws: OpenCodePlugin.UnownedExistingFile.self) {
        _ = try OpenCodePlugin.remove(from: foreign)
    }
}

@Test func openCodeGeneratorEscapesTheAbsoluteHelperPathAsJSON() throws {
    let path = "/Applications/Let \"It\" Brew\\helper\nletitbrew"
    let source = String(decoding: try OpenCodePlugin.install(into: nil, cliPath: path), as: UTF8.self)
    let encoded = try JSONEncoder().encode(path)
    #expect(source.contains("const cli = \(String(decoding: encoded, as: UTF8.self))"))
}

@Test func openCodeRejectsRelativeHelperPaths() {
    #expect(throws: OpenCodePlugin.RelativeCLIPath.self) {
        _ = try OpenCodePlugin.install(into: nil, cliPath: "relative/letitbrew")
    }
}

private extension String {
    var firstLine: String? { split(separator: "\n", maxSplits: 1).first.map(String.init) }
}
