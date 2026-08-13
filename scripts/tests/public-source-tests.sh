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

if ! grep -qE '^[[:space:]]+MARKETING_VERSION: 0\.5\.1$' project.yml; then
    fail "project.yml MARKETING_VERSION is not 0.5.1"
fi

if ! grep -qE '^[[:space:]]+CURRENT_PROJECT_VERSION: 20$' project.yml; then
    fail "project.yml CURRENT_PROJECT_VERSION is not 20"
fi

if ! grep -Fq 'print("letitbrew 0.5.1")' Sources/letitbrew/main.swift; then
    fail "letitbrew --version source is not 0.5.1"
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
