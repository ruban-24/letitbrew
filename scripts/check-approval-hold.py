#!/usr/bin/env python3
"""Checks with a real agent that an approved command holds and nothing else does.

usage: scripts/check-approval-hold.py AGENT [LETITBREW_CLI]
AGENT is claude, copilot, gemini, or qwen. LETITBREW_CLI defaults to
.build/debug/letitbrew, so run `swift build` first.

The agent must be installed, signed in, and connected in Settings → Agents. The
script runs it in a hidden tmux window in a new temporary folder, asks it to run
`ping`, and reads `letitbrew status --json` for that session:

1. While the approval prompt waits, no approved command is running.
2. After approving, the approved command is running.
3. After denying a second prompt with Esc, none is running.

Each step costs one short model turn. Re-run it when an agent updates, because
the hold depends on how the agent starts approved commands.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

AGENTS = {
    # launch command, folder-trust prompt and its keys, ready, approval prompt, approve keys
    "claude": ("claude --permission-mode default", r"trust this folder", ["Down", "Enter"],
               r"manual mode|for shortcuts", r"Do you want to proceed", ["1"]),
    "copilot": ("copilot", r"Do you trust the files", ["1"],
                r"Manual Approval", r"Do you want to run", ["1"]),
    "gemini": ("gemini --approval-mode default", r"Do you trust the files", ["Enter"],
               r"Type your message", r"Allow execution", ["Enter"]),
    "qwen": ("qwen --approval-mode default", r"Do you trust the files", ["Enter"],
             r"Type your message", r"Allow execution", ["Enter"]),
}
# API keys an agent may show while signing in never reach the output.
SECRET = re.compile(r"AQ\.[A-Za-z0-9_\-]{12,}|AIza[0-9A-Za-z_\-]{20,}|sk-[A-Za-z0-9_\-]{16,}")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in AGENTS:
        sys.exit(__doc__)
    agent = sys.argv[1]
    cli = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else ".build/debug/letitbrew")
    launch, trust, trust_keys, ready, approval, approve_keys = AGENTS[agent]
    for tool in ("tmux", launch.split()[0], cli):
        if not shutil.which(tool):
            sys.exit(f"missing: {tool}")

    folder = tempfile.mkdtemp(prefix=f"approval-hold-{agent}-")
    window = f"approval-hold-{agent}-{os.getpid()}"
    results = []

    def tmux(*args):
        return subprocess.run(["tmux", *args], capture_output=True, text=True).stdout

    def screen():
        return SECRET.sub("[REDACTED]", tmux("capture-pane", "-p", "-t", window))

    def wait_for(pattern, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if re.search(pattern, screen()):
                return True
            time.sleep(0.3)
        return False

    def keys(*names):
        for name in names:
            tmux("send-keys", "-t", window, name)

    def prompt(text):
        tmux("send-keys", "-t", window, "-l", text)
        time.sleep(1)
        keys("Enter")

    def session():
        board = json.loads(subprocess.run([cli, "status", "--json"],
                                          capture_output=True, text=True).stdout)
        mine = [s for s in board["sessions"]
                if s["tool"] == agent and s["repo"] == os.path.basename(folder)]
        return mine[0] if mine else None

    def check(name, passed, detail):
        results.append(passed)
        print(f"{'PASS' if passed else 'FAIL'}  {name}: {detail}")

    def ask(count):
        prompt("Run exactly this one shell command, unchanged, as a single call: "
               f"ping -c {count} 127.0.0.1")
        if not wait_for(rf"ping -c {count}(.|\n)*({approval})", 120):
            raise RuntimeError("no approval prompt appeared:\n" + screen())
        time.sleep(8)  # past Claude's six-second permission notification

    try:
        tmux("new-session", "-d", "-s", window, "-x", "200", "-y", "50", "-c", folder)
        keys(launch, "Enter")
        if wait_for(trust, 30):
            time.sleep(1.5)  # the dialog ignores keys until it has drawn
            keys(*trust_keys)
        if not wait_for(ready, 60):
            raise RuntimeError("the agent never became ready:\n" + screen())
        time.sleep(2)

        ask(15)
        waiting = session()
        check("unanswered approval", waiting is not None
              and waiting["state"] == "awaiting_input"
              and not waiting.get("approved_command_running"),
              json.dumps(waiting))
        keys(*approve_keys)
        time.sleep(4)
        running = session()
        check("approved command", running is not None
              and (running.get("approved_command_running") or running["state"] == "working"),
              json.dumps(running))
        if running and running["state"] == "working":
            print("      note: the agent's own hook already reported Working")
        time.sleep(16)  # let ping finish

        ask(16)
        keys("Escape")
        time.sleep(5)
        denied = session()
        check("denied approval", denied is None
              or not denied.get("approved_command_running"),
              json.dumps(denied))
    except RuntimeError as error:
        check("run", False, str(error))
    finally:
        tmux("kill-session", "-t", window)
        shutil.rmtree(folder, ignore_errors=True)

    sys.exit(0 if results and all(results) else 1)


main()
