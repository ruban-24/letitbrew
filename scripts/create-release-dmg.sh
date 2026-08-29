#!/bin/bash
# Create and verify the exact Let It Brew DMG. This does not notarize or publish it.
set -uo pipefail

RELEASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
# shellcheck source=lib-direct-distribution.sh
source "$RELEASE_SCRIPT_DIR/lib-direct-distribution.sh"

RELEASE_DMG_STAGE=""
RELEASE_DMG_MOUNT=""
RELEASE_DMG_WORKING=""
RELEASE_DMG_OWNS_LOCK=0

release_dmg_ditto() {
    /usr/bin/ditto "$@"
}

release_dmg_codesign() {
    /usr/bin/codesign "$@"
}

release_dmg_hdiutil() {
    /usr/bin/hdiutil "$@"
}

release_dmg_setfile() {
    /usr/bin/SetFile "$@"
}

release_dmg_osascript() {
    /usr/bin/osascript "$@"
}

release_dmg_verify_artifact() {
    "$RELEASE_SCRIPT_DIR/verify-artifact.sh" "$1" --release
}

release_dmg_security_identities() {
    /usr/bin/security find-identity -v -p codesigning
}

release_dmg_cleanup() {
    local status=$?
    local cleanup_failed=0
    if [ -n "$RELEASE_DMG_MOUNT" ] && [ -d "$RELEASE_DMG_MOUNT" ]; then
        release_detach_disk_image release_dmg_hdiutil "$RELEASE_DMG_MOUNT" || true
        /bin/rmdir "$RELEASE_DMG_MOUNT" >/dev/null 2>&1 || true
    fi
    if [ -n "$RELEASE_DMG_WORKING" ] && [ -f "$RELEASE_DMG_WORKING" ]; then
        /bin/rm -f "$RELEASE_DMG_WORKING"
    fi
    if [ -n "$RELEASE_DMG_STAGE" ] && [ -d "$RELEASE_DMG_STAGE" ]; then
        /bin/rm -rf "$RELEASE_DMG_STAGE"
    fi
    if [ "$RELEASE_DMG_OWNS_LOCK" -eq 1 ]; then
        release_lock_release || cleanup_failed=1
        [ "$cleanup_failed" -ne 0 ] || RELEASE_DMG_OWNS_LOCK=0
    fi
    if [ "$status" -eq 0 ] && [ "$cleanup_failed" -ne 0 ]; then return 1; fi
    return "$status"
}

release_dmg_identity_is_valid() {
    local expected_hash="$1"
    local output line count=0 hash
    output="$(release_dmg_security_identities 2>&1)" || return 1
    while IFS= read -r line; do
        case "$line" in
            *\"Developer\ ID\ Application:*"($LETITBREW_RELEASE_TEAM_ID)\"")
                hash="$(printf '%s\n' "$line" | /usr/bin/awk '{ print $2 }')"
                if [ "$hash" = "$expected_hash" ]; then count=$((count + 1)); fi
                ;;
        esac
    done <<<"$output"
    [ "$count" -eq 1 ]
}

