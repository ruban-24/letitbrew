#!/bin/bash
# Point the ruban-24/homebrew-tap cask at an already-published GitHub release.
# Run after the release is published. Reads the release, hashes the downloaded
# DMG, rewrites the cask's version and sha256, then commits and pushes. This
# script never creates, edits, uploads to, or deletes a GitHub release.
set -uo pipefail

# shellcheck source=lib-direct-distribution.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)/lib-direct-distribution.sh"

HOMEBREW_TAP_RELEASE_REPO="ruban-24/letitbrew"
HOMEBREW_TAP_CASK="Casks/letitbrew.rb"
HOMEBREW_TAP_WORK=""
HOMEBREW_TAP_KEEP_WORK=0
HOMEBREW_TAP_VERSION=""
HOMEBREW_TAP_SHA=""

homebrew_tap_remote_url() {
    printf '%s\n' "https://github.com/ruban-24/homebrew-tap.git"
}

homebrew_tap_gh() {
    gh "$@"
}

homebrew_tap_git() {
    /usr/bin/git "$@"
}

homebrew_tap_usage() {
    printf 'usage: %s <version> [--dry-run]\n' "${0##*/}" >&2
}

homebrew_tap_cleanup() {
    if [ -n "$HOMEBREW_TAP_WORK" ] && [ "$HOMEBREW_TAP_KEEP_WORK" -eq 0 ]; then
        /bin/rm -rf "$HOMEBREW_TAP_WORK"
    fi
    HOMEBREW_TAP_WORK=""
}

# Report a failed step. The GitHub release is already published and this
# script never changes it, so the message says so and gives the manual finish.
homebrew_tap_fail() {
    local step="$1" manual="${2:-}"
    {
        printf 'FATAL: Homebrew tap update failed while %s.\n' "$step"
        printf 'The GitHub release v%s is published and was not changed.\n' "$HOMEBREW_TAP_VERSION"
        printf 'To finish the tap update by hand:\n'
        if [ -n "$manual" ]; then
            printf '  %s\n' "$manual"
            printf '  or, if the tap moved on since the clone, rerun scripts/update-homebrew-tap.sh %s\n' "$HOMEBREW_TAP_VERSION"
        else
            printf '  scripts/update-homebrew-tap.sh %s\n' "$HOMEBREW_TAP_VERSION"
            printf '  or, in a clone of ruban-24/homebrew-tap, set %s to\n' "$HOMEBREW_TAP_CASK"
            printf '    version "%s"\n' "$HOMEBREW_TAP_VERSION"
            if [ -n "$HOMEBREW_TAP_SHA" ]; then
                printf '    sha256 "%s"\n' "$HOMEBREW_TAP_SHA"
            else
                printf '    sha256 "<shasum -a 256 of the downloaded LetItBrew-%s.dmg>"\n' "$HOMEBREW_TAP_VERSION"
            fi
            printf '  then commit and push to main.\n'
        fi
    } >&2
    return 1
}

# Prints "draft prerelease" then one asset name per line.
homebrew_tap_release_facts() {
    /usr/bin/python3 -I -c '
import json, sys
release = json.load(sys.stdin)
print(str(release["isDraft"]).lower(), str(release["isPrerelease"]).lower())
for asset in release["assets"]:
    print(asset["name"])
'
}

