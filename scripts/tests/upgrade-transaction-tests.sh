#!/bin/bash
# Deterministic, isolated tests for the shell transaction. No command in this
# file addresses /Applications, launchd, Service Management, or real pmset.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib-power-baseline.sh
source "$SCRIPT_DIR/lib-power-baseline.sh"
# shellcheck source=../upgrade-installed-app.sh
source "$SCRIPT_DIR/upgrade-installed-app.sh"
# shellcheck source=../verify-installed-app.sh
source "$SCRIPT_DIR/verify-installed-app.sh"

TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/letitbrew-release-script-tests.XXXXXX)"
test_cleanup() { /bin/rm -rf "$TEST_ROOT"; }
trap test_cleanup EXIT
TESTS=0
FAILURES=0

record_failure() {
    echo "not ok: $1" >&2
    FAILURES=$((FAILURES + 1))
}

expect_equal() {
    local actual="$1" expected="$2" label="$3"
    TESTS=$((TESTS + 1))
    if [ "$actual" = "$expected" ]; then
        echo "ok: $label"
    else
        record_failure "$label (actual '$actual', expected '$expected')"
    fi
}

expect_true() {
    local label="$1"
    shift
    TESTS=$((TESTS + 1))
    if "$@"; then echo "ok: $label"; else record_failure "$label"; fi
}

expect_false() {
    local label="$1"
    shift
    TESTS=$((TESTS + 1))
    if "$@" >/dev/null 2>&1; then record_failure "$label"; else echo "ok: $label"; fi
}

echo "-- strict SleepDisabled parser --"
expect_equal "$(printf ' SleepDisabled 0\n' | baseline_parse_sleepdisabled)" 0 "parses one baseline 0"
expect_equal "$(printf '\tSleepDisabled\t1\n' | baseline_parse_sleepdisabled)" 1 "parses one baseline 1"
expect_false "rejects missing SleepDisabled" baseline_parse_sleepdisabled <<<"System-wide power settings:"
expect_false "rejects duplicate SleepDisabled" baseline_parse_sleepdisabled <<<' SleepDisabled 0
 SleepDisabled 0'
expect_false "rejects conflicting SleepDisabled" baseline_parse_sleepdisabled <<<' SleepDisabled 0
 SleepDisabled 1'
expect_false "rejects malformed SleepDisabled" baseline_parse_sleepdisabled <<<' SleepDisabled yes'

echo
echo "-- isolated build-order policy helper --"
expect_true "recognizes strictly newer numeric build" upgrade_build_is_strictly_newer 1 2
expect_false "does not call an equal build newer" upgrade_build_is_strictly_newer 2 2
expect_false "does not call an older build newer" upgrade_build_is_strictly_newer 2 1
expect_false "rejects a non-decimal candidate build" upgrade_build_is_strictly_newer 2 2.1

echo
echo "-- Service Management BundleProgram representation --"
launch_state=$'system/com.ruban24.letitbrew.daemon = {\n\tstate = running\n\tprogram identifier = Contents/Library/LaunchServices/LetItBrewDaemon (mode: 2)\n\tparent bundle identifier = com.ruban24.letitbrew\n\tparent bundle version = 2\n}'
expect_true "accepts exact relative mode-2 BundleProgram job" \
    upgrade_launch_job_matches_bundle_program \
        "$launch_state" Contents/Library/LaunchServices/LetItBrewDaemon 2
expect_false "rejects a stale parent bundle build" \
    upgrade_launch_job_matches_bundle_program \
        "$launch_state" Contents/Library/LaunchServices/LetItBrewDaemon 1
expect_false "rejects a wrong relative BundleProgram" \
    upgrade_launch_job_matches_bundle_program \
        "$launch_state" Contents/Library/LaunchServices/OtherDaemon 2

