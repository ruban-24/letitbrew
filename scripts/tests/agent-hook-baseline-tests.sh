#!/bin/bash
# Deterministic tests for the agent-hook contract's CI-only power baseline.
# No command in this file invokes real pmset.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
HELPER="$SCRIPT_DIR/lib-agent-hook-test-baseline.sh"
TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/letitbrew-agent-hook-baseline-tests.XXXXXX)"
STRICT_READ_SENTINEL="$TEST_ROOT/strict-read"
TESTS=0
FAILURES=0
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

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

if [ ! -f "$HELPER" ]; then
    record_failure "agent-hook baseline helper exists"
    echo "FAIL: $FAILURES of 1 agent-hook baseline assertions" >&2
    exit 1
fi

# shellcheck source=../lib-agent-hook-test-baseline.sh
source "$HELPER"

baseline_read_sleepdisabled() {
    : > "$STRICT_READ_SENTINEL"
    printf '1\n'
}

unset LETITBREW_TEST_AGENT_HOOK_SLEEP_DISABLED_BASELINE
expect_equal "$(agent_hook_test_read_sleepdisabled)" 1 \
    "an unset test baseline delegates to the strict real reader"
expect_true "delegation calls the strict real reader" test -f "$STRICT_READ_SENTINEL"

for baseline in 0 1; do
    /bin/rm -f "$STRICT_READ_SENTINEL"
    LETITBREW_TEST_AGENT_HOOK_SLEEP_DISABLED_BASELINE="$baseline"
    expect_equal "$(agent_hook_test_read_sleepdisabled)" "$baseline" \
        "an explicit canonical test baseline $baseline is accepted"
    expect_false "test baseline $baseline does not call the real reader" \
        test -e "$STRICT_READ_SENTINEL"
done

for baseline in '' 2 01 false; do
    /bin/rm -f "$STRICT_READ_SENTINEL"
    LETITBREW_TEST_AGENT_HOOK_SLEEP_DISABLED_BASELINE="$baseline"
    expect_false "a noncanonical test baseline '$baseline' is rejected" \
        agent_hook_test_read_sleepdisabled
    expect_false "a rejected test baseline '$baseline' does not call the real reader" \
        test -e "$STRICT_READ_SENTINEL"
done

echo "=================================="
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: $TESTS agent-hook baseline assertions"
else
    echo "FAIL: $FAILURES of $TESTS agent-hook baseline assertions" >&2
fi
exit "$FAILURES"
