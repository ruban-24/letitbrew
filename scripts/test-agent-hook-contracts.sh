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
"$CLI" doctor >/dev/null
grep -q '__letitbrew_hook' "$TEST_HOME/.claude/settings.json"
grep -q '__letitbrew_codex_hook' "$TEST_HOME/.codex/hooks.json"
grep -q '__letitbrew_cursor_hook' "$TEST_HOME/.cursor/hooks.json"
grep -q '^// __letitbrew_opencode_plugin$' "$TEST_HOME/.config/opencode/plugins/letitbrew.js"
grep -q '__letitbrew_copilot_hook' "$TEST_HOME/.copilot/hooks/letitbrew.json"
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
for command in "install claude extra" "uninstall nope"; do ! "$CLI" $command >/dev/null 2>&1; done
echo "PASS"
