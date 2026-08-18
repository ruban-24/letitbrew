#!/bin/bash
# Build and export an exact Developer ID release without publishing it.
set -uo pipefail

RELEASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
# shellcheck source=lib-direct-distribution.sh
source "$RELEASE_SCRIPT_DIR/lib-direct-distribution.sh"
# shellcheck source=lib-v0.5.1-update-support-contract.sh
source "$RELEASE_SCRIPT_DIR/lib-v0.5.1-update-support-contract.sh"

release_build_security_identities() {
    /usr/bin/security find-identity -v -p codesigning
}

release_build_xcodegen() {
    local tool="$1"
    shift
    "$tool" "$@"
}

release_build_xcodebuild() {
    /usr/bin/xcodebuild "$@"
}

release_build_verify() {
    "$RELEASE_SCRIPT_DIR/verify-artifact.sh" "$1" --release &&
        release_build_verify_v051_compatibility "$1"
}

release_build_verify_v051_compatibility() {
    v051_update_support_contract_accepts "$1" || {
        release_error "exported app is incompatible with the v0.5.1 UpdateSupport inventory contract."
        return 1
    }
}

release_build_ditto() {
    /usr/bin/ditto "$@"
}

release_build_codesign() {
    /usr/bin/codesign "$@"
}

release_build_plutil() {
    /usr/bin/plutil "$@"
}

