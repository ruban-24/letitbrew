#!/bin/bash
# Uninstall must remove every Let It Brew-owned artifact and nothing else.
#
# Runs the real helper against a throwaway LETITBREW_TEST_HOME, so the user's
# live agent hook and plugin files are never touched.
# Covers the filesystem-effect steps only: the daemon gates and the self-trash
# are attended procedures.
#
# Usage: scripts/test-uninstall-safety.sh ["/Applications/Let It Brew Dev.app/Contents/Helpers/letitbrew"]
set -uo pipefail

CLI="${1:-/Applications/Let It Brew Dev.app/Contents/Helpers/letitbrew}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-power-baseline.sh
source "$SCRIPT_DIR/lib-power-baseline.sh"

[ -x "$CLI" ] || { echo "FATAL: $CLI not found or not executable." >&2; exit 1; }

# Exact ownership markers (Sources/LetItBrewCore/ClaudeHooks.swift,
# CodexHooks.swift) — not the loose substring "letitbrew", which could match
# text that has nothing to do with Let It Brew's own hook entries. Matched as
# the trailing sentinel HookFile.isOurs actually checks (": # <marker>", see
# Sources/LetItBrewCore/HookFile.swift), not as a bare substring anywhere in
# the file, so a stray mention of the marker text elsewhere can't pass this.
#
# Known gap: this confirms SOME owned entry exists/is gone, not one owned
# entry per installed event. Asserting per-event presence would mean
# duplicating ClaudeHooks.events/CodexHooks.events here, which would silently
# drift from the Swift source that actually defines them — left out on
# purpose rather than reimplementing that contract in bash.
CLAUDE_MARKER="__letitbrew_hook"
CODEX_MARKER="__letitbrew_codex_hook"
CLAUDE_MARKER_SUFFIX=": # ${CLAUDE_MARKER}\""
CODEX_MARKER_SUFFIX=": # ${CODEX_MARKER}\""

entry_baseline="$(baseline_read_sleepdisabled)" || {
    echo "FATAL: could not read an exact SleepDisabled baseline." >&2
    exit 1
}

fail=0
check() {
    local desc="$1"
    shift
    if "$@"; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc" >&2
        fail=1
    fi
}

TEST_HOME="$(mktemp -d /tmp/letitbrew-uninstall-test.XXXXXX)"
mktemp_status=$?
if [ "$mktemp_status" -ne 0 ] || [ -z "$TEST_HOME" ] || [ ! -d "$TEST_HOME" ]; then
    echo "FATAL: mktemp did not produce a usable temporary directory (status $mktemp_status)." >&2
    exit 1
fi
case "$TEST_HOME" in
    /tmp/letitbrew-uninstall-test.*) ;;
    *)
        echo "FATAL: mktemp returned an unexpected path '$TEST_HOME'." >&2
        exit 1
        ;;
esac
trap 'rm -rf "$TEST_HOME"' EXIT
export LETITBREW_TEST_HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.codex" "$TEST_HOME/.copilot/hooks" "$TEST_HOME/.config/opencode/plugins"

# A user hook Let It Brew must never touch.
cat > "$TEST_HOME/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "Stop": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/usr/bin/true" }] }
    ]
  }
}
JSON
user_claude_before="$(python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
groups=doc.get("hooks",{}).get("Stop",[])
kept=[g for g in groups if not any(h.get("command","").endswith(": # __letitbrew_hook") for h in g.get("hooks",[]))]
print(json.dumps({"model":doc.get("model"),"kept":kept},sort_keys=True))
' "$TEST_HOME/.claude/settings.json")"
printf '{"version":1,"hooks":{"foreign":[{"nested":["copilot",4]}]}}' > "$TEST_HOME/.copilot/hooks/letitbrew.json"
copilot_foreign_before="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["hooks"]["foreign"],sort_keys=True))' "$TEST_HOME/.copilot/hooks/letitbrew.json")"

