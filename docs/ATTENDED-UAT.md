# Attended UAT

Maintainer checklists for the paths that cannot be automated. These are not
pull-request checks — they need a signed install, physical access to the Mac, and
a reinstall between runs.

The reason they exist is in [ARCHITECTURE.md](ARCHITECTURE.md#testing-boundary):
`Sources/LetItBrewApp/` is not a SwiftPM target, so `swift test` never executes
the live URLSession download, DMG/Gatekeeper operations, model actions, SwiftUI
confirmation behavior, AppKit quit, result-directory polling, or relaunch report.
`xcodebuild` proves those compile. This document is the evidence that they run.

If a safety or power test fails, stop with physical access to the Mac, preserve
the original `SleepDisabled` baseline, record the exact reproduction, and stop
using the affected feature until it is understood.

## v2.0.0 release scope

### Menu-bar flask

`swift test` proves the flask draws distinct idle, awake, needs-you and paused
frames, that the awake sequence loops, and that Reduce Motion and Low Power Mode
leave a single frame. It cannot see the status item. With the signed app, on a
light menu bar and then a dark one (change the wallpaper or **System Settings →
Appearance**):

1. With no agent Working, confirm an empty, still flask. Hover it: the tooltip
   reads "Watching for agents" (or the release reason, such as "Low Power Mode
   is on").
2. Start a Claude turn that runs for a minute. Confirm the flask fills and its
   bubbles rise in a steady loop, and the tooltip reads "Keeping awake · 1 agent
   working". Open the menu: the icon stays legible on the highlighted button.
3. Leave a Claude approval unanswered. Confirm the flask is filled and still
   with an orange dot at its top right, the glyph matches the menu-bar colour on
   both light and dark bars, and the tooltip reads "1 agent needs you" (with
   "Keeping awake · " in front while another agent is Working).
4. Pause Let It Brew. Confirm an empty flask with a slash, distinct from idle,
   and the tooltip "Let It Brew is paused".
5. With an agent Working, turn on **System Settings → Accessibility → Display →
   Reduce motion**, then separately turn on Low Power Mode. Each time the flask
   stops on one filled frame within a second and resumes when switched off.
6. In Activity Monitor, confirm Let It Brew's CPU stays near zero while the
   flask is idle, paused, or needs you; it only wakes for frames while awake.
7. With VoiceOver on, focus the status item: it reads "Let It Brew," then the
   tooltip text.

### Needs-you desktop alerts (#63)

`AlertPolicy` tests cover the 30-second rule, one alert per Waiting episode,
wording, and hidden project names. These steps cover what they cannot:
notification permission, delivery, and click-through.

1. Update from 1.0.1 with no alert settings saved. Confirm Settings → Alerts
   sits between Power and Closed Lid, Desktop alerts is off, and the menu shows
   "Get alerts when an agent needs you?" once at the bottom. Choose Not Now,
   quit and relaunch: the tip does not return. On a clean install, confirm the
   tip shows and Turn On enables Desktop alerts and removes it.
2. Turn on Desktop alerts. Confirm macOS asks for notification permission
   exactly once, with no sound option offered.
3. Leave a Claude Code approval unanswered in Terminal. After 30 seconds
   confirm one banner, "Claude Code needs you" with "<folder> · Waiting for
   your approval", and no second banner while it keeps waiting. Repeat with a
   question: "<folder> · Waiting for your answer".
4. Answer an approval within 20 seconds: no banner. Approve a command that runs
   for a minute: no banner while it runs.
5. Switch to another app, then click the banner. Confirm Terminal (or the
   session's host app: iTerm2, Ghostty, VS Code, Orca) comes forward.
6. Turn on Hide project names and repeat step 3: the body is "Waiting for
   your approval" with no folder. Check the banner and Notification Center
   never show the prompt, question, or command.
7. Deny notifications in System Settings → Notifications. Confirm the Alerts
   tab shows the warning and Open Settings… opens Let It Brew's notification
   page.
8. Check the Alerts tab and the menu tip in light and dark appearance.

### Finished, battery/heat and Wi-Fi alerts (#64)

`AlertPolicy` tests cover the 3-minute and 60-second rules at their edges,
one alert per episode, exit-status wording, hidden names and the per-type
defaults; the `hold` integration tests cover the exit-status result file.
These steps cover real notifications, the real power and network triggers,
and the Alerts tab.
Turn on Desktop alerts first, and run the CLI from the installed bundle as in
the `hold` section.

1. On an install that has never changed the alert types, open Settings →
   Alerts. "Alert me when" lists "An agent needs you" ("After it has waited 30
   seconds"), "Work finishes" ("Agents and held commands that ran 3 minutes or
   more"), "Keeping awake stops for battery or heat", and "Wi-Fi drops while
   the lid is closed". The first three are on and Wi-Fi is off. The Privacy
   footer reads "Alerts never include your prompts or questions." Turn Desktop
   alerts off: the group and Privacy dim and the footer reads "Turn on desktop
   or phone alerts to choose what you hear about." Nothing is clipped in light
   or dark appearance; quit and relaunch, and every toggle keeps its value.
2. Start a Codex (or Claude Code) turn that works for at least 4 minutes,
   then let it finish. One banner: "Codex finished" / "<folder> · Worked for
   4 min". Clicking it brings the session's app forward. A turn of about 2
   minutes sends nothing. Approve a prompt mid-turn: going Waiting sends no
   finished banner. With Hide project names on, the body is only "Worked for
   N min". A Claude turn that runs subagents sends one banner, for the parent.
3. Run `letitbrew hold -- sh -c 'sleep 200'`: after it ends, "sh -c sleep 200
   finished" / "Succeeded after 3 min". Run
   `letitbrew hold -- sh -c 'sleep 200; exit 1'`: "… failed" / "Failed after 3
   min". `letitbrew hold -- sleep 60` sends nothing. With Hide project names on,
   the titles read "A held command finished" and "A held command failed".
   Afterwards `~/Library/Application Support/LetItBrew/hold-results/` is empty.
4. Hold with no exit status: start `sleep 240 &`, run
   `letitbrew hold --pid <its PID>`, and wait: "Process <PID> finished" /
   "Finished after 4 min". Run bare `letitbrew hold` for 4 minutes and press
   Ctrl-C: no banner. Also `kill -9` the CLI of a `hold -- sleep 600` after 4
   minutes, then the `sleep`: "sleep 600 finished" / "Finished after N min",
   with no success or failure claimed.
5. Battery floor: on battery just above the floor (Settings → Power), keep an
   agent Working or a hold running until the charge reaches the floor. One
   banner: "Your Mac stopped keeping awake" / "Battery reached <floor>%." It
   does not repeat while the battery stays low. If work starts after the
   battery is already below the floor, nothing is sent.
6. Connected power only: turn it on, hold the Mac with work while plugged in,
   then unplug: "It switched to battery power." Plug in, wait for the hold,
   unplug again: a second banner.
7. Low Power Mode: turn on "Respect Low Power Mode", hold with work, then turn
   Low Power Mode on in System Settings → Battery: "Low Power Mode turned on."
   Pausing Let It Brew first, then turning it on, sends nothing.
8. Heat: if a sustained load can push `pmset -g therm` to a serious thermal
   level while work is held, confirm "It got too warm." once. Otherwise record
   this step as not reproduced.
9. Wi-Fi: turn on "Wi-Fi drops while the lid is closed". With the closed-lid
   switch on, hold the Mac with a 10-minute `letitbrew hold -- sleep 600`,
   close the lid, then turn the Wi-Fi router off (or leave its range) for
   about two minutes. Open the lid: Notification Center shows one "Wi-Fi
   dropped while your Mac was closed" / "Agents may be stuck until it
   reconnects." Repeat with an outage of about 20 seconds: no banner. Repeat
   with the lid open, and with nothing held: no banner. Turn Wi-Fi off with the
   lid open, then close it: no banner.
10. Check that no banner or Notification Center entry from steps 2–9 shows a
    prompt, question, tool name or command (a held command's own label is
    shown only while Hide project names is off).

### `letitbrew hold -- <command>`

`swift test` covers exit codes, Ctrl-C, record cleanup, pruning, and the
warnings with a stand-in app state. These need the signed app. Run the CLI
from the installed bundle:
`/Applications/Let\ It\ Brew.app/Contents/MacOS/letitbrew` (or `letitbrew`
once it is on the PATH).

1. With Let It Brew running, no agents working, and `pmset -g assertions`
   showing no Let It Brew assertion, run `letitbrew hold -- sleep 120`. Within
   two seconds the menu lists "Holding · sleep 120" with "Command" and an
   elapsed time, the header reads "Keeping your Mac awake" and
   "1 command is holding", and `pmset -g assertions` shows the hold. When the
   command ends the row disappears and the hold is released on the next poll.
2. With a Claude session working, start a hold. The header reads
   "1 agent is working · 1 command is holding". End the Claude turn: the Mac
   stays held until the command ends.
3. Run `letitbrew hold -- sh -c 'for i in $(seq 24); do date +%T | tee -a hold.log; sleep 5; done'`
   on battery with the closed-lid switch on, and close the lid within ten
   seconds. After two minutes, open it: the timestamps continue without a gap.
   Repeat with the closed-lid switch off: the Mac sleeps when the lid closes.
4. On battery below the battery floor, start a hold. No assertion is taken and
   the header shows "Battery limit reached". Repeat for connected-power-only
   on battery, and Low Power Mode with "Respect Low Power Mode" on.
5. Run `letitbrew hold -- vim` (or another full-screen program): it draws,
   takes input, and Ctrl-C/`:q` behave exactly as without `hold`. `echo $?`
   after `letitbrew hold -- false` prints 1.
6. Pause Let It Brew and run `letitbrew hold -- true`: one line warns that
   Let It Brew is paused and the command still runs. Quit Let It Brew and
   repeat: the warning says it isn't running.
7. Start `letitbrew hold -- sleep 600`, then `kill -9` the `letitbrew`
   process and the `sleep`. Within two seconds the row is gone and
   `~/Library/Application Support/LetItBrew/holds/` is empty.

### `letitbrew hold --pid N` and bare `letitbrew hold` (#60)

`swift test` covers `--pid` holding until another process exits (including a
root-owned PID), bare `hold` ending on SIGINT with exit 0, record cleanup, the
missing-PID error, usage errors, and the warnings with a stand-in app state.
These need the signed app and a real terminal. Run the CLI from the installed
bundle as in the section above.

1. Run `sleep 120 &`, then `letitbrew hold --pid $!`. Within two seconds the
   menu lists "Holding · Process <pid>" with the terminal glyph, "Command", and
   an elapsed time; the header reads "Keeping your Mac awake" and
   "1 command is holding"; `pmset -g assertions` shows the hold. When `sleep`
   ends, the CLI exits, `echo $?` prints 0, and the row disappears.
2. Run bare `letitbrew hold`. The menu lists "Holding · Terminal". Press
   Ctrl-C: the CLI exits without printing anything, `echo $?` prints 0, and
   the row disappears within two seconds.
3. Start bare `letitbrew hold` in a Terminal window and close the window
   (SIGHUP). The row disappears and `holds/` is empty.
4. With a Claude session working and one `hold -- sleep 300` running, start
   `letitbrew hold --pid 1`. The header reads
   "1 agent is working · 2 commands are holding" and the row reads
   "Holding · Process 1". Press Ctrl-C: `echo $?` prints 130.
5. Run `letitbrew hold --pid 99999` (or any PID `ps -p` reports missing): one
   line says there is no process with that PID, `echo $?` prints 1, and no row
   appears.
6. Start bare `letitbrew hold`, then `kill -9` the `letitbrew` process from
   another terminal. Within two seconds the row is gone and `holds/` is empty.
7. Pause Let It Brew and run bare `letitbrew hold`: one line warns that Let It
   Brew is paused and ends "Holding anyway."; within two seconds of resuming,
   the row appears and the Mac is held. Quit Let It Brew and run
   `letitbrew hold --pid 1`: the warning says it isn't running.

### Homebrew cask (#68)

`brew audit --cask --strict --online` and install/uninstall with a scratch
`--appdir` were checked before the cask merged. These need a spare Mac or
user account without Let It Brew installed and a real release newer than the
cask:

1. `brew install ruban-24/tap/letitbrew` puts `Let It Brew.app` in
   `/Applications` and `which letitbrew` prints the Homebrew `bin` link.
   Launch the app, connect an agent, and confirm the hook command points
   at `/Applications/Let It Brew.app/Contents/Helpers/letitbrew`, not the
   Homebrew link.
2. With the cask at release N and release N+1 published, update in the app
   (Settings → General → Check for Updates…). Afterwards bump the cask to
   N+1: `brew outdated --cask` does not list letitbrew and `brew upgrade`
   does not touch the app.
3. Open Settings → About → Uninstall Let It Brew…, then run
   `brew uninstall letitbrew`. The CLI link and
   `$(brew --prefix)/Caskroom/letitbrew` are gone and
   `sudo launchctl print system/com.ruban24.letitbrew.daemon` reports no
   such service.
4. Reinstall with `brew install ruban-24/tap/letitbrew` and record
   `pmset -g | grep SleepDisabled`. Launch the app, turn on closed-lid
   operation, approve the helper, and start a Claude turn so a hold is active.
   Run plain `brew uninstall letitbrew` without the in-app uninstaller. It
   finishes without errors, the `launchctl print` check above reports no such
   service, System Settings → General → Login Items & Extensions no longer
   lists the helper, and `SleepDisabled` matches the recorded value.
5. Repeat the install and enable steps from step 4, then run
   `brew reinstall letitbrew`. The helper is unregistered during the
   reinstall. Launch the app: it asks you to set up closed-lid support again.
   Choose Set Up (approve the helper if asked), and confirm `launchctl print`
   finds the service and a closed-lid hold works.

### Homebrew tap update (#69)

`scripts/tests/homebrew-tap-update-tests.sh` runs the update against a local
copy of the tap with a fake release. Only the real release can show the real
push. During the 2.0.0 cut, right after publishing GitHub release `v2.0.0`:

1. Run `scripts/update-homebrew-tap.sh 2.0.0 --dry-run`. The printed SHA-256
   matches the `LetItBrew-2.0.0.dmg` line in the published
   `LetItBrew-2.0.0-SHA256SUMS`, the diff changes only `version` and `sha256`,
   and `gh api repos/ruban-24/homebrew-tap/commits/main --jq .sha` is the same
   before and after.
2. Run `scripts/update-homebrew-tap.sh 2.0.0`. It ends with "Pushed letitbrew
   2.0.0 to the Homebrew tap", and the tap's latest commit is
   "letitbrew 2.0.0". Run it again: "Nothing to do", with no new commit.
3. Run `brew update`, then `brew info --cask ruban-24/tap/letitbrew` shows
   2.0.0, and `brew fetch --cask ruban-24/tap/letitbrew` downloads the DMG
   without a checksum error.
4. Confirm the GitHub release `v2.0.0` and its three assets are unchanged by
   the tap step.

### Command-line tool in Settings (#61)

`swift test` covers state detection (not installed, ours, Homebrew on Apple
Silicon and Intel, another app's file), the Settings wording for each state,
and the install and remove commands run without privileges against a temp
directory, including never replacing another app's file and never removing a
link that isn't ours. These need the signed app and an administrator account.
Before starting, record `ls -l /usr/local/bin/letitbrew /opt/homebrew/bin/letitbrew`.

1. On a Mac installed from the DMG with nothing at `/usr/local/bin/letitbrew`,
   open Settings → General. Command-line tool sits between the launch-at-login
   group (and Appearance, once it lands) and Updates. The row reads
   "`letitbrew` command" (letitbrew in monospace), "Not installed", and
   Install…, with the footer "Lets you run `letitbrew hold` in any terminal.
   Adds a link in /usr/local/bin and asks for your password."
2. Click Install… and choose Cancel in the password prompt. Confirm the prompt
   is the standard macOS administrator password prompt (macOS may name
   osascript as the requester; record what it shows), no error is shown,
   the row still reads "Not installed", and `ls -l /usr/local/bin/letitbrew`
   reports no such file.
3. Click Install… and enter your password. The row reads "● Installed in
   /usr/local/bin" with a green dot and Remove…, and the footer is gone.
   `readlink /usr/local/bin/letitbrew` prints
   `/Applications/Let It Brew.app/Contents/Helpers/letitbrew`.
4. Open a new Terminal window and run `which letitbrew` (prints
   `/usr/local/bin/letitbrew`) and `letitbrew hold -- sleep 30`: the menu lists
   "Holding · sleep 30" and the command exits 0.
5. Connect Claude Code (or reconnect it) and confirm the hook command in
   `~/.claude/settings.json` still points at
   `/Applications/Let It Brew.app/Contents/Helpers/letitbrew`, not
   `/usr/local/bin/letitbrew`.
6. Click Remove…, cancel the prompt: nothing changes. Click Remove… again and
   enter your password: the row returns to "Not installed" and the link is
   gone; the app bundle's CLI is untouched.
7. On a Mac where `/usr/local/bin` does not exist (common on a clean Apple
   Silicon Mac), Install… creates it and the link.
8. Put another app's file there: `sudo sh -c 'printf "#!/bin/sh\n" > /usr/local/bin/letitbrew'`.
   Reopen Settings: the row reads "/usr/local/bin/letitbrew belongs to another
   app. Let It Brew won't replace it." with no button. Remove the file.
9. On an Apple Silicon Mac with `brew install ruban-24/tap/letitbrew`, the row
   reads "● Installed by Homebrew" with no button. On an Intel Mac with the
   cask installed (its link is `/usr/local/bin/letitbrew`), the row also reads
   "● Installed by Homebrew" with no button, never Remove….
10. Check the group in light and dark appearance, and with VoiceOver: the dot
    is not read out, the row reads the state text and the button.
11. Restore anything changed so the `ls -l` output matches the record from the
    start.

### Menu-bar icon picker (#67)

`swift test` proves the beer mug, coffee cup, kettle and cauldron each draw
distinct idle, awake, needs-you and paused frames inside the canvas, that their
awake sequences loop (the kettle's in four frames, the others in eight), that
Reduce Motion and Low Power Mode leave one frame, and that a missing or unknown
saved choice is the flask. It cannot see the status item or Settings. With the
signed app:

1. Update from a build without the picker. Confirm the menu bar still shows the
   flask and Settings → General → Appearance has Flask selected, directly under
   the launch-at-login group and above Updates.
2. Confirm the Appearance group reads "Menu bar icon" with "Changes right away.
   It moves while your Mac is kept awake." under it, then five tiles in one row:
   Flask, Beer mug, Coffee, Kettle, Cauldron. Each tile's icon (about 30 pt)
   plays its awake loop; the selected tile has an accent border and a soft
   accent fill.
3. With an agent Working, click each tile in turn. The menu-bar icon changes at
   once without a relaunch and keeps animating: the mug's fizz rises and its
   foam bobs, the coffee steams, the kettle puffs from its spout, the cauldron
   bubbles.
4. For each new icon, at true size on a light menu bar and then a dark one
   (change the wallpaper or **System Settings → Appearance**), check the
   1.8 pt stroke reads cleanly next to other status items in all four states:
   idle (empty, still); awake; needs-you (filled and still, no steam, puffs or
   bubbles, with the orange dot at the top right in a cleared ring); paused
   (empty with a slash and a cleared gap either side). Open the menu: the icon
   stays legible on the highlighted button.
5. Turn on **Reduce motion**, then separately Low Power Mode. The menu-bar icon
   and every Settings preview stop on one frame, and resume when switched off.
6. Choose Cauldron, quit Let It Brew and relaunch it: the cauldron is still in
   the menu bar and selected in Settings.
7. With VoiceOver, move through the tiles: each reads its name and the chosen
   one reads as selected.

### Manual keep-awake sessions (#62)

`swift test` covers the session state machine (start, +1h, End, deadline
expiry), last-action-wins with Pause, resume on the same boot and discard
after a reboot or once expired, every power rule releasing a session, the
row and header wording, and `letitbrew status` (+ `--json`). These need the
signed app, light and dark appearance (**System Settings → Appearance**),
and a MacBook:

1. Idle, open the menu. Under the header (title, detail, switch, battery
   line) and a divider, the Keep awake row shows a timer glyph and
   "Keep awake", then bordered buttons "30m" "1h" "2h" "4h" "Until…"
   "Indefinitely", wrapping inside the 344 pt menu. The session list, the
   alerts tip, and Settings…/Quit follow below their dividers. Check both
   appearances.
2. Click 1h. The row becomes "Awake · 1:00 left" (time in bold, tabular
   digits) with "Until <time>" below and "+1h" and "End" on the right. The
   header reads "Keeping your Mac awake" / "You asked to keep it awake until
   <time>", the icon animates, and `pmset -g assertions` shows the hold.
   Leave the menu open for two minutes: the countdown ticks down by the
   minute. Click +1h: "1:58 left" becomes "2:58 left" and the Until time
   moves an hour. Click End: the buttons return and the hold is released.
3. Click Until…: it highlights in the accent colour and a line opens under
   the buttons: "Until [time] <word> [Start]". Pick a time later today
   before 6 PM ("today"), from 6 PM ("tonight"), and earlier than now
   ("tomorrow"). Start: the row counts down to that time. Click Until… again
   to close the line without starting.
4. Click Indefinitely. The row reads "Awake · No time limit" / "Until you
   end it" with End only, and the header detail is "You asked to keep it
   awake". (Indefinite is not in the mockup; wording is the coordinator's.)
5. With a session running, start a Claude turn: the header detail reads
   "You asked to keep it awake until <time> · 1 agent is working". End the
   turn: the session still holds. End the session while the turn runs: the
   agent still holds.
6. Turn the switch off (Pause). The session ends at once, the header reads
   "Let It Brew is paused" / "Agents will not keep your Mac awake", and the
   buttons show with "Starting one turns Let It Brew back on." under them.
   Click 30m: the switch turns back on and the session runs. A
   `letitbrew hold` running during the Pause is unaffected by the session.
7. Start a 30m session on battery with closed-lid operation on, run
   `sh -c 'for i in $(seq 24); do date +%T | tee -a session.log; sleep 5; done'`,
   and close the lid. After two minutes open it: no gap in the timestamps,
   and with closed-lid Low Power Mode on, the Mac switched to Low Power Mode
   while closed. Repeat with the closed-lid switch off: the Mac sleeps.
8. Start a 30m session, then use `letitbrew status` and `letitbrew status
   --json`: they report "manual session: until <time> (0:30 left)" and
   `manual_session` with `deadline` and `seconds_remaining`. With an
   Indefinitely session: "manual session: no time limit" and
   `"indefinite": true`.
9. Let a 30m session run out with the lid closed: within a few seconds of the
   deadline the Mac sleeps, and on opening the menu the buttons are back.
10. On battery below the battery floor, start a session. No assertion is
    taken; the header shows "Battery limit reached" and "Your keep-awake
    session is held back", and the row reads "Held back · 0:30 left". Repeat
    for connected-power-only on battery and for Low Power Mode with "Respect
    Low Power Mode" on.
11. Start a 2h session, quit Let It Brew and relaunch it (or install an
    update): the row resumes with the original Until time. Start an
    Indefinitely session and restart the Mac: after login the buttons show
    and no session runs.
12. With closed-lid Low Power Mode on, a 1h session, and nothing else
    holding, close the lid for a minute and open it: the row read "Awake",
    never "Held back", while Let It Brew's own Low Power Mode was on.
13. Start a 1h session, then begin Settings → About → Uninstall Let It Brew…
    and leave the confirmation open: the session has ended and the duration
    buttons do nothing. Cancel the uninstall: Let It Brew turns back on with
    no session.

### ntfy phone alerts (#65)

`AlertPolicy` tests cover away detection (lid closed, screen locked, 5
minutes without input, a docked Mac), the once-per-wait phone follow-up when
the person becomes away, and Always send to phone. `NtfyPublisher` tests cover
the request, the token header, and retry-once-then-drop against a stub
server. These steps need a phone, the network, and the signed app. Use a
throwaway topic; never paste a real topic into an issue.

1. Settings → Alerts, "On your phone": "Phone alerts" with "Get alerts on your
   phone through the free ntfy app." and Set Up; footer "Phone alerts go out
   only when you're away from your Mac." Press Set Up. The group expands in
   place: "Waiting for a test to arrive…", Cancel, a QR code (about 92 pt), the
   two steps naming a `letitbrew-` topic with at least 12 random characters
   and a Copy button beside it, the line "On iPhone, open ntfy, tap +, and
   paste this topic.", Send Test, and Advanced with Server "https://ntfy.sh"
   and Access token ("Optional"). Press Copy and paste somewhere: only the
   bare topic is pasted. Confirm with Little Snitch or `nettop -p "Let It
   Brew"` that Set Up and editing Advanced send no request. Press Cancel: the
   section returns to Set Up, and Set Up again shows a new topic.
2. **QR code (open question).** The code encodes the topic's https address
   (`https://ntfy.sh/<topic>`). The ntfy docs offer a subscribe deep link
   (`ntfy://<host>/<topic>`) only for Android, and the iOS app registers no
   URL scheme. Scan the code with an iPhone and an Android phone (the ntfy app
   and the system camera) and record what happens. If the app does not
   subscribe, report the result so the payload can change. On iPhone, also
   follow the hint: press Copy, open ntfy, tap +, paste the topic and
   subscribe (with a self-hosted server, choose it in ntfy's "Use another
   server" before subscribing).
3. Press Send Test. The phone shows "Let It Brew test" / "Phone alerts are
   working." Settings shows "● Working · test sent at <time>" (green dot,
   the real time), Turn Off, a smaller QR code with "ntfy.sh/<topic>" and a
   Copy button (it copies the bare topic), the iPhone line, Send Test,
   "Always send to phone" (off), and a collapsed Advanced showing
   "ntfy.sh". The "Alert me when" and Privacy groups are no longer dimmed,
   and the "Turn on desktop or phone alerts…" footer is gone, even with
   Desktop alerts off.
4. Away rule, with Always send to phone off and an approval left waiting 30
   seconds each time:
   - At the Mac, typing: no phone alert (desktop banner only, if on).
   - Lock the screen (Ctrl-Cmd-Q): the phone gets "Claude Code needs you" /
     "<folder> · Waiting for your approval", the desktop banner's words.
   - Close the lid with closed-lid support on while something keeps the Mac
     awake (a second agent Working, or `letitbrew hold -- sleep 600`; a lone
     Waiting agent releases the hold and the Mac sleeps): the phone gets the
     alert.
   - Docked with the lid closed and an external display, typing: no phone
     alert. Lock the screen while docked and let an approval wait: the
     phone gets it.
   - Leave the Mac untouched for 5 minutes, then let an approval wait: the
     phone gets the alert.
   - Becoming away later: at the Mac, let an approval wait 30 seconds (no
     phone alert), then lock the screen while it is still waiting. The phone
     gets the alert within a few seconds. Unlock, lock again: nothing more
     arrives for that wait. Repeat with Desktop alerts off: the phone still
     gets it once on locking. Answer a wait before locking: nothing arrives.
   Turn on Always send to phone and repeat at the Mac: the phone gets it.
5. The other alert types follow the same away rule, with the desktop's
   words, and are never resent on becoming away. With the screen locked
   and Always send to phone off:
   - `letitbrew hold -- sh -c 'sleep 200'` ends: the phone gets "sh -c
     sleep 200 finished" / "Succeeded after 3 min". An agent turn of over 3
     minutes ending sends "<Agent> finished" / "<folder> · Worked for N min".
   - With Connected power only on, hold the Mac with work while plugged in,
     then unplug: the phone gets "Your Mac stopped keeping awake" / "It
     switched to battery power." (the #64 section covers the other rules).
   - At the Mac, let one of these alert on the desktop only, then lock the
     screen: nothing follows on the phone.
   - The Wi-Fi alert fires only while the network is down, so its phone send
     fails, is retried once, and is dropped. Expect no Wi-Fi alert on the
     phone; it still shows on the desktop.
6. Turn on Hide project names: the phone body is only the state ("Waiting
   for your approval", "Worked for N min") and a held command is "A held
   command". Confirm no phone alert ever contains a prompt, question, or
   command, and has no emoji.
7. Turn Wi-Fi off, lock the screen, and let an approval wait 30 seconds.
   Confirm the menu shows no error, the hold is unchanged, and nothing arrives
   later when Wi-Fi returns (the send was retried once, then dropped).
   With Wi-Fi off, Send Test shows "The test didn't reach ntfy.sh. Check your
   connection and try again." in Settings only.
8. Custom server and token (needs a self-hosted ntfy with auth, or an ntfy.sh
   account token): open Advanced, enter the https server and an access token,
   press Return. Status drops back to "Waiting for a test to arrive…".
   Subscribe the phone to the topic on that server, press Send Test, and
   confirm it arrives. An `http://` server is rejected and the field reverts.
9. End to end on the maintainer's self-hosted ntfy server: open Advanced
   and enter the server's https URL and an access token (press Return after
   each). Status drops back to "Waiting for a test to arrive…" with Turn Off
   (not Cancel, since a test has been sent). Scan the QR code with the phone, or
   subscribe the ntfy app to that server and topic, then press Send Test: it
   arrives on the phone and Settings shows "● Working · test sent at <time>". Then close
   the lid with something keeping the Mac awake (see step 4) and let an agent
   approval wait 30 seconds: the real alert arrives on the phone through the
   self-hosted server. Check the server's log shows the request carried the
   token and nothing but the topic, title and message.
10. Keychain: in Keychain Access, find "Let It Brew ntfy access token"
   (service ending `.ntfy`). Confirm the token is not in
   `defaults read com.ruban24.letitbrew` (only `ntfyTopic`, `ntfyServer`,
   `ntfyTestSentAt`, `ntfyTestSent`, `phoneAlertsOn`,
   `alwaysSendToPhone`). Quit and relaunch: still Working and the token
   still works. Turn on Always send to phone, then Turn Off: the section
   returns to Set Up, the Keychain item and the topic stay, and a waiting
   approval with the screen locked sends nothing. Press Set Up: straight back
   to Working with the same topic, server, token and Always send to phone;
   the phone needs no new scan and the next alert arrives. Cancel on a fresh
   setup (step 1, before any test) is the only thing that removes the
   Keychain item and the topic.
11. Never set up: with Desktop alerts on and no Set Up, lock the screen and
   let an approval wait. Confirm no request leaves the Mac (Little Snitch or
   `nettop`).
12. Uninstall from Settings: confirm the Keychain item is removed.
13. Check the section in light and dark appearance, in all three states.
   With Set Up pressed (the tallest state), and again in Working with
   Advanced expanded, the whole "On your phone" group shows below "On this
   Mac" without scrolling or clipping; "Alert me when" and Privacy are reached
   by scrolling.

### Menu layout polish (2.0.0)

`swift test` covers which setup card shows and its icon. The look needs the
signed app. Check every step in light and dark appearance (**System Settings
→ Appearance**):

1. Fresh setup, with closed-lid setup unfinished and the alerts tip not yet
   dismissed, open the menu. It has one divider, directly above Settings…
   and Quit Let It Brew. The header, Keep awake, the session list and the
   cards are separated by space, not lines.
2. "Keep awake" is a small grey label, the same style as the session list's
   section titles, with no timer icon. Below it, compact buttons "30m" "1h"
   "2h" "4h" "Until…" "Indefinitely" sit close together on one line, clearly
   quieter than the menu title. Click Until…: it fills with the accent
   colour, and the Until line still appears below. Click it again to close.
3. The setup cards ("Finish closed-lid setup" and the alerts tip) are
   neutral: a near-white card with a thin border in light mode, a faint
   lifted card in dark mode, and no orange or purple wash. Only the icons
   are coloured: an orange laptop on the closed-lid card and a purple bell
   on the tip. Turn On is still the filled purple button. Both cards still
   work: the closed-lid card opens Settings, and Not Now dismisses the tip.
   If a sleep hold fails to release, its warning card has the same neutral
   look with an orange warning icon. An "Update … available" row keeps
   the same left edge as Settings… and Quit.
4. Click 1h. The small "Keep awake" label stays above "Awake · 1:00 left"
   (no timer icon), with "Until <time>" below and +1h and End on the right.
   End returns to the buttons.

## v1.0.1 release scope

This release replaces the input check for Claude, Copilot, Gemini, and Qwen
approvals. A click or key press no longer counts as an answer; an approval holds
only while the approved command runs. Record version 1.0.1, build 46, the full
commit, and artifact hashes, and `pmset -g | grep SleepDisabled` before and after.

1. Connect each of the four agents in Settings → Agents, then run
   `swift build` and `scripts/check-approval-hold.py claude`, then `copilot`,
   `gemini`, and `qwen`. Each prints three PASS lines: an unanswered approval is
   not running, an approved one is, and a denied one is not.
2. With a Claude approval showing "Needs your approval", open and close Let It
   Brew's menu, click in the terminal, and type in another pane without
   answering. Confirm the row stays "Needs your approval" and the menu header
   does not count it as working.
3. Approve `for i in $(seq 13); do date +%T | tee -a heartbeat.log; sleep 5; done`
   on battery, then close the lid within ten seconds. After two minutes, open it:
   the timestamps continue without a gap, and `pmset -g log` shows a Clamshell
   Sleep a few seconds after the last one.
4. Deny an approval with Esc, and leave another unanswered. Confirm each row
   lets the Mac sleep.

## v1.0.0 release scope

This release adds three things: closed-lid Low Power Mode in the daemon, a
Waiting state with an input check, and app-level session activation. It also
redesigns the menu and Settings, connects Cursor, Gemini CLI, Qwen Code, and Kimi
Code, and carries the unpublished v0.8.4 fixes, so run the v0.8.4 release scope
below with this build too.
Record version 1.0.0, build 45, the full commit, and artifact hashes. Before
starting, record `pmset -g custom | grep -E 'Power:|powermode'` and
`pmset -g | grep SleepDisabled`. Both must read back identically after every
case below.

### Closed-lid Low Power Mode

1. With the default setting on, on battery, start long Working agent work,
   close the lid with no external display, and wait 30 seconds. Over SSH or
   from another Mac with screen sharing, confirm every source reports `1` and
   the work continues.
2. Open the lid while work continues. Confirm each source returns to its
   recorded value within a few seconds and the Mac stays awake.
3. Close the lid again, then let the work finish. Confirm the energy mode is
   restored before the Mac sleeps: wake it and compare.
4. Repeat on the charger, and with one source already in Low Power Mode, and
   with `powermode 2` (High Power) on a Mac that offers it. Each exact prior
   value must come back.
5. With an external display attached and the lid closed, confirm Low Power Mode
   is not switched.
6. Turn on **Respect Low Power Mode**. Confirm closed-lid work keeps holding
   while Let It Brew's own switch is active, and that turning on Low Power
   Mode yourself with the lid open still releases the hold. With Low Power
   Mode set to "Only on Battery", start closed-lid work on the charger, then
   unplug: the hold must release, because battery Low Power Mode is yours.
7. Turn the closed-lid Low Power Mode setting off and confirm nothing is
   switched.
8. While switched, force-quit Let It Brew. Confirm the daemon restores the
   energy mode and `SleepDisabled` when the connection drops.
9. While switched, `sudo launchctl kickstart -k` the daemon. Confirm launch
   reconciliation restores the energy mode, and that the app reconnects and
   switches again only while the lid is still closed.
10. Uninstall while switched. Confirm the energy mode is restored before the
    service is unregistered.

### Waiting and the input check

   Claude refuses a foreground `sleep 240`; use a long command it accepts, for
   example `ping -c 240 127.0.0.1 >/dev/null && echo done`.
1. Claude: trigger a permission prompt for a long command and leave it. After
   about six seconds the row shows orange "Needs your approval" and the header
   reads "Agents are waiting for you". Close the lid and confirm the Mac sleeps.
2. Claude: approve a prompt after the six-second notification, for a command
   that runs several minutes, then walk away with the lid open. Confirm the row
   shows Working and the Mac stays awake until the command finishes.
3. Claude: approve within six seconds. Confirm the session never shows Waiting.
4. Claude and Codex: ask a question (`AskUserQuestion`, `request_user_input`).
   Confirm Waiting with no input, then Working after answering. Claude: leave
   the question unanswered for at least ten seconds, then type one key in that
   app without answering. The row must still read "Waiting for your answer"
   and the Mac must still be allowed to sleep; the session record keeps
   `detail: waiting-question` and `last_event: PreToolUse`.
5. Codex: trigger an approval with and without `approvals_reviewer =
   auto_review`. Confirm the session stays Working and holds in both.
6. Copilot, OpenCode, and Pi: confirm their questions and approvals show
   Waiting, release without input, and resume after an answer. Copilot: allow
   a long command with an allow rule or "approve for session", run it again,
   and confirm it stays Working with no input. Pi: open a dialog at the idle
   prompt and confirm no Waiting row appears.
7. Quit an agent that is Waiting without answering, before and after typing in
   its app. Confirm its row disappears and the Mac may sleep.
8. With a Claude approval Waiting, move the pointer, scroll, open and close Let
   It Brew's menu, and type in another app, such as a chat. Confirm the row
   stays Waiting and the Mac may still sleep. Then type one key in the
   session's own terminal or app and confirm the row shows Working and holds.
   Repeat with the session under tmux: input in any app counts there. With a
   question Waiting, type in the session's app without answering and confirm
   the row stays Waiting. Approve with Enter, then open Let It Brew's menu
   within a second, and confirm the row shows Working and holds.
9. Approve a long Claude command, then quit and relaunch Let It Brew while it
   runs. Confirm the row shows Working and the Mac stays awake.
10. Copilot: deny an approval, dismiss a question, and press Esc during a
    wait. Confirm each session returns to Idle or Working and does not stay
    Working after the turn has ended. Record any case that has no hook.
11. In the signed, Finder-launched app with no Input Monitoring permission,
    confirm key presses and clicks are still observed (step 8) and that no
    permission prompt appears.

### Session jump

Click a Working and a Waiting row for sessions in Terminal, iTerm2 (including
with its session-restoration server), Ghostty, Orca (whose terminal host runs
detached from the app), VS Code's terminal, the Claude desktop app, and the
Codex app. Each should bring its app forward with no permission prompt. Before
release, a dry run of the shipping lookup against live sessions resolved
Ghostty, Orca, and the Codex app, including Codex nested under the ChatGPT
app's bundled tools inside an Orca terminal, and a background process could
activate an app on this macOS; one click in the signed app still confirms the
popover path. Under tmux, confirm the click does nothing and nothing
fails. Confirm rows recorded before this release, which have no process ID, are
not clickable.

### Menu and Settings layout

In light and dark mode, with the signed app:

1. With one Waiting session and Working sessions in a shared folder and on
   their own, open the menu. Confirm **Needs You** lists the waiting session
   first, **Working** follows, folder rows do not repeat the folder name, and
   the header reads, for example, "2 agents are working · 1 waiting". The
   folder icon and name line up with the logos and names of sessions on their
   own rows, and an expanded folder's sessions keep that same left edge inside
   one shaded, rounded block. A
   Claude session left with only background work reads **Monitoring
   background tasks**.
2. Hover an expanded folder: its whole shaded block, folder and sessions,
   highlights; moving onto one of its sessions also highlights that session,
   and moving off the folder clears both. Hover a session: it highlights only
   if it can be brought forward, and its active time gives way to the eye
   button. Stop watching one session from
   the eye button and another from the right-click menu. With a Claude
   approval Waiting, click its row, then right-click it and choose **Show
   Session’s App**: both bring the app forward, and the row must stay
   Waiting, because clicks in Let It Brew's menu never count as an answer.
3. With more sessions than fit, confirm the list scrolls inside the menu and
   the footer stays visible.
4. Open Settings with ⌘, from the menu. Confirm the toolbar tabs General,
   Agents, Power, Closed Lid, and About, that the window title follows the
   tab, and that each pane fits without clipping. Run **Check for Updates…**
   from General.
5. On Agents, confirm the Claude Code, Codex, OpenCode, Copilot, and Pi marks
   are legible in dark mode and each row shows its connection status.
6. On Closed Lid, turn the closed-lid setting off and on, and confirm the
   helper status and Low Power Mode setting follow it.

### Background work after a Claude turn ends

Use a cheap model, for example `claude --model haiku`, in a fresh Claude Code
session for each case. Read the session's record under
`~/Library/Application Support/LetItBrew/sessions` and `pmset -g assertions`
to confirm the hold, and the menu to confirm the row.

1. Ask Claude to run `sleep 900` with `run_in_background` and reply without
   waiting. After it replies, the record is Working with `last_event: Stop`
   and `detail: background-shell`, the menu row reads **Monitoring background
   tasks**, the header counts it as monitoring, and the Mac is held, also with
   the lid closed. Wait at least two minutes: Claude's `idle_prompt`
   Notification arrives about a minute after the Stop, and the record must
   still be Working with `detail: background-shell` and an unchanged
   `updated_at`, with the Mac still held. Kill the sleep and send any prompt:
   the next Stop makes it Idle.
2. Repeat case 1 but leave the sleep running for over two hours without
   another hook (or, for a faster check, confirm from the status output that
   the reason becomes "monitoring hold expired" once the session's newest
   `updated_at` is two hours old). The hold releases while the row stays
   listed as **No update in 2 h · Mac can sleep** until the next hook.
3. Ask Claude to use the Agent tool with model haiku to start `sleep 800` in
   the background and return. After the parent replies, the child record is
   gone, the parent is Working with `detail: background-shell` and reads
   **Monitoring background tasks**, and killing the sleep plus one more
   prompt makes it Idle.
4. Ask Claude to start a background Agent that runs a few tool calls, and let
   the turn end. The parent reads **Monitoring background tasks** with
   `detail: background-agent` and the subagent's own row reads Working; both
   survive the `idle_prompt` a minute later. Then stop that agent with
   TaskStop before it finishes and let a turn end: the child record is
   deleted by the parent's Stop and the parent is Idle.
5. Ask Claude to schedule a recurring session task (for example `/loop 5m`
   with a harmless prompt) and let the turn end. The record is Working with
   `detail: scheduled-tasks`, reads **Monitoring background tasks**, and holds
   between firings. Cancel the loop and let a turn end: the session is Idle.
   Start the loop again, then Stop Watching the monitoring row: it disappears
   and the hold releases, and only the loop's next firing, a real new turn,
   brings it back.
6. Start a Codex session, let it work, and `kill -9` the Codex process. On
   the next poll the row disappears and the hold releases. Repeat with a
   Claude session: same result.

### Cursor, Gemini CLI, Qwen Code, and Kimi Code

Real CLI runs recorded in [AGENT-HOOK-CONTRACTS.md](AGENT-HOOK-CONTRACTS.md)
cover each agent's prompt, tool, Esc, and quit. These cases cover what those runs
could not.

1. Install this build over the previous one with Claude Code connected. Without
   any action, Claude stays connected, because its hook command changed and the
   app repairs it. Run a Claude prompt: the row goes Working, then Idle. Wait a
   minute, then confirm the background service kept the same process ID:
   `pgrep -x LetItBrewDaemon`. The automated checks can finish before a crash.
2. In **Settings → Agents**, turn each new agent on, then off. All nine rows fit,
   each connects, and turning it off removes only Let It Brew's entries. Turning an
   agent on creates its configuration file even if that CLI is not installed. Other
   switches and **Refresh Connections** do not dim, and the footer text changes once,
   to its final message. Flip several switches quickly: each one takes effect.
3. In Gemini or Qwen in a real terminal, approve a long command such as `sleep 60`
   with a real key press, without clicking the terminal first. The row reads
   **Needs your approval**, then stays Working and holds until the command
   finishes. Simulated keys do not count as input, so only this case proves it. A
   click in the terminal, or an Enter under a second before the prompt appears,
   also counts as an answer, so the row can read Working early. That is expected.
4. With Claude and Cursor both connected, run one `cursor-agent` prompt. There is one
   Cursor row and no Claude Code row. A duplicate row still holds the Mac, so it does
   not block a release.
5. With Claude connected and Cursor not, run one `cursor-agent` prompt. The session
   appears as Claude Code and holds until the turn ends.
6. In Cursor's editor agent, send one prompt and let it finish. The row goes Working,
   then Idle.
7. In Copilot, press Esc twice mid-turn; its footer reads `esc esc interrupt`. The
   row goes Idle.

8. Run one closed-lid test, because this release also changed the daemon's restore
   retry. Record `pmset -g | grep SleepDisabled` and `pgrep -x LetItBrewDaemon`. On
   battery with no external display, start a long agent task and close the lid for
   at least a minute. Open it and confirm from the task's output that work continued.
   When the task finishes, `SleepDisabled` reads its recorded value and the process
   ID is unchanged. Start another task and quit Let It Brew during the hold:
   `SleepDisabled` returns to its recorded value within a few seconds. A failed
   restore cannot be forced on a real Mac, so only unit tests cover the retry itself.

Esc during a Gemini tool leaves the turn Working until the next prompt's end, `/clear`,
exit, Stop Tracking, or the 12-hour expiry, as with Claude. Esc at a Gemini approval
prompt counts as a key press and holds the same way. Both are accepted limits, not
failures.

## v0.8.4 release scope

v0.8.4 fixes Claude and Codex sessions left Working by compaction, interrupts,
and missing subagent completion, and finds Codex bundled in newer desktop apps.
Record version 0.8.4, build 35, the full commit, and artifact hashes with the results. In the
signed app, run the Claude and Codex cases below, including idle compaction,
manual `/compact`, Codex Esc after approving the new `Interrupt` hook in
`/hooks`, and Codex subagents, with another session running to confirm it
remains protected. Verify that normal long-running work still holds the Mac
awake. With only the ChatGPT desktop app's bundled Codex available, confirm
Agents settings verifies already-trusted Codex hooks. Record Claude Esc
interrupts separately; Claude sends no hook for them, so they stay Working.
Run the signed-artifact and download-channel checks on the final release.
Power, daemon, login-item, and updater code are unchanged.

## v0.8.3 release scope

v0.8.3 fixes Claude parent/child completion and cleanup.
Record version 0.8.3, build 34, the full commit, and artifact hashes with the results. Exercise the
Claude completion, session-end, and resume cases below in the signed app, with
another Claude session running to confirm it remains protected. Verify that
normal long-running work still holds the Mac awake. Record interruption and
still-running monitor cases separately; this patch does not claim to resolve
missing completion hooks. Run the signed-artifact and download-channel checks
on the final release. Power, daemon, login-item, and updater code are unchanged.

## v0.8.2 release scope

v0.8.2 keeps the Launch at login setting's layout stable during registration,
failure, and retry. Record version 0.8.2, build 33, the full commit, and artifact
hashes with the results. In Settings → General, enable and disable Launch at
login: the switch and Closed lid section must remain in place while progress
appears beside the switch. Restore the original login preference after testing.
In the isolated native fixture, simulate registration failure, open the error
popover, and invoke Open Login Items; the form must stay in place and the
recovery action must run. Repeat the layout regression in light and dark mode.
The registration, power, daemon, agent-hook, and updater implementations are
unchanged. Run the signed-artifact and download-channel checks on the final
release, and smoke-test its Settings window before publication.

## v0.8.1 release scope

v0.8.1 stabilizes the activity menu during concurrent hook updates and fixes a
snapshot-read timing race. Record version 0.8.1, build 32, the full commit, and
artifact hashes with the results. With five or more Working Claude sessions,
scroll down and alternate tool activity between sessions and folders: surviving
rows and groups must keep their positions, with no polling-driven animation or
scrollbar movement. Stop and resume a child in an expanded two-session folder:
the header and expansion must remain while one child is still Working. Check
that actual completions remove rows, disclosure clicks still work, new sessions
append, and existing power/agent-visibility rules still apply. Run the signed
artifact and download-channel gates for the final release.

## v0.8.0 release scope

v0.8.0 adds Pi 0.87.1+ support and filters finished/idle Claude background
tasks on Stop. Record version 0.8.0, build 31, the full commit, and artifact
hashes with the results. Check Pi connection, task completion, and disconnect,
plus Claude background-agent completion. Power, daemon, and updater
implementations are unchanged. Verify the final signed/notarized artifact
and packaging before publication.

## v0.7.3 release scope

v0.7.3 changes only the update action's menu-row affordances and confirmation
ownership. Record version 0.7.3, build 30, the full commit, and artifact hashes
with the results. The completed v0.7.2 release evidence remains valid for
unchanged power, daemon, agent-hook, Settings, packaging, and recovery behavior.
Run the signed v0.7.2 -> v0.7.3 one-click update path from the menu popover and
confirm that it presents exactly one installer without opening Settings.

## v0.7.2 release scope

v0.7.2 changes only the menu popover's compact safety-state copy and leading
brand mark. Record version 0.7.2, build 29, the full commit, and artifact hashes
with the results. The completed v0.7.1 release evidence remains valid for
unchanged power, daemon, agent-hook, Settings, packaging, and recovery behavior.
Run the visual menu checks and the signed v0.7.1 → v0.7.2 one-click update path;
the latter is the live gate for the guided-DMG compatibility fix shipped in
v0.7.1.

## v0.7.1 release scope

v0.7.1 carries the v0.7.0 power, display, menu, Settings, passive-update,
recovery, and guided-installer changes, and corrects the mounted-DMG payload
check. Record version 0.7.1, build 28, the full commit, and artifact hashes with
the results. The completed v0.7.0 UAT remains evidence for unchanged behavior;
repeat the fresh-install and one-click-update paths with the signed v0.7.1
candidate because packaging and update validation are the affected release
boundaries.

## Manual replacement bridge

Run this once from a signed v0.6.5 install to the signed v0.7.1 candidate. It
proves the path required for existing users; do not substitute a fresh install.

1. With v0.6.5 installed at `/Applications/Let It Brew.app`, record its version
   and build, relevant preferences, agent connection states, a harmless session
   data fixture, daemon registration and health, and the exact `SleepDisabled`
   value.
2. Quit Let It Brew. Do not uninstall it or disconnect its agents.
3. Verify the v0.7.1 DMG against the candidate's generated checksum and release
   manifest. Open it, drag **Let It Brew.app** to **Applications**, and choose **Replace**.
4. Relaunch from Applications and confirm version 0.7.1, build 28.
5. Confirm the recorded preferences, agent connections, and session fixture are
   unchanged. Confirm the daemon's registered/absent state and health match the
   pre-replacement state with the v0.7.1 identity.
6. Confirm `pmset -g` has the exact recorded `SleepDisabled` value and there is
   no unexpected sleep debt, updater workspace, staged app, or backup.

This bridge bypasses the updater inside v0.6.5; it does not exercise the
corrected mounted-DMG validator. That validator requires a separate one-click
update from signed v0.7.1 to a signed version newer than v0.7.1 whose DMG uses
the guided layout. Run the checklist below when that authorized candidate
exists.

## One-click update

Run update UAT only from a Developer ID signed, release-verified install at the
exact path `/Applications/Let It Brew.app`. Record the old and new marketing
versions, decimal builds, full artifact hashes, app/daemon/helper CDHashes, and
the exact `SleepDisabled` entry before changing anything.

First exercise **Settings → General → Check for Updates…** when the current
published release is equal to or older than the installed app. It must report
**Let It Brew is up to date.** without downloading or quitting.

An available-update check requires a strictly newer published GitHub release with
exactly these two versioned updater assets, plus the byte-identical website alias:

- `LetItBrew-<version>.dmg`
- `LetItBrew-<version>-SHA256SUMS`
- `LetItBrew.dmg` (direct website download; ignored by updater asset selection)

Publishing, uploading, tagging, or promoting a release always needs separate
authorization. Until an authorized higher release exists, the production
available-update network path remains an explicit untested gate; do not replace
it with a report from the pure coordinator tests.

When that release exists, walk this checklist independently for each service
state below:

1. Record the old signed app identity, exact `SleepDisabled` baseline, relevant
   preferences, and a harmless user-data fixture beneath Let It Brew's user data
   directory.
2. Choose **Check for Updates…**. Confirm the exact expected version is offered
   and that cancelling once leaves the app, daemon, baseline, settings, and data
   unchanged.
3. Check again and choose **Install Update**. Observe one download/verification
   phase, the old app quitting, and exactly one ordinary app relaunching.
4. Confirm the result sheet reports success and the installed app version/build,
   hashes, Team ID, and app/helper/daemon identities match the new artifact.
5. Confirm the original preference values and user-data fixture are unchanged.
6. Confirm `pmset -g` still has the exact recorded `SleepDisabled` value and
   `/Library/Application Support/LetItBrew/` has no unexpected sleep debt.
7. Confirm there is no updater lock, backup, staged app, failed-new app, or
   download workspace left after proven success.

A signed attended rollback test must also inject one deterministic post-swap
failure, then prove the prior app relaunches, its original registered/absent
daemon state is restored, the exact baseline and user data survive, the result
sheet reports failure, and every retained recovery path is recorded. The isolated
shell failure matrix is necessary evidence but is not a substitute for this live
gate. Do not manufacture an unsafe power or service failure merely to satisfy the
checklist.

## Codex hook approval refresh

Run this flow with a signed candidate whose exact Codex hook definitions are
installed but not yet trusted:

1. Open **Settings → Agents** and confirm Codex reports **Action needed**.
2. In Codex, run `/hooks`, inspect the exact Let It Brew hook definitions, and
   approve them.
3. Return to Let It Brew without clicking **Refresh Connections**.
4. Confirm the Codex row changes to **Connected** automatically.
5. If Let It Brew says existing Codex sessions must be restarted, confirm an
   already-open session does not count as refreshed until it is restarted.
6. Repeat once by opening **Settings → Agents** directly and confirm pane
   appearance also refreshes the status without **Refresh Connections**.

Keep **Refresh Connections** available as the attended fallback. Confirm
returning to the app does not reconnect a Codex integration that the user
explicitly disconnected, does not recheck Claude as a side effect, and does not
create a timer or repeated refresh while the app remains active.

## Four-agent hook lifecycle matrix — not run by automation

This is an attended release gate, not evidence collected by this repository.
Do **not** run it against an unbacked-up local configuration, and do not record
which vendors happen to be installed today. At execution time, record the exact
installed vendor version. If a vendor is absent, mark that vendor's live UAT as
not run and keep it as a release gate; do not replace it with process-detection
or simulated evidence.

### Exact-target preservation and recovery (required for every vendor)

Before each vendor pass, resolve the selected user configuration target without
replacing its lexical symlink and make a private `0700` evidence directory
beneath `/private/tmp`. For each present final regular file, reserve a unique
recovery **name in that file's same parent directory and filesystem**. Do the
identical procedure for the exact registry
`~/Library/Application Support/LetItBrew/agent-hook-targets.json`.

For every present target and registry, record bytes and SHA-256, device/inode,
mode, owner/group, flags, mtime and birthtime where available, ACLs, and extended
attributes. `ctime` and link count are audit observations only: a same-directory
rename can legitimately change them, so do not require impossible equality.
Retain the original inode by atomically moving the original final file to a
unique same-directory recovery name, then create a disposable test copy at the
lexical target. Keep any lexical symlink unchanged. This lets the watched-agent
switch operate only on the disposable copy while the original inode remains
recoverable.

On normal cleanup, quit the Dev candidate, atomically move any test target to a
unique same-directory quarantine name, then atomically rename the retained
original recovery inode back to its lexical final target. Verify the recorded
bytes, digest, device/inode, mode, ownership, flags, mtime/birthtime where
available, ACLs, and xattrs. Apply this verification to the registry too. If a
test or Mac crashes, do not reconnect or overwrite anything: with the candidate
quit, perform that same quarantine-then-rename recovery before resuming normal
use. Keep the quarantine file for diagnosis until the verification succeeds.

For a truly absent target or registry, record absence rather than creating a
placeholder or recovery inode. After the pass, quarantine any created test file
and verify absence again. Do not promise inode identity for a file that did not
exist before the pass.

Turn the agent's watched switch on, verify its healthy state, and record whether
an existing session needs restart. For every pass use harmless work and verify:

1. `SessionStart` is Idle; a prompt makes it Working; a stop makes it Idle; and
   session end removes the record.
2. The Working → Idle → Working sequence updates the row and open-lid hold
   within two polls; removal releases it when it is the final Working record.
3. Turning the watched switch off immediately hides that vendor's records and
   removes only the owned configuration. Restore every backed-up target's exact
   bytes and metadata after the pass, or remove a target only when true absence
   was recorded before the pass.

Run these vendor-specific additions rather than claiming untested parity:

### Claude Code

Verify untrusted-workspace holdback before workspace trust. Run `/compact` at
an idle prompt and confirm the session stays Idle; run it in a fresh session
with too few messages to compact and confirm it stays Idle. Let a turn
auto-compact and confirm it stays Working until its `Stop`. Interrupt a turn
with Esc, confirm it stays Working, then run `/compact` and confirm it becomes
Idle. Start two child `agent_id` values, stop one child only, and confirm the other
remains Working. Confirm `StopFailure` becomes Idle and `Stop` remains Working
while `background_tasks` is nonempty, then becomes Idle after a later empty
Stop. Where the documented permission lifecycle is observed, it preserves the
existing Working state.

After a parent stops with an active background child, let the final child finish.
When its `SubagentStop` reports no remaining background work, confirm the parent
becomes Idle without another user prompt or parent Stop. Repeat with another
background task still running and confirm the hold remains. End a parent session
with children and confirm none of that session's rows remain; a second Claude
session must remain unaffected. Resume the ended session and confirm new work
appears normally.

Record interruption separately: Claude does not promise a Stop hook for a user
interrupt. A stopped parent with a still-running monitor, or a turn interrupted
without a later terminal event, can remain Working under the hook-only contract.
Do not claim these cases fixed solely from the parent/child cleanup regression.

### Codex

Verify `/hooks` trust approval before lifecycle observation, including the
`Interrupt` hook after upgrading an existing install. Press Esc during a turn
and confirm it becomes Idle. Run `/compact` at an idle prompt and confirm the
session stays Idle. Exercise two simultaneous distinct `agent_id` values; each
remains Working until its own `SubagentStop`. End a session with children and
confirm none of its rows remain. Where the documented permission lifecycle is
observed, it preserves the existing Working state.

Codex cannot be made to omit `SubagentStop` on demand, so replay that case
through the installed helper with a throwaway session. Pipe each payload, such
as `{"session_id":"uat-silent","cwd":"/tmp","agent_id":"A"}` (omit `agent_id`
for parent events), to `/Applications/Let It Brew.app/Contents/Helpers/letitbrew
hook codex <Event>`. Send `UserPromptSubmit`, `SubagentStart` for `A`, `Stop`,
`UserPromptSubmit`, `SubagentStart` for `B`, then `Stop`. Confirm `A` disappears
at the second `Stop` while `B`, heard during that turn, stays Working and holds
the Mac. Repeat with a new session ID and `Interrupt` in place of the final
`Stop`. End both sessions with `SessionEnd` and confirm none of their rows
remain.

### OpenCode

Test only a stable 1.x local CLI/app runtime. Confirm permission requests and
questions become Idle, while permission replies, answered questions, and
rejected questions return to Working. Send duplicate `session.status: idle`
and `session.idle` edges and confirm both remain idempotent.

### GitHub Copilot CLI

Confirm selected hooks remain silent and exit zero. Exercise permission prompts
and question tools and confirm they become Idle; a later `PostToolUse` for the
completed question returns to Working. Exercise `ErrorOccurred` with the tested
CLI version: `recoverable: true` must preserve the prior state, while
`recoverable: false` must become Idle.

At the end of each pass, complete the exact-target recovery and verification
above for the registry and every selected configuration target. This matrix never
permits live process detection, CPU detection, or transcript parsing as a
substitute for a lifecycle hook.

## Concurrent Working sessions and adaptive menu

Run this only with an isolated, signed Dev candidate. Do not install, launch, or
exercise the production bundle for this check. Keep closed-lid support disabled,
do not approve or register the Dev background service, and confirm
`com.ruban24.letitbrew.dev.daemon` is absent before, during, and after the run.
This is an open-lid assertion and menu test; it must not change `SleepDisabled`.

Before connecting any agent, follow **Exact-target preservation and recovery**
above for every selected target and registry. Do not use `ditto` or another
copy as restoration evidence: the retained same-directory original inode is the
only restore authority. Record true absence separately; do not create a
placeholder backup for an absent config.

Then record:

- the candidate commit and SHA-256 of the candidate app executable;
- the Dev bundle ID and the app's signing identity;
- whether each Claude, Codex, OpenCode, and Copilot user target exists;
  every resolved target path; a byte-for-byte backup of every existing file; and
  each file's pre-test SHA-256; and
- affirmative absence of the Dev daemon registration and process.

Use one newly created disposable root beneath `/private/tmp`, with two
same-named project folders at different full paths. Start sessions from the
connected agents for use in those folders; begin the matrix with all sessions in
the first full path. Use only harmless test work. Do
not inspect, copy, screenshot, or include notification prose, prompts, responses,
reasoning, tool details, or final assistant text in the evidence; record only
structural events, counts, hold state, and menu/accessibility observations. Each
expected transition must appear within two one-second polls. For every numbered
step below, record the actual visible Working count and whether the Dev app's
open-lid `PreventUserIdleSystemSleep` assertion is present or absent.

1. Make one session Working. Expect one flat row and the open-lid assertion.
2. Make a second session in that same full folder path Working. Expand its
   disclosure header and expect two aligned children and the assertion still
   present.
3. Make three more sessions Working in that folder, for five total. Expect one
   header and four session rows in the 294-point visible window, with the fifth
   child reachable through the single outer scroll.
4. Trigger a harmless permission request in a Working session without recording
   its prose. A `PermissionRequest` or permission-prompt notification must leave
   the visible count, row state, and assertion unchanged.
5. Make one session Idle through `Stop` or an idle notification. Its child row
   must disappear, the visible count must fall by one, and the assertion must
   remain present. Submit new work in that same session; it must reappear as
   Working and restore the previous visible count.
6. Make two sessions in the second same-named folder Working, allowing other
   sessions to become Idle as needed to keep the total near five. Confirm the
   full paths remain distinct groups. Expand the second group and confirm the
   first collapses; manual expansion must not jump while the chosen group remains
   eligible.
7. Make every session Idle. All rows must disappear and the open-lid assertion
   must be absent.

Record these visual and accessibility results during the matrix:

- popover viewport: test once at the current display scaling and once after
  selecting **System Settings > Displays > Larger Text** for the display that
  contains the menu bar. Before changing the display, record its exact current
  resolution/scaling selection. At both scales require a 344-point width, one
  outer vertical scroll, no nested group scroll, and a visible cap of 294 points
  (one 54-point header plus four 60-point rows). After the scaled pass, restore
  the exact recorded display selection and verify the restoration;
- accordion: at most one repository expanded, with disclosure state announced;
- alignment: grouped children have the same logo, text, and timer columns as a
  flat row, with no indentation; visible rows show the agent and project folder,
  while colliding eight-character ID prefixes lengthen until each accessibility
  label's short ID is unique; and
- VoiceOver: group labels include the full folder path, session count, agent
  summary, and expanded/collapsed state; child labels include agent, full folder
  path, short ID, Working state, and accumulated active time; disclosure and
  session-action controls remain keyboard reachable.

At cleanup, quit the Dev app and end the test sessions before removing only the
exact disposable root. Unless the user explicitly approves retaining the
validated Let It Brew-owned hooks, use the quarantine-then-atomic-rename
procedure above to restore each retained original target and registry inode
without replacing a lexical symlink. Quarantine a newly created config only when
preflight recorded true absence. Finally record the visible Working count as
zero, the open-lid assertion as absent, and the Dev daemon registration and
process as absent throughout.

## Uninstall

Uninstall's filesystem effects have their own throwaway-home check:

```sh
scripts/test-uninstall-safety.sh
```

The daemon gates and the app's self-trash cannot be automated — they need a
reinstall per run. Verify them attended on a signed install at
`/Applications/Let It Brew.app`:

1. Record whether Let It Brew is active or already paused. Choose **Uninstall
   Let It Brew…** and confirm that exactly one confirmation appears.
2. Cancel once. A previously active app must resume; a previously paused app
   must stay paused. Start uninstall again, confirm, and verify the dialog stays
   dismissed throughout teardown.
3. `sudo launchctl print system/com.ruban24.letitbrew.daemon` reports no such
   service.
4. `pgrep -f Let It Brew` reports nothing.
5. `pmset -g | grep SleepDisabled` matches the value recorded before the test.
6. `/Library/Application Support/LetItBrew/` contains no `.sleep-debt.json`.
7. `~/Library/Application Support/LetItBrew/` is absent.
8. `defaults read com.ruban24.letitbrew` reports the domain does not exist.
9. `Let It Brew.app` is in the Trash and absent from `/Applications`.

For a never-registered Launch at Login state, confirm uninstall treats both
Service Management's documented `kSMErrorJobNotFound` and macOS 26's observed
`SMAppServiceErrorDomain (1)` response as already absent only when Let It Brew
did not record an enabled choice. The app must quit without showing a leftovers
report.

If a genuine best-effort step is forced to fail, confirm the report says the
app bundle was removed only when that is true, confirms the privileged
background service is stopped, gives exact cleanup steps, hides the ordinary
menu-bar item, and labels its final action **Finish & Quit**.
A Launch at Login failure must also offer **Open Login Items…**, and its copied
diagnostic must include the NSError domain, code, and nested underlying error
when one exists.

Close the Settings window immediately after confirming uninstall, before
teardown completes. If a best-effort failure reaches the report, confirm the
menu-bar popover shows only **Uninstall needs attention** and **Show Cleanup
Instructions**, not the ordinary paused interface. Opening those instructions
must reopen Settings and present the report from any selected pane; once the
report is visible, the ordinary menu-bar item must disappear.

If a real hard gate blocks during an attended run, do not manufacture a second
failure. Confirm the error remains visible while the app stays paused and that
**Try Again** and **Resume Let It Brew** remain usable. When the diagnostic is
offered after a retry or a confirm-time refusal, confirm **Copy Diagnostic**
also remains usable.

`UninstallEnvironmentLive.swift` and the model actions that drive the real
uninstall have no automated coverage. The checklist above is the only evidence
for the live teardown.

## The three service states

The update and uninstall checklists must be walked independently for each state
below. Reconciliation never gates on the "Keep agents working when the lid is
closed" toggle: it proves whether the daemon is present or affirmatively absent.
Uninstall unregisters a present daemon and skips unregister only after fresh
affirmative absence, so all three states must genuinely complete rather than
skip themselves based on the preference.

**1. Never registered.** A fresh copy where the closed-lid toggle has never been
turned on. There is no service to reconcile or unregister. For uninstall, a
fresh affirmative absence result skips the Service Management unregister call
and cleanup completes normally. For update UAT: the daemon is affirmatively
absent before and after, and no launchd job or daemon process appears.

**2. Registered and running.** Turn the toggle on, click **Set Up Closed-Lid
Support** if shown, and approve Let It Brew in **System Settings → General →
Login Items & Extensions → App Background Activity**. Confirm
`sudo launchctl print system/com.ruban24.letitbrew.daemon` reports
`state = running`, then run the checklist. This is the primary case. For update
UAT: afterwards exactly one new daemon answers with the installed candidate's
native CDHash/version/build.

**3. Stranded — registered, but the toggle is off.** Repeat state 2 to get the
daemon approved and running, then turn the closed-lid toggle back **off** before
uninstalling or updating. Turning the toggle off releases the sleep hold but does
not unregister the daemon, so the service is still registered even though the
preference now reads "off". Confirm `launchctl print` still reports the daemon
registered before you start. Uninstall must still reconcile and unregister it
exactly as in state 2; update must follow the registered path and emerge as the
strictly identified new daemon. **The false preference must never be treated as
daemon absence** — this is the regression that caused the most trouble in this
work.
