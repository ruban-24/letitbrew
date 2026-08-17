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
