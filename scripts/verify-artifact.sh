#!/bin/bash
# Strict verification of a production Let It Brew.app candidate. This verifies the
# complete signed product before any installed bundle or service is touched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
APP="${1:?usage: verify-artifact.sh <Let It Brew.app> [--release]}"
MODE="${2:-}"
EXPECTED_TEAM="MV2UL94MDC"
EXPECTED_APP_ID="com.ruban24.letitbrew"
EXPECTED_DAEMON_ID="$EXPECTED_APP_ID.daemon"
EXPECTED_HELPER_ID="$EXPECTED_APP_ID.cli"

[ "$MODE" = "" ] || [ "$MODE" = "--release" ] || {
    echo "FATAL: unknown verification mode '$MODE'." >&2
    exit 1
}
[ -d "$APP" ] || { echo "FATAL: $APP is not a bundle." >&2; exit 1; }
[ ! -L "$APP" ] || { echo "FATAL: refusing a symlinked app bundle." >&2; exit 1; }

fail=0
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc" >&2
        fail=1
    fi
}
note() { printf '     %s\n' "$*"; }

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

signing_info() {
    /usr/bin/codesign -dvvv --verbose=4 "$1" 2>&1
}

signing_field() {
    local file="$1"
    local field="$2"
    signing_info "$file" | /usr/bin/awk -F= -v field="$field" '$1 == field { print $2; exit }'
}

normalized_entitlements() {
    local file="$1"
    local raw normalized

    raw="$(/usr/bin/codesign -d --entitlements - --xml "$file" 2>/dev/null)" || return 1
    [ -n "$raw" ] || return 0
    normalized="$(printf '%s' "$raw" | /usr/bin/plutil -convert xml1 -o - - 2>/dev/null)" || return 1
    printf '%s\n' "$normalized" | /usr/bin/awk '
        /<plist[[:space:]][^>]*>/ {
            found = 1
            if (getline > 0 && $0 ~ /^[[:space:]]*<dict(\/?>)[[:space:]]*$/) valid = 1
            exit
        }
        END { exit (found && valid ? 0 : 1) }
    ' || return 1
    printf '%s' "$normalized"
}

embedded_plist_string() {
    local file="$1"
    local key="$2"
    /usr/bin/plutil -p "$file" 2>/dev/null | /usr/bin/awk -F'"' -v key="$key" '
        $2 == key && $3 == " => " { value = $4; count++ }
        END {
            if (count == 1 && value != "") print value
            else exit 1
        }
    '
}

MAIN="$APP/Contents/MacOS/LetItBrew"
DAEMON="$APP/Contents/Library/LaunchServices/LetItBrewDaemon"
HELPER="$APP/Contents/Helpers/letitbrew"
INFO_PLIST="$APP/Contents/Info.plist"
PLISTS_DIR="$APP/Contents/Library/LaunchDaemons"

echo "== verifying production artifact $APP =="
[ "$MODE" = "--release" ] && echo "(release mode: Developer ID + secure timestamp required)"

echo
echo "-- required components --"
for file in "$MAIN" "$DAEMON" "$HELPER" "$INFO_PLIST"; do
    check "$(basename "$file") present" test -f "$file"
    check "$(basename "$file") is not a symlink" test ! -L "$file"
done

echo
echo "-- embedded legal resources --"
LEGAL_VERIFIER="$SCRIPT_DIR/verify-legal-resources.sh"
check "legal resource verifier present" test -x "$LEGAL_VERIFIER"
if [ -x "$LEGAL_VERIFIER" ]; then
    "$LEGAL_VERIFIER" "$APP" || fail=1
fi
check "main executable bit set" test -x "$MAIN"
check "daemon executable bit set" test -x "$DAEMON"
check "helper executable bit set" test -x "$HELPER"