release_dmg_create_image() {
    local stage="$1" destination="$2" volume_name="$3"
    local working="${destination%.dmg}.read-write.$$.dmg" finder_disk
    [ ! -e "$working" ] && [ ! -L "$working" ] || return 1
    RELEASE_DMG_WORKING="$working"
    release_dmg_hdiutil create \
        -fs 'HFS+' \
        -format UDRW \
        -volname "$volume_name" \
        -srcfolder "$stage" \
        -nospotlight \
        "$working" >/dev/null || return 1
    RELEASE_DMG_MOUNT="$(/usr/bin/mktemp -d /private/tmp/LetItBrewDMGMount.XXXXXX)" || return 1
    release_dmg_hdiutil attach \
        -readwrite \
        -noverify \
        -noautoopen \
        -mountpoint "$RELEASE_DMG_MOUNT" \
        "$working" >/dev/null || return 1
    finder_disk="$(/usr/bin/basename "$RELEASE_DMG_MOUNT")" || return 1
    release_dmg_osascript "$RELEASE_SCRIPT_DIR/configure-release-dmg.applescript" "$finder_disk" || return 1
    release_dmg_setfile -c icnC "$RELEASE_DMG_MOUNT/.VolumeIcon.icns" || return 1
    release_dmg_setfile -a V "$RELEASE_DMG_MOUNT/.VolumeIcon.icns" || return 1
    release_dmg_setfile -a V "$RELEASE_DMG_MOUNT/.background" || return 1
    release_dmg_setfile -a C "$RELEASE_DMG_MOUNT" || return 1
    /bin/rm -rf "$RELEASE_DMG_MOUNT/.fseventsd" || return 1
    release_dmg_payload_is_valid "$RELEASE_DMG_MOUNT" || return 1
    release_detach_disk_image release_dmg_hdiutil "$RELEASE_DMG_MOUNT" || return 1
    /bin/rmdir "$RELEASE_DMG_MOUNT" || return 1
    RELEASE_DMG_MOUNT=""
    release_dmg_hdiutil convert \
        "$working" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$destination" >/dev/null || return 1
    [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
    /bin/rm "$working" || return 1
    RELEASE_DMG_WORKING=""
}

release_dmg_verify_image() {
    local dmg="$1" expected_version="$2" expected_build="$3"
    local mounted_app mounted_version mounted_build
    release_dmg_hdiutil verify "$dmg" || return 1
    RELEASE_DMG_MOUNT="$(/usr/bin/mktemp -d /private/tmp/LetItBrewDMGMount.XXXXXX)" || return 1
    release_dmg_hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$RELEASE_DMG_MOUNT" "$dmg" >/dev/null || return 1
    mounted_app="$RELEASE_DMG_MOUNT/Let It Brew.app"
    release_dmg_payload_is_valid "$RELEASE_DMG_MOUNT" || {
        release_error "DMG payload or hidden presentation assets do not match the release contract."
        return 1
    }
    mounted_version="$(release_plist_value "$mounted_app/Contents/Info.plist" CFBundleShortVersionString)" || return 1
    mounted_build="$(release_plist_value "$mounted_app/Contents/Info.plist" CFBundleVersion)" || return 1
    [ "$mounted_version" = "$expected_version" ] && [ "$mounted_build" = "$expected_build" ] || {
        release_error "mounted app version/build does not match the manifest."
        return 1
    }
    release_dmg_verify_artifact "$mounted_app" || return 1
    release_detach_disk_image release_dmg_hdiutil "$RELEASE_DMG_MOUNT" || return 1
    /bin/rmdir "$RELEASE_DMG_MOUNT" || return 1
    RELEASE_DMG_MOUNT=""
}

release_dmg_usage() {
    echo "usage: scripts/create-release-dmg.sh <release-root> [--replace-after-app-staple]" >&2
}

release_dmg_main() {
    local requested_root="${1:-}"
    local replace=0 root manifest version build commit identity app info
    local target temporary name phase app_stapled existing_sha
    local background volume_icon stage_entry_count stage_background_count
    [ -n "$requested_root" ] || { release_dmg_usage; return 2; }
    shift || true
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --replace-after-app-staple) replace=1; shift ;;
            -h|--help) release_dmg_usage; return 0 ;;
            *) release_error "unknown argument '$1'."; release_dmg_usage; return 2 ;;
        esac
    done
    [ "$(release_effective_uid)" -ne 0 ] || { release_error "refusing to create a release DMG as root."; return 1; }
    root="$(release_canonical_existing_private_tmp_dir "$requested_root")" || {
        release_error "release root must be a non-symlinked directory beneath /private/tmp."
        return 1
    }
    if [ "${RELEASE_DMG_BORROW_LOCK:-0}" = 1 ]; then
        release_lock_is_owned "$root" || { release_error "borrowed release lock is not owned by this transaction."; return 1; }
    else
        release_lock_acquire "$root" dmg || return 1
        RELEASE_DMG_OWNS_LOCK=1
    fi
    manifest="$(release_find_manifest "$root")" || { release_error "expected exactly one release manifest."; return 1; }
    version="$(release_manifest_get "$manifest" MARKETING_VERSION)" || return 1
    build="$(release_manifest_get "$manifest" BUILD)" || return 1
    commit="$(release_manifest_get "$manifest" GIT_COMMIT)" || return 1
    identity="$(release_manifest_get "$manifest" SIGNING_IDENTITY_SHA1)" || return 1
    release_version_is_canonical "$version" && [[ "$build" =~ ^[0-9]+$ ]] && [[ "$commit" =~ ^[0-9a-f]{40}$ ]] && [[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]] || {
        release_error "release manifest identity fields are malformed."
        return 1
    }
    release_require_manifest_identity "$manifest" TEAM_ID "$LETITBREW_RELEASE_TEAM_ID" || return 1
    release_require_manifest_identity "$manifest" BUNDLE_ID "$LETITBREW_RELEASE_APP_ID" || return 1
    release_dmg_identity_is_valid "$identity" || {
        release_error "the manifest's exact Developer ID identity is not currently valid for Team $LETITBREW_RELEASE_TEAM_ID."
        return 1
    }
    app="$root/export/Let It Brew.app"
    info="$app/Contents/Info.plist"
    background="$RELEASE_SCRIPT_DIR/assets/dmg-background.png"
    volume_icon="$app/Contents/Resources/AppIcon.icns"
    [ -d "$app" ] && [ ! -L "$app" ] || { release_error "missing exported Let It Brew.app."; return 1; }
    [ -f "$background" ] && [ ! -L "$background" ] || { release_error "missing trusted DMG background."; return 1; }
    [ -f "$volume_icon" ] && [ ! -L "$volume_icon" ] || { release_error "release app is missing AppIcon.icns."; return 1; }
    [ "$(release_plist_value "$info" CFBundleShortVersionString)" = "$version" ] || { release_error "app marketing version drifted from manifest."; return 1; }
    [ "$(release_plist_value "$info" CFBundleVersion)" = "$build" ] || { release_error "app build drifted from manifest."; return 1; }
    release_dmg_verify_artifact "$app" || return 1

    name="LetItBrew-${version}.dmg"
    target="$root/$name"
    temporary="$root/.${name%.dmg}.new.$$.dmg"
    [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || { release_error "temporary DMG path already exists."; return 1; }
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ "$replace" -eq 1 ] || { release_error "$target already exists; refusing to overwrite it."; return 1; }
        [ -f "$target" ] && [ ! -L "$target" ] || { release_error "existing DMG is not an ordinary file."; return 1; }
    elif [ "$replace" -eq 1 ]; then
        release_error "replacement mode requires an existing pre-notarization DMG."
        return 1
    fi
    if [ "$replace" -eq 1 ]; then
        app_stapled="$(release_manifest_get "$manifest" APP_STAPLED 2>/dev/null || true)"
        [ "$app_stapled" = 1 ] || { release_error "replacement mode requires a validated stapled app."; return 1; }
        phase=app-stapled
        existing_sha="$(release_sha256 "$target")" || return 1
        release_manifest_set "$manifest" DMG_PRE_APP_STAPLE_SHA256 "$existing_sha" || return 1
    else
        phase=pre-notarization
    fi

    RELEASE_DMG_STAGE="$(/usr/bin/mktemp -d /private/tmp/LetItBrewDMGStage.XXXXXX)" || return 1
    /bin/chmod 700 "$RELEASE_DMG_STAGE" || return 1
    release_dmg_ditto "$app" "$RELEASE_DMG_STAGE/Let It Brew.app" || return 1
    /bin/mkdir "$RELEASE_DMG_STAGE/.background" || return 1
    release_dmg_ditto "$background" "$RELEASE_DMG_STAGE/.background/dmg-background.png" || return 1
    release_dmg_ditto "$volume_icon" "$RELEASE_DMG_STAGE/.VolumeIcon.icns" || return 1
    /bin/ln -s /Applications "$RELEASE_DMG_STAGE/Applications" || return 1
    stage_entry_count="$(/usr/bin/find "$RELEASE_DMG_STAGE" -mindepth 1 -maxdepth 1 -print | /usr/bin/awk 'END { print NR + 0 }')" || return 1
    stage_background_count="$(/usr/bin/find "$RELEASE_DMG_STAGE/.background" -mindepth 1 -maxdepth 1 -print | /usr/bin/awk 'END { print NR + 0 }')" || return 1
    [ "$stage_entry_count" -eq 4 ] && [ "$stage_background_count" -eq 1 ] || return 1
    [ "$(/usr/bin/find "$RELEASE_DMG_STAGE" -name '*.pkg' -print | /usr/bin/awk 'END { print NR + 0 }')" -eq 0 ] || {
        release_error "refusing to package an installer package."
        return 1
    }
    release_dmg_create_image "$RELEASE_DMG_STAGE" "$temporary" "Let It Brew $version" || return 1
    [ -f "$temporary" ] && [ ! -L "$temporary" ] || { release_error "hdiutil did not create the expected DMG."; return 1; }
    release_dmg_codesign --force --sign "$identity" --timestamp "$temporary" || return 1
    release_dmg_codesign --verify --strict "$temporary" || return 1
    release_dmg_verify_image "$temporary" "$version" "$build" || return 1
    if [ "$replace" -eq 1 ]; then
        /bin/mv -f "$temporary" "$target" || return 1
    else
        /bin/mv "$temporary" "$target" || return 1
    fi
    release_manifest_set "$manifest" DMG_FILENAME "$name" || return 1
    release_manifest_set "$manifest" DMG_PHASE "$phase" || return 1
    release_manifest_set "$manifest" DMG_SHA256 "$(release_sha256 "$target")" || return 1
    release_manifest_set "$manifest" DMG_APPLICATIONS_SYMLINK "$LETITBREW_DMG_APPLICATIONS_SYMLINK" || return 1
    release_manifest_set "$manifest" DMG_TOP_LEVEL_ENTRIES "$LETITBREW_DMG_TOP_LEVEL_ENTRIES" || return 1
    release_manifest_set "$manifest" DMG_BACKGROUND_ENTRY "$LETITBREW_DMG_BACKGROUND_ENTRY" || return 1

    release_dmg_cleanup || return 1
    RELEASE_DMG_STAGE=""
    echo "PASS: signed DMG created and verified"
    release_note "DMG: $target"
    release_note "phase: $phase"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -e
    umask 077
    trap release_dmg_cleanup EXIT
    trap 'exit 130' INT TERM HUP
    release_dmg_main "$@"
fi
