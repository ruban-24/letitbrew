#!/bin/sh
set -eu

# Runs the production SwiftUI section in an isolated native window. No login
# item registration, preferences, or installed app state are touched.
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/letitbrew-login-layout.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT HUP INT TERM

xcrun swiftc -swift-version 6 -parse-as-library \
    "$repo_root/Sources/LetItBrewApp/LaunchAtLoginSettingsSection.swift" \
    "$repo_root/scripts/tests/fixtures/LoginSettingsLayoutTests.swift" \
    -o "$fixture_dir/login-settings-layout-tests"
"$fixture_dir/login-settings-layout-tests"