echo
echo "-- LaunchServices registration precedes service registration --"
register_test_root="$TEST_ROOT/register-service"
register_test_app="$register_test_root/installed.app"
register_test_events="$register_test_root/events"
register_test_lsregister="$register_test_root/lsregister"
/bin/mkdir -p "$register_test_app/Contents/MacOS"
printf '%s\n' \
    '#!/bin/sh' \
    'printf "app:%s\\n" "$*" >>"$REGISTER_TEST_EVENTS"' \
    'exit 0' >"$register_test_app/Contents/MacOS/LetItBrew"
/bin/chmod +x "$register_test_app/Contents/MacOS/LetItBrew"
printf '%s\n' \
    '#!/bin/sh' \
    'printf "ls:%s\\n" "$*" >>"$REGISTER_TEST_EVENTS"' \
    'exit "${REGISTER_LS_STATUS:-0}"' >"$register_test_lsregister"
/bin/chmod +x "$register_test_lsregister"
export REGISTER_TEST_EVENTS="$register_test_events"
export REGISTER_LS_STATUS=0
production_lsregister="$UPGRADE_LSREGISTER"
UPGRADE_LSREGISTER="$register_test_lsregister"
UPGRADE_DEST="$register_test_app"
UPGRADE_WORKDIR="$register_test_root"
UPGRADE_COMMAND_COUNTER=0
UPGRADE_TIMEOUT=2
expect_true "registers the exact installed bundle before submitting its service" \
    upgrade_register_service "$register_test_app/Contents/MacOS/LetItBrew"
expect_equal "$(/bin/cat "$register_test_events")" \
    "$(printf 'ls:-f -R -trusted %s\napp:--register-daemon' "$register_test_app")" \
    "LaunchServices registration strictly precedes the app command"

: >"$register_test_events"
expect_false "rejects service registration from a non-installed app path" \
    upgrade_register_service "$register_test_root/other.app/Contents/MacOS/LetItBrew"
expect_false "path refusal performs no LaunchServices or app command" test -s "$register_test_events"

: >"$register_test_events"
export REGISTER_LS_STATUS=1
expect_false "refuses when LaunchServices registration fails" \
    upgrade_register_service "$register_test_app/Contents/MacOS/LetItBrew"
expect_equal "$(/bin/cat "$register_test_events")" \
    "$(printf 'ls:-f -R -trusted %s' "$register_test_app")" \
    "LaunchServices failure prevents the app registration command"
UPGRADE_LSREGISTER="$production_lsregister"
unset REGISTER_TEST_EVENTS REGISTER_LS_STATUS
UPGRADE_TIMEOUT=20

echo
echo "-- strict daemon probe JSON --"
probe_json="$TEST_ROOT/probe.json"
printf '%s\n' '{"protocolVersion":1,"marketingVersion":"0.3.0","build":"2","buildIdentity":"A1B2C3","reconciliationReady":true,"message":"ready"}' >"$probe_json"
expect_true "accepts exact signed identity/version/build readiness" \
    upgrade_validate_json_probe "$probe_json" 0.3.0 2 a1b2c3
expect_false "rejects a stale daemon CDHash" \
    upgrade_validate_json_probe "$probe_json" 0.3.0 2 deadbeef
expect_false "rejects a mismatched daemon build" \
    upgrade_validate_json_probe "$probe_json" 0.3.0 3 a1b2c3
printf '%s\n' '{"protocolVersion":1,"marketingVersion":"0.3.0","build":"2","buildIdentity":"A1B2C3","reconciliationReady":false,"message":"debt remains"}' >"$probe_json"
expect_false "rejects an unreconciled exact-identity daemon" \
    upgrade_validate_json_probe "$probe_json" 0.3.0 2 a1b2c3

echo
echo "-- updater preparation preserves actual daemon presence --"
update_prepare_output="$TEST_ROOT/update-prepare.json"
UPDATE_PREPARE_JSON=""
UPDATE_PREPARE_STATUS=0
TEST_PREPARE_BASELINE=0
upgrade_run_app_command() {
    UPGRADE_LAST_OUTPUT="$update_prepare_output"
    printf '%s\n' "$UPDATE_PREPARE_JSON" >"$UPGRADE_LAST_OUTPUT"
    return "$UPDATE_PREPARE_STATUS"
}
baseline_read_sleepdisabled() { printf '%s\n' "$TEST_PREPARE_BASELINE"; }

