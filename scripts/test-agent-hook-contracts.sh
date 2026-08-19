#!/bin/bash
# Four-agent contract: all writes are contained below one explicit test home.
set -euo pipefail
CLI_INPUT="${1:?usage: test-agent-hook-contracts.sh /absolute/path/to/letitbrew}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLI_INPUT")"
[[ "$CLI" = /* && -x "$CLI" ]] || { echo "FATAL: CLI must be an executable absolute path" >&2; exit 1; }
command -v node >/dev/null || { echo "FATAL: node is required for the OpenCode runtime contract" >&2; exit 1; }
# shellcheck source=lib-power-baseline.sh
source "$SCRIPT_DIR/lib-power-baseline.sh"
# shellcheck source=lib-agent-hook-test-baseline.sh
source "$SCRIPT_DIR/lib-agent-hook-test-baseline.sh"
ENTRY_SLEEP_DISABLED="$(agent_hook_test_read_sleepdisabled)" || { echo "FATAL: could not read SleepDisabled baseline" >&2; exit 1; }
# Registry selection/persistence is deliberately descriptor-only.  Keep this
# source gate beside the black-box contract so a future convenience reopen
# cannot quietly reintroduce Foundation path I/O after target selection.
INSTALL_SOURCE="$SCRIPT_DIR/../Sources/letitbrew/InstallCommand.swift"
# This is intentionally a source gate as well as behavioral coverage: agent
# installation must not regress to fd pseudo-path transport, Foundation path
# mutation, or URL AtomicFile compatibility overloads after target selection.
python3 "$SCRIPT_DIR/check-agent-install-transport.py" "$INSTALL_SOURCE"
for fixture in "$SCRIPT_DIR"/fixtures/agent-install-transport-multiline-*.swift; do
  if python3 "$SCRIPT_DIR/check-agent-install-transport.py" "$fixture" >/dev/null 2>&1; then
    echo "FATAL: source gate accepted $fixture" >&2; exit 1
  fi
done
grep -Fq 'AtomicFile.write(data, replacing: capture, permissions: .exact(0o600))' "$INSTALL_SOURCE"
! sed -n '/private func loadRegistry/,/private func resolveJSONTarget/p' "$INSTALL_SOURCE" | grep -Eq 'Data\(contentsOf:|FileManager\.(default\.)?(createDirectory|removeItem|moveItem|replaceItem)'
INSTALL_BLOCK="$(sed -n '/func runInstall/,/func runUninstall/p' "$INSTALL_SOURCE")"
grep -Fq 'let observed = try target.capture()' <<<"$INSTALL_BLOCK"
grep -Fq 'AtomicFile.write(bytes, replacing: observed)' <<<"$INSTALL_BLOCK"
! grep -Eq 'ExactFileCapture\.capture\(at:|AtomicFile\.write\([^)]*to:|Data\(contentsOf:' <<<"$INSTALL_BLOCK"
UNINSTALL_BLOCK="$(sed -n '/func runUninstall/,/private func doctorAgent/p' "$INSTALL_SOURCE")"
grep -Fq 'let observed = try target.capture()' <<<"$UNINSTALL_BLOCK"
grep -Fq 'AtomicFile.remove(observed, expectedData: existing, hooks: hooks)' <<<"$UNINSTALL_BLOCK"
! grep -Eq 'ExactFileCapture\.capture\(at:|AtomicFile\.write\([^)]*to:|AtomicFile\.remove\([^)]*ifUnchangedFrom:|Data\(contentsOf:' <<<"$UNINSTALL_BLOCK"
DOCTOR_BLOCK="$(sed -n '/private func doctorAgent/,/func runPrepareExact/p' "$INSTALL_SOURCE")"
grep -Fq 'let data = try target.capture().data' <<<"$DOCTOR_BLOCK"
! grep -Eq 'Data\(contentsOf:|ExactFileCapture\.capture\(at:' <<<"$DOCTOR_BLOCK"
PREPARE_BLOCK="$(sed -n '/func runPrepareExact/,/private func doctorLease/p' "$INSTALL_SOURCE")"
grep -Fq 'let capture = try target.capture()' <<<"$PREPARE_BLOCK"
grep -Fq 'AtomicFile.write(bytes, replacing: capture)' <<<"$PREPARE_BLOCK"
! grep -Eq 'Data\(contentsOf:|ExactFileCapture\.capture\(at:|AtomicFile\.write\([^)]*to:' <<<"$PREPARE_BLOCK"
TEST_HOME="$(mktemp -d /tmp/letitbrew-agent-hooks.XXXXXX)"
trap 'rm -rf "$TEST_HOME"' EXIT
export LETITBREW_TEST_HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.codex" "$TEST_HOME/.copilot/hooks"
printf '{"foreign":{"claude":{"nested":[1,{"kept":true}]}}}\n' > "$TEST_HOME/.claude/settings.json"
printf '{"description":"foreign","hooks":{"foreign":[{"nested":["codex",2]}]}}\n' > "$TEST_HOME/.codex/hooks.json"
printf '{"version":1,"hooks":{"foreign":[{"nested":["copilot",4]}]}}\n' > "$TEST_HOME/.copilot/hooks/letitbrew.json"
for agent in claude codex opencode copilot; do "$CLI" install "$agent" >/dev/null; done
REGISTRY="$TEST_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json"
test "$(stat -f '%Lp' "$REGISTRY")" = "600"

# Every adapter accepts a genuinely missing target.  Three JSON adapters were
# already exercised above with existing files; exercise the OpenCode existing
# case separately because it is an exact standalone plugin file.
for agent in claude codex opencode copilot; do
  MISSING_HOME="$(mktemp -d /tmp/letitbrew-agent-missing.XXXXXX)"
  env LETITBREW_TEST_HOME="$MISSING_HOME" "$CLI" install "$agent" >/dev/null
  test -f "$MISSING_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json"
  rm -rf "$MISSING_HOME"
done
OPENCODE_EXISTING_HOME="$(mktemp -d /tmp/letitbrew-opencode-existing.XXXXXX)"
mkdir -p "$OPENCODE_EXISTING_HOME/.config/opencode/plugins"
printf '// __letitbrew_opencode_plugin\nexport default []\n' > "$OPENCODE_EXISTING_HOME/.config/opencode/plugins/letitbrew.js"
env LETITBREW_TEST_HOME="$OPENCODE_EXISTING_HOME" "$CLI" install opencode >/dev/null
grep -q '__letitbrew_opencode_plugin' "$OPENCODE_EXISTING_HOME/.config/opencode/plugins/letitbrew.js"
rm -rf "$OPENCODE_EXISTING_HOME"

# First-connect JSON resolves exactly one anchored final path and records that
# final path; a final OpenCode symlink is never followed.
SYMLINK_CONNECT_HOME="$(mktemp -d /tmp/letitbrew-json-connect.XXXXXX)"
mkdir -p "$SYMLINK_CONNECT_HOME/.claude" "$SYMLINK_CONNECT_HOME/managed"
printf '{}' > "$SYMLINK_CONNECT_HOME/managed/settings.json"
ln -s ../managed/settings.json "$SYMLINK_CONNECT_HOME/.claude/settings.json"
env LETITBREW_TEST_HOME="$SYMLINK_CONNECT_HOME" "$CLI" install claude >/dev/null
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["targets"]["claude"] == sys.argv[2]' "$SYMLINK_CONNECT_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json" "$SYMLINK_CONNECT_HOME/managed/settings.json"
test "$(readlink "$SYMLINK_CONNECT_HOME/.claude/settings.json")" = '../managed/settings.json'
rm -rf "$SYMLINK_CONNECT_HOME"

# Preflight refusal is before registry persistence: malformed JSON and an
# unowned/symlinked OpenCode plugin leave both vendor and registry untouched.
REFUSAL_HOME="$(mktemp -d /tmp/letitbrew-install-refusal.XXXXXX)"
mkdir -p "$REFUSAL_HOME/.claude" "$REFUSAL_HOME/.codex" "$REFUSAL_HOME/.copilot/hooks" "$REFUSAL_HOME/.config/opencode/plugins"
for refusal in \
  "claude:$REFUSAL_HOME/.claude/settings.json" \
  "codex:$REFUSAL_HOME/.codex/hooks.json" \
  "copilot:$REFUSAL_HOME/.copilot/hooks/letitbrew.json"; do
  agent="${refusal%%:*}"; target="${refusal#*:}"
  printf '{ malformed' > "$target"; cp "$target" "$target.before"
  ! env LETITBREW_TEST_HOME="$REFUSAL_HOME" "$CLI" install "$agent" >/dev/null 2>&1
  cmp -s "$target.before" "$target"
  ! test -e "$REFUSAL_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json"
done
printf '// foreign plugin\n' > "$REFUSAL_HOME/foreign.js"
ln -s "$REFUSAL_HOME/foreign.js" "$REFUSAL_HOME/.config/opencode/plugins/letitbrew.js"
! env LETITBREW_TEST_HOME="$REFUSAL_HOME" "$CLI" install opencode >/dev/null 2>&1
test "$(cat "$REFUSAL_HOME/foreign.js")" = '// foreign plugin'
! test -e "$REFUSAL_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json"
rm -rf "$REFUSAL_HOME"
"$CLI" doctor >/dev/null
# `prepare-exact` accepts only the exact agent/snapshot inspection.  A
# healthy target updates its registry evidence without rewriting vendor bytes
# (including inode and nanosecond mtime).
PREP_TARGET="$TEST_HOME/.copilot/hooks/letitbrew.json"
PREP_INPUT="$TEST_HOME/prepare-copilot.json"
python3 -c 'import hashlib,json,os,sys; p=sys.argv[1]; a=sys.argv[2]; s=os.stat(p); print(json.dumps({"version":1,"agent":a,"snapshot":{"path":p,"exists":True,"deviceID":s.st_dev,"inode":s.st_ino,"byteCount":s.st_size,"modificationSeconds":s.st_mtime_ns//1_000_000_000,"modificationNanoseconds":s.st_mtime_ns%1_000_000_000,"sha256":hashlib.sha256(open(p,"rb").read()).hexdigest()},"expectedState":"healthyOwned"}))' "$PREP_TARGET" copilot > "$PREP_INPUT"
cp "$PREP_TARGET" "$TEST_HOME/prepare-copilot-before.json"
PREP_STAT_BEFORE="$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}:{s.st_size}:{s.st_mtime_ns}")' "$PREP_TARGET")"
"$CLI" prepare-exact copilot < "$PREP_INPUT" >/dev/null
cmp -s "$TEST_HOME/prepare-copilot-before.json" "$PREP_TARGET"
test "$PREP_STAT_BEFORE" = "$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}:{s.st_size}:{s.st_mtime_ns}")' "$PREP_TARGET")"
! "$CLI" prepare-exact claude < "$PREP_INPUT" >/dev/null 2>&1
grep -q '__letitbrew_hook' "$TEST_HOME/.claude/settings.json"
grep -q '__letitbrew_codex_hook' "$TEST_HOME/.codex/hooks.json"
grep -q '^// __letitbrew_opencode_plugin$' "$TEST_HOME/.config/opencode/plugins/letitbrew.js"
grep -q '__letitbrew_copilot_hook' "$TEST_HOME/.copilot/hooks/letitbrew.json"
# The fixtures start with no ownership marker.  Require the complete current
# lifecycle surface, rather than accepting one marker or an arbitrary grep.
node -e '
const fs=require("fs");
const cases=[[process.argv[1],"__letitbrew_hook",13],[process.argv[2],"__letitbrew_codex_hook",11],[process.argv[3],"__letitbrew_copilot_hook",9]];
for (const [file, marker, count] of cases) { const source=fs.readFileSync(file,"utf8"); const found=source.split(marker).length-1; if(found!==count) throw new Error(`${file}: expected ${count} ${marker} entries, got ${found}`) }
' "$TEST_HOME/.claude/settings.json" "$TEST_HOME/.codex/hooks.json" "$TEST_HOME/.copilot/hooks/letitbrew.json"
test "$(node "$SCRIPT_DIR/test-opencode-plugin.mjs" "$CLI" "$TEST_HOME/.config/opencode/plugins/letitbrew.js")" = "PASS: OpenCode plugin runtime contract"
"$CLI" uninstall opencode >/dev/null
"$CLI" uninstall copilot >/dev/null
! test -e "$TEST_HOME/.config/opencode/plugins/letitbrew.js"
! grep -q '__letitbrew_copilot_hook' "$TEST_HOME/.copilot/hooks/letitbrew.json"
grep -q '__letitbrew_hook' "$TEST_HOME/.claude/settings.json"
grep -q '__letitbrew_codex_hook' "$TEST_HOME/.codex/hooks.json"
node -e 'const fs=require("fs"); const [claude,codex,copilot]=process.argv.slice(1).map(f=>JSON.parse(fs.readFileSync(f))); const actual=[claude.foreign,codex.hooks.foreign,copilot.hooks.foreign].map(JSON.stringify); const expected=[{"claude":{"nested":[1,{"kept":true}]}},[{"nested":["codex",2]}],[{"nested":["copilot",4]}]].map(JSON.stringify); if(actual.some((value,index)=>value!==expected[index])) process.exit(1)' "$TEST_HOME/.claude/settings.json" "$TEST_HOME/.codex/hooks.json" "$TEST_HOME/.copilot/hooks/letitbrew.json"
# Exact grammar: unscoped and each four-agent scoped form are accepted; every
# malformed/extra form is rejected without relying on shell word splitting.
for agent in claude codex opencode copilot; do "$CLI" install "$agent" >/dev/null; done
for agent in claude codex opencode copilot; do "$CLI" uninstall "$agent" >/dev/null; done
"$CLI" install >/dev/null
"$CLI" uninstall >/dev/null
! "$CLI" >/dev/null 2>&1
for command in "install claude extra" "uninstall nope" "uninstall claude extra" "install nope" "install cursor" "uninstall cursor" "prepare-exact cursor" "prepare-exact"; do ! "$CLI" $command >/dev/null 2>&1; done
# In a fresh home, an absent exact preparation creates only the requested
# owned target.  A stale owned target is then repaired using a new exact
# capture; neither case relies on an ambient vendor-home variable.
PREP_HOME="$(mktemp -d /tmp/letitbrew-prepare.XXXXXX)"
mkdir -p "$PREP_HOME/.claude"
PREP_CLAUDE="$PREP_HOME/.claude/settings.json"
PREP_ABSENT="$PREP_HOME/prepare-absent.json"
python3 -c 'import json,sys; print(json.dumps({"version":1,"agent":"claude","snapshot":{"path":sys.argv[1],"exists":False},"expectedState":"absent"}))' "$PREP_CLAUDE" > "$PREP_ABSENT"
env LETITBREW_TEST_HOME="$PREP_HOME" "$CLI" prepare-exact claude < "$PREP_ABSENT" >/dev/null
grep -q '__letitbrew_hook' "$PREP_CLAUDE"
python3 -c 'import json,sys; p,old=sys.argv[1:]; d=json.load(open(p)); walk=lambda x: {k:walk(v) for k,v in x.items()} if isinstance(x,dict) else [walk(v) for v in x] if isinstance(x,list) else x.replace(old,"/private/tmp/letitbrew-stale") if isinstance(x,str) else x; json.dump(walk(d),open(p,"w"))' "$PREP_CLAUDE" "$CLI"
PREP_REPAIR="$PREP_HOME/prepare-repair.json"
python3 -c 'import hashlib,json,os,sys; p=sys.argv[1]; s=os.stat(p); print(json.dumps({"version":1,"agent":"claude","snapshot":{"path":p,"exists":True,"deviceID":s.st_dev,"inode":s.st_ino,"byteCount":s.st_size,"modificationSeconds":s.st_mtime_ns//1_000_000_000,"modificationNanoseconds":s.st_mtime_ns%1_000_000_000,"sha256":hashlib.sha256(open(p,"rb").read()).hexdigest()},"expectedState":"repairableOwned"}))' "$PREP_CLAUDE" > "$PREP_REPAIR"
env LETITBREW_TEST_HOME="$PREP_HOME" "$CLI" prepare-exact claude < "$PREP_REPAIR" >/dev/null
grep -q '__letitbrew_hook' "$PREP_CLAUDE"
! grep -qF '/private/tmp/letitbrew-stale' "$PREP_CLAUDE"
# A later prepare cannot retarget a recorded agent, nor escape its explicit
# test root even when the supplied snapshot is otherwise valid and absent.
PREP_CONFLICT="$PREP_HOME/prepare-conflict.json"
python3 -c 'import json,sys; print(json.dumps({"version":1,"agent":"claude","snapshot":{"path":sys.argv[1],"exists":False},"expectedState":"absent"}))' "$PREP_HOME/.claude/other.json" > "$PREP_CONFLICT"
! env LETITBREW_TEST_HOME="$PREP_HOME" "$CLI" prepare-exact claude < "$PREP_CONFLICT" >/dev/null 2>&1
PREP_OUTSIDE_DIR="$(mktemp -d /tmp/letitbrew-prepare-outside.XXXXXX)"
PREP_OUTSIDE="$PREP_OUTSIDE_DIR/outside.json"
python3 -c 'import json,sys; print(json.dumps({"version":1,"agent":"claude","snapshot":{"path":sys.argv[1],"exists":False},"expectedState":"absent"}))' "$PREP_OUTSIDE" > "$PREP_HOME/prepare-outside.json"
! env LETITBREW_TEST_HOME="$PREP_HOME" "$CLI" prepare-exact claude < "$PREP_HOME/prepare-outside.json" >/dev/null 2>&1
! test -e "$PREP_OUTSIDE"
# Once recorded, both whole-file adapters keep using their exact A target even
# if a caller supplies a different ambient B home.  Test-home mode purposely
# ignores ambient variables, so this also proves they cannot redirect writes.
AB_HOME="$(mktemp -d /tmp/letitbrew-recorded-target.XXXXXX)"
mkdir -p "$AB_HOME/custom" "$AB_HOME/ambient-copilot/hooks" "$AB_HOME/ambient-opencode/plugins"
AB_COPILOT="$AB_HOME/custom/copilot.json"
AB_OPENCODE="$AB_HOME/custom/opencode.js"
printf '{"version":1,"hooks":{"foreign":[]}}' > "$AB_COPILOT"
python3 -c 'import json,sys; print(json.dumps({"version":1,"targets":{"copilot":sys.argv[1],"opencode":sys.argv[2]}}))' "$AB_COPILOT" "$AB_OPENCODE" > "$AB_HOME/registry.json"
mkdir -p "$AB_HOME/Library/Application Support/LetItBrew"
mv "$AB_HOME/registry.json" "$AB_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json"
env LETITBREW_TEST_HOME="$AB_HOME" COPILOT_HOME="$AB_HOME/ambient-copilot" OPENCODE_CONFIG_DIR="$AB_HOME/ambient-opencode" "$CLI" install copilot >/dev/null
env LETITBREW_TEST_HOME="$AB_HOME" COPILOT_HOME="$AB_HOME/ambient-copilot" OPENCODE_CONFIG_DIR="$AB_HOME/ambient-opencode" "$CLI" install opencode >/dev/null
grep -q '__letitbrew_copilot_hook' "$AB_COPILOT"
grep -q '^// __letitbrew_opencode_plugin$' "$AB_OPENCODE"
! test -e "$AB_HOME/ambient-copilot/hooks/letitbrew.json"
! test -e "$AB_HOME/ambient-opencode/plugins/letitbrew.js"

# Every recorded A target wins over a configured/ambient B target across the
# complete install, doctor, uninstall lifecycle.  B is deliberately valid but
# foreign, so touching it would be observable even when an operation succeeds.
ALL_AB_HOME="$(mktemp -d /tmp/letitbrew-recorded-all.XXXXXX)"
mkdir -p "$ALL_AB_HOME/custom" "$ALL_AB_HOME/.claude" "$ALL_AB_HOME/.codex" "$ALL_AB_HOME/.copilot/hooks" "$ALL_AB_HOME/.config/opencode/plugins" "$ALL_AB_HOME/Library/Application Support/LetItBrew"
printf '{"foreign":{"a":"claude"}}' > "$ALL_AB_HOME/custom/claude.json"
printf '{"description":"a","hooks":{"foreign":[]}}' > "$ALL_AB_HOME/custom/codex.json"
printf '{"version":1,"hooks":{"foreign":[]}}' > "$ALL_AB_HOME/custom/copilot.json"
printf '{"ambient":"claude"}' > "$ALL_AB_HOME/.claude/settings.json"
printf '{"description":"ambient","hooks":{"foreign":[]}}' > "$ALL_AB_HOME/.codex/hooks.json"
printf '{"version":1,"hooks":{"foreign":[]}}' > "$ALL_AB_HOME/.copilot/hooks/letitbrew.json"
printf '// ambient OpenCode plugin\n' > "$ALL_AB_HOME/.config/opencode/plugins/letitbrew.js"
for B in "$ALL_AB_HOME/.claude/settings.json" "$ALL_AB_HOME/.codex/hooks.json" "$ALL_AB_HOME/.copilot/hooks/letitbrew.json" "$ALL_AB_HOME/.config/opencode/plugins/letitbrew.js"; do cp "$B" "$B.before"; done
python3 -c 'import json,sys; h=sys.argv[1]; targets={"claude":h+"/custom/claude.json","codex":h+"/custom/codex.json","copilot":h+"/custom/copilot.json","opencode":h+"/custom/opencode.js"}; json.dump({"version":1,"targets":targets},open(h+"/Library/Application Support/LetItBrew/agent-hook-targets.json","w"))' "$ALL_AB_HOME"
for agent in claude codex copilot opencode; do env LETITBREW_TEST_HOME="$ALL_AB_HOME" COPILOT_HOME="$ALL_AB_HOME/ignored" OPENCODE_CONFIG_DIR="$ALL_AB_HOME/ignored" "$CLI" install "$agent" >/dev/null; done
ALL_AB_DOCTOR="$(env LETITBREW_TEST_HOME="$ALL_AB_HOME" "$CLI" doctor || true)"
for state in 'Claude Code: healthy' 'Codex: healthy' 'GitHub Copilot CLI: healthy' 'OpenCode: healthy'; do grep -Fq "$state" <<< "$ALL_AB_DOCTOR"; done
for agent in claude codex copilot opencode; do env LETITBREW_TEST_HOME="$ALL_AB_HOME" "$CLI" uninstall "$agent" >/dev/null; done
for B in "$ALL_AB_HOME/.claude/settings.json" "$ALL_AB_HOME/.codex/hooks.json" "$ALL_AB_HOME/.copilot/hooks/letitbrew.json" "$ALL_AB_HOME/.config/opencode/plugins/letitbrew.js"; do cmp -s "$B.before" "$B"; done
rm -rf "$ALL_AB_HOME"

# The real command ordering is exercised under fault injection, not only in
# pure transaction closures.  A preflight/persist fault leaves the vendor
# byte-for-byte untouched; a vendor fault leaves the exact target recorded.
# Removal and clear boundaries deliberately retain a stale record until a
# later retry proves the already-clean target and clears without rewriting it.
target_for_agent() {
  case "$1" in
    claude) printf '%s/.claude/settings.json' "$2";;
    codex) printf '%s/.codex/hooks.json' "$2";;
    copilot) printf '%s/.copilot/hooks/letitbrew.json' "$2";;
    opencode) printf '%s/.config/opencode/plugins/letitbrew.js' "$2";;
  esac
}
seed_agent_target() {
  local agent="$1" home="$2" target
  target="$(target_for_agent "$agent" "$home")"
  mkdir -p "$(dirname "$target")"
  case "$agent" in
    claude) printf '{"foreign":{"keep":1}}\n' > "$target";;
    codex) printf '{"description":"foreign","hooks":{"keep":[]}}\n' > "$target";;
    copilot) printf '{"version":1,"hooks":{"keep":[]}}\n' > "$target";;
    opencode) : ;; # its missing file is a valid install input
  esac
}
for agent in claude codex copilot opencode; do
  FAULT_HOME="$(mktemp -d /tmp/letitbrew-command-fault.XXXXXX)"
  seed_agent_target "$agent" "$FAULT_HOME"; TARGET="$(target_for_agent "$agent" "$FAULT_HOME")"
  test -e "$TARGET" && cp "$TARGET" "$FAULT_HOME/vendor-before" || : > "$FAULT_HOME/vendor-before"
  ! env LETITBREW_TEST_HOME="$FAULT_HOME" LETITBREW_TEST_FAULT=registry-persist "$CLI" install "$agent" >/dev/null 2>&1
  cmp -s "$FAULT_HOME/vendor-before" "$TARGET" 2>/dev/null || test ! -e "$TARGET"
  ! test -e "$FAULT_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json"
  rm -rf "$FAULT_HOME"

  FAULT_HOME="$(mktemp -d /tmp/letitbrew-command-fault.XXXXXX)"
  seed_agent_target "$agent" "$FAULT_HOME"; TARGET="$(target_for_agent "$agent" "$FAULT_HOME")"
  test -e "$TARGET" && cp "$TARGET" "$FAULT_HOME/vendor-before" || : > "$FAULT_HOME/vendor-before"
  ! env LETITBREW_TEST_HOME="$FAULT_HOME" LETITBREW_TEST_FAULT=vendor-commit "$CLI" install "$agent" >/dev/null 2>&1
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["targets"][sys.argv[2]] == sys.argv[3]' "$FAULT_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json" "$agent" "$TARGET"
  cmp -s "$FAULT_HOME/vendor-before" "$TARGET" 2>/dev/null || test ! -e "$TARGET"
  rm -rf "$FAULT_HOME"

  FAULT_HOME="$(mktemp -d /tmp/letitbrew-command-fault.XXXXXX)"
  seed_agent_target "$agent" "$FAULT_HOME"; TARGET="$(target_for_agent "$agent" "$FAULT_HOME")"
  env LETITBREW_TEST_HOME="$FAULT_HOME" "$CLI" install "$agent" >/dev/null
  ! env LETITBREW_TEST_HOME="$FAULT_HOME" LETITBREW_TEST_FAULT=vendor-remove "$CLI" uninstall "$agent" >/dev/null 2>&1
  python3 -c 'import json,sys; assert sys.argv[2] in json.load(open(sys.argv[1]))["targets"]' "$FAULT_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json" "$agent"
  ! env LETITBREW_TEST_HOME="$FAULT_HOME" LETITBREW_TEST_FAULT=registry-clear "$CLI" uninstall "$agent" >/dev/null 2>&1
  python3 -c 'import json,sys; assert sys.argv[2] in json.load(open(sys.argv[1]))["targets"]' "$FAULT_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json" "$agent"
  test -e "$TARGET" && cp "$TARGET" "$FAULT_HOME/after-removal" || : > "$FAULT_HOME/after-removal"
  env LETITBREW_TEST_HOME="$FAULT_HOME" "$CLI" uninstall "$agent" >/dev/null
  cmp -s "$FAULT_HOME/after-removal" "$TARGET" 2>/dev/null || test ! -e "$TARGET"
  python3 -c 'import json,sys; assert sys.argv[2] not in json.load(open(sys.argv[1]))["targets"]' "$FAULT_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json" "$agent"
  rm -rf "$FAULT_HOME"
done

# A replacement that appears after OpenCode's quarantine validation is not
# removed by the actual CLI; the registry can clear while the foreign active
# file survives exactly as the next owner's file.
REPLACEMENT_HOME="$(mktemp -d /tmp/letitbrew-active-replacement.XXXXXX)"
env LETITBREW_TEST_HOME="$REPLACEMENT_HOME" "$CLI" install opencode >/dev/null
env LETITBREW_TEST_HOME="$REPLACEMENT_HOME" LETITBREW_TEST_FAULT=active-replacement "$CLI" uninstall opencode >/dev/null
test "$(cat "$REPLACEMENT_HOME/.config/opencode/plugins/letitbrew.js")" = 'foreign replacement after quarantine'
rm -rf "$REPLACEMENT_HOME"
# Doctor always prints each requested configuration state and still performs
# its independent watchdog check when another adapter is invalid.
DOCTOR_HOME="$(mktemp -d /tmp/letitbrew-doctor.XXXXXX)"
mkdir -p "$DOCTOR_HOME/.claude" "$DOCTOR_HOME/.codex" "$DOCTOR_HOME/.copilot/hooks"
printf '{ malformed' > "$DOCTOR_HOME/.claude/settings.json"
env LETITBREW_TEST_HOME="$DOCTOR_HOME" "$CLI" install codex >/dev/null
env LETITBREW_TEST_HOME="$DOCTOR_HOME" "$CLI" install copilot >/dev/null
python3 -c 'import json,sys; p,old=sys.argv[1:]; d=json.load(open(p)); walk=lambda x: {k:walk(v) for k,v in x.items()} if isinstance(x,dict) else [walk(v) for v in x] if isinstance(x,list) else x.replace(old,"/private/tmp/letitbrew-stale") if isinstance(x,str) else x; json.dump(walk(d),open(p,"w"))' "$DOCTOR_HOME/.copilot/hooks/letitbrew.json" "$CLI"
DOCTOR_OUTPUT="$(env LETITBREW_TEST_HOME="$DOCTOR_HOME" "$CLI" doctor || true)"
grep -q '^Claude Code: configuration invalid$' <<< "$DOCTOR_OUTPUT"
grep -q '^Codex: healthy$' <<< "$DOCTOR_OUTPUT"
grep -q '^OpenCode: not installed$' <<< "$DOCTOR_OUTPUT"
grep -q '^GitHub Copilot CLI: needs repair$' <<< "$DOCTOR_OUTPUT"
grep -q '^Lid-closed watchdog:' <<< "$DOCTOR_OUTPUT"
# Registry decoding is strict at the top level. An unknown member means every
# requested agent is configuration-invalid, but doctor still runs its wholly
# independent watchdog check.
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["extra"]=1; json.dump(d,open(p,"w"))' "$DOCTOR_HOME/Library/Application Support/LetItBrew/agent-hook-targets.json"
STRICT_REGISTRY_OUTPUT="$(env LETITBREW_TEST_HOME="$DOCTOR_HOME" "$CLI" doctor || true)"
grep -q '^Claude Code: configuration invalid$' <<< "$STRICT_REGISTRY_OUTPUT"
grep -q '^Codex: configuration invalid$' <<< "$STRICT_REGISTRY_OUTPUT"
grep -q '^OpenCode: configuration invalid$' <<< "$STRICT_REGISTRY_OUTPUT"
grep -q '^GitHub Copilot CLI: configuration invalid$' <<< "$STRICT_REGISTRY_OUTPUT"
grep -q '^Lid-closed watchdog:' <<< "$STRICT_REGISTRY_OUTPUT"
# Registry parent symlinks are unsafe even with a non-symlink final name: a
# test-home operation must fail before either vendor config or registry bytes
# can escape through the parent.
SYMLINK_HOME="$(mktemp -d /tmp/letitbrew-registry-link.XXXXXX)"
OUTSIDE_HOME="$(mktemp -d /tmp/letitbrew-registry-outside.XXXXXX)"
trap 'rm -rf "$TEST_HOME" "$SYMLINK_HOME" "$OUTSIDE_HOME" "$PREP_HOME" "$PREP_OUTSIDE_DIR" "$AB_HOME" "$DOCTOR_HOME"' EXIT
mkdir -p "$SYMLINK_HOME/Library/Application Support"
ln -s "$OUTSIDE_HOME" "$SYMLINK_HOME/Library/Application Support/LetItBrew"
! env LETITBREW_TEST_HOME="$SYMLINK_HOME" "$CLI" install claude >/dev/null 2>&1
! test -e "$OUTSIDE_HOME/agent-hook-targets.json"
! test -e "$SYMLINK_HOME/.claude/settings.json"
EXIT_SLEEP_DISABLED="$(agent_hook_test_read_sleepdisabled)" || { echo "FATAL: could not read SleepDisabled baseline on exit" >&2; exit 1; }
test "$ENTRY_SLEEP_DISABLED" = "$EXIT_SLEEP_DISABLED"
echo "PASS"
