#!/bin/bash
# Isolated tests for update-homebrew-tap.sh. A local bare repository seeded with
# a copy of the real cask stands in for ruban-24/homebrew-tap, and a stand-in
# for gh serves a fake release. Nothing here contacts GitHub.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
# shellcheck source=../update-homebrew-tap.sh
source "$SCRIPT_DIR/update-homebrew-tap.sh"
CASK_FIXTURE="$SCRIPT_DIR/tests/fixtures/homebrew-tap-letitbrew.rb"

TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/letitbrew-homebrew-tap-tests.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
TESTS=0
FAILURES=0

# Keep the developer's git config (signing, hooks) out of the fixture commits.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME="Tap Test" GIT_AUTHOR_EMAIL="tap-test@example.invalid"
export GIT_COMMITTER_NAME="Tap Test" GIT_COMMITTER_EMAIL="tap-test@example.invalid"
export TMPDIR="$TEST_ROOT/tmp"
/bin/mkdir -p "$TMPDIR"

record_failure() { printf 'not ok: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
expect_equal() {
    local actual="$1" expected="$2" label="$3"; TESTS=$((TESTS + 1))
    if [ "$actual" = "$expected" ]; then printf 'ok: %s\n' "$label"; else record_failure "$label (actual '$actual', expected '$expected')"; fi
}
expect_contains() {
    local file="$1" text="$2" label="$3"; TESTS=$((TESTS + 1))
    if /usr/bin/grep -Fq -- "$text" "$file"; then printf 'ok: %s\n' "$label"; else record_failure "$label (missing '$text')"; /bin/cat "$file" >&2; fi
}

# Stand-in release served by homebrew_tap_gh.
FAKE_DRAFT=false
FAKE_PRERELEASE=false
FAKE_ASSETS=""
FAKE_DMG=""
FAKE_SUMS=""
GH_LOG="$TEST_ROOT/gh.log"
TAP_REMOTE=""

homebrew_tap_remote_url() { printf '%s\n' "$TAP_REMOTE"; }
homebrew_tap_gh() {
    printf '%s\n' "$*" >>"$GH_LOG"
    case "$1 $2" in
        "release view")
            [ "$3" = "v2.0.0" ] || return 1
            printf '{"isDraft":%s,"isPrerelease":%s,"assets":[%s]}\n' "$FAKE_DRAFT" "$FAKE_PRERELEASE" "$FAKE_ASSETS"
            ;;
        "release download")
            local dir="${!#}"
            /bin/cp "$FAKE_DMG" "$dir/LetItBrew-2.0.0.dmg" && /bin/cp "$FAKE_SUMS" "$dir/LetItBrew-2.0.0-SHA256SUMS"
            ;;
        *) return 1 ;;
    esac
}

# Fresh bare tap seeded with the real cask, and a fresh published release.
setup() {
    local name="$1" seed="$TEST_ROOT/$1/seed"
    TAP_REMOTE="$TEST_ROOT/$name/homebrew-tap.git"
    /bin/mkdir -p "$seed/Casks"
    /bin/cp "$CASK_FIXTURE" "$seed/Casks/letitbrew.rb"
    git init --quiet -b main "$seed"
    git -C "$seed" add . && git -C "$seed" commit --quiet -m seed
    git clone --quiet --bare "$seed" "$TAP_REMOTE"

    FAKE_DMG="$TEST_ROOT/$name/LetItBrew-2.0.0.dmg"
    printf 'fake dmg %s\n' "$name" >"$FAKE_DMG"
    FAKE_SHA="$(/usr/bin/shasum -a 256 "$FAKE_DMG" | /usr/bin/awk '{ print $1 }')"
    FAKE_SUMS="$TEST_ROOT/$name/LetItBrew-2.0.0-SHA256SUMS"
    printf '%s  LetItBrew-2.0.0.dmg\n%s  LetItBrew-2.0.0-48.manifest\n' "$FAKE_SHA" "$FAKE_SHA" >"$FAKE_SUMS"
    FAKE_DRAFT=false
    FAKE_PRERELEASE=false
    FAKE_ASSETS='{"name":"LetItBrew-2.0.0-SHA256SUMS"},{"name":"LetItBrew-2.0.0.dmg"},{"name":"LetItBrew.dmg"}'
    : >"$GH_LOG"
    SEED_HEAD="$(git -C "$TAP_REMOTE" rev-parse main)"
    OUT="$TEST_ROOT/$name/out"
}

run_update() {
    local status=0
    ( homebrew_tap_main "$@" ) >"$OUT" 2>&1 || status=$?
    printf '%s\n' "$status"
}

remote_cask() { git -C "$TAP_REMOTE" show main:Casks/letitbrew.rb; }
remote_head() { git -C "$TAP_REMOTE" rev-parse main; }

# --- tests ---

setup push
expect_equal "$(run_update 2.0.0)" 0 "update succeeds against a published release"
expected="$(/usr/bin/sed -e 's/^  version "1.0.1"$/  version "2.0.0"/' \
    -e "s/^  sha256 \"[0-9a-f]*\"\$/  sha256 \"$FAKE_SHA\"/" "$CASK_FIXTURE")"
