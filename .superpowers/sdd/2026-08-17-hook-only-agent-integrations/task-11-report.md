# Task 11 report — optional agent connections in the popup

Base: `b44edc1`

## RED evidence

Added the required `connectedAgentCount` popup tests before changing production
code, then ran:

```text
swift test --filter MenuPresentationPolicyTests && swift test --filter AgentConnectionPolicyTests
```

The build failed as intended because `MenuSetupAttentionInput` still accepted
`agentNames`: the compiler reported the incorrect `connectedAgentCount` label
and could not convert the supplied `Int` to `[String]`.

## GREEN evidence

Implemented the count-based input and exact precedence, and ran:

```text
swift test --filter MenuPresentationPolicyTests
swift test --filter AgentConnectionPolicyTests
swift test --filter ProductTerminologyContractTests
```

All passed: 19 menu-presentation tests, 5 connection-policy tests, and 3
terminology-contract tests.

The new coverage proves:

- update result, closed-lid setup, then zero managed-connected agents is the
  popup precedence;
- zero uses the approved `Connect an agent` copy, while one managed connected
  agent has no connection banner;
- Claude Code, Codex, Cursor, OpenCode, and GitHub Copilot CLI use the shared
  `AgentID` display-name catalog in both session rows and repository summaries;
- Settings keeps catalog-backed rows, uses the approved optional-connection
  introduction, and popup terminology excludes `Not connected`, `Waiting`,
  `Needs input`, and `Starting`.

Further verification:

```text
swift test
swift build
xcodegen generate
xcodebuild -project LetItBrew.xcodeproj -scheme LetItBrew -configuration Debug -derivedDataPath /private/tmp/letitbrew-agent-hooks-ui-derived CODE_SIGNING_ALLOWED=NO build
git diff --check
```

All passed. The full Swift suite reported 676 passing tests. The unsigned
Xcode build reported `** BUILD SUCCEEDED **`.

## File scope and review

Changed only Task 11 production/test files:

- `Sources/LetItBrewAppCore/MenuPresentationPolicy.swift`
- `Sources/LetItBrewApp/MenuBarContentView.swift`
- `Sources/LetItBrewApp/LetItBrewSettingsView.swift`
- `Tests/LetItBrewAppCoreTests/MenuPresentationPolicyTests.swift`
- `Tests/LetItBrewAppCoreTests/ProductTerminologyContractTests.swift`

`AgentConnectionPolicy.swift` and its existing focused tests required no
mechanical change: the popup now directly counts only `.connected` and
`.managed` model rows as required. No assets, downloads, popup agent list, or
prominent Disconnect action were added. Cursor, OpenCode, and Copilot retain
the existing neutral terminal fallback.

Known attended-UAT gap: no manual click-through of the unsigned Debug app was
performed; the regenerated Xcode build covers compilation of the SwiftUI-only
views.

DONE
