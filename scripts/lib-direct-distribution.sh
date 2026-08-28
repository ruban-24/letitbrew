#!/bin/bash
# Shared, source-only helpers for Let It Brew's direct-distribution scripts.
# This file never signs, builds, mounts, submits, staples, or publishes by itself.

LETITBREW_RELEASE_TEAM_ID="MV2UL94MDC"
LETITBREW_RELEASE_APP_ID="com.ruban24.letitbrew"
RELEASE_WORKFLOW_LOCK_DIR="${RELEASE_WORKFLOW_LOCK_DIR:-}"
RELEASE_WORKFLOW_LOCK_TOKEN="${RELEASE_WORKFLOW_LOCK_TOKEN:-}"

release_error() {
    printf 'FATAL: %s\n' "$*" >&2
}

release_note() {
    printf '     %s\n' "$*"
}

release_retry_sleep() {
    /bin/sleep "$1"
}

release_detach_disk_image() {
    local hdiutil_function="$1"
    local mount_point="$2"
    local attempt
    case "$hdiutil_function" in
        release_dmg_hdiutil|release_notary_hdiutil) ;;
        *) return 1 ;;
    esac
    for attempt in 1 2 3 4 5; do
        if "$hdiutil_function" detach "$mount_point" >/dev/null 2>&1; then
            return 0
        fi
        [ "$attempt" -eq 5 ] || release_retry_sleep 1 || return 1
    done
    return 1
}

release_effective_uid() {
    /usr/bin/id -u
}

release_lock_acquire() {
    local root="$1"
    local purpose="$2"
    local lock="$root/.letitbrew-direct-distribution.lock"
    local token="${purpose}:$$:${RANDOM}:${RANDOM}"
    [ -z "$RELEASE_WORKFLOW_LOCK_DIR" ] && [ -z "$RELEASE_WORKFLOW_LOCK_TOKEN" ] || {
        release_error "this process already owns a release-workflow lock."
        return 1
    }
    if ! /bin/mkdir -m 700 "$lock" 2>/dev/null; then
        release_error "release workspace is locked by another or interrupted transaction: $lock"
        return 1
    fi
    RELEASE_WORKFLOW_LOCK_DIR="$lock"
    RELEASE_WORKFLOW_LOCK_TOKEN="$token"
    printf '%s\n' "$token" >"$lock/owner" || {
        release_error "could not journal release lock ownership; preserving the lock for inspection."
        return 1
    }
}

release_lock_is_owned() {
    local root="$1"
    local expected="$root/.letitbrew-direct-distribution.lock"
    local owner
    [ -n "$RELEASE_WORKFLOW_LOCK_TOKEN" ] || return 1
    [ "$RELEASE_WORKFLOW_LOCK_DIR" = "$expected" ] || return 1
    [ -d "$expected" ] && [ ! -L "$expected" ] || return 1
    [ -f "$expected/owner" ] && [ ! -L "$expected/owner" ] || return 1
    owner="$(/bin/cat "$expected/owner")" || return 1
    [ "$owner" = "$RELEASE_WORKFLOW_LOCK_TOKEN" ]
}

release_lock_release() {
    local lock="$RELEASE_WORKFLOW_LOCK_DIR"
    local token="$RELEASE_WORKFLOW_LOCK_TOKEN"
    local owner
    [ -n "$lock" ] && [ -n "$token" ] || return 0
    [ -d "$lock" ] && [ ! -L "$lock" ] || {
        release_error "release lock path changed; refusing cleanup."
        return 1
    }
    [ -f "$lock/owner" ] && [ ! -L "$lock/owner" ] || {
        release_error "release lock owner record changed; refusing cleanup."
        return 1
    }
    owner="$(/bin/cat "$lock/owner")" || return 1
    [ "$owner" = "$token" ] || {
        release_error "release lock ownership changed; refusing cleanup."
        return 1
    }
    /bin/rm "$lock/owner" || return 1
    /bin/rmdir "$lock" || return 1
    RELEASE_WORKFLOW_LOCK_DIR=""
    RELEASE_WORKFLOW_LOCK_TOKEN=""
}

release_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

release_sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk 'NR == 1 { print $1 }'
}

release_project_value() {
    local project_file="$1"
    local key="$2"
    local values count
    values="$(/usr/bin/awk -v key="$key" '$1 == key ":" { print $2 }' "$project_file")" || return 1
    count="$(printf '%s\n' "$values" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')"
    [ "$count" -eq 1 ] || return 1
    printf '%s\n' "$values"
}

release_version_is_canonical() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

