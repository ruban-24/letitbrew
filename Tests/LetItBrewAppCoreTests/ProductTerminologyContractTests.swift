import Foundation
import Testing
import LetItBrewCore

@Test func ordinaryInterfaceDoesNotRegressToRemovedControlsOrJargon() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let interfaceFiles = [
        "Sources/LetItBrewApp/MenuBarContentView.swift",
        "Sources/LetItBrewApp/LetItBrewSettingsView.swift",
    ]
    let source = try interfaceFiles
        .map { try String(contentsOf: repository.appendingPathComponent($0), encoding: .utf8) }
        .joined(separator: "\n")

    let removedTerms = [
        "\"Auto\"",
        "\"Always\"",
        "\"Off\"",
        "Sleep Now",
        "stethoscope",
        "Turn off protection",
        "Setup or Repair",
        "Remove Integrations",
        "Activity Display",
        "idleGrace",
    ]

    for term in removedTerms {
        #expect(!source.contains(term),
                "The ordinary interface must not expose the removed term: \(term)")
    }
}

@Test func theUninstallControlStatesThatNothingWasRemovedWhenItRefuses() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let view = try String(
        contentsOf: repository.appendingPathComponent(
            "Sources/LetItBrewApp/LetItBrewSettingsView.swift"
        ),
        encoding: .utf8
    )
    let environment = try String(
        contentsOf: repository.appendingPathComponent(
            "Sources/LetItBrewApp/UninstallEnvironmentLive.swift"
        ),
        encoding: .utf8
    )

    #expect(view.contains("Uninstall Let It Brew…"),
            "The About pane must offer the uninstall control.")
    #expect(environment.contains("Nothing was removed."),
            "A refused gate must say so, so the user never guesses at partial state.")
}

@Test func optionalConnectionTerminologyUsesTheFiveAgentCatalog() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let settings = try String(
        contentsOf: repository.appendingPathComponent(
            "Sources/LetItBrewApp/LetItBrewSettingsView.swift"
        ),
        encoding: .utf8
    )
    let menu = try String(
        contentsOf: repository.appendingPathComponent(
            "Sources/LetItBrewApp/MenuBarContentView.swift"
        ),
        encoding: .utf8
    )
    let policy = try String(
        contentsOf: repository.appendingPathComponent(
            "Sources/LetItBrewAppCore/MenuPresentationPolicy.swift"
        ),
        encoding: .utf8
    )

    #expect(AgentID.allCases.map(\.displayName) == [
        "Claude Code", "Codex", "Cursor", "OpenCode", "GitHub Copilot CLI",
    ])
    #expect(settings.contains("ForEach(model.agentHooks)"),
            "Settings must render every catalog-backed connection row.")
    #expect(settings.contains("Connect the local coding agents you want Let It Brew to follow."))
    #expect(policy.contains("Connect an agent"))
    #expect(policy.contains("Open Settings to connect your coding agent."))
    #expect(!menu.contains("Not connected"))

    for removedAgentState in ["Waiting", "Needs input", "Starting"] {
        #expect(!menu.contains(removedAgentState),
                "The popup must not label agent sessions as \(removedAgentState).")
    }
}

@Test func publicReadmeDocumentsTheOptionalFiveAgentCatalog() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let readme = try String(
        contentsOf: repository.appendingPathComponent("README.md"),
        encoding: .utf8
    )
    let normalizedReadme = readme.split(whereSeparator: \.isWhitespace).joined(separator: " ")

    let supportedAgents = try #require(
        readme.components(separatedBy: "## Supported agents").dropFirst().first?
            .components(separatedBy: "## Safety").first
    )
    let privacyAndPaths = try #require(
        readme.components(separatedBy: "## Privacy and local data").dropFirst().first?
            .components(separatedBy: "## Uninstalling").first
    )
    let uninstall = try #require(
        readme.components(separatedBy: "## Uninstalling").dropFirst().first?
            .components(separatedBy: "## FAQ").first
    )
    let normalizedUninstall = uninstall.split(whereSeparator: \.isWhitespace).joined(separator: " ")

    for displayName in AgentID.allCases.map(\.displayName) {
        #expect(supportedAgents.contains(displayName),
                "The Supported agents section must document \(displayName).")
    }

    for requiredFreshConnectFact in [
        "all five agent rows are optional and disconnected.",
        "choose **Connect** for each local agent you want Let It Brew to follow",
        "no agent configuration is changed before that choice.",
        "migrates only previously owned Claude Code and Codex connections.",
    ] {
        #expect(normalizedReadme.contains(requiredFreshConnectFact))
    }

    for requiredPathFact in [
        "`~/.claude/settings.json` | Claude Code user settings; only Let It Brew-owned hook entries are changed after Connect.",
        "`~/.codex/hooks.json` | Default Codex hook file when `CODEX_HOME` is unset.",
        "When `CODEX_HOME` is present, Let It Brew uses `<CODEX_HOME>/hooks.json`.",
        "`~/.cursor/hooks.json` | Cursor's user-scoped hook file; project, team, and enterprise scopes are not touched.",
        "`~/.config/opencode/plugins/letitbrew.js` | Default OpenCode plugin path when `OPENCODE_CONFIG_DIR` is unset.",
        "When `OPENCODE_CONFIG_DIR` is present, Let It Brew uses `<OPENCODE_CONFIG_DIR>/plugins/letitbrew.js`.",
        "`~/.copilot/hooks/letitbrew.json` | Default GitHub Copilot CLI hook file when `COPILOT_HOME` is unset.",
        "When `COPILOT_HOME` is present, Let It Brew uses `<COPILOT_HOME>/hooks/letitbrew.json`.",
    ] {
        #expect(privacyAndPaths.contains(requiredPathFact))
    }

    for displayName in AgentID.allCases.map(\.displayName) {
        #expect(normalizedUninstall.contains(displayName),
                "Uninstalling must name \(displayName).")
    }

    #expect(normalizedReadme.contains("Yes for local Cursor hooks."))
    #expect(normalizedReadme.contains("Let It Brew also supports local OpenCode and GitHub Copilot CLI hooks."))

    for obsoleteClaim in [
        "connects Claude Code and Codex automatically",
        "watches Claude Code and Codex sessions only",
        "Does it work with Cursor or other editor-embedded agents?** No.",
    ] {
        #expect(!readme.contains(obsoleteClaim),
                "The README must not retain the obsolete claim: \(obsoleteClaim)")
    }

    #expect(readme.contains(
        "[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)"
    ))
}