homebrew_tap_cask_value() {
    /usr/bin/awk -v key="$2" '
        $0 ~ "^  " key " \"[^\"]*\"$" { count++; value = $2 }
        END {
            if (count != 1) exit 1
            gsub(/"/, "", value)
            print value
        }
    ' "$1"
}

homebrew_tap_run() {
    local version="" dry_run=0 arg asset tag dmg_name sums_name json facts download dmg sums
    local sha published_sha tap cask current_version current_sha tmp

    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            -*) homebrew_tap_usage; return 2 ;;
            *)
                [ -z "$version" ] || { homebrew_tap_usage; return 2; }
                version="$arg"
                ;;
        esac
    done
    if ! release_version_is_canonical "$version"; then
        homebrew_tap_usage
        return 2
    fi
    HOMEBREW_TAP_VERSION="$version"
    tag="v$version"
    dmg_name="LetItBrew-$version.dmg"
    sums_name="LetItBrew-$version-SHA256SUMS"

    HOMEBREW_TAP_WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/letitbrew-homebrew-tap.XXXXXX")" \
        || homebrew_tap_fail "creating a temporary workspace" || return 1
    download="$HOMEBREW_TAP_WORK/download"
    tap="$HOMEBREW_TAP_WORK/tap"
    cask="$tap/$HOMEBREW_TAP_CASK"

    json="$(homebrew_tap_gh release view "$tag" --repo "$HOMEBREW_TAP_RELEASE_REPO" \
        --json isDraft,isPrerelease,assets)" \
        || homebrew_tap_fail "reading GitHub release $tag (is it published, and is gh signed in?)" || return 1
    facts="$(printf '%s' "$json" | homebrew_tap_release_facts)" \
        || homebrew_tap_fail "reading GitHub release $tag (unexpected release metadata)" || return 1
    case "$(printf '%s\n' "$facts" | /usr/bin/head -n 1)" in
        "false false") ;;
        *) homebrew_tap_fail "checking GitHub release $tag: it is a draft or pre-release; publish it as a full release first" || return 1 ;;
    esac
    for asset in "$dmg_name" "$sums_name"; do
        printf '%s\n' "$facts" | /usr/bin/tail -n +2 | /usr/bin/grep -Fxq "$asset" \
            || homebrew_tap_fail "checking GitHub release $tag: asset $asset is missing" || return 1
    done

    /bin/mkdir "$download" || homebrew_tap_fail "creating a download directory" || return 1
    homebrew_tap_gh release download "$tag" --repo "$HOMEBREW_TAP_RELEASE_REPO" \
        --pattern "$dmg_name" --pattern "$sums_name" --dir "$download" \
        || homebrew_tap_fail "downloading $dmg_name from GitHub release $tag" || return 1
    dmg="$download/$dmg_name"
    sums="$download/$sums_name"
    [ -f "$dmg" ] && [ -f "$sums" ] \
        || homebrew_tap_fail "downloading $dmg_name from GitHub release $tag" || return 1

    sha="$(release_sha256 "$dmg")"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || homebrew_tap_fail "hashing the downloaded $dmg_name" || return 1
    published_sha="$(/usr/bin/awk -v name="$dmg_name" '$2 == name || $2 == "*" name { print $1 }' "$sums")"
    [ "$published_sha" = "$sha" ] \
        || homebrew_tap_fail "checking the downloaded $dmg_name: SHA-256 $sha does not match $sums_name ('$published_sha')" \
        || return 1
    HOMEBREW_TAP_SHA="$sha"
    printf 'Release %s: %s SHA-256 %s\n' "$tag" "$dmg_name" "$sha"

    homebrew_tap_git clone --quiet "$(homebrew_tap_remote_url)" "$tap" \
        || homebrew_tap_fail "cloning $(homebrew_tap_remote_url)" || return 1
    current_version="$(homebrew_tap_cask_value "$cask" version)" \
        || homebrew_tap_fail "reading $HOMEBREW_TAP_CASK: expected exactly one top-level version line" || return 1
    current_sha="$(homebrew_tap_cask_value "$cask" sha256)" \
        || homebrew_tap_fail "reading $HOMEBREW_TAP_CASK: expected exactly one top-level sha256 line" || return 1
    if [ "$current_version" = "$version" ] && [ "$current_sha" = "$sha" ]; then
        printf 'Homebrew tap already points at %s with this SHA-256. Nothing to do.\n' "$version"
        return 0
    fi

    tmp="$cask.new"
    /usr/bin/awk -v version="$version" -v sha="$sha" '
        /^  version "[^"]*"$/ { print "  version \"" version "\""; next }
        /^  sha256 "[^"]*"$/ { print "  sha256 \"" sha "\""; next }
        { print }
    ' "$cask" >"$tmp" && /bin/mv "$tmp" "$cask" \
        || homebrew_tap_fail "editing $HOMEBREW_TAP_CASK" || return 1
    homebrew_tap_git -C "$tap" --no-pager diff \
        || homebrew_tap_fail "showing the cask diff" || return 1

    if [ "$dry_run" -eq 1 ]; then
        printf 'Dry run: nothing was committed or pushed.\n'
        return 0
    fi

    homebrew_tap_git -C "$tap" commit --quiet -am "letitbrew $version" \
        || homebrew_tap_fail "committing the cask change" || return 1
    if ! homebrew_tap_git -C "$tap" push --quiet origin HEAD; then
        HOMEBREW_TAP_KEEP_WORK=1
        homebrew_tap_fail "pushing to $(homebrew_tap_remote_url)" \
            "git -C '$tap' push origin HEAD   (the commit is ready in that clone)"
        return 1
    fi
    printf 'Pushed letitbrew %s to the Homebrew tap.\n' "$version"
}

homebrew_tap_main() {
    local status=0
    HOMEBREW_TAP_KEEP_WORK=0
    HOMEBREW_TAP_VERSION=""
    HOMEBREW_TAP_SHA=""
    homebrew_tap_run "$@" || status=$?
    homebrew_tap_cleanup
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap homebrew_tap_cleanup EXIT
    trap 'exit 130' INT TERM HUP
    homebrew_tap_main "$@"
fi