UPDATE_PREPARE_JSON='{"protocolVersion":1,"marketingVersion":"0.3.0","build":"2","buildIdentity":"A1B2C3","reconciliationReady":true,"daemonState":"registered","sleepDisabledBaseline":0}'
expect_true "accepts an authenticated registered daemon preparation" \
    upgrade_prepare_old_preserving_daemon_state "/old/Let It Brew" 0.3.0 2 a1b2c3
expect_equal "$UPGRADE_OLD_SERVICE_STATE" registered "records registered daemon state"
expect_equal "$UPGRADE_PREPARED_BASELINE" 0 "records registered exact baseline"
expect_equal "$UPGRADE_OLD_PROBE_MODE" strict "registered rollback requires a strict probe"

UPDATE_PREPARE_JSON='{"reconciliationReady":true,"daemonState":"absent"}'
TEST_PREPARE_BASELINE=1
expect_true "accepts only an affirmatively absent daemon result" \
    upgrade_prepare_old_preserving_daemon_state "/old/Let It Brew" 0.3.0 2 a1b2c3
expect_equal "$UPGRADE_OLD_SERVICE_STATE" absent "records absent daemon state"
expect_equal "$UPGRADE_PREPARED_BASELINE" 1 "records stable absent-state baseline"
expect_equal "$UPGRADE_OLD_PROBE_MODE" "" "absent rollback never probes a daemon"

UPDATE_PREPARE_JSON='{"reconciliationReady":true,"daemonState":"unknown"}'
expect_false "rejects an unknown daemon state" \
    upgrade_prepare_old_preserving_daemon_state "/old/Let It Brew" 0.3.0 2 a1b2c3

echo
echo "-- relaunch tracking precedes count validation --"
process_count_file="$TEST_ROOT/process-count-calls"
printf '0\n' >"$process_count_file"
upgrade_process_count_for_path() {
    local calls
    calls="$(/bin/cat "$process_count_file")"
    calls=$((calls + 1))
    printf '%s\n' "$calls" >"$process_count_file"
    if [ "$calls" -eq 1 ]; then printf '0\n'; else printf '2\n'; fi
}
upgrade_open_installed_app() { return 0; }
UPGRADE_DEST="$TEST_ROOT/relaunch.app"
UPGRADE_TIMEOUT=0
UPGRADE_RELAUNCHED=0
upgrade_relaunch_exactly_one
relaunch_status=$?
expect_equal "$relaunch_status" 1 "duplicate-count relaunch fails"
expect_equal "$UPGRADE_RELAUNCHED" 1 "successful open is tracked before count failure"
UPGRADE_TIMEOUT=20
upgrade_process_count_for_path() { printf '0\n'; }
upgrade_request_ordinary_quit() { return 1; }
expect_true "rollback quit is already successful when exact app count is zero" upgrade_quit_ordinary_app

TEST_FAIL_POINT=""
TEST_LIVE_BASELINE=0
TEST_EVENTS=""
TEST_ABSENT_NEW_CALLS=0
TEST_BASELINE_CALLS=0

test_event() {
    TEST_EVENTS="${TEST_EVENTS}${TEST_EVENTS:+,}$1"
}

test_bundle_kind() {
    /bin/cat "$1/kind"
}

make_fake_bundle() {
    local path="$1" kind="$2"
    /bin/mkdir -p \
        "$path/Contents/MacOS" \
        "$path/Contents/Library/LaunchServices" \
        "$path/Contents/Helpers"
    printf '%s\n' "$kind" >"$path/kind"
    for executable in \
        "$path/Contents/MacOS/LetItBrew" \
        "$path/Contents/Library/LaunchServices/LetItBrewDaemon" \
        "$path/Contents/Helpers/letitbrew"; do
        printf '#!/bin/sh\nexit 0\n' >"$executable"
        /bin/chmod +x "$executable"
    done
}