expect_equal "$(remote_cask)" "$expected" "pushed cask changes only version and sha256, to the downloaded DMG's hash"
expect_equal "$(git -C "$TAP_REMOTE" log -1 --format=%s main)" "letitbrew 2.0.0" "commit message names the version"
expect_equal "$(git -C "$TAP_REMOTE" rev-list --count main)" 2 "exactly one commit was pushed"
expect_equal "$(/usr/bin/awk '{ print $1, $2 }' "$GH_LOG" | /usr/bin/sort -u | /usr/bin/tr '\n' ';')" \
    "release download;release view;" "only reads the GitHub release"
expect_equal "$(/bin/ls -A "$TMPDIR")" "" "workspace is removed after success"

before="$(remote_head)"
expect_equal "$(run_update 2.0.0)" 0 "rerun after a successful push succeeds"
expect_contains "$OUT" "already points at 2.0.0" "rerun reports the tap is current"
expect_equal "$(remote_head)" "$before" "rerun pushes nothing"

setup dryrun
expect_equal "$(run_update 2.0.0 --dry-run)" 0 "dry run succeeds"
expect_contains "$OUT" '-  version "1.0.1"' "dry run shows the old version"
expect_contains "$OUT" '+  version "2.0.0"' "dry run shows the new version"
expect_contains "$OUT" "+  sha256 \"$FAKE_SHA\"" "dry run shows the new sha256"
expect_contains "$OUT" "nothing was committed or pushed" "dry run says it did not push"
expect_equal "$(remote_head)" "$SEED_HEAD" "dry run leaves the tap unchanged"

setup rejected
/bin/mkdir -p "$TAP_REMOTE/hooks"
printf '#!/bin/sh\necho "push refused by test" >&2\nexit 1\n' >"$TAP_REMOTE/hooks/pre-receive"
/bin/chmod 755 "$TAP_REMOTE/hooks/pre-receive"
expect_equal "$(run_update 2.0.0)" 1 "rejected push fails"
expect_contains "$OUT" "failed while pushing to $TAP_REMOTE" "rejected push names the failed step"
expect_contains "$OUT" "GitHub release v2.0.0 is published and was not changed" "rejected push says the release is untouched"
expect_contains "$OUT" "push origin HEAD" "rejected push prints the manual push command"
kept="$(/usr/bin/sed -n "s/^  git -C '\\(.*\\)' push origin HEAD.*/\\1/p" "$OUT")"
/bin/rm "$TAP_REMOTE/hooks/pre-receive"
case "$kept" in
    "$TMPDIR"/?*) expect_equal "$(git -C "$kept" push --quiet origin HEAD 2>&1; echo $?)" 0 "manual push command finishes the update" ;;
    *) record_failure "manual push command names the kept clone (got '$kept')" ;;
esac
expect_equal "$(git -C "$TAP_REMOTE" show main:Casks/letitbrew.rb | /usr/bin/grep -c "$FAKE_SHA")" 1 "manual push lands the new sha256"
expect_equal "$(/usr/bin/awk '{ print $1, $2 }' "$GH_LOG" | /usr/bin/sort -u | /usr/bin/tr '\n' ';')" \
    "release download;release view;" "failed push still only read the GitHub release"

setup mismatch
printf '%s  LetItBrew-2.0.0.dmg\n' "$(printf '0%.0s' {1..64})" >"$FAKE_SUMS"
expect_equal "$(run_update 2.0.0)" 1 "checksum mismatch fails"
expect_contains "$OUT" "does not match LetItBrew-2.0.0-SHA256SUMS" "checksum mismatch is reported"
expect_equal "$(remote_head)" "$SEED_HEAD" "checksum mismatch leaves the tap unchanged"

setup draft
FAKE_DRAFT=true
expect_equal "$(run_update 2.0.0)" 1 "draft release is refused"
expect_contains "$OUT" "draft or pre-release" "draft refusal is reported"
expect_equal "$(remote_head)" "$SEED_HEAD" "draft refusal leaves the tap unchanged"

setup prerelease
FAKE_PRERELEASE=true
expect_equal "$(run_update 2.0.0)" 1 "pre-release is refused"
expect_equal "$(remote_head)" "$SEED_HEAD" "pre-release refusal leaves the tap unchanged"

setup missingasset
FAKE_ASSETS='{"name":"LetItBrew-2.0.0-SHA256SUMS"},{"name":"LetItBrew.dmg"}'
expect_equal "$(run_update 2.0.0)" 1 "missing versioned DMG is refused"
expect_contains "$OUT" "asset LetItBrew-2.0.0.dmg is missing" "missing asset is reported"
expect_equal "$(remote_head)" "$SEED_HEAD" "missing asset leaves the tap unchanged"

setup unpublished
expect_equal "$(run_update 2.0.1)" 1 "unpublished release fails"
expect_contains "$OUT" "failed while reading GitHub release v2.0.1" "unpublished release names the failed step"
expect_contains "$OUT" "scripts/update-homebrew-tap.sh 2.0.1" "unpublished release prints the rerun command"
expect_equal "$(remote_head)" "$SEED_HEAD" "unpublished release leaves the tap unchanged"

setup usage
expect_equal "$(run_update 2.0)" 2 "malformed version is a usage error"
expect_equal "$(run_update 2.0.0 --push)" 2 "unknown flag is a usage error"
expect_equal "$(/bin/cat "$GH_LOG")" "" "usage errors contact nothing"

printf '%s tests, %s failures\n' "$TESTS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
