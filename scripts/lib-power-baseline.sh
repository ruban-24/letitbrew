# Shared helpers for capturing and verifying the pre-existing `disablesleep`
# (`SleepDisabled`) value around live power operations, plus immutable app
# Legal-resource verification. Sourced, not executed.
#
# The parser is deliberately three-way: exactly one canonical 0/1 value is
# accepted; missing, duplicated, conflicting, malformed, and unreadable output
# are refusals. Callers must check every nonzero return.

# Validates the immutable Legal payload in exactly one ordinary app bundle.
# This is intentionally callable from release fixtures, while production
# callers still run their complete verifier after this check succeeds.
baseline_verify_legal_resources() {
    local app="${1:-}" legal_dir legal_entries legal_path legal_mode fail=0

    [ "$#" -eq 1 ] || { echo "FATAL: expected exactly one app bundle path." >&2; return 1; }
    [ -d "$app" ] || { echo "FATAL: $app is not a bundle." >&2; return 1; }
    [ ! -L "$app" ] || { echo "FATAL: refusing a symlinked app bundle." >&2; return 1; }

    baseline_legal_check() {
        local description="$1"
        shift
        if "$@" >/dev/null 2>&1; then
            echo "ok: $description"
        else
            echo "FAIL: $description" >&2
            fail=1
        fi
    }

    legal_dir="$app/Contents/Resources/Legal"
    baseline_legal_check "Legal directory present" test -d "$legal_dir"
    baseline_legal_check "Legal directory is not a symlink" test ! -L "$legal_dir"
    if [ -d "$legal_dir" ] && [ ! -L "$legal_dir" ]; then
        legal_entries="$(/usr/bin/find "$legal_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null | /usr/bin/sed 's|.*/||' | /usr/bin/sort | /usr/bin/tr '\n' ',')"
        baseline_legal_check "Legal contains exactly LICENSE, NOTICE, and TRADEMARKS.md" \
            test "$legal_entries" = "LICENSE,NOTICE,TRADEMARKS.md,"
        for legal_path in LICENSE NOTICE TRADEMARKS.md; do
            baseline_legal_check "Legal/$legal_path present as an ordinary file" test -f "$legal_dir/$legal_path"
            baseline_legal_check "Legal/$legal_path is not a symlink" test ! -L "$legal_dir/$legal_path"
            legal_mode="$(/usr/bin/stat -f '%Lp' "$legal_dir/$legal_path" 2>/dev/null)"
            baseline_legal_check "Legal/$legal_path has mode 644" test "$legal_mode" = 644
        done
        baseline_legal_check "Legal/LICENSE has the Apache 2.0 header" \
            /usr/bin/grep -Fq "Apache License" "$legal_dir/LICENSE"
        baseline_legal_check "Legal/LICENSE names Version 2.0, January 2004" \
            /usr/bin/grep -Fxq "                           Version 2.0, January 2004" "$legal_dir/LICENSE"
        baseline_legal_check "Legal/NOTICE attributes Ruban" \
            /usr/bin/grep -Fq "Copyright 2026 Ruban" "$legal_dir/NOTICE"
        baseline_legal_check "Legal/TRADEMARKS.md has the trademark-policy heading" \
            /usr/bin/grep -Fxq "# Let It Brew Trademark Policy" "$legal_dir/TRADEMARKS.md"
    fi

    if [ "$fail" -eq 0 ]; then
        echo "PASS: embedded legal resource verification"
    else
        echo "FAIL: embedded legal resource verification" >&2
    fi
    return "$fail"
}

baseline_parse_sleepdisabled() {
    /usr/bin/awk '
        $1 == "SleepDisabled" {
            count += 1
            if (NF != 2 || ($2 != "0" && $2 != "1")) invalid = 1
            value = $2
        }
        END {
            if (count == 1 && invalid == 0) {
                print value
                exit 0
            }
            exit 1
        }
    '
}

baseline_read_sleepdisabled() {
    local output value
    if ! output="$(/usr/bin/pmset -g 2>/dev/null)"; then
        echo "FATAL: pmset -g failed; refusing to infer SleepDisabled." >&2
        return 1
    fi
    if ! value="$(printf '%s\n' "$output" | baseline_parse_sleepdisabled)"; then
        echo "FATAL: pmset -g did not contain exactly one canonical SleepDisabled 0/1 value." >&2
        return 1
    fi
    printf '%s\n' "$value"
}

# Polls until SleepDisabled equals $1, or returns nonzero after $2 seconds.
# An unreadable value stops immediately instead of consuming the timeout.
baseline_wait_for() {
    local expected="$1"
    local timeout="${2:-15}"
    local waited=0
    local actual

    case "$expected" in
        0|1) ;;
        *)
            echo "FATAL: invalid expected SleepDisabled value '$expected'." >&2
            return 1
            ;;
    esac
    case "$timeout" in
        ''|*[!0-9]*)
            echo "FATAL: invalid SleepDisabled timeout '$timeout'." >&2
            return 1
            ;;
    esac

    while :; do
        actual="$(baseline_read_sleepdisabled)" || return 1
        [ "$actual" = "$expected" ] && return 0
        if [ "$waited" -ge "$timeout" ]; then
            echo "FAIL: timed out after ${timeout}s waiting for SleepDisabled=$expected (still $actual)." >&2
            return 1
        fi
        /bin/sleep 1
        waited=$((waited + 1))
    done
}

baseline_assert() {
    local expected="$1"
    local label="${2:-baseline}"
    local actual

    case "$expected" in
        0|1) ;;
        *)
            echo "FATAL: invalid expected SleepDisabled value '$expected'." >&2
            return 1
            ;;
    esac
    actual="$(baseline_read_sleepdisabled)" || return 1
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $label — SleepDisabled is $actual, expected $expected." >&2
        echo "Recovery requires an explicit, evidence-backed restore to $expected; this script will not guess." >&2
        return 1
    fi
    echo "ok: $label — SleepDisabled=$actual"
}
