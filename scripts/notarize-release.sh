#!/bin/bash
# Notarize Let It Brew's app and final DMG using only a named Keychain profile.
# This script never accepts raw Apple IDs, passwords, API keys, or publication.
set -uo pipefail

RELEASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
# shellcheck source=lib-direct-distribution.sh
source "$RELEASE_SCRIPT_DIR/lib-direct-distribution.sh"
# shellcheck source=create-release-dmg.sh
source "$RELEASE_SCRIPT_DIR/create-release-dmg.sh"

RELEASE_NOTARY_MOUNT=""
RELEASE_NOTARY_OWNS_LOCK=0

release_notary_xcrun() {
    /usr/bin/xcrun "$@"
}

release_notary_ditto() {
    /usr/bin/ditto "$@"
}

release_notary_codesign() {
    /usr/bin/codesign "$@"
}

release_notary_hdiutil() {
    /usr/bin/hdiutil "$@"
}

release_notary_spctl() {
    /usr/sbin/spctl "$@"
}

release_notary_verify_artifact() {
    "$RELEASE_SCRIPT_DIR/verify-artifact.sh" "$1" --release
}

release_notary_create_final_dmg() {
    local status
    RELEASE_DMG_BORROW_LOCK=1
    if release_dmg_main "$1" --replace-after-app-staple; then
        status=0
    else
        status=$?
    fi
    RELEASE_DMG_BORROW_LOCK=0
    release_dmg_cleanup || true
    return "$status"
}

release_notary_json_field() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

release_notary_log_has_no_issues() {
    /usr/bin/python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)

issues = payload.get("issues", "missing")
if payload.get("status") != "Accepted" or issues not in (None, []):
    raise SystemExit(1)
PY
}

release_notary_cleanup() {
    local status=$?
    local cleanup_failed=0
    if [ -n "$RELEASE_NOTARY_MOUNT" ] && [ -d "$RELEASE_NOTARY_MOUNT" ]; then
        release_detach_disk_image release_notary_hdiutil "$RELEASE_NOTARY_MOUNT" || true
        /bin/rmdir "$RELEASE_NOTARY_MOUNT" >/dev/null 2>&1 || true
    fi
    if [ "$RELEASE_NOTARY_OWNS_LOCK" -eq 1 ]; then
        release_lock_release || cleanup_failed=1
        [ "$cleanup_failed" -ne 0 ] || RELEASE_NOTARY_OWNS_LOCK=0
    fi
    if [ "$status" -eq 0 ] && [ "$cleanup_failed" -ne 0 ]; then return 1; fi
    return "$status"
}