# Transaction adapters. Production has no environment switch for these; shell
# function replacement is possible only because this test sourced the script.
upgrade_unregister_service() {
    test_event "unregister-$(test_bundle_kind "$UPGRADE_DEST")"
    [ "$TEST_FAIL_POINT" != unregister ]
}
upgrade_unregister_best_effort() { test_event "rollback-unregister"; }
upgrade_wait_service_absent() {
    local kind
    kind="$(test_bundle_kind "$UPGRADE_DEST")"
    test_event "absent-$kind"
    if [ "$kind" = new ]; then
        TEST_ABSENT_NEW_CALLS=$((TEST_ABSENT_NEW_CALLS + 1))
        [ "$TEST_FAIL_POINT" != absent-new ] || [ "$TEST_ABSENT_NEW_CALLS" -ne 1 ]
        return
    fi
    [ "$TEST_FAIL_POINT" != absent-old ]
}
upgrade_register_service() {
    local kind
    kind="$(test_bundle_kind "$UPGRADE_DEST")"
    test_event "register-$kind"
    [ "$TEST_FAIL_POINT" != "register-$kind" ]
}
upgrade_wait_service_current() {
    local kind
    kind="$(test_bundle_kind "$UPGRADE_DEST")"
    test_event "current-$kind"
    [ "$TEST_FAIL_POINT" != "current-$kind" ]
}
upgrade_probe_new_strict() { test_event "probe-new"; [ "$TEST_FAIL_POINT" != probe-new ]; }
upgrade_probe_restored_old() { test_event "probe-old"; [ "$TEST_FAIL_POINT" != probe-old ]; }
upgrade_verify_artifact() { test_event "verify-$(test_bundle_kind "$1")${2:+ $2}"; return 0; }
upgrade_verify_installed() { test_event "verify-installed"; [ "$TEST_FAIL_POINT" != verify-installed ]; }
upgrade_relaunch_exactly_one() { test_event "relaunch"; [ "$TEST_FAIL_POINT" != relaunch ]; }
upgrade_quit_ordinary_app() { test_event "quit"; return 0; }
baseline_assert() {
    local expected="$1"
    TEST_BASELINE_CALLS=$((TEST_BASELINE_CALLS + 1))
    test_event "baseline-$TEST_LIVE_BASELINE"
    [ "$TEST_LIVE_BASELINE" = "$expected" ] || return 1
    [ "$TEST_FAIL_POINT" != baseline-new ] || [ "$TEST_BASELINE_CALLS" -ne 2 ]
}

setup_transaction() {
    local name="$1" baseline="$2"
    UPGRADE_WORKDIR="$TEST_ROOT/$name"
    /bin/mkdir -p "$UPGRADE_WORKDIR"
    UPGRADE_DEST="$UPGRADE_WORKDIR/installed.app"
    UPGRADE_STAGE="$UPGRADE_WORKDIR/staged.app"
    UPGRADE_BACKUP="$UPGRADE_WORKDIR/previous.app"
    UPGRADE_FAILED="$UPGRADE_WORKDIR/failed-new.app"
    make_fake_bundle "$UPGRADE_DEST" old
    make_fake_bundle "$UPGRADE_STAGE" new
    UPGRADE_BASELINE="$baseline"
    TEST_LIVE_BASELINE="$baseline"
    UPGRADE_RELAUNCH=0
    UPGRADE_RELAUNCHED=0
    UPGRADE_PHASE=pre-swap
    UPGRADE_OLD_PROBE_MODE=legacy
    UPGRADE_OLD_SERVICE_STATE=registered
    TEST_FAIL_POINT=""
    TEST_EVENTS=""
    TEST_ABSENT_NEW_CALLS=0
    TEST_BASELINE_CALLS=0
}

run_transaction() {
    upgrade_transaction 0.1.0 1 oldhash 0.2.0 2 newhash manifest
}

echo
echo "-- refusal before swap --"
setup_transaction refusal 0
TEST_FAIL_POINT=unregister
run_transaction >/dev/null 2>&1
status=$?
expect_equal "$status" 1 "unregister refusal is nonzero"
expect_equal "$(test_bundle_kind "$UPGRADE_DEST")" old "unregister refusal leaves old destination"
expect_true "unregister refusal leaves staged candidate" test -d "$UPGRADE_STAGE"
expect_false "unregister refusal creates no backup" test -e "$UPGRADE_BACKUP"

