import AppKit
import Foundation
import LetItBrewAppCore
import LetItBrewCore

enum CodexExecutableLocator {
    @MainActor
    static func locate() -> URL? {
        let workspaceApplication = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        )
        return CodexExecutableDiscovery.locate(
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            applicationURLs: [workspaceApplication].compactMap { $0 }
        )
    }
}

enum LiveCodexHookTrustInspection {
    nonisolated static func inspect(
        executableURL: URL?,
        hooksURL: URL,
        cwd: URL,
        appVersion: String
    ) -> CodexHookTrustResult {
        guard let executableURL else { return .couldNotVerify }

        let initialize: [String: Any] = [
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": [
                    "name": "letitbrew",
                    "title": "Let It Brew",
                    "version": appVersion,
                ],
            ],
        ]
        let afterInitialize: [[String: Any]] = [
            ["method": "initialized", "params": [:]],
            [
                "method": "hooks/list",
                "id": 2,
                "params": ["cwds": [cwd.path]],
            ],
        ]

        let initializeInput: Data
        var afterInitializeInput = Data()
        do {
            initializeInput = try JSONSerialization.data(withJSONObject: initialize)
                + Data([0x0A])
            for message in afterInitialize {
                afterInitializeInput.append(
                    try JSONSerialization.data(withJSONObject: message)
                )
                afterInitializeInput.append(0x0A)
            }
        } catch {
            return .couldNotVerify
        }

        let execution = StagedJSONLineProcessRunner.run(
            executableURL: executableURL,
            arguments: ["app-server", "--stdio"],
            stages: [
                StagedJSONLineRequest(input: initializeInput, responseID: 1),
                StagedJSONLineRequest(input: afterInitializeInput, responseID: 2),
            ],
            timeout: 5
        )
        guard execution.launchError == nil,
              !execution.stageTimedOut,
              execution.completedResponseIDs == [1, 2]
        else { return .couldNotVerify }
        return CodexHookTrust.classifyAppServerOutput(
            execution.output,
            expectedEvents: CodexHooks.appServerEvents,
            expectedSourcePath: hooksURL.path,
            ownershipSuffix: HookFile.ownershipComment(marker: CodexHooks.marker)
        )
    }
}
