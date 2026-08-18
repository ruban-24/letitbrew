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

@Test func optionalConnectionTerminologyUsesTheFourAgentCatalog() throws {
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
        "Claude Code", "Codex", "OpenCode", "GitHub Copilot CLI",
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

@Test func publicReadmeDocumentsTheOptionalFourAgentCatalog() throws {
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
        "all four agent rows are optional and disconnected.",
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

    #expect(normalizedReadme.contains("Let It Brew supports local OpenCode and GitHub Copilot CLI hooks."))
    #expect(!readme.localizedCaseInsensitiveContains("cursor"))

    for obsoleteClaim in [
        "connects Claude Code and Codex automatically",
        "watches Claude Code and Codex sessions only",
        "Does it work with Cursor or other editor-embedded agents?** No.",
    ] {
        #expect(!readme.contains(obsoleteClaim),
                "The README must not retain the obsolete claim: \(obsoleteClaim)")
    }

    #expect(readme.contains(
        "[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)"
    ))
    #expect(readme.contains("Let It Brew v0.6.0 and later is licensed under the"))
    #expect(readme.contains("[Apache License 2.0](LICENSE) (`Apache-2.0`)."))
    #expect(!readme.contains("LICENSES/MIT-v0.5.1-and-earlier.txt"))
    #expect(!readme.contains("v0.5.1 and earlier"))
}