run_rollback_case() {
    local name="$1" fail_point="$2"
    setup_transaction "$name" 0
    TEST_FAIL_POINT="$fail_point"
    run_transaction >/dev/null 2>&1
    local status=$?
    expect_equal "$status" 1 "$name returns nonzero"
    expect_equal "$(test_bundle_kind "$UPGRADE_DEST")" old "$name restores old destination"
    expect_true "$name preserves failed new bundle" test -d "$UPGRADE_FAILED"
    expect_false "$name consumes backup only by restoring it" test -e "$UPGRADE_BACKUP"
    expect_true "$name re-registers and probes old service" /usr/bin/grep -q 'register-old.*probe-old' <<<"$TEST_EVENTS"
    expect_true "$name verifies the restored old bundle in restored mode" \
        /usr/bin/grep -q 'verify-old --restored' <<<"$TEST_EVENTS"
    expect_false "$name never verifies the new bundle in restored mode" \
        /usr/bin/grep -q 'verify-new --restored' <<<"$TEST_EVENTS"
}

echo
echo "-- every post-swap service failure rolls back --"
run_rollback_case verify_failure verify-installed
run_rollback_case registration_failure register-new
run_rollback_case current_failure current-new
run_rollback_case probe_failure probe-new
run_rollback_case baseline_failure baseline-new

echo
echo "-- exact baseline preservation on success --"
for baseline in 0 1; do
    setup_transaction "success-$baseline" "$baseline"
    run_transaction >/dev/null 2>&1
    status=$?
    expect_equal "$status" 0 "baseline $baseline transaction succeeds"
    expect_equal "$(test_bundle_kind "$UPGRADE_DEST")" new "baseline $baseline installs new destination"
    expect_false "baseline $baseline deletes backup only after health" test -e "$UPGRADE_BACKUP"
    expect_true "baseline $baseline was asserted after old stop and new health" /usr/bin/grep -q "baseline-$baseline.*baseline-$baseline" <<<"$TEST_EVENTS"
done

echo
echo "-- absent daemon remains absent on success and rollback --"
for baseline in 0 1; do
    setup_transaction "absent-success-$baseline" "$baseline"
    UPGRADE_OLD_SERVICE_STATE=absent
    run_transaction >/dev/null 2>&1
    status=$?
    expect_equal "$status" 0 "absent baseline $baseline transaction succeeds"
    expect_equal "$(test_bundle_kind "$UPGRADE_DEST")" new "absent baseline $baseline installs new destination"
    expect_true "absent baseline $baseline proves absence before and after swap" \
        /usr/bin/grep -q 'absent-old.*absent-new' <<<"$TEST_EVENTS"
    expect_false "absent baseline $baseline never registers or probes a daemon" \
        /usr/bin/grep -Eq '(^|,)(register|probe)-' <<<"$TEST_EVENTS"
done

setup_transaction absent_rollback 0
UPGRADE_OLD_SERVICE_STATE=absent
TEST_FAIL_POINT=verify-installed
run_transaction >/dev/null 2>&1
status=$?
expect_equal "$status" 1 "absent post-swap failure is nonzero"
expect_equal "$(test_bundle_kind "$UPGRADE_DEST")" old "absent post-swap failure restores old destination"
expect_true "absent rollback preserves failed new bundle" test -d "$UPGRADE_FAILED"
expect_false "absent rollback never registers or probes restored old daemon" \
    /usr/bin/grep -Eq '(^|,)(register-old|probe-old)(,|$)' <<<"$TEST_EVENTS"
expect_true "absent rollback proves restored old daemon remains absent" \
    /usr/bin/grep -q 'absent-old.*absent-new.*absent-old' <<<"$TEST_EVENTS"