install_status=0
"$CLI" install >/dev/null 2>&1 || install_status=$?
if [ "$install_status" -ne 0 ]; then
    echo "FATAL: $CLI install exited $install_status; a working install is required before uninstall can be exercised." >&2
    exit 1
fi

# Prove there is something for uninstall to remove. Without this, a helper
# that installs nothing would make every absence check below pass vacuously.
check "Let It Brew's Claude entries are present after install" \
    grep -qF "$CLAUDE_MARKER_SUFFIX" "$TEST_HOME/.claude/settings.json"
check "Let It Brew's Codex entries are present after install" \
    grep -qF "$CODEX_MARKER_SUFFIX" "$TEST_HOME/.codex/hooks.json"
check "Let It Brew's OpenCode plugin is present after install" grep -q '^// __letitbrew_opencode_plugin$' "$TEST_HOME/.config/opencode/plugins/letitbrew.js"
check "Let It Brew's Copilot entries are present after install" grep -q '__letitbrew_copilot_hook' "$TEST_HOME/.copilot/hooks/letitbrew.json"

uninstall_status=0
"$CLI" uninstall >/dev/null 2>&1 || uninstall_status=$?
check "uninstall exits 0" [ "$uninstall_status" -eq 0 ]

check "Let It Brew's Claude entries are gone" \
    bash -c '! grep -qF "$1" "$0/.claude/settings.json"' "$TEST_HOME" "$CLAUDE_MARKER_SUFFIX"

user_claude_after="$(python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
groups=doc.get("hooks",{}).get("Stop",[])
kept=[g for g in groups if not any(h.get("command","").endswith(": # __letitbrew_hook") for h in g.get("hooks",[]))]
print(json.dumps({"model":doc.get("model"),"kept":kept},sort_keys=True))
' "$TEST_HOME/.claude/settings.json")"
check "the user's own Claude configuration survived unchanged" \
    [ "$user_claude_before" = "$user_claude_after" ]

check "Let It Brew's Codex entries are gone" \
    bash -c '! grep -qF "$1" "$0/.codex/hooks.json" 2>/dev/null' "$TEST_HOME" "$CODEX_MARKER_SUFFIX"
check "Let It Brew's OpenCode plugin is gone" test ! -e "$TEST_HOME/.config/opencode/plugins/letitbrew.js"
check "Let It Brew's Copilot entries are gone" bash -c '! grep -q __letitbrew_copilot_hook "$0/.copilot/hooks/letitbrew.json"' "$TEST_HOME"
copilot_foreign_after="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["hooks"]["foreign"],sort_keys=True))' "$TEST_HOME/.copilot/hooks/letitbrew.json")"
check "Copilot's complete foreign subtree survived unchanged" [ "$copilot_foreign_before" = "$copilot_foreign_after" ]

# Every mergeable JSON target must refuse malformed bytes without a rewrite.
# These are the post-uninstall configured paths, so there is no registry
# record silently redirecting the test to a different target.
for malformed in \
    "claude:$TEST_HOME/.claude/settings.json" \
    "codex:$TEST_HOME/.codex/hooks.json" \
    "copilot:$TEST_HOME/.copilot/hooks/letitbrew.json"; do
    agent="${malformed%%:*}"
    target="${malformed#*:}"
    before="$TEST_HOME/${agent}-malformed-before.json"
    printf '{ this is not json' > "$target"
    cp "$target" "$before"
    uninstall_status=0
    "$CLI" uninstall "$agent" >/dev/null 2>&1 || uninstall_status=$?
    check "uninstall $agent refuses malformed input with the defined status 1" [ "$uninstall_status" -eq 1 ]
    check "a malformed $agent file was left byte-identical" cmp -s "$before" "$target"
done