release_build_require_tools() {
    local xcodegen_path
    xcodegen_path="$(command -v xcodegen 2>/dev/null)" || {
        release_error "xcodegen is required."
        return 1
    }
    case "$xcodegen_path" in /*) ;; *) release_error "xcodegen did not resolve to an absolute path."; return 1 ;; esac
    [ -x "$xcodegen_path" ] || {
        release_error "xcodegen is not executable at $xcodegen_path."
        return 1
    }
    RELEASE_XCODEGEN="$xcodegen_path"
    for tool in /usr/bin/git /usr/bin/security /usr/bin/xcodebuild /usr/bin/ditto /usr/bin/shasum /usr/libexec/PlistBuddy; do
        [ -x "$tool" ] || { release_error "required tool is missing: $tool"; return 1; }
    done
    [ -x "$RELEASE_SCRIPT_DIR/verify-artifact.sh" ] || {
        release_error "verify-artifact.sh is missing or not executable."
        return 1
    }
}

release_build_require_clean_tree() {
    local repo="$1"
    local status
    status="$(/usr/bin/git -C "$repo" status --porcelain=v1 --untracked-files=all)" || {
        release_error "git status failed."
        return 1
    }
    [ -z "$status" ] || {
        release_error "release builds require a completely clean tracked and untracked worktree."
        printf '%s\n' "$status" >&2
        return 1
    }
}

release_build_select_identity() {
    local output line hash name count=0
    output="$(release_build_security_identities 2>&1)" || {
        release_error "could not enumerate code-signing identities."
        return 1
    }
    RELEASE_IDENTITY_HASH=""
    RELEASE_IDENTITY_NAME=""
    while IFS= read -r line; do
        case "$line" in
            *\"Developer\ ID\ Application:*"($LETITBREW_RELEASE_TEAM_ID)\"")
                hash="$(printf '%s\n' "$line" | /usr/bin/awk '{ print $2 }')"
                name="${line#*\"}"
                name="${name%\"*}"
                [[ "$hash" =~ ^[0-9A-Fa-f]{40}$ ]] || continue
                count=$((count + 1))
                RELEASE_IDENTITY_HASH="$hash"
                RELEASE_IDENTITY_NAME="$name"
                ;;
        esac
    done <<<"$output"
    [ "$count" -eq 1 ] || {
        release_error "expected exactly one valid Developer ID Application identity for Team $LETITBREW_RELEASE_TEAM_ID; found $count."
        return 1
    }
}

release_build_write_export_options() {
    local path="$1"
    local identity_hash="$2"
    /bin/cat >"$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>method</key>
    <string>developer-id</string>
    <key>signingCertificate</key>
    <string>$identity_hash</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>stripSwiftSymbols</key>
    <false/>
    <key>teamID</key>
    <string>$LETITBREW_RELEASE_TEAM_ID</string>
</dict>
</plist>
EOF
}

release_build_archive() {
    local repo="$1" derived="$2" archive="$3" identity_hash="$4"
    CLANG_MODULE_CACHE_PATH="$derived/ModuleCache.noindex" \
    SWIFTPM_MODULECACHE_OVERRIDE="$derived/SwiftPMModuleCache.noindex" \
    release_build_xcodebuild \
        -project "$repo/LetItBrew.xcodeproj" \
        -scheme LetItBrew \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$derived" \
        -archivePath "$archive" \
        DEVELOPMENT_TEAM="$LETITBREW_RELEASE_TEAM_ID" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$identity_hash" \
        OTHER_CODE_SIGN_FLAGS=--timestamp \
        ONLY_ACTIVE_ARCH=NO \
        'ARCHS=arm64 x86_64' \
        archive
}

release_build_export() {
    local archive="$1" export_dir="$2" options="$3"
    release_build_xcodebuild \
        -exportArchive \
        -archivePath "$archive" \
        -exportPath "$export_dir" \
        -exportOptionsPlist "$options"
}

release_build_slice_cdhash() {
    local file="$1" arch="$2" info cdhash
    info="$(release_build_codesign -d --arch "$arch" -vvv --verbose=4 "$file" 2>&1)" || return 1
    printf '%s\n' "$info" | /usr/bin/grep -qE '^CodeDirectory .*flags=0x[0-9a-f]*10000\(runtime\)' || return 1
    cdhash="$(printf '%s\n' "$info" | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
    [[ "$cdhash" =~ ^[0-9A-Fa-f]{40}$ ]] || return 1
    printf '%s\n' "$cdhash"
}

release_build_normalized_entitlements() {
    local file="$1"
    local raw normalized

    raw="$(release_build_codesign -d --entitlements - --xml "$file" 2>/dev/null)" || return 1
    [ -n "$raw" ] || return 0
    normalized="$(printf '%s' "$raw" | release_build_plutil -convert xml1 -o - - 2>/dev/null)" || return 1
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

release_build_verify_release_details() {
    local app="$1"
    local main="$app/Contents/MacOS/LetItBrew"
    local daemon="$app/Contents/Library/LaunchServices/LetItBrewDaemon"
    local helper="$app/Contents/Helpers/letitbrew"
    local entitlements get_task_allow file role arch suffix key value
    entitlements="$(release_build_normalized_entitlements "$main")" || {
        release_error "release app entitlements could not be read as a dictionary."
        return 1
    }
    if [ -n "$entitlements" ] && printf '%s\n' "$entitlements" | /usr/bin/grep -Fq '<key>com.apple.security.get-task-allow</key>'; then
        get_task_allow="$(printf '%s' "$entitlements" | release_build_plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - - 2>/dev/null)" || {
            release_error "release app get-task-allow entitlement could not be parsed."
            return 1
        }
        case "$get_task_allow" in
            false) ;;
            true) release_error "release app carries com.apple.security.get-task-allow=true."; return 1 ;;
            *) release_error "release app get-task-allow entitlement is not Boolean."; return 1 ;;
        esac
    fi
    for role in APP DAEMON HELPER; do
        case "$role" in
            APP) file="$main" ;;
            DAEMON) file="$daemon" ;;
            HELPER) file="$helper" ;;
        esac
        for arch in arm64 x86_64; do
            value="$(release_build_slice_cdhash "$file" "$arch")" || {
                release_error "$role $arch slice lacks a native CDHash or hardened runtime."
                return 1
            }
            case "$arch" in arm64) suffix=ARM64 ;; x86_64) suffix=X86_64 ;; esac
            key="${role}_${suffix}_CDHASH"
            printf -v "$key" '%s' "$value"
            export "$key"
        done
    done
}

release_build_usage() {
    echo "usage: scripts/build-release-artifact.sh [--output-root /private/tmp/new-directory]" >&2
}

release_build_main() {
    local requested_output=""
    local repo project commit short_commit default_output output_root
    local derived archive export_dir export_options app info dsyms_zip app_zip manifest
    local actual_version actual_build

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --output-root)
                [ "$#" -ge 2 ] || { release_build_usage; return 2; }
                requested_output="$2"
                shift 2
                ;;
            -h|--help) release_build_usage; return 0 ;;
            *) release_error "unknown argument '$1'."; release_build_usage; return 2 ;;
        esac
    done

    [ "$(release_effective_uid)" -ne 0 ] || {
        release_error "refusing to build a release as root."
        return 1
    }
    repo="$(cd "$RELEASE_SCRIPT_DIR/.." && /bin/pwd -P)" || return 1
    project="$repo/project.yml"
    [ -f "$project" ] || { release_error "missing $project"; return 1; }

    release_build_require_tools || return 1
    release_build_require_clean_tree "$repo" || return 1
    release_read_project_version "$project" || return 1
    commit="$(/usr/bin/git -C "$repo" rev-parse --verify HEAD)" || {
        release_error "could not resolve HEAD."
        return 1
    }
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { release_error "HEAD is not a full Git commit."; return 1; }
    short_commit="${commit:0:12}"
    default_output="/private/tmp/LetItBrewRelease-${RELEASE_MARKETING_VERSION}-${RELEASE_BUILD_VERSION}-${short_commit}"
    [ -n "$requested_output" ] || requested_output="$default_output"
    output_root="$(release_canonical_new_private_tmp_path "$requested_output")" || {
        release_error "output root must be a new, non-symlinked directory directly beneath an existing /private/tmp directory."
        return 1
    }

    release_build_select_identity || return 1
    /bin/mkdir -m 700 "$output_root" || return 1
    derived="$output_root/DerivedData"
    archive="$output_root/LetItBrew.xcarchive"
    export_dir="$output_root/export"
    export_options="$output_root/ExportOptions.plist"
    manifest="$output_root/LetItBrew-${RELEASE_MARKETING_VERSION}-${RELEASE_BUILD_VERSION}.manifest"
    app="$export_dir/Let It Brew.app"
    info="$app/Contents/Info.plist"
    app_zip="$output_root/LetItBrew-${RELEASE_MARKETING_VERSION}-${RELEASE_BUILD_VERSION}.app-notary.zip"
    dsyms_zip="$output_root/LetItBrew-${RELEASE_MARKETING_VERSION}-${RELEASE_BUILD_VERSION}.dSYMs.zip"

    echo "== Let It Brew Developer ID build =="
    release_note "version: $RELEASE_MARKETING_VERSION ($RELEASE_BUILD_VERSION)"
    release_note "commit: $commit"
    release_note "identity: $RELEASE_IDENTITY_NAME"
    release_note "workspace: $output_root"

    release_build_xcodegen "$RELEASE_XCODEGEN" generate \
        --spec "$project" --project "$repo" --project-root "$repo" --no-env || return 1
    release_build_require_clean_tree "$repo" || {
        release_error "project generation changed release inputs."
        return 1
    }
    release_build_write_export_options "$export_options" "$RELEASE_IDENTITY_HASH" || return 1
    release_build_archive "$repo" "$derived" "$archive" "$RELEASE_IDENTITY_HASH" || return 1
    [ -d "$archive/dSYMs" ] || { release_error "archive did not retain dSYMs."; return 1; }
    release_build_export "$archive" "$export_dir" "$export_options" || return 1
    [ -d "$app" ] && [ ! -L "$app" ] || { release_error "export did not produce Let It Brew.app."; return 1; }

    actual_version="$(release_plist_value "$info" CFBundleShortVersionString)" || return 1
    actual_build="$(release_plist_value "$info" CFBundleVersion)" || return 1
    [ "$actual_version" = "$RELEASE_MARKETING_VERSION" ] || { release_error "exported marketing version '$actual_version' does not match source."; return 1; }
    [ "$actual_build" = "$RELEASE_BUILD_VERSION" ] || { release_error "exported build '$actual_build' does not match source."; return 1; }
    release_build_verify "$app" || return 1
    release_build_verify_release_details "$app" || return 1

    release_build_ditto -c -k --sequesterRsrc --keepParent "$app" "$app_zip" || return 1
    release_build_ditto -c -k --keepParent "$archive/dSYMs" "$dsyms_zip" || return 1
    [ -f "$app_zip" ] && [ -f "$dsyms_zip" ] || { release_error "release ZIP creation was incomplete."; return 1; }

    release_manifest_set "$manifest" FORMAT 1 || return 1
    release_manifest_set "$manifest" PRODUCT "Let It Brew" || return 1
    release_manifest_set "$manifest" TEAM_ID "$LETITBREW_RELEASE_TEAM_ID" || return 1
    release_manifest_set "$manifest" BUNDLE_ID "$LETITBREW_RELEASE_APP_ID" || return 1
    release_manifest_set "$manifest" MARKETING_VERSION "$RELEASE_MARKETING_VERSION" || return 1
    release_manifest_set "$manifest" BUILD "$RELEASE_BUILD_VERSION" || return 1
    release_manifest_set "$manifest" GIT_COMMIT "$commit" || return 1
    release_manifest_set "$manifest" SIGNING_IDENTITY_SHA1 "$RELEASE_IDENTITY_HASH" || return 1
    release_manifest_set "$manifest" APP_NOTARY_ZIP "$(/usr/bin/basename "$app_zip")" || return 1
    release_manifest_set "$manifest" APP_NOTARY_ZIP_SHA256 "$(release_sha256 "$app_zip")" || return 1
    release_manifest_set "$manifest" DSYMS_ZIP "$(/usr/bin/basename "$dsyms_zip")" || return 1
    release_manifest_set "$manifest" DSYMS_ZIP_SHA256 "$(release_sha256 "$dsyms_zip")" || return 1
    release_manifest_set "$manifest" APP_MAIN_SHA256 "$(release_sha256 "$app/Contents/MacOS/LetItBrew")" || return 1
    release_manifest_set "$manifest" DAEMON_SHA256 "$(release_sha256 "$app/Contents/Library/LaunchServices/LetItBrewDaemon")" || return 1
    release_manifest_set "$manifest" HELPER_SHA256 "$(release_sha256 "$app/Contents/Helpers/letitbrew")" || return 1
    release_manifest_set "$manifest" APP_ARM64_CDHASH "$APP_ARM64_CDHASH" || return 1
    release_manifest_set "$manifest" APP_X86_64_CDHASH "$APP_X86_64_CDHASH" || return 1
    release_manifest_set "$manifest" DAEMON_ARM64_CDHASH "$DAEMON_ARM64_CDHASH" || return 1
    release_manifest_set "$manifest" DAEMON_X86_64_CDHASH "$DAEMON_X86_64_CDHASH" || return 1
    release_manifest_set "$manifest" HELPER_ARM64_CDHASH "$HELPER_ARM64_CDHASH" || return 1
    release_manifest_set "$manifest" HELPER_X86_64_CDHASH "$HELPER_X86_64_CDHASH" || return 1

    echo "PASS: Developer ID release exported and verified"
    release_note "app: $app"
    release_note "manifest: $manifest"
    release_note "archive and dSYMs retained beneath: $output_root"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -e
    release_build_main "$@"
fi
