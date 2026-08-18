import Foundation
import Testing

@Test func allSupportedAgentsHaveSharedLogoAssets() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let menu = try String(
        contentsOf: repository.appendingPathComponent(
            "Sources/LetItBrewApp/MenuBarContentView.swift"
        ),
        encoding: .utf8
    )
    let settings = try String(
        contentsOf: repository.appendingPathComponent(
            "Sources/LetItBrewApp/LetItBrewSettingsView.swift"
        ),
        encoding: .utf8
    )
    let mappings = [
        (toolID: "claude", asset: "ClaudeAgent", filename: "claude-agent.png"),
        (toolID: "codex", asset: "CodexAgent", filename: "codex-agent.png"),
        (toolID: "opencode", asset: "OpenCodeAgent", filename: "opencode-agent.png"),
        (toolID: "copilot", asset: "CopilotAgent", filename: "copilot-agent.png"),
    ]

    #expect(menu.contains("AgentLogo(toolID: session.toolID)"))
    #expect(settings.contains("AgentLogo(toolID: health.id)"))

    for mapping in mappings {
        #expect(menu.contains("case \"\(mapping.toolID)\":"))
        #expect(menu.contains("Image(\"\(mapping.asset)\")"))

        let imageset = repository
            .appendingPathComponent("Sources/LetItBrewApp/Assets.xcassets")
            .appendingPathComponent("\(mapping.asset).imageset")
        let contentsURL = imageset.appendingPathComponent("Contents.json")
        let imageURL = imageset.appendingPathComponent(mapping.filename)
        let contentsExists = FileManager.default.fileExists(atPath: contentsURL.path)
        let imageExists = FileManager.default.fileExists(atPath: imageURL.path)
        #expect(contentsExists, "Missing \(mapping.asset) Contents.json")
        #expect(imageExists, "Missing \(mapping.filename)")
        guard contentsExists, imageExists else { continue }

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: contentsURL))
                as? [String: Any]
        )
        let images = try #require(object["images"] as? [[String: Any]])
        #expect(images.contains { $0["filename"] as? String == mapping.filename })
        #expect((try Data(contentsOf: imageURL)).isEmpty == false)
    }

    #expect(!menu.contains("case \"cursor\":"))
    #expect(!menu.contains("Image(\"CursorAgent\")"))
    #expect(!FileManager.default.fileExists(atPath: repository
        .appendingPathComponent("Sources/LetItBrewApp/Assets.xcassets/CursorAgent.imageset")
        .path))
}
