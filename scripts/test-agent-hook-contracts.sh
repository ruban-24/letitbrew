#!/bin/bash
# Five-agent contract: all writes are contained below one explicit test home.
set -euo pipefail
CLI_INPUT="${1:?usage: test-agent-hook-contracts.sh /absolute/path/to/letitbrew}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLI_INPUT")"
[[ "$CLI" = /* && -x "$CLI" ]] || { echo "FATAL: CLI must be an executable absolute path" >&2; exit 1; }
command -v node >/dev/null || { echo "FATAL: node is required for the OpenCode runtime contract" >&2; exit 1; }
TEST_HOME="$(mktemp -d /tmp/letitbrew-agent-hooks.XXXXXX)"
trap 'rm -rf "$TEST_HOME"' EXIT
export LETITBREW_TEST_HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.codex" "$TEST_HOME/.cursor" "$TEST_HOME/.copilot/hooks"
printf '{"foreign":{"claude":true}}\n' > "$TEST_HOME/.claude/settings.json"
printf '{"description":"foreign","hooks":{"foreign":[]}}\n' > "$TEST_HOME/.codex/hooks.json"
printf '{"version":1,"hooks":{"foreign":[]}}\n' > "$TEST_HOME/.cursor/hooks.json"
printf '{"version":1,"hooks":{"foreign":[]}}\n' > "$TEST_HOME/.copilot/hooks/letitbrew.json"
for agent in claude codex cursor opencode copilot; do "$CLI" install "$agent" >/dev/null; done
REGISTRY="$TEST_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json"
test "$(stat -f '%Lp' "$REGISTRY")" = "600"
"$CLI" doctor >/dev/null
grep -q '__letitbrew_hook' "$TEST_HOME/.claude/settings.json"
grep -q '__letitbrew_codex_hook' "$TEST_HOME/.codex/hooks.json"
grep -q '__letitbrew_cursor_hook' "$TEST_HOME/.cursor/hooks.json"
grep -q '^// __letitbrew_opencode_plugin$' "$TEST_HOME/.config/opencode/plugins/letitbrew.js"
grep -q '__letitbrew_copilot_hook' "$TEST_HOME/.copilot/hooks/letitbrew.json"
# The fixtures start with no ownership marker.  Require the complete current
# lifecycle surface, rather than accepting one marker or an arbitrary grep.
node -e '
const fs=require("fs");
const cases=[[process.argv[1],"__letitbrew_hook",13],[process.argv[2],"__letitbrew_codex_hook",11],[process.argv[3],"__letitbrew_cursor_hook",8],[process.argv[4],"__letitbrew_copilot_hook",5]];
for (const [file, marker, count] of cases) { const source=fs.readFileSync(file,"utf8"); const found=source.split(marker).length-1; if(found!==count) throw new Error(`${file}: expected ${count} ${marker} entries, got ${found}`) }
' "$TEST_HOME/.claude/settings.json" "$TEST_HOME/.codex/hooks.json" "$TEST_HOME/.cursor/hooks.json" "$TEST_HOME/.copilot/hooks/letitbrew.json"
test "$(node "$SCRIPT_DIR/test-opencode-plugin.mjs" "$CLI" "$TEST_HOME/.config/opencode/plugins/letitbrew.js")" = "PASS: OpenCode plugin runtime contract"
"$CLI" uninstall cursor >/dev/null
"$CLI" uninstall opencode >/dev/null
"$CLI" uninstall copilot >/dev/null
! grep -q '__letitbrew_cursor_hook' "$TEST_HOME/.cursor/hooks.json"
! test -e "$TEST_HOME/.config/opencode/plugins/letitbrew.js"
! grep -q '__letitbrew_copilot_hook' "$TEST_HOME/.copilot/hooks/letitbrew.json"
grep -q '__letitbrew_hook' "$TEST_HOME/.claude/settings.json"
grep -q '__letitbrew_codex_hook' "$TEST_HOME/.codex/hooks.json"
node -e 'const fs=require("fs"); for (const f of process.argv.slice(1)) { const x=JSON.parse(fs.readFileSync(f)); if (!(x.foreign?.claude || x.hooks?.foreign)) process.exit(1) }' "$TEST_HOME/.claude/settings.json" "$TEST_HOME/.codex/hooks.json" "$TEST_HOME/.cursor/hooks.json" "$TEST_HOME/.copilot/hooks/letitbrew.json"
# Exact grammar: unscoped and each five-agent scoped form are accepted; every
# malformed/extra form is rejected without relying on shell word splitting.
for agent in claude codex cursor opencode copilot; do "$CLI" install "$agent" >/dev/null; done
for agent in claude codex cursor opencode copilot; do "$CLI" uninstall "$agent" >/dev/null; done
"$CLI" install >/dev/null
"$CLI" uninstall >/dev/null
! "$CLI" >/dev/null 2>&1
for command in "install claude extra" "uninstall nope" "uninstall claude extra" "install nope" "prepare-exact"; do ! "$CLI" $command >/dev/null 2>&1; done
# Registry parent symlinks are unsafe even with a non-symlink final name: a
# test-home operation must fail before either vendor config or registry bytes
# can escape through the parent.
SYMLINK_HOME="$(mktemp -d /tmp/letitbrew-registry-link.XXXXXX)"
OUTSIDE_HOME="$(mktemp -d /tmp/letitbrew-registry-outside.XXXXXX)"
trap 'rm -rf "$TEST_HOME" "$SYMLINK_HOME" "$OUTSIDE_HOME"' EXIT
mkdir -p "$SYMLINK_HOME/Library/Application Support"
ln -s "$OUTSIDE_HOME" "$SYMLINK_HOME/Library/Application Support/LetItBrew"
! env LETITBREW_TEST_HOME="$SYMLINK_HOME" "$CLI" install claude >/dev/null 2>&1
! test -e "$OUTSIDE_HOME/agent-hook-targets.json"
! test -e "$SYMLINK_HOME/.claude/settings.json"
echo "PASS"
