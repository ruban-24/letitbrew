#!/bin/sh
set -eu

# This guard prevents a public source snapshot from retaining internal plans,
# root-only agent artwork, stale release metadata, broken README artwork, or a
# pre-release publication instruction.
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

failed=0

fail() {
    printf '%s\n' "public-source guard: $*" >&2
    failed=1
}

for forbidden_prefix in design/ docs/superpowers/ .superpowers/; do
    if git ls-files | grep -q "^${forbidden_prefix}"; then
        fail "tracked internal path begins with ${forbidden_prefix}"
    fi
done

for forbidden_file in claude.png codex.png; do
    if git ls-files --error-unmatch "$forbidden_file" >/dev/null 2>&1; then
        fail "tracked root agent image ${forbidden_file}"
    fi
done

task_number_paths=$(git ls-files | grep -Ei '(^|/)[^/]*task[[:space:]_-]*[0-9]+[^/]*$' || true)
if [ -n "$task_number_paths" ]; then
    fail "tracked filenames must describe product behavior, not internal task numbers: ${task_number_paths}"
fi

if git grep -IqEi '(^|[^[:alnum:]])task[[:space:]_-]*[0-9]+([^[:alnum:]]|$)' -- ':!scripts/tests/public-source-tests.sh'; then
    fail "tracked source still contains an internal task-number reference from development"
fi

for agent in 'Claude Code' Codex OpenCode 'GitHub Copilot CLI'; do
    if ! grep -Fq "$agent" README.md; then
        fail "README is missing supported agent: $agent"
    fi
done

if git grep -Iqi 'Cursor' -- README.md Sources Tests; then
    fail "current public source still mentions removed Cursor support"
fi

if git grep -Fq '"$HELPER" --version' -- scripts ':!scripts/tests/public-source-tests.sh'; then
    fail "distribution scripts execute an unverified candidate helper"
fi

image_targets=$( {
    sed -nE 's/.*<img[[:space:]][^>]*src="([^"]+)".*/\1/p' README.md
    sed -nE 's/.*!\[[^]]*\]\(([^)[:space:]]+)([[:space:]].*)?\).*/\1/p' README.md
} | sort -u )

for image_target in $image_targets; do
    case "$image_target" in
        http://*|https://*|data:*|\#*) continue ;;
    esac

    if [ ! -f "$image_target" ]; then
        fail "README local image target does not exist: ${image_target}"
    fi
done

if ! grep -qE '^[[:space:]]+MARKETING_VERSION: 0\.7\.3$' project.yml; then
    fail "project.yml MARKETING_VERSION is not 0.7.3"
fi

if ! grep -qE '^[[:space:]]+CURRENT_PROJECT_VERSION: 30$' project.yml; then
    fail "project.yml CURRENT_PROJECT_VERSION is not 30"
fi

if ! grep -Fq 'print("letitbrew 0.7.3")' Sources/letitbrew/main.swift; then
    fail "letitbrew --version source is not 0.7.3"
fi

if ! grep -Fq '## 0.7.1 (build 28)' RELEASE-NOTES.md \
    || ! grep -Fq 'Do not uninstall first' RELEASE-NOTES.md \
    || ! grep -Fq 'settings and agent connections are preserved' RELEASE-NOTES.md; then
    fail "0.7.1 release notes are missing the one-time manual replacement bridge"
fi

if ! grep -Fq '0.6.5 or earlier' SUPPORT.md \
    || ! grep -Fq 'choose **Replace**' SUPPORT.md \
    || ! grep -Fq 'Do not uninstall first' SUPPORT.md; then
    fail "SUPPORT.md is missing the one-time manual replacement instructions"
fi

if ! grep -Fq '## v0.7.3 release scope' docs/ATTENDED-UAT.md \
    || ! grep -Fq 'Record version 0.7.3, build 30' docs/ATTENDED-UAT.md; then
    fail "attended UAT release scope is not 0.7.3 build 30"
fi

if ! grep -Fq '## Manual replacement bridge' docs/ATTENDED-UAT.md \
    || ! grep -Fq 'signed v0.6.5' docs/ATTENDED-UAT.md \
    || ! grep -Fq 'choose **Replace**' docs/ATTENDED-UAT.md \
    || ! grep -Fq 'signed version newer than v0.7.1' docs/ATTENDED-UAT.md; then
    fail "attended UAT is missing the signed 0.6.5 manual bridge and corrected-updater gates"
fi

if ! awk '
    /^\[!\[License:/ { license_badge = NR }
    /^\[!\[macOS 14\+/ { macos_badge = NR }
    /^\[!\[CI\]/ { ci_badge = NR }
    /^<a href="https:\/\/github.com\/ruban-24\/letitbrew\/releases\/latest\/download\/LetItBrew\.dmg">$/ {
        download_button = NR
    }
    END {
        if (!license_badge || !macos_badge || !ci_badge || !download_button) exit 1
        if (!(license_badge < macos_badge && macos_badge < ci_badge && ci_badge < download_button)) exit 1
    }
' README.md; then
    fail "README repository badges must stay grouped above the download button"
fi

if ! grep -Fq 'MountedUpdatePayloadValidator.validate' Sources/LetItBrewApp/OneClickUpdateOperationsLive.swift; then
    fail "live updater does not use the shared mounted-payload validator"
fi

if [ "$(/usr/bin/grep -m 1 -v '^$' LICENSE)" != "                                 Apache License" ] \
    || ! grep -Fq "Version 2.0, January 2004" LICENSE; then
    fail "LICENSE is not the Apache License 2.0 canonical header"
fi

if [ -e LICENSES/MIT-v0.5.1-and-earlier.txt ] || [ -L LICENSES/MIT-v0.5.1-and-earlier.txt ]; then
    fail "current source snapshot must not carry the historical MIT license file"
fi

if ! grep -Fq "Copyright 2026 Ruban" NOTICE 2>/dev/null \
    || ! grep -Fq "TRADEMARKS.md" NOTICE 2>/dev/null; then
    fail "NOTICE lacks the required Ruban attribution or trademark-policy link"
fi

if ! grep -Fq "Apache-2.0" README.md \
    || ! grep -Fq "v0.6.0 and later" README.md; then
    fail "README license boundary is incomplete"
fi

if grep -Fq 'v0.5.1 and earlier' README.md RELEASE-NOTES.md \
    || grep -Fq 'LICENSES/MIT-v0.5.1-and-earlier.txt' README.md RELEASE-NOTES.md; then
    fail "current documentation must not make a historical MIT license claim or reference"
fi

if ! grep -Fq "By contributing, you agree that your contribution is licensed under Apache License 2.0 and that you have the right to submit it." CONTRIBUTING.md; then
    fail "CONTRIBUTING.md does not state Apache 2.0 inbound terms"
fi

if grep -qi 'GitHub pre-release' SIGNING.md; then
    fail "SIGNING.md still instructs a GitHub pre-release"
fi

if grep -qi 'increased text size' RELEASE-NOTES.md docs/ATTENDED-UAT.md; then
    fail "release validation still names the unsupported macOS increased-text-size gate"
fi

if ! grep -Fq 'System Settings > Displays' docs/ATTENDED-UAT.md \
    || ! grep -Fq 'Larger Text' docs/ATTENDED-UAT.md; then
    fail "attended UAT does not name the macOS Displays > Larger Text scaling gate"
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi

printf '%s\n' 'public-source guard: PASS'