shopt -s nullglob
daemon_plists=("$PLISTS_DIR"/*.plist)
shopt -u nullglob
if [ "${#daemon_plists[@]}" -eq 1 ]; then
    DAEMON_PLIST="${daemon_plists[0]}"
    echo "ok: exactly one embedded launch daemon plist"
    check "launch daemon plist is not a symlink" test ! -L "$DAEMON_PLIST"
else
    DAEMON_PLIST=""
    echo "FAIL: expected exactly one embedded launch daemon plist; found ${#daemon_plists[@]}" >&2
    fail=1
fi

echo
echo "-- production metadata --"
app_id="$(plist_value "$INFO_PLIST" CFBundleIdentifier)"
app_version="$(plist_value "$INFO_PLIST" CFBundleShortVersionString)"
app_build="$(plist_value "$INFO_PLIST" CFBundleVersion)"
note "bundle: id=$app_id version=$app_version build=$app_build"
check "production bundle identifier" test "$app_id" = "$EXPECTED_APP_ID"
check "marketing version present" test -n "$app_version"
check "build version present" test -n "$app_build"
check "LSUIElement is true" test "$(plist_value "$INFO_PLIST" LSUIElement)" = true
icon_name="$(plist_value "$INFO_PLIST" CFBundleIconName)"
check "CFBundleIconName is set" test -n "$icon_name"
check "compiled AppIcon.icns present" test -f "$APP/Contents/Resources/AppIcon.icns"

echo
echo "-- signed update support --"
UPDATE_SUPPORT="$APP/Contents/Resources/UpdateSupport"
if [ "$app_version" = "0.3.0" ]; then
    note "legacy 0.3.0 rollback artifact: signed update support was not yet shipped"
else
    check "update support directory present" test -d "$UPDATE_SUPPORT"
    check "update support directory is not a symlink" test ! -L "$UPDATE_SUPPORT"
    if [ -d "$UPDATE_SUPPORT" ] && [ ! -L "$UPDATE_SUPPORT" ]; then
        update_support_count="$(/usr/bin/find "$UPDATE_SUPPORT" -mindepth 1 -maxdepth 1 -print | /usr/bin/awk 'END { print NR + 0 }')"
        check "exactly five update support entries" test "$update_support_count" -eq 5
        for support in run-update.sh upgrade-installed-app.sh verify-artifact.sh verify-legal-resources.sh lib-power-baseline.sh; do
            support_path="$UPDATE_SUPPORT/$support"
            check "$support present as an ordinary file" test -f "$support_path"
            check "$support is not a symlink" test ! -L "$support_path"
        done
        for support in run-update.sh upgrade-installed-app.sh verify-artifact.sh verify-legal-resources.sh; do
            support_mode="$(/usr/bin/stat -f '%Lp' "$UPDATE_SUPPORT/$support" 2>/dev/null)"
            check "$support has mode 755" test "$support_mode" = 755
        done
        support_mode="$(/usr/bin/stat -f '%Lp' "$UPDATE_SUPPORT/lib-power-baseline.sh" 2>/dev/null)"
        check "lib-power-baseline.sh has mode 644" test "$support_mode" = 644
    fi
fi

echo
echo "-- universal binaries (arm64 + x86_64) --"
for file in "$MAIN" "$DAEMON" "$HELPER"; do
    archs="$(/usr/bin/lipo -archs "$file" 2>/dev/null)"
    note "$(basename "$file"): $archs"
    case " $archs " in *" arm64 "*) echo "ok: $(basename "$file") has arm64" ;; *) echo "FAIL: $(basename "$file") is missing arm64" >&2; fail=1 ;; esac
    case " $archs " in *" x86_64 "*) echo "ok: $(basename "$file") has x86_64" ;; *) echo "FAIL: $(basename "$file") is missing x86_64" >&2; fail=1 ;; esac
done

echo
echo "-- strict signatures and live-image identity --"
check "bundle passes --deep --strict" /usr/bin/codesign --verify --deep --strict "$APP"
check "main signature valid" /usr/bin/codesign --verify --strict "$MAIN"
check "daemon signature valid" /usr/bin/codesign --verify --strict "$DAEMON"
check "helper signature valid" /usr/bin/codesign --verify --strict "$HELPER"

expected_ids=("$EXPECTED_APP_ID" "$EXPECTED_DAEMON_ID" "$EXPECTED_HELPER_ID")
signed_files=("$APP" "$DAEMON" "$HELPER")
for index in 0 1 2; do
    file="${signed_files[$index]}"
    expected_id="${expected_ids[$index]}"
    info="$(signing_info "$file")"
    identifier="$(printf '%s\n' "$info" | /usr/bin/awk -F= '/^Identifier=/{print $2; exit}')"
    team="$(printf '%s\n' "$info" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    cdhash="$(printf '%s\n' "$info" | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
    note "$(basename "$file"): identifier=$identifier team=$team CDHash=$cdhash"
    [ "$identifier" = "$expected_id" ] || { echo "FAIL: $(basename "$file") identifier '$identifier', expected '$expected_id'" >&2; fail=1; }
    [ "$team" = "$EXPECTED_TEAM" ] || { echo "FAIL: $(basename "$file") Team ID '$team', expected '$EXPECTED_TEAM'" >&2; fail=1; }
    [ -n "$cdhash" ] || { echo "FAIL: $(basename "$file") has no native CDHash" >&2; fail=1; }
    if printf '%s\n' "$info" | /usr/bin/grep -qE '^CodeDirectory .*flags=0x[0-9a-f]*10000\(runtime\)'; then
        echo "ok: $(basename "$file") has hardened runtime"
    else
        echo "FAIL: $(basename "$file") is missing hardened runtime" >&2
        fail=1
    fi
    if [ "$MODE" = "--release" ]; then
        printf '%s\n' "$info" | /usr/bin/grep -q 'Authority=Developer ID Application' || { echo "FAIL: $(basename "$file") is not Developer ID signed" >&2; fail=1; }
        printf '%s\n' "$info" | /usr/bin/grep -qE '^Timestamp=' || { echo "FAIL: $(basename "$file") has no secure timestamp" >&2; fail=1; }
    fi
done

if [ "$MODE" = "--release" ]; then
    if ! main_entitlements="$(normalized_entitlements "$MAIN")"; then
        echo "FAIL: Let It Brew release app entitlements could not be read as a dictionary" >&2
        fail=1
    elif [ -z "$main_entitlements" ] || ! printf '%s\n' "$main_entitlements" | /usr/bin/grep -Fq '<key>com.apple.security.get-task-allow</key>'; then
        echo "ok: Let It Brew release app does not enable get-task-allow"
    elif ! main_get_task_allow="$(printf '%s' "$main_entitlements" | \
        /usr/bin/plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - - 2>/dev/null)"; then
        echo "FAIL: Let It Brew release app get-task-allow entitlement could not be parsed" >&2
        fail=1
    else
        case "$main_get_task_allow" in
            false) echo "ok: Let It Brew release app does not enable get-task-allow" ;;
            true)
                echo "FAIL: Let It Brew release app carries com.apple.security.get-task-allow=true" >&2
                fail=1
                ;;
            *)
                echo "FAIL: Let It Brew release app get-task-allow entitlement is not Boolean" >&2
                fail=1
                ;;
        esac
    fi
fi

echo
echo "-- daemon/helper entitlements and notification linkage --"
for file in "$DAEMON" "$HELPER"; do
    if ! entitlements="$(normalized_entitlements "$file")"; then
        echo "FAIL: $(basename "$file") entitlements could not be read as a dictionary" >&2
        fail=1
    elif printf '%s\n' "$entitlements" | /usr/bin/grep -Fq '<key>application-identifier</key>' || \
         printf '%s\n' "$entitlements" | /usr/bin/grep -Fq '<key>com.apple.security.get-task-allow</key>'; then
        echo "FAIL: $(basename "$file") carries app entitlements" >&2
        fail=1
    else
        echo "ok: $(basename "$file") carries no app entitlements"
    fi
done
for file in "$MAIN" "$DAEMON" "$HELPER"; do
    if /usr/bin/otool -L "$file" 2>/dev/null | /usr/bin/grep -qi UserNotifications; then
        echo "FAIL: $(basename "$file") links UserNotifications" >&2
        fail=1
    else
        echo "ok: $(basename "$file") does not link UserNotifications"
    fi
done

echo
echo "-- launch daemon contract --"
if [ -n "$DAEMON_PLIST" ]; then
    label="$(plist_value "$DAEMON_PLIST" Label)"
    check "launch daemon plist filename" test "$(basename "$DAEMON_PLIST")" = "$EXPECTED_DAEMON_ID.plist"
    check "launch daemon label" test "$label" = "$EXPECTED_DAEMON_ID"
    check "associated bundle identifier" test "$(plist_value "$DAEMON_PLIST" AssociatedBundleIdentifiers:0)" = "$EXPECTED_APP_ID"
    check "embedded daemon program path" test "$(plist_value "$DAEMON_PLIST" BundleProgram)" = "Contents/Library/LaunchServices/LetItBrewDaemon"
    check "Mach service label" test "$(plist_value "$DAEMON_PLIST" MachServices:$EXPECTED_DAEMON_ID)" = true
    check "RunAtLoad enabled" test "$(plist_value "$DAEMON_PLIST" RunAtLoad)" = true
    check "KeepAlive successful-exit restart policy" test "$(plist_value "$DAEMON_PLIST" KeepAlive:SuccessfulExit)" = false
fi

echo
echo "-- app/helper version consistency --"
cli_version="$(embedded_plist_string "$HELPER" CFBundleShortVersionString)"
cli_build="$(embedded_plist_string "$HELPER" CFBundleVersion)"
note "app=$app_version helper=$cli_version app-build=$app_build helper-build=$cli_build"
check "helper and app marketing versions match" test "$cli_version" = "$app_version"
check "helper and app builds match" test "$cli_build" = "$app_build"

echo
echo "=================================="
if [ "$fail" -eq 0 ]; then
    echo "PASS: production artifact verification"
else
    echo "FAIL: production artifact verification — see above" >&2
fi
exit "$fail"