release_notary_process_submission() {
    local prefix="$1" kind="$2" artifact="$3" profile="$4" timeout="$5" manifest="$6" root="$7"
    local submitted_key="${prefix}_NOTARY_SUBMITTED_SHA256"
    local id_key="${prefix}_NOTARY_SUBMISSION_ID"
    local status_key="${prefix}_NOTARY_STATUS"
    local log_sha_key="${prefix}_NOTARY_LOG_SHA256"
    local submit_json="$root/${kind}-notary-submit.json"
    local wait_json="$root/${kind}-notary-wait.json"
    local notary_log="$root/${kind}-notary-log.json"
    local temp current_sha recorded_sha submission_id status

    current_sha="$(release_sha256 "$artifact")" || return 1
    recorded_sha="$(release_manifest_get "$manifest" "$submitted_key" 2>/dev/null || true)"
    submission_id="$(release_manifest_get "$manifest" "$id_key" 2>/dev/null || true)"
    if [ -n "$recorded_sha" ]; then
        [ "$recorded_sha" = "$current_sha" ] || {
            release_error "$kind artifact bytes changed after notarization submission was prepared."
            return 1
        }
        if [ -z "$submission_id" ]; then
            if [ -f "$submit_json" ] && [ ! -L "$submit_json" ]; then
                submission_id="$(release_notary_json_field "$submit_json" id)" || return 1
                [[ "$submission_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
                    release_error "$kind submission response has no valid UUID."
                    return 1
                }
                release_manifest_set "$manifest" "$id_key" "$submission_id" || return 1
            else
                release_error "$kind submission outcome is ambiguous; the hash was journaled but no response/UUID exists. Refusing automatic resubmission."
                return 1
            fi
        fi
    else
        [ -z "$submission_id" ] || { release_error "$kind submission UUID exists without its submitted hash."; return 1; }
        [ ! -e "$submit_json" ] && [ ! -L "$submit_json" ] || { release_error "untracked $submit_json already exists."; return 1; }
        release_manifest_set "$manifest" "$submitted_key" "$current_sha" || return 1
        temp="${submit_json}.new.$$"
        if ! release_notary_xcrun notarytool submit "$artifact" \
            --keychain-profile "$profile" \
            --no-wait \
            --output-format json >"$temp"; then
            [ ! -s "$temp" ] || /bin/mv "$temp" "$submit_json"
            release_error "$kind submission failed or has an unknown outcome; inspect retained evidence before any retry."
            return 1
        fi
        /bin/mv "$temp" "$submit_json" || return 1
        submission_id="$(release_notary_json_field "$submit_json" id)" || return 1
        [[ "$submission_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
            release_error "$kind submission response has no valid UUID."
            return 1
        }
        release_manifest_set "$manifest" "$id_key" "$submission_id" || return 1
    fi

    temp="${wait_json}.new.$$"
    if ! release_notary_xcrun notarytool wait "$submission_id" \
        --keychain-profile "$profile" \
        --timeout "$timeout" \
        --output-format json >"$temp"; then
        [ ! -s "$temp" ] || /bin/mv -f "$temp" "$wait_json"
        release_error "$kind notarization did not complete successfully; resume UUID $submission_id, never blindly resubmit."
        return 1
    fi
    /bin/mv -f "$temp" "$wait_json" || return 1
    status="$(release_notary_json_field "$wait_json" status)" || return 1
    [ "$status" = Accepted ] || {
        release_error "$kind notarization status is '$status', not Accepted."
        return 1
    }
    temp="${notary_log}.new.$$"
    [ ! -e "$temp" ] && [ ! -L "$temp" ] || return 1
    release_notary_xcrun notarytool log --keychain-profile "$profile" "$submission_id" "$temp" || return 1
    [ -s "$temp" ] || { release_error "$kind notarization log is empty."; return 1; }
    release_notary_log_has_no_issues "$temp" || {
        release_error "$kind notarization log is malformed or reports issues."
        return 1
    }
    /bin/mv -f "$temp" "$notary_log" || return 1
    release_manifest_set "$manifest" "$status_key" Accepted || return 1
    release_manifest_set "$manifest" "$log_sha_key" "$(release_sha256 "$notary_log")" || return 1
}

release_notary_finalize_app() {
    local root="$1" manifest="$2" app="$3" app_zip="$4" profile="$5" timeout="$6" version="$7" build="$8"
    local stapled_zip stored_sha
    if [ "$(release_manifest_get "$manifest" APP_STAPLED 2>/dev/null || true)" = 1 ]; then
        release_notary_xcrun stapler validate "$app" || return 1
        release_notary_verify_artifact "$app" || return 1
        stapled_zip="$root/LetItBrew-${version}-${build}.stapled-app.zip"
        [ -f "$stapled_zip" ] && [ ! -L "$stapled_zip" ] || { release_error "stapled app evidence ZIP is missing."; return 1; }
        stored_sha="$(release_manifest_get "$manifest" APP_STAPLED_ZIP_SHA256)" || return 1
        [ "$(release_sha256 "$stapled_zip")" = "$stored_sha" ] || { release_error "stapled app evidence ZIP drifted."; return 1; }
        return 0
    fi
    release_notary_process_submission APP app "$app_zip" "$profile" "$timeout" "$manifest" "$root" || return 1
    release_notary_xcrun stapler staple "$app" || return 1
    release_notary_xcrun stapler validate "$app" || return 1
    release_notary_verify_artifact "$app" || return 1
    stapled_zip="$root/LetItBrew-${version}-${build}.stapled-app.zip"
    [ ! -e "$stapled_zip" ] && [ ! -L "$stapled_zip" ] || { release_error "$stapled_zip already exists."; return 1; }
    release_notary_ditto -c -k --sequesterRsrc --keepParent "$app" "$stapled_zip" || return 1
    release_manifest_set "$manifest" APP_STAPLED_ZIP "$(/usr/bin/basename "$stapled_zip")" || return 1
    release_manifest_set "$manifest" APP_STAPLED_ZIP_SHA256 "$(release_sha256 "$stapled_zip")" || return 1
    release_manifest_set "$manifest" APP_STAPLED 1 || return 1
}

release_notary_final_verify_dmg() {
    local dmg="$1" version="$2" build="$3"
    local mounted_app entry_count package_count
    release_notary_xcrun stapler validate "$dmg" || return 1
    release_notary_codesign --verify --strict "$dmg" || return 1
    release_notary_hdiutil verify "$dmg" || return 1
    RELEASE_NOTARY_MOUNT="$(/usr/bin/mktemp -d /private/tmp/LetItBrewNotaryMount.XXXXXX)" || return 1
    release_notary_hdiutil attach -readonly -nobrowse -mountpoint "$RELEASE_NOTARY_MOUNT" "$dmg" >/dev/null || return 1
    mounted_app="$RELEASE_NOTARY_MOUNT/Let It Brew.app"
    [ -d "$mounted_app" ] && [ ! -L "$mounted_app" ] || return 1
    [ -L "$RELEASE_NOTARY_MOUNT/Applications" ] && [ "$(/usr/bin/readlink "$RELEASE_NOTARY_MOUNT/Applications")" = /Applications ] || return 1
    entry_count="$(/usr/bin/find "$RELEASE_NOTARY_MOUNT" -mindepth 1 -maxdepth 1 -print | /usr/bin/awk 'END { print NR + 0 }')"
    package_count="$(/usr/bin/find "$RELEASE_NOTARY_MOUNT" -name '*.pkg' -print | /usr/bin/awk 'END { print NR + 0 }')"
    [ "$entry_count" -eq 2 ] && [ "$package_count" -eq 0 ] || return 1
    [ "$(release_plist_value "$mounted_app/Contents/Info.plist" CFBundleShortVersionString)" = "$version" ] || return 1
    [ "$(release_plist_value "$mounted_app/Contents/Info.plist" CFBundleVersion)" = "$build" ] || return 1
    release_notary_xcrun stapler validate "$mounted_app" || return 1
    release_notary_verify_artifact "$mounted_app" || return 1
    release_notary_spctl --assess --type execute --verbose=4 "$mounted_app" || return 1
    release_detach_disk_image release_notary_hdiutil "$RELEASE_NOTARY_MOUNT" || return 1
    /bin/rmdir "$RELEASE_NOTARY_MOUNT" || return 1
    RELEASE_NOTARY_MOUNT=""
    release_notary_spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" || return 1
}

release_notary_write_sums() {
    local root="$1" dmg="$2" manifest="$3" sums="$4" temp
    local dmg_name manifest_name dmg_sha manifest_sha
    dmg_name="$(/usr/bin/basename "$dmg")" || return 1
    manifest_name="$(/usr/bin/basename "$manifest")" || return 1
    dmg_sha="$(release_sha256 "$dmg")" || return 1
    manifest_sha="$(release_sha256 "$manifest")" || return 1
    temp="${sums}.new.$$"
    [ "$(cd "$root" && /bin/pwd -P)" = "$(cd "$(dirname "$dmg")" && /bin/pwd -P)" ] || return 1
    [ "$(cd "$root" && /bin/pwd -P)" = "$(cd "$(dirname "$manifest")" && /bin/pwd -P)" ] || return 1
    # This exact two-space format is parsed by the in-app updater. Do not rely
    # on a checksum tool's presentation defaults for a release API contract.
    printf '%s  %s\n%s  %s\n' \
        "$dmg_sha" "$dmg_name" \
        "$manifest_sha" "$manifest_name" >"$temp" || return 1
    /bin/mv -f "$temp" "$sums"
}

release_notary_write_latest_alias() {
    local root="$1" dmg="$2" alias temp dmg_sha
    alias="$root/LetItBrew.dmg"
    temp="${alias}.new.$$"
    [ -f "$dmg" ] && [ ! -L "$dmg" ] || return 1
    [ "$(cd "$root" && /bin/pwd -P)" = "$(cd "$(dirname "$dmg")" && /bin/pwd -P)" ] || return 1
    dmg_sha="$(release_sha256 "$dmg")" || return 1
    if [ -e "$alias" ] || [ -L "$alias" ]; then
        [ -f "$alias" ] && [ ! -L "$alias" ] || return 1
        [ "$(release_sha256 "$alias")" = "$dmg_sha" ] || return 1
        /bin/chmod 0600 "$alias" || return 1
        [ "$(/usr/bin/stat -f '%Lp' "$alias")" = 600 ] || return 1
        return 0
    fi
    [ ! -e "$temp" ] && [ ! -L "$temp" ] || return 1
    if ! release_notary_ditto "$dmg" "$temp"; then
        /bin/rm -f "$temp"
        return 1
    fi
    /bin/chmod 0600 "$temp" || { /bin/rm -f "$temp"; return 1; }
    [ "$(release_sha256 "$temp")" = "$dmg_sha" ] || { /bin/rm -f "$temp"; return 1; }
    /bin/ln "$temp" "$alias" || { /bin/rm -f "$temp"; return 1; }
    /bin/rm "$temp" || return 1
    [ -f "$alias" ] && [ ! -L "$alias" ] && \
        [ "$(/usr/bin/stat -f '%Lp' "$alias")" = 600 ] && \
        [ "$(release_sha256 "$alias")" = "$dmg_sha" ]
}

release_notary_usage() {
    echo "usage: scripts/notarize-release.sh <release-root> --keychain-profile <profile> [--timeout 30m]" >&2
}

release_notary_main() {
    local requested_root="${1:-}" profile="" timeout=30m
    local root manifest version build app app_zip app_zip_name app_zip_sha
    local dmg dmg_name submitted_dmg submitted_sha current_sha sums final_sha already_complete=0
    [ -n "$requested_root" ] || { release_notary_usage; return 2; }
    shift || true
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --keychain-profile)
                [ "$#" -ge 2 ] || { release_notary_usage; return 2; }
                profile="$2"
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || { release_notary_usage; return 2; }
                timeout="$2"
                shift 2
                ;;
            -h|--help) release_notary_usage; return 0 ;;
            *) release_error "unknown argument '$1'. Raw credential flags are never accepted."; release_notary_usage; return 2 ;;
        esac
    done
    [ "$(release_effective_uid)" -ne 0 ] || { release_error "refusing notarization as root."; return 1; }
    [[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
        release_error "a simple named notarytool Keychain profile is required."
        return 1
    }
    [[ "$timeout" =~ ^[1-9][0-9]*[smh]?$ ]] || { release_error "timeout must be a positive notarytool duration such as 30m."; return 1; }
    [ -x /usr/bin/python3 ] || { release_error "Xcode's /usr/bin/python3 is required for strict notarization-log JSON validation."; return 1; }
    root="$(release_canonical_existing_private_tmp_dir "$requested_root")" || { release_error "invalid release root."; return 1; }
    release_lock_acquire "$root" notarize || return 1
    RELEASE_NOTARY_OWNS_LOCK=1
    manifest="$(release_find_manifest "$root")" || { release_error "expected exactly one release manifest."; return 1; }
    version="$(release_manifest_get "$manifest" MARKETING_VERSION)" || return 1
    build="$(release_manifest_get "$manifest" BUILD)" || return 1
    release_version_is_canonical "$version" || { release_error "manifest marketing version is not canonical major.minor.patch."; return 1; }
    [[ "$build" =~ ^[0-9]+$ ]] || { release_error "manifest build is not decimal."; return 1; }
    release_require_manifest_identity "$manifest" TEAM_ID "$LETITBREW_RELEASE_TEAM_ID" || return 1
    release_require_manifest_identity "$manifest" BUNDLE_ID "$LETITBREW_RELEASE_APP_ID" || return 1
    app="$root/export/Let It Brew.app"
    [ -d "$app" ] && [ ! -L "$app" ] || { release_error "missing exported app."; return 1; }
    release_notary_verify_artifact "$app" || return 1
    app_zip_name="$(release_manifest_get "$manifest" APP_NOTARY_ZIP)" || return 1
    case "$app_zip_name" in */*|.|..) release_error "unsafe app ZIP name in manifest."; return 1 ;; esac
    app_zip="$root/$app_zip_name"
    [ -f "$app_zip" ] && [ ! -L "$app_zip" ] || { release_error "missing app notarization ZIP."; return 1; }
    app_zip_sha="$(release_manifest_get "$manifest" APP_NOTARY_ZIP_SHA256)" || return 1
    [ "$(release_sha256 "$app_zip")" = "$app_zip_sha" ] || { release_error "app notarization ZIP drifted from build manifest."; return 1; }
    dmg_name="$(release_manifest_get "$manifest" DMG_FILENAME)" || return 1
    case "$dmg_name" in */*|.|..) release_error "unsafe DMG filename in manifest."; return 1 ;; esac
    [ "$dmg_name" = "LetItBrew-${version}.dmg" ] || { release_error "DMG filename is not the required versioned name."; return 1; }
    dmg="$root/$dmg_name"
    [ -f "$dmg" ] && [ ! -L "$dmg" ] || { release_error "create and verify the pre-notarization DMG first."; return 1; }

    if [ "$(release_manifest_get "$manifest" NOTARIZATION_COMPLETE 2>/dev/null || true)" = 1 ]; then
        final_sha="$(release_manifest_get "$manifest" DMG_FINAL_STAPLED_SHA256)" || return 1
        [ "$(release_sha256 "$dmg")" = "$final_sha" ] || { release_error "completed final DMG drifted from its manifest."; return 1; }
        release_notary_final_verify_dmg "$dmg" "$version" "$build" || return 1
        already_complete=1
    fi
    if [ "$already_complete" -eq 1 ]; then
        release_notary_write_latest_alias "$root" "$dmg" || return 1
        echo "PASS: notarization was already complete and final evidence still verifies"
        release_notary_cleanup || return 1
        return 0
    fi

    echo "== Let It Brew notarization =="
    release_note "app submission: $app_zip_name"
    release_note "profile: named Keychain profile (name is not recorded)"
    release_note "timeout: $timeout"
    release_notary_finalize_app "$root" "$manifest" "$app" "$app_zip" "$profile" "$timeout" "$version" "$build" || return 1

    if [ -z "$(release_manifest_get "$manifest" DMG_NOTARY_SUBMISSION_ID 2>/dev/null || true)" ]; then
        release_notary_create_final_dmg "$root" || return 1
    fi
    [ "$(release_manifest_get "$manifest" DMG_PHASE)" = app-stapled ] || { release_error "final DMG was not built from the stapled app."; return 1; }
    current_sha="$(release_sha256 "$dmg")" || return 1
    submitted_dmg="$root/LetItBrew-${version}.notary-submission.dmg"
    if [ -e "$submitted_dmg" ] || [ -L "$submitted_dmg" ]; then
        [ -f "$submitted_dmg" ] && [ ! -L "$submitted_dmg" ] || return 1
        submitted_sha="$(release_sha256 "$submitted_dmg")" || return 1
        [ "$submitted_sha" = "$current_sha" ] || {
            [ -n "$(release_manifest_get "$manifest" DMG_NOTARY_SUBMISSION_ID 2>/dev/null || true)" ] || { release_error "stale submitted-DMG evidence exists."; return 1; }
        }
    else
        [ -z "$(release_manifest_get "$manifest" DMG_NOTARY_SUBMISSION_ID 2>/dev/null || true)" ] || { release_error "DMG submission evidence is missing."; return 1; }
        release_notary_ditto "$dmg" "$submitted_dmg" || return 1
    fi
    release_manifest_set "$manifest" DMG_NOTARY_SUBMITTED_FILE "$(/usr/bin/basename "$submitted_dmg")" || return 1
    release_notary_process_submission DMG dmg "$submitted_dmg" "$profile" "$timeout" "$manifest" "$root" || return 1
    submitted_sha="$(release_manifest_get "$manifest" DMG_NOTARY_SUBMITTED_SHA256)" || return 1
    if release_notary_xcrun stapler validate "$dmg" >/dev/null 2>&1; then
        : # Resume after a successful staple that preceded final manifest journaling.
    else
        [ "$(release_sha256 "$dmg")" = "$submitted_sha" ] || { release_error "DMG changed between submission and stapling."; return 1; }
        release_notary_xcrun stapler staple "$dmg" || return 1
    fi
    release_notary_final_verify_dmg "$dmg" "$version" "$build" || return 1
    release_manifest_set "$manifest" DMG_FINAL_STAPLED_SHA256 "$(release_sha256 "$dmg")" || return 1
    release_manifest_set "$manifest" DMG_SHA256 "$(release_sha256 "$dmg")" || return 1
    release_manifest_set "$manifest" NOTARIZATION_COMPLETE 1 || return 1
    sums="$root/LetItBrew-${version}-SHA256SUMS"
    release_notary_write_sums "$root" "$dmg" "$manifest" "$sums" || return 1
    release_notary_write_latest_alias "$root" "$dmg" || return 1

    release_notary_cleanup || return 1
    RELEASE_NOTARY_MOUNT=""

    echo "PASS: app and DMG notarization, stapling, and validation complete"
    release_note "final DMG: $dmg"
    release_note "website alias: $root/LetItBrew.dmg"
    release_note "checksums: $sums"
    release_note "nothing was uploaded to a publication channel"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -e
    umask 077
    trap release_notary_cleanup EXIT
    trap 'exit 130' INT TERM HUP
    release_notary_main "$@"
fi
