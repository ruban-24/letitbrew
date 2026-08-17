#!/bin/bash
# Focused, history-free compatibility contract for the v0.5.1 UpdateSupport
# predicate. It intentionally sources only committed test data and does not
# invoke release-build helpers or Git.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
# shellcheck source=fixtures/v0.5.1-update-support-contract.sh
source "$SCRIPT_DIR/fixtures/v0.5.1-update-support-contract.sh"

TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/letitbrew-v051-update-support-contract.XXXXXX)"
TESTS=0
FAILURES=0
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

record_failure() { printf 'not ok: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
expect_true() {
    local label="$1"
    shift
    TESTS=$((TESTS + 1))
    if "$@"; then printf 'ok: %s\n' "$label"; else record_failure "$label"; fi
}
expect_false() {
    local label="$1"
    shift
    TESTS=$((TESTS + 1))
    if "$@" >/dev/null 2>&1; then record_failure "$label"; else printf 'ok: %s\n' "$label"; fi
}

make_exact_four_file_app() {
    local app="$1" support_dir="$1/Contents/Resources/UpdateSupport" support
    /bin/mkdir -p "$support_dir"
    for support in run-update.sh upgrade-installed-app.sh verify-artifact.sh; do
        printf '#!/bin/bash\n' >"$support_dir/$support"
        /bin/chmod 755 "$support_dir/$support"
    done
    printf '# immutable support data\n' >"$support_dir/lib-power-baseline.sh"
    /bin/chmod 644 "$support_dir/lib-power-baseline.sh"
}

exact_four="$TEST_ROOT/exact-four/Let It Brew.app"
make_exact_four_file_app "$exact_four"
expect_true "accepts exact four ordinary files with frozen modes" \
    v051_update_support_contract_accepts "$exact_four"

fifth_entry="$TEST_ROOT/fifth-entry/Let It Brew.app"
make_exact_four_file_app "$fifth_entry"
printf '#!/bin/bash\n' >"$fifth_entry/Contents/Resources/UpdateSupport/fifth.sh"
/bin/chmod 755 "$fifth_entry/Contents/Resources/UpdateSupport/fifth.sh"
expect_false "rejects a fifth immediate UpdateSupport entry" \
    v051_update_support_contract_accepts "$fifth_entry"

symlinked_script="$TEST_ROOT/symlinked-script/Let It Brew.app"
make_exact_four_file_app "$symlinked_script"
foreign_script="$TEST_ROOT/foreign-run-update.sh"
printf '#!/bin/bash\n' >"$foreign_script"
/bin/chmod 755 "$foreign_script"
/bin/rm "$symlinked_script/Contents/Resources/UpdateSupport/run-update.sh"
/bin/ln -s "$foreign_script" "$symlinked_script/Contents/Resources/UpdateSupport/run-update.sh"
expect_false "rejects a live symlink to an ordinary executable script" \
    v051_update_support_contract_accepts "$symlinked_script"

wrong_script_mode="$TEST_ROOT/wrong-script-mode/Let It Brew.app"
make_exact_four_file_app "$wrong_script_mode"
/bin/chmod 644 "$wrong_script_mode/Contents/Resources/UpdateSupport/verify-artifact.sh"
expect_false "rejects an executable support script with mode 644" \
    v051_update_support_contract_accepts "$wrong_script_mode"

wrong_library_mode="$TEST_ROOT/wrong-library-mode/Let It Brew.app"
make_exact_four_file_app "$wrong_library_mode"
/bin/chmod 755 "$wrong_library_mode/Contents/Resources/UpdateSupport/lib-power-baseline.sh"
expect_false "rejects lib-power-baseline.sh with mode 755" \
    v051_update_support_contract_accepts "$wrong_library_mode"

echo "=================================="
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: $TESTS frozen v0.5.1 UpdateSupport assertions"
else
    echo "FAIL: $FAILURES of $TESTS frozen v0.5.1 UpdateSupport assertions" >&2
fi
exit "$FAILURES"
