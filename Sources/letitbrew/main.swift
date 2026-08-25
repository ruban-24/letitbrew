import Foundation
import LetItBrewCore

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "hook":
    guard arguments.count == 3,
          let agent = AgentID(rawValue: arguments[1])
    else { exit(0) }
    exit(runHook(agent: agent, event: arguments[2]))
case "install":
    if arguments.count == 1 {
        exit(runInstall())
    }
    guard arguments.count == 2, let agent = AgentID(rawValue: arguments[1]) else {
        FileHandle.standardError.write(Data("Usage: letitbrew install [claude|codex|opencode|copilot]\n".utf8))
        exit(1)
    }
    exit(runInstall(agents: [agent]))
case "uninstall":
    if arguments.count == 1 {
        exit(runUninstall())
    }
    guard arguments.count == 2, let agent = AgentID(rawValue: arguments[1]) else {
        FileHandle.standardError.write(Data("Usage: letitbrew uninstall [claude|codex|opencode|copilot]\n".utf8))
        exit(1)
    }
    exit(runUninstall(agents: [agent]))
case "doctor":
    exit(runDoctor())
case "prepare-exact":
    guard arguments.count == 2, let agent = AgentID(rawValue: arguments[1]) else { exit(1) }
    exit(runPrepareExact(agent: agent, input: FileHandle.standardInput.readDataToEndOfFile()))
case "watch":
    exit(runWatch(lidClosed: arguments.contains("--lid-closed")))
case "status":
    exit(runStatus(json: arguments.contains("--json")))
case "repair":
    exit(runRepair())
case "--version":
    print("letitbrew 0.6.3")
    exit(0)
default:
    print("""
    letitbrew - keep your Mac awake while AI agents work

    Usage:
      letitbrew install [claude|codex|opencode|copilot]
                              install hooks for all agents, or one agent
      letitbrew uninstall [claude|codex|opencode|copilot]
                              remove hooks for all agents, or one agent
      letitbrew doctor         report install health per event
      letitbrew watch          hold the Mac awake while agents work
      letitbrew watch --lid-closed
                              also keep it awake with the lid shut (asks for
                              your password once, at startup)
      letitbrew status [--json]  one-shot board
      letitbrew repair          clear a sleep-watchdog lease left by a dead
                              watchdog loop (see `letitbrew doctor`)
      letitbrew hook <agent> <event>
                              internal: called by agent lifecycle hooks
      letitbrew --version

    Testing only:
      LETITBREW_TEST_HOME      redirect both config paths beneath this
                              directory instead of the real home directory.
                              Takes precedence over CODEX_HOME. Must be an
                              absolute path.
    """)
    exit(1)
}