release_dmg_payload_is_valid() {
    local root="$1" entry_count background_count package_count
    [ -d "$root/Let It Brew.app" ] && [ ! -L "$root/Let It Brew.app" ] || return 1
    [ -L "$root/Applications" ] && [ "$(/usr/bin/readlink "$root/Applications")" = /Applications ] || return 1
    [ -f "$root/.DS_Store" ] && [ ! -L "$root/.DS_Store" ] || return 1
    [ -f "$root/.VolumeIcon.icns" ] && [ ! -L "$root/.VolumeIcon.icns" ] || return 1
    [ -d "$root/.background" ] && [ ! -L "$root/.background" ] || return 1
    [ -f "$root/.background/dmg-background.png" ] && [ ! -L "$root/.background/dmg-background.png" ] || return 1

    entry_count="$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print | /usr/bin/awk 'END { print NR + 0 }')" || return 1
    background_count="$(/usr/bin/find "$root/.background" -mindepth 1 -maxdepth 1 -print | /usr/bin/awk 'END { print NR + 0 }')" || return 1
    package_count="$(/usr/bin/find "$root" -name '*.pkg' -print | /usr/bin/awk 'END { print NR + 0 }')" || return 1
    [ "$entry_count" -eq 5 ] && [ "$background_count" -eq 1 ] && [ "$package_count" -eq 0 ]
}

release_read_project_version() {
    local project_file="$1"
    RELEASE_MARKETING_VERSION="$(release_project_value "$project_file" MARKETING_VERSION)" || {
        release_error "project.yml must contain exactly one MARKETING_VERSION."
        return 1
    }
    RELEASE_BUILD_VERSION="$(release_project_value "$project_file" CURRENT_PROJECT_VERSION)" || {
        release_error "project.yml must contain exactly one CURRENT_PROJECT_VERSION."
        return 1
    }
    release_version_is_canonical "$RELEASE_MARKETING_VERSION" || {
        release_error "marketing version '$RELEASE_MARKETING_VERSION' is not canonical major.minor.patch."
        return 1
    }
    [[ "$RELEASE_BUILD_VERSION" =~ ^[0-9]+$ ]] || {
        release_error "build '$RELEASE_BUILD_VERSION' is not decimal."
        return 1
    }
}

release_canonical_new_private_tmp_path() {
    local requested="$1"
    local parent base canonical_parent
    [ -n "$requested" ] || return 1
    [ ! -e "$requested" ] && [ ! -L "$requested" ] || return 1
    parent="$(/usr/bin/dirname "$requested")" || return 1
    base="$(/usr/bin/basename "$requested")" || return 1
    [ -d "$parent" ] && [ "$base" != . ] && [ "$base" != .. ] || return 1
    canonical_parent="$(cd "$parent" && /bin/pwd -P)" || return 1
    case "$canonical_parent/" in
        /private/tmp/|/private/tmp/*) ;;
        *) return 1 ;;
    esac
    printf '%s/%s\n' "${canonical_parent%/}" "$base"
}

release_canonical_existing_private_tmp_dir() {
    local requested="$1"
    local canonical
    [ -d "$requested" ] && [ ! -L "$requested" ] || return 1
    canonical="$(cd "$requested" && /bin/pwd -P)" || return 1
    case "$canonical/" in
        /private/tmp/*) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$canonical"
}

release_find_manifest() {
    local root="$1"
    local manifests
    manifests="$(/usr/bin/find "$root" -maxdepth 1 -type f -name 'LetItBrew-*.manifest' -print)" || return 1
    [ "$(printf '%s\n' "$manifests" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] || return 1
    printf '%s\n' "$manifests"
}

release_manifest_get() {
    local manifest="$1"
    local key="$2"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
    /usr/bin/awk -F= -v key="$key" '
        $1 == key {
            sub(/^[^=]*=/, "")
            print
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$manifest"
}

release_manifest_set() {
    local manifest="$1"
    local key="$2"
    local value="$3"
    local temp unsorted
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || {
        release_error "invalid manifest key '$key'."
        return 1
    }
    case "$value" in *$'\n'*|*$'\r'*) release_error "manifest value for $key contains a newline."; return 1 ;; esac
    [ ! -L "$manifest" ] || {
        release_error "refusing symlinked manifest $manifest."
        return 1
    }
    temp="${manifest}.sorted.$$"
    unsorted="${manifest}.unsorted.$$"
    if [ -f "$manifest" ]; then
        /usr/bin/awk -F= -v key="$key" '$1 != key' "$manifest" >"$unsorted" || return 1
    else
        : >"$unsorted" || return 1
    fi
    printf '%s=%s\n' "$key" "$value" >>"$unsorted" || return 1
    LC_ALL=C /usr/bin/sort "$unsorted" >"$temp" || {
        /bin/rm -f "$unsorted" "$temp"
        return 1
    }
    /bin/mv "$temp" "$manifest" || {
        /bin/rm -f "$unsorted" "$temp"
        return 1
    }
    /bin/rm -f "$unsorted"
}

release_require_manifest_identity() {
    local manifest="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual="$(release_manifest_get "$manifest" "$key")" || {
        release_error "manifest is missing $key."
        return 1
    }
    [ "$actual" = "$expected" ] || {
        release_error "manifest $key '$actual' does not equal expected '$expected'."
        return 1
    }
}