setup_transaction absent_new_presence_rollback 0
UPGRADE_OLD_SERVICE_STATE=absent
TEST_FAIL_POINT=absent-new
run_transaction >/dev/null 2>&1
status=$?
expect_equal "$status" 1 "unexpected new daemon presence is nonzero"
expect_equal "$(test_bundle_kind "$UPGRADE_DEST")" old "unexpected new daemon presence restores old destination"
expect_true "unexpected new daemon presence is stopped before restoring absent old state" \
    /usr/bin/grep -q 'absent-new.*rollback-unregister.*absent-new.*absent-old' <<<"$TEST_EVENTS"

prepare_swapped_state() {
    local name="$1"
    setup_transaction "$name" 0
    /bin/mv "$UPGRADE_DEST" "$UPGRADE_BACKUP"
    /bin/mv "$UPGRADE_STAGE" "$UPGRADE_DEST"
    UPGRADE_PHASE=swapped
    UPGRADE_OLD_VERSION=0.1.0
    UPGRADE_OLD_BUILD=1
    UPGRADE_OLD_CDHASH=oldhash
}

echo
echo "-- interrupt and unexpected-exit recovery --"
prepare_swapped_state signal_recovery
( trap - EXIT; upgrade_handle_signal >/dev/null 2>&1 )
signal_status=$?
expect_equal "$signal_status" 130 "post-swap signal exits 130"
expect_equal "$(test_bundle_kind "$UPGRADE_DEST")" old "post-swap signal restores old destination"
expect_true "post-swap signal preserves failed new bundle" test -d "$UPGRADE_FAILED"

prepare_swapped_state exit_recovery
( trap - EXIT; false; upgrade_exit_cleanup >/dev/null 2>&1 )
exit_status=$?
expect_equal "$exit_status" 1 "unexpected post-swap exit remains nonzero"
expect_equal "$(test_bundle_kind "$UPGRADE_DEST")" old "unexpected post-swap exit restores old destination"
expect_true "unexpected post-swap exit preserves failed new bundle" test -d "$UPGRADE_FAILED"

echo
echo "-- cleanup and incomplete-result contracts --"
cleanup_pre="$TEST_ROOT/cleanup-pre"
/bin/mkdir -p "$cleanup_pre"
UPGRADE_WORKDIR="$cleanup_pre"
UPGRADE_PHASE=pre-swap
UPGRADE_LOCK=""
upgrade_exit_cleanup
expect_false "pre-swap cleanup removes staging workspace" test -e "$cleanup_pre"

cleanup_rollback="$TEST_ROOT/cleanup-rollback"
/bin/mkdir -p "$cleanup_rollback"
UPGRADE_WORKDIR="$cleanup_rollback"
UPGRADE_PHASE=rolled-back
upgrade_exit_cleanup >/dev/null 2>&1
expect_true "rollback cleanup preserves recovery material" test -d "$cleanup_rollback"

acceptance_result 0 1
incomplete_status=$?
expect_equal "$incomplete_status" 2 "incomplete acceptance returns nonzero status 2"
acceptance_result 1 0
failed_status=$?
expect_equal "$failed_status" 1 "failed acceptance returns status 1"

term_waiter="$TEST_ROOT/term-waiter.sh"
printf '%s\n' '#!/bin/sh' "trap 'exit 0' TERM" 'while :; do /bin/sleep 1; done' >"$term_waiter"
/bin/chmod +x "$term_waiter"
"$term_waiter" &
ACCEPT_HOLD_PID=$!
hold_test_pid="$ACCEPT_HOLD_PID"
/bin/sleep 1
acceptance_stop_hold_client
expect_false "acceptance cleanup terminates its exact hold client" /bin/kill -0 "$hold_test_pid"

timeout_log="$TEST_ROOT/timeout.log"
upgrade_run_bounded 1 "$timeout_log" "$term_waiter"
timeout_status=$?
expect_equal "$timeout_status" 124 "bounded diagnostic command reports timeout"

echo
echo "=================================="
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: $TESTS isolated release-script assertions"
else
    echo "FAIL: $FAILURES of $TESTS isolated release-script assertions" >&2
fi
exit "$FAILURES"