# OpenCode owns a whole file and must refuse both an unowned same-name file
# and a later final-component symlink, preserving the destination bytes.
OPENCODE_PLUGIN="$TEST_HOME/.config/opencode/plugins/letitbrew.js"
printf '// user plugin\n' > "$OPENCODE_PLUGIN"
cp "$OPENCODE_PLUGIN" "$TEST_HOME/opencode-foreign-before.js"
uninstall_status=0
"$CLI" uninstall opencode >/dev/null 2>&1 || uninstall_status=$?
check "uninstall opencode refuses an unowned file" [ "$uninstall_status" -eq 1 ]
check "an unowned OpenCode file was left byte-identical" cmp -s "$TEST_HOME/opencode-foreign-before.js" "$OPENCODE_PLUGIN"
mv "$OPENCODE_PLUGIN" "$TEST_HOME/opencode-symlink-destination.js"
ln -s "$TEST_HOME/opencode-symlink-destination.js" "$OPENCODE_PLUGIN"
uninstall_status=0
"$CLI" uninstall opencode >/dev/null 2>&1 || uninstall_status=$?
check "uninstall opencode refuses a final symlink" [ "$uninstall_status" -eq 1 ]
check "an OpenCode symlink destination was left byte-identical" cmp -s "$TEST_HOME/opencode-foreign-before.js" "$TEST_HOME/opencode-symlink-destination.js"

# Use the executable command's test-only boundary seams to prove disconnect
# ordering: a failed clear leaves the recorded stale target for a real retry,
# while a post-quarantine active replacement survives the old owner's remove.
BOUNDARY_HOME="$(mktemp -d /tmp/letitbrew-uninstall-boundary.XXXXXX)"
mkdir -p "$BOUNDARY_HOME/.copilot/hooks"
printf '{"version":1,"hooks":{"foreign":[1]}}' > "$BOUNDARY_HOME/.copilot/hooks/letitbrew.json"
env LETITBREW_TEST_HOME="$BOUNDARY_HOME" "$CLI" install copilot >/dev/null
boundary_registry="$BOUNDARY_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json"
boundary_target="$BOUNDARY_HOME/.copilot/hooks/letitbrew.json"
uninstall_status=0
env LETITBREW_TEST_HOME="$BOUNDARY_HOME" LETITBREW_TEST_FAULT=registry-clear "$CLI" uninstall copilot >/dev/null 2>&1 || uninstall_status=$?
check "registry clear failure is reported" [ "$uninstall_status" -eq 1 ]
check "registry clear failure retains its stale Copilot record" python3 -c 'import json,sys; assert "copilot" in json.load(open(sys.argv[1]))["targets"]' "$boundary_registry"
cp "$boundary_target" "$BOUNDARY_HOME/copilot-after-failed-clear.json"
env LETITBREW_TEST_HOME="$BOUNDARY_HOME" "$CLI" uninstall copilot >/dev/null
retry_stale=0
python3 -c 'import json,sys; assert "copilot" not in json.load(open(sys.argv[1]))["targets"]' "$boundary_registry" || retry_stale=$?
check "retry clears stale Copilot record" [ "$retry_stale" -eq 0 ]
check "retry does not rewrite an already-clean Copilot target" cmp -s "$BOUNDARY_HOME/copilot-after-failed-clear.json" "$boundary_target"
rm -rf "$BOUNDARY_HOME"

REPLACEMENT_HOME="$(mktemp -d /tmp/letitbrew-uninstall-replacement.XXXXXX)"
env LETITBREW_TEST_HOME="$REPLACEMENT_HOME" "$CLI" install opencode >/dev/null
env LETITBREW_TEST_HOME="$REPLACEMENT_HOME" LETITBREW_TEST_FAULT=active-replacement "$CLI" uninstall opencode >/dev/null
check "an active OpenCode replacement survives its predecessor's removal" test "$(cat "$REPLACEMENT_HOME/.config/opencode/plugins/letitbrew.js")" = "foreign replacement after quarantine"
rm -rf "$REPLACEMENT_HOME"

exit_baseline="$(baseline_read_sleepdisabled)" || {
    echo "FAIL: could not read an exact SleepDisabled baseline on exit." >&2
    fail=1
}
check "the power baseline never moved" [ "$entry_baseline" = "$exit_baseline" ]

if [ "$fail" -eq 0 ]; then
    echo "PASS"
else
    echo "FAILED" >&2
fi
exit "$fail"
