#!/bin/bash
# Correctness pressure suite for concurrent session capture. Every cache and
# test record uses an isolated location beneath /private/tmp; no user agent
# configuration or Application Support directory is read.
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_TEST_ROOT="$(mktemp -d /private/tmp/letitbrew-session-pressure.XXXXXX)"
if [ -z "$RAW_TEST_ROOT" ] || [ ! -d "$RAW_TEST_ROOT" ] || [ -L "$RAW_TEST_ROOT" ]; then
    echo "FATAL: unsafe session-pressure test root: ${RAW_TEST_ROOT:-<empty>}" >&2
    exit 1
fi
TEST_ROOT="$(/bin/realpath "$RAW_TEST_ROOT" 2>/dev/null)" || {
    echo "FATAL: unsafe session-pressure test root: $RAW_TEST_ROOT" >&2
    exit 1
}
case "$TEST_ROOT" in
    /private/tmp/letitbrew-session-pressure.*) ;;
    *)
        echo "FATAL: unsafe session-pressure test root: ${TEST_ROOT:-<empty>}" >&2
        exit 1
        ;;
esac
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

export SWIFTPM_MODULECACHE_OVERRIDE="$TEST_ROOT/swiftpm-module-cache"
export CLANG_MODULE_CACHE_PATH="$TEST_ROOT/clang-module-cache"
export LETITBREW_SESSION_PRESSURE_COUNTS="1,10,15,50,100"
export LETITBREW_SESSION_PRESSURE_AGENTS="claude,codex,opencode,copilot"
export LETITBREW_SESSION_PRESSURE_ROOT="$TEST_ROOT"
/bin/mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH"

cd "$REPOSITORY_ROOT"
swift test \
    --scratch-path "$TEST_ROOT/build" \
    --filter SessionPressureTests
