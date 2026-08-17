#!/bin/bash
# Isolated tests for the detached updater bridge. No test touches /Applications,
# a real Let It Brew process, launchd, Service Management, or pmset.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
# shellcheck source=../run-update.sh
source "$SCRIPT_DIR/run-update.sh"

TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/letitbrew-update-runner-tests.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
TESTS=0
FAILURES=0

record_failure() { printf 'not ok: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
expect_true() {
    local label="$1"; shift; TESTS=$((TESTS + 1))
    if "$@"; then printf 'ok: %s\n' "$label"; else record_failure "$label"; fi
}
expect_false() {
    local label="$1"; shift; TESTS=$((TESTS + 1))
    if "$@" >/dev/null 2>&1; then record_failure "$label"; else printf 'ok: %s\n' "$label"; fi
}
expect_equal() {
    local actual="$1" expected="$2" label="$3"; TESTS=$((TESTS + 1))
    if [ "$actual" = "$expected" ]; then printf 'ok: %s\n' "$label"; else record_failure "$label (actual '$actual', expected '$expected')"; fi
}

make_workspace() {
    local name="$1" root="$TEST_ROOT/$1"
    /bin/mkdir -p "$root/UpdateSupport" "$root/Candidate/Let It Brew.app"
    for support in run-update.sh upgrade-installed-app.sh verify-artifact.sh lib-power-baseline.sh; do
        /usr/bin/printf '#!/bin/bash\n' >"$root/UpdateSupport/$support"
    done
    /bin/chmod 755 \
        "$root/UpdateSupport/run-update.sh" \
        "$root/UpdateSupport/upgrade-installed-app.sh" \
        "$root/UpdateSupport/verify-artifact.sh"
    /bin/chmod 644 "$root/UpdateSupport/lib-power-baseline.sh"
    printf '%s\n' "$root"
}

RUNNER_TEST_COMMAND="$RUNNER_INSTALLED_BIN"
RUNNER_TEST_ALIVE_CALLS=0
RUNNER_TEST_EXIT_AFTER=0
RUNNER_TEST_UPGRADE_STATUS=0
RUNNER_TEST_UPGRADE_ARGS=""
update_runner_ps_command() { printf '%s\n' "$RUNNER_TEST_COMMAND"; }
update_runner_kill_zero() {
    RUNNER_TEST_ALIVE_CALLS=$((RUNNER_TEST_ALIVE_CALLS + 1))
    [ "$RUNNER_TEST_ALIVE_CALLS" -le "$RUNNER_TEST_EXIT_AFTER" ]
}
update_runner_sleep() { :; }
update_runner_upgrade() {
    RUNNER_TEST_UPGRADE_ARGS="$*"
    return "$RUNNER_TEST_UPGRADE_STATUS"
}

# Main derives support/root from BASH_SOURCE, so function-level tests validate
# waiting and results, while a subprocess fixture below validates full path
# confinement using a copied real runner/support set.
RUNNER_TIMEOUT=2
RUNNER_TEST_EXIT_AFTER=1
expect_true "waits until the exact app exits" update_runner_wait_for_app_exit 123
RUNNER_TEST_COMMAND=/tmp/Other
RUNNER_TEST_ALIVE_CALLS=0
expect_false "refuses a PID that was never the installed app" update_runner_wait_for_app_exit 123
RUNNER_TEST_COMMAND="$RUNNER_INSTALLED_BIN"
RUNNER_TEST_ALIVE_CALLS=0
RUNNER_TEST_EXIT_AFTER=9
expect_false "times out rather than signaling a stuck app" update_runner_wait_for_app_exit 123
RUNNER_TEST_COMMAND=/tmp/Reused
RUNNER_TEST_ALIVE_CALLS=0
RUNNER_TEST_EXIT_AFTER=9
expect_false "initial PID reuse cannot impersonate the app" update_runner_wait_for_app_exit 123

result_root="$(make_workspace result)"
expect_true "writes an atomic success result" update_runner_write_result "$result_root/success.json" 0
expect_equal "$(/bin/cat "$result_root/success.json")" '{"status":"success","exitCode":0}' "success result is strict JSON"
expect_true "writes an atomic failure result" update_runner_write_result "$result_root/failure.json" 7
expect_equal "$(/bin/cat "$result_root/failure.json")" '{"status":"failure","exitCode":7}' "failure result carries the exit status"
expect_false "never overwrites an existing result" update_runner_write_result "$result_root/failure.json" 0

fixture_root="$(make_workspace full)"
/usr/bin/install -m 755 "$SCRIPT_DIR/run-update.sh" "$fixture_root/UpdateSupport/run-update.sh" || exit 1
/usr/bin/install -m 755 "$SCRIPT_DIR/upgrade-installed-app.sh" "$fixture_root/UpdateSupport/upgrade-installed-app.sh" || exit 1
/usr/bin/install -m 755 "$SCRIPT_DIR/verify-artifact.sh" "$fixture_root/UpdateSupport/verify-artifact.sh" || exit 1
/usr/bin/install -m 644 "$SCRIPT_DIR/lib-power-baseline.sh" "$fixture_root/UpdateSupport/lib-power-baseline.sh" || exit 1
expect_false "full runner refuses a non-Let It Brew PID before any transaction" \
    "$fixture_root/UpdateSupport/run-update.sh" \
        --candidate "$fixture_root/Candidate/Let It Brew.app" \
        --app-pid $$ \
        --result "$fixture_root/result.json" \
        --log "$fixture_root/update.log"
expect_true "PID refusal records failure without invoking the transaction" test -f "$fixture_root/result.json"
expect_equal "$(/bin/cat "$fixture_root/result.json")" '{"status":"failure","exitCode":1}' "PID refusal records strict failure JSON"
/bin/mkdir -p "$TEST_ROOT/outside/Let It Brew.app"
expect_false "candidate outside the private runner root is rejected" \
    "$fixture_root/UpdateSupport/run-update.sh" \
        --candidate "$TEST_ROOT/outside/Let It Brew.app" \
        --app-pid $$ \
        --result "$fixture_root/other-result.json" \
        --log "$fixture_root/other-log"
expect_false "confinement rejection publishes no misleading result" test -e "$fixture_root/other-result.json"
expect_false "confinement rejection creates no transaction log" test -e "$fixture_root/other-log"

echo "=================================="
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: $TESTS detached-update-runner assertions"
else
    echo "FAIL: $FAILURES of $TESTS detached-update-runner assertions" >&2
fi
exit "$FAILURES"
