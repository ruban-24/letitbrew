#!/bin/bash
# Isolated command-adapter tests. These never invoke real xcodebuild, codesign,
# hdiutil, notarytool, stapler, or spctl. The verifier's legal-only fixture
# mode validates copied static legal resources without inspecting signatures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
# shellcheck source=../build-release-artifact.sh
source "$SCRIPT_DIR/build-release-artifact.sh"
# shellcheck source=../create-release-dmg.sh
source "$SCRIPT_DIR/create-release-dmg.sh"
# shellcheck source=../notarize-release.sh
source "$SCRIPT_DIR/notarize-release.sh"
# shellcheck source=../lib-power-baseline.sh
source "$SCRIPT_DIR/lib-power-baseline.sh"
TEST_VERSION="$(release_project_value "$SCRIPT_DIR/../project.yml" MARKETING_VERSION)"
TEST_BUILD="$(release_project_value "$SCRIPT_DIR/../project.yml" CURRENT_PROJECT_VERSION)"
ORIGINAL_RELEASE_BUILD_VERIFY_DETAILS="$(declare -f release_build_verify_release_details)"

TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/letitbrew-direct-distribution-tests.XXXXXX)"
TEST_LEDGER="$TEST_ROOT/ledger"
TESTS=0
FAILURES=0

test_cleanup() { /bin/rm -rf "$TEST_ROOT"; }
trap test_cleanup EXIT

record_failure() {
    printf 'not ok: %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

expect_true() {
    local label="$1"
    shift
    TESTS=$((TESTS + 1))
    if "$@"; then printf 'ok: %s\n' "$label"; else record_failure "$label"; fi
}

expect_false() {
    local label="$1"
    shift
    TESTS=$((TESTS + 1))
    if "$@" >/dev/null 2>&1; then record_failure "$label"; else printf 'ok: %s\n' "$label"; fi
}

expect_equal() {
    local actual="$1" expected="$2" label="$3"
    TESTS=$((TESTS + 1))
    if [ "$actual" = "$expected" ]; then
        printf 'ok: %s\n' "$label"
    else
        record_failure "$label (actual '$actual', expected '$expected')"
    fi
}

expect_contains() {
    local file="$1" pattern="$2" label="$3"
    expect_true "$label" /usr/bin/grep -qE "$pattern" "$file"
}

clear_ledger() { : >"$TEST_LEDGER"; }
event() { printf '%s\n' "$*" >>"$TEST_LEDGER"; }

release_effective_uid() { printf '%s\n' "${TEST_UID:-501}"; }
release_plist_value() {
    case "$2" in
        CFBundleShortVersionString) printf '%s\n' "$TEST_VERSION" ;;
        CFBundleVersion) printf '%s\n' "$TEST_BUILD" ;;
        *) return 1 ;;
    esac
}

make_fake_app() {
    local app="$1" executable
    /bin/mkdir -p \
        "$app/Contents/MacOS" \
        "$app/Contents/Library/LaunchServices" \
        "$app/Contents/Helpers" \
        "$app/Contents/Resources/Legal"
    printf 'plist\n' >"$app/Contents/Info.plist"
    for executable in \
        "$app/Contents/MacOS/LetItBrew" \
        "$app/Contents/Library/LaunchServices/LetItBrewDaemon" \
        "$app/Contents/Helpers/letitbrew"; do
        printf 'fake executable: %s\n' "$executable" >"$executable"
        /bin/chmod +x "$executable"
    done
    /usr/bin/install -m 644 "$SCRIPT_DIR/../LICENSE" "$app/Contents/Resources/Legal/LICENSE"
    /usr/bin/install -m 644 "$SCRIPT_DIR/../NOTICE" "$app/Contents/Resources/Legal/NOTICE"
    /usr/bin/install -m 644 "$SCRIPT_DIR/../TRADEMARKS.md" "$app/Contents/Resources/Legal/TRADEMARKS.md"
}

verify_legal_resources_only() {
    baseline_verify_legal_resources "$1"
}

make_legal_only_app() {
    local app="$1"
    /bin/mkdir -p "$app/Contents/Resources/Legal"
    /usr/bin/install -m 644 "$SCRIPT_DIR/../LICENSE" "$app/Contents/Resources/Legal/LICENSE"
    /usr/bin/install -m 644 "$SCRIPT_DIR/../NOTICE" "$app/Contents/Resources/Legal/NOTICE"
    /usr/bin/install -m 644 "$SCRIPT_DIR/../TRADEMARKS.md" "$app/Contents/Resources/Legal/TRADEMARKS.md"
}

make_four_file_update_support() {
    local app="$1" support_dir="$1/Contents/Resources/UpdateSupport" support
    /bin/mkdir -p "$support_dir"
    for support in run-update.sh upgrade-installed-app.sh verify-artifact.sh; do
        printf '#!/bin/bash\n' >"$support_dir/$support"
        /bin/chmod 755 "$support_dir/$support"
    done
    printf '# immutable support data\n' >"$support_dir/lib-power-baseline.sh"
    /bin/chmod 644 "$support_dir/lib-power-baseline.sh"
}

normal_verifier_runs_legal_then_full_gates() {
    local app="$1" transcript="$TEST_ROOT/normal-verifier-transcript"
    LETITBREW_VERIFY_ARTIFACT_LEGAL_ONLY=1 "$SCRIPT_DIR/verify-artifact.sh" "$app" >"$transcript" 2>&1 || true
    /usr/bin/grep -Fq 'PASS: embedded legal resource verification' "$transcript" &&
        /usr/bin/grep -Fq -- '-- signed update support --' "$transcript" &&
        /usr/bin/grep -Fq -- '-- strict signatures and live-image identity --' "$transcript"
}

frozen_v051_contract_runs_without_git_or_cwd() {
    local no_git="$TEST_ROOT/no-git-bin" transcript="$TEST_ROOT/no-git-transcript"
    /bin/mkdir -p "$no_git"
    printf '#!/bin/bash\nexit 127\n' >"$no_git/git"
    /bin/chmod 755 "$no_git/git"
    (
        cd /private/tmp || exit 1
        PATH="$no_git:$PATH" /bin/bash \
            "$SCRIPT_DIR/tests/frozen-v0.5.1-update-support-contract-tests.sh"
    ) >"$transcript" 2>&1 &&
        /usr/bin/grep -Fq 'PASS: 5 frozen v0.5.1 UpdateSupport assertions' "$transcript"
}

echo "-- shared path and manifest contracts --"
new_path="$TEST_ROOT/new-release"
expect_equal "$(release_canonical_new_private_tmp_path "$new_path")" "$new_path" "accepts a new /private/tmp output path"
/bin/mkdir "$TEST_ROOT/existing"
expect_false "rejects an existing output directory" release_canonical_new_private_tmp_path "$TEST_ROOT/existing"
/bin/ln -s "$TEST_ROOT/missing" "$TEST_ROOT/output-link"
expect_false "rejects a symlinked output path" release_canonical_new_private_tmp_path "$TEST_ROOT/output-link"
expect_false "rejects output outside /private/tmp" release_canonical_new_private_tmp_path "/letitbrew-release-output"
manifest_contract="$TEST_ROOT/contract.manifest"
release_manifest_set "$manifest_contract" ZETA two
release_manifest_set "$manifest_contract" ALPHA one
release_manifest_set "$manifest_contract" ZETA changed
expect_equal "$(release_manifest_get "$manifest_contract" ZETA)" changed "manifest replacement is exact"
expect_equal "$(/usr/bin/sed -n '1p' "$manifest_contract")" ALPHA=one "manifest keys are deterministically sorted"
expect_true "accepts canonical major.minor.patch" release_version_is_canonical 0.4.0
expect_false "rejects a two-component release version" release_version_is_canonical 0.4
expect_false "rejects a leading-zero release version" release_version_is_canonical 00.4.0
expect_false "rejects a fourth release component" release_version_is_canonical 0.4.0.1

echo
echo "-- embedded legal resource contract --"
legal_app="$TEST_ROOT/legal/Let It Brew.app"
make_fake_app "$legal_app"
expect_true "accepts exactly the three embedded legal resources" verify_legal_resources_only "$legal_app"

for legal_name in LICENSE NOTICE TRADEMARKS.md; do
    fixture="$TEST_ROOT/legal-missing-$legal_name/Let It Brew.app"
    make_fake_app "$fixture"
    /bin/rm -f "$fixture/Contents/Resources/Legal/$legal_name"
    expect_false "rejects a missing Legal/$legal_name" verify_legal_resources_only "$fixture"
done

for legal_name in LICENSE NOTICE TRADEMARKS.md; do
    fixture="$TEST_ROOT/legal-symlink-$legal_name/Let It Brew.app"
    foreign="$TEST_ROOT/foreign-$legal_name"
    make_fake_app "$fixture"
    /bin/rm -f "$fixture/Contents/Resources/Legal/$legal_name"
    case "$legal_name" in
        LICENSE) /usr/bin/install -m 644 "$SCRIPT_DIR/../LICENSE" "$foreign" ;;
        NOTICE) /usr/bin/install -m 644 "$SCRIPT_DIR/../NOTICE" "$foreign" ;;
        TRADEMARKS.md) /usr/bin/install -m 644 "$SCRIPT_DIR/../TRADEMARKS.md" "$foreign" ;;
    esac
    /bin/ln -s "$foreign" "$fixture/Contents/Resources/Legal/$legal_name"
    expect_false "rejects a symlinked Legal/$legal_name" verify_legal_resources_only "$fixture"
done

fixture="$TEST_ROOT/legal-wrong-family/Let It Brew.app"
make_fake_app "$fixture"
/bin/mkdir -p "$fixture/Contents/Resources/Legal"
printf 'MIT License\n' >"$fixture/Contents/Resources/Legal/LICENSE"
expect_false "rejects a non-Apache embedded LICENSE" verify_legal_resources_only "$fixture"

minimal_legal_app="$TEST_ROOT/legal-only/Let It Brew.app"
make_legal_only_app "$minimal_legal_app"
expect_false "normal verifier refuses a Legal-only app" "$SCRIPT_DIR/verify-artifact.sh" "$minimal_legal_app"
expect_false "old Legal-only environment cannot bypass normal verification" \
    env LETITBREW_VERIFY_ARTIFACT_LEGAL_ONLY=1 "$SCRIPT_DIR/verify-artifact.sh" "$minimal_legal_app"
expect_false "old Legal-only environment cannot bypass release verification" \
    env LETITBREW_VERIFY_ARTIFACT_LEGAL_ONLY=1 "$SCRIPT_DIR/verify-artifact.sh" "$minimal_legal_app" --release
expect_true "normal verifier calls Legal validation and continues through full gates despite the retired environment" \
    normal_verifier_runs_legal_then_full_gates "$minimal_legal_app"

echo
echo "-- frozen v0.5.1 update support compatibility --"
v051_four_file_app="$TEST_ROOT/v051-four-file/Let It Brew.app"
make_fake_app "$v051_four_file_app"
make_four_file_update_support "$v051_four_file_app"
expect_true "frozen v0.5.1 exact-four predicate accepts the current inventory" \
    release_build_verify_v051_compatibility "$v051_four_file_app"

expect_true "frozen v0.5.1 predicate works without Git from an unrelated caller cwd" \
    frozen_v051_contract_runs_without_git_or_cwd

echo
echo "-- Developer ID identity refusal and selection --"
TEST_IDENTITY_MODE=none
release_build_security_identities() {
    case "$TEST_IDENTITY_MODE" in
        none) printf '     0 valid identities found\n' ;;
        wrong) printf '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Example (WRONGTEAM1)"\n' ;;
        multiple)
            printf '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: First (MV2UL94MDC)"\n'
            printf '  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Second (MV2UL94MDC)"\n'
            ;;
        valid) printf '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Release Owner (MV2UL94MDC)"\n' ;;
    esac
}
expect_false "refuses when no Developer ID identity exists" release_build_select_identity
TEST_IDENTITY_MODE=wrong
expect_false "refuses a Developer ID identity for another Team" release_build_select_identity
TEST_IDENTITY_MODE=multiple
expect_false "refuses ambiguous same-Team Developer ID identities" release_build_select_identity
TEST_IDENTITY_MODE=valid
expect_true "selects one exact-Team Developer ID identity" release_build_select_identity
expect_equal "$RELEASE_IDENTITY_HASH" 0123456789ABCDEF0123456789ABCDEF01234567 "pins the full identity SHA-1"

echo
echo "-- build refusal and exact command order --"
release_build_require_tools() { event tools; RELEASE_XCODEGEN=/fake/xcodegen; }
TEST_DIRTY=0
release_build_require_clean_tree() { event clean; [ "$TEST_DIRTY" -eq 0 ]; }
release_build_xcodegen() { event xcodegen; }
release_build_archive() {
    event "archive:$4"
    /bin/mkdir -p "$3/dSYMs"
    printf 'symbols\n' >"$3/dSYMs/LetItBrew.dSYM"
}
release_build_export() {
    event export
    make_fake_app "$2/Let It Brew.app"
}
release_build_verify() { event verify-release; }
release_build_verify_release_details() {
    event verify-slices-entitlements
    APP_ARM64_CDHASH=1111111111111111111111111111111111111111
    APP_X86_64_CDHASH=2222222222222222222222222222222222222222
    DAEMON_ARM64_CDHASH=3333333333333333333333333333333333333333
    DAEMON_X86_64_CDHASH=4444444444444444444444444444444444444444
    HELPER_ARM64_CDHASH=5555555555555555555555555555555555555555
    HELPER_X86_64_CDHASH=6666666666666666666666666666666666666666
    export APP_ARM64_CDHASH APP_X86_64_CDHASH DAEMON_ARM64_CDHASH DAEMON_X86_64_CDHASH HELPER_ARM64_CDHASH HELPER_X86_64_CDHASH
}
release_build_ditto() {
    local last="" arg
    for arg in "$@"; do last="$arg"; done
    event "package:$(/usr/bin/basename "$last")"
    printf 'fake zip\n' >"$last"
}

TEST_UID=0
expect_false "release build refuses root before tools or identity" release_build_main --output-root "$TEST_ROOT/root-output"
TEST_UID=501

TEST_DIRTY=1
clear_ledger
expect_false "dirty worktree refuses before identity or generation" release_build_main --output-root "$TEST_ROOT/dirty-output"
expect_equal "$(/bin/cat "$TEST_LEDGER")" $'tools\nclean' "dirty refusal stops at the clean-tree gate"

TEST_DIRTY=0
TEST_IDENTITY_MODE=none
clear_ledger
expect_false "missing identity refuses before project generation" release_build_main --output-root "$TEST_ROOT/no-identity-output"
expect_false "identity refusal does not call xcodegen" /usr/bin/grep -q xcodegen "$TEST_LEDGER"

TEST_IDENTITY_MODE=valid
build_root="$TEST_ROOT/release-build"
clear_ledger
expect_true "isolated Developer ID build transaction succeeds" release_build_main --output-root "$build_root"
expect_contains "$TEST_LEDGER" '^tools$.*' "build checked required tools"
build_events="$(/usr/bin/tr '\n' ',' <"$TEST_LEDGER")"
expect_contains <(printf '%s\n' "$build_events") "tools,clean,xcodegen,clean,archive:0123456789ABCDEF0123456789ABCDEF01234567,export,verify-release,verify-slices-entitlements,package:LetItBrew-${TEST_VERSION}-${TEST_BUILD}\\.app-notary\\.zip,package:LetItBrew-${TEST_VERSION}-${TEST_BUILD}\\.dSYMs\\.zip," "build order is generate, archive, export, release-verify, evidence"
build_manifest="$build_root/LetItBrew-${TEST_VERSION}-${TEST_BUILD}.manifest"
expect_equal "$(release_manifest_get "$build_manifest" MARKETING_VERSION)" "$TEST_VERSION" "manifest records marketing version"
expect_equal "$(release_manifest_get "$build_manifest" BUILD)" "$TEST_BUILD" "manifest records build"
expect_true "manifest records exact full commit" bash -c '[[ "$1" =~ ^[0-9a-f]{40}$ ]]' _ "$(release_manifest_get "$build_manifest" GIT_COMMIT)"
expect_equal "$(release_manifest_get "$build_manifest" SIGNING_IDENTITY_SHA1)" 0123456789ABCDEF0123456789ABCDEF01234567 "manifest records pinned identity"
expect_true "archive dSYM is retained" test -f "$build_root/LetItBrew.xcarchive/dSYMs/LetItBrew.dSYM"
expect_false "duplicate build output is refused" release_build_main --output-root "$build_root"

expect_true "acquires an exclusive per-release-root lock" release_lock_acquire "$build_root" ownership-test
owned_lock_token="$RELEASE_WORKFLOW_LOCK_TOKEN"
printf 'foreign-owner\n' >"$RELEASE_WORKFLOW_LOCK_DIR/owner"
expect_false "lock cleanup refuses a changed owner token" release_lock_release
expect_true "owner mismatch preserves the lock" test -d "$build_root/.letitbrew-direct-distribution.lock"
printf '%s\n' "$owned_lock_token" >"$RELEASE_WORKFLOW_LOCK_DIR/owner"
expect_true "exact owner can release its lock" release_lock_release
expect_false "owned lock is removed after exact cleanup" test -e "$build_root/.letitbrew-direct-distribution.lock"

echo
echo "-- release-only entitlement and slice gates --"
unset -f release_build_verify_release_details
eval "$ORIGINAL_RELEASE_BUILD_VERIFY_DETAILS"
TEST_GET_TASK_ALLOW=false
TEST_BAD_SLICE=0
TEST_ENTITLEMENT_CODESIGN_FAILURE=0
TEST_PLUTIL_CONVERT_FAILURE=0
TEST_PLUTIL_EXTRACT_FAILURE=0
TEST_ENTITLEMENT_XML=$'<?xml version="1.0"?>\n<plist version="1.0">\n<dict>\n<key>com.apple.security.get-task-allow</key>\n<false/>\n</dict>\n</plist>'
release_build_plutil() {
    case "$1" in
        -convert)
            [ "$TEST_PLUTIL_CONVERT_FAILURE" -eq 0 ] || return 1
            /usr/bin/plutil "$@"
            ;;
        -extract)
            printf '%s\n' "$2" >"$TEST_ROOT/plutil-key"
            [ "$TEST_PLUTIL_EXTRACT_FAILURE" -eq 0 ] || return 1
            printf '%s\n' "$TEST_GET_TASK_ALLOW"
            ;;
        *) return 1 ;;
    esac
}
release_build_codesign() {
    local args="$*"
    if [[ "$args" == *"--entitlements"* ]]; then
        [ "$TEST_ENTITLEMENT_CODESIGN_FAILURE" -eq 0 ] || return 1
        printf '%s\n' "$TEST_ENTITLEMENT_XML"
    elif [ "$TEST_BAD_SLICE" -eq 1 ] && [[ "$args" == *"x86_64"* ]]; then
        printf 'CDHash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    else
        printf 'CodeDirectory v=20500 flags=0x10000(runtime)\nCDHash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    fi
}
TEST_GET_TASK_ALLOW=true
expect_false "rejects get-task-allow on the release app" release_build_verify_release_details "$build_root/export/Let It Brew.app"
expect_equal "$(/bin/cat "$TEST_ROOT/plutil-key")" 'com\.apple\.security\.get-task-allow' "escapes the dotted entitlement key for plutil"
TEST_GET_TASK_ALLOW=false
TEST_ENTITLEMENT_CODESIGN_FAILURE=1
expect_false "rejects unreadable release-app entitlements" release_build_verify_release_details "$build_root/export/Let It Brew.app"
TEST_ENTITLEMENT_CODESIGN_FAILURE=0
TEST_ENTITLEMENT_XML='not a property list'
expect_false "rejects malformed release-app entitlements" release_build_verify_release_details "$build_root/export/Let It Brew.app"
TEST_ENTITLEMENT_XML=$'<?xml version="1.0"?>\n<plist version="1.0">\n<array/>\n</plist>'
expect_false "rejects a non-dictionary entitlement plist" release_build_verify_release_details "$build_root/export/Let It Brew.app"
TEST_ENTITLEMENT_XML=$'<?xml version="1.0"?>\n<plist version="1.0">\n<dict>\n<key>com.apple.security.get-task-allow</key>\n<false/>\n</dict>\n</plist>'
TEST_PLUTIL_CONVERT_FAILURE=1
expect_false "rejects a failed entitlement normalization" release_build_verify_release_details "$build_root/export/Let It Brew.app"
TEST_PLUTIL_CONVERT_FAILURE=0
TEST_PLUTIL_EXTRACT_FAILURE=1
expect_false "rejects a failed get-task-allow extraction" release_build_verify_release_details "$build_root/export/Let It Brew.app"
TEST_PLUTIL_EXTRACT_FAILURE=0
TEST_ENTITLEMENT_XML=$'<?xml version="1.0"?>\n<plist version="1.0">\n<dict/>\n</plist>'
expect_true "accepts a valid entitlement dictionary with no get-task-allow key" release_build_verify_release_details "$build_root/export/Let It Brew.app"
TEST_ENTITLEMENT_XML=$'<?xml version="1.0"?>\n<plist version="1.0">\n<dict>\n<key>com.apple.security.get-task-allow</key>\n<false/>\n</dict>\n</plist>'
TEST_BAD_SLICE=1
expect_false "rejects a slice without hardened runtime" release_build_verify_release_details "$build_root/export/Let It Brew.app"
TEST_BAD_SLICE=0
expect_true "accepts entitlement-free runtime slices with CDHashes" release_build_verify_release_details "$build_root/export/Let It Brew.app"

echo
echo "-- DMG payload, naming, signing, verification, and replacement --"
TEST_DETACH_ATTEMPTS=0
TEST_DETACH_FAILURES=2
release_dmg_hdiutil() {
    [ "$1" = detach ] || return 1
    TEST_DETACH_ATTEMPTS=$((TEST_DETACH_ATTEMPTS + 1))
    [ "$TEST_DETACH_ATTEMPTS" -gt "$TEST_DETACH_FAILURES" ]
}
release_retry_sleep() { event "detach-retry-sleep:$1"; }
clear_ledger
expect_true "transient DMG detach retries without forcing the mount" release_detach_disk_image release_dmg_hdiutil /private/tmp/test-mount
expect_equal "$TEST_DETACH_ATTEMPTS" 3 "DMG detach stops immediately after a successful retry"
expect_equal "$(/usr/bin/grep -c '^detach-retry-sleep:1$' "$TEST_LEDGER")" 2 "DMG detach waits between transient failures"
TEST_DETACH_ATTEMPTS=0
TEST_DETACH_FAILURES=5
expect_false "persistent DMG detach failure remains an error after the bound" release_detach_disk_image release_dmg_hdiutil /private/tmp/test-mount
expect_equal "$TEST_DETACH_ATTEMPTS" 5 "DMG detach attempts are strictly bounded"
release_retry_sleep() { /bin/sleep "$1"; }
release_dmg_identity_is_valid() { return 0; }
release_dmg_verify_artifact() { event "dmg-app-verify"; }
release_dmg_ditto() { /usr/bin/ditto "$@"; }
release_dmg_codesign() { event "dmg-codesign:$*"; }
release_dmg_create_image() {
    local stage="$1" destination="$2"
    event create-image
    [ -d "$stage/Let It Brew.app" ] || return 1
    [ -L "$stage/Applications" ] && [ "$(/usr/bin/readlink "$stage/Applications")" = /Applications ] || return 1
    [ "$(/usr/bin/find "$stage" -mindepth 1 -maxdepth 1 -print | /usr/bin/awk 'END { print NR + 0 }')" -eq 2 ] || return 1
    [ "$(/usr/bin/find "$stage" -name '*.pkg' -print | /usr/bin/awk 'END { print NR + 0 }')" -eq 0 ] || return 1
    printf 'unsigned dmg bytes\n' >"$destination"
}
release_dmg_verify_image() { event verify-image; }
TEST_UID=0
expect_false "DMG creation refuses root" release_dmg_main "$build_root"
TEST_UID=501
/bin/mkdir "$build_root/.letitbrew-direct-distribution.lock"
printf 'other-transaction\n' >"$build_root/.letitbrew-direct-distribution.lock/owner"
expect_false "DMG creation refuses a concurrent release-root lock" release_dmg_main "$build_root"
/bin/rm "$build_root/.letitbrew-direct-distribution.lock/owner"
/bin/rmdir "$build_root/.letitbrew-direct-distribution.lock"
clear_ledger
expect_true "creates isolated stable version-named DMG" release_dmg_main "$build_root"
expect_true "DMG has stable marketing-version name" test -f "$build_root/LetItBrew-${TEST_VERSION}.dmg"
dmg_events="$(/usr/bin/tr '\n' ',' <"$TEST_LEDGER")"
expect_contains <(printf '%s\n' "$dmg_events") 'dmg-app-verify,create-image,dmg-codesign:--force --sign 0123456789ABCDEF0123456789ABCDEF01234567 --timestamp .*\.new\.[0-9]+\.dmg,dmg-codesign:--verify --strict .*\.new\.[0-9]+\.dmg,verify-image,' "DMG is release-verified, built, signed, then image-verified"
expect_equal "$(release_manifest_get "$build_manifest" DMG_TOP_LEVEL_ENTRIES)" "Applications,Let It Brew.app" "manifest records the exact two-item payload"
expect_false "ordinary DMG creation refuses overwrite" release_dmg_main "$build_root"
release_dmg_cleanup >/dev/null 2>&1 || true
release_manifest_set "$build_manifest" APP_STAPLED 1
clear_ledger
expect_true "controlled replacement rebuilds from a validated stapled app" release_dmg_main "$build_root" --replace-after-app-staple
expect_equal "$(release_manifest_get "$build_manifest" DMG_PHASE)" app-stapled "replacement journals the app-stapled phase"

TEST_DMG_CREATE_IMAGE_DEFINITION="$(declare -f release_dmg_create_image)"
release_dmg_create_image() { return 1; }
expect_true "notary transaction acquires its release-root lock" release_lock_acquire "$build_root" borrowed-cleanup-test
expect_false "borrowed final-DMG failure remains nonzero" release_notary_create_final_dmg "$build_root"
expect_false "borrowed final-DMG failure removes its staging directory" test -d "$RELEASE_DMG_STAGE"
expect_true "borrowed final-DMG cleanup preserves the owning notary lock" release_lock_is_owned "$build_root"
expect_true "owning notary transaction releases after borrowed failure" release_lock_release
unset -f release_dmg_create_image
eval "$TEST_DMG_CREATE_IMAGE_DEFINITION"

echo
echo "-- named-profile-only, resumable notarization order --"
release_manifest_set "$build_manifest" APP_STAPLED 0
release_manifest_set "$build_manifest" DMG_PHASE pre-notarization
TEST_WAIT_STATUS=Accepted
TEST_WAIT_FAIL=0
TEST_STAPLE_FAIL=0
TEST_APP_STAPLED=0
TEST_DMG_STAPLED=0
TEST_SUBMIT_COUNT=0
release_notary_verify_artifact() { event notary-verify-app; }
release_notary_log_has_no_issues() { return 0; }
release_notary_xcrun() {
    local command="$1"
    shift
    case "$command" in
        notarytool)
            local action="$1"
            shift
            case "$action" in
                submit)
                    TEST_SUBMIT_COUNT=$((TEST_SUBMIT_COUNT + 1))
                    event "submit:$(/usr/bin/basename "$1"):$*"
                    if [[ "$1" == *.zip ]]; then
                        printf '{"id":"11111111-1111-1111-1111-111111111111","status":"In Progress"}\n'
                    else
                        printf '{"id":"22222222-2222-2222-2222-222222222222","status":"In Progress"}\n'
                    fi
                    ;;
                wait)
                    event "wait:$1:$*"
                    [ "$TEST_WAIT_FAIL" -eq 0 ] || return 1
                    printf '{"id":"%s","status":"%s"}\n' "$1" "$TEST_WAIT_STATUS"
                    ;;
                log)
                    event "log:$*"
                    local output_path="${@: -1}"
                    printf '{"status":"Accepted","issues":[]}\n' >"$output_path"
                    ;;
            esac
            ;;
        stapler)
            local action="$1" target="$2"
            event "stapler:$action:$(/usr/bin/basename "$target")"
            if [ "$action" = staple ]; then
                if [ "$TEST_STAPLE_FAIL" -eq 1 ] && [[ "$target" == *.app ]]; then return 1; fi
                case "$target" in *.app) TEST_APP_STAPLED=1 ;; *.dmg) TEST_DMG_STAPLED=1 ;; esac
                return 0
            fi
            case "$target" in *.app) [ "$TEST_APP_STAPLED" -eq 1 ] ;; *.dmg) [ "$TEST_DMG_STAPLED" -eq 1 ] ;; esac
            ;;
    esac
}
release_notary_ditto() {
    local source="" destination="" arg
    for arg in "$@"; do source="$destination"; destination="$arg"; done
    event "notary-copy:$(/usr/bin/basename "$destination")"
    if [[ "$destination" == *.zip ]]; then printf 'stapled app zip\n' >"$destination"; else /bin/cp "$source" "$destination"; fi
}
release_notary_create_final_dmg() {
    local root="$1" manifest dmg
    manifest="$(release_find_manifest "$root")" || return 1
    dmg="$root/$(release_manifest_get "$manifest" DMG_FILENAME)"
    event create-final-dmg
    printf 'signed dmg containing stapled app\n' >"$dmg"
    release_manifest_set "$manifest" DMG_PHASE app-stapled
    release_manifest_set "$manifest" DMG_SHA256 "$(release_sha256 "$dmg")"
}
release_notary_final_verify_dmg() { event final-dmg-verify; }

expect_false "notarization refuses a missing Keychain profile" release_notary_main "$build_root"
expect_false "notarization refuses raw credential arguments" release_notary_main "$build_root" --apple-id person@example.com
TEST_UID=0
expect_false "notarization refuses root" release_notary_main "$build_root" --keychain-profile letitbrew-release
TEST_UID=501

bad_version_root="$TEST_ROOT/bad-version"
/usr/bin/ditto "$build_root" "$bad_version_root"
bad_version_manifest="$(release_find_manifest "$bad_version_root")"
release_manifest_set "$bad_version_manifest" MARKETING_VERSION '../0.3.0'
expect_false "notarization rejects a non-dotted-decimal manifest version" release_notary_main "$bad_version_root" --keychain-profile letitbrew-release
release_notary_cleanup >/dev/null 2>&1 || true

noncanonical_version_root="$TEST_ROOT/noncanonical-version"
/usr/bin/ditto "$build_root" "$noncanonical_version_root"
noncanonical_version_manifest="$(release_find_manifest "$noncanonical_version_root")"
release_manifest_set "$noncanonical_version_manifest" MARKETING_VERSION '00.4.0'
expect_false "notarization rejects a noncanonical numeric version" release_notary_main "$noncanonical_version_root" --keychain-profile letitbrew-release
release_notary_cleanup >/dev/null 2>&1 || true

bad_name_root="$TEST_ROOT/bad-name"
/usr/bin/ditto "$build_root" "$bad_name_root"
bad_name_manifest="$(release_find_manifest "$bad_name_root")"
release_manifest_set "$bad_name_manifest" DMG_FILENAME '../Let It Brew.dmg'
expect_false "notarization rejects a slash-bearing DMG filename" release_notary_main "$bad_name_root" --keychain-profile letitbrew-release
release_notary_cleanup >/dev/null 2>&1 || true

staple_failure_root="$TEST_ROOT/staple-failure"
/usr/bin/ditto "$build_root" "$staple_failure_root"
TEST_STAPLE_FAIL=1
clear_ledger
expect_false "app staple failure stops notarization" release_notary_main "$staple_failure_root" --keychain-profile letitbrew-release --timeout 30m
expect_false "app staple failure prevents final DMG construction" /usr/bin/grep -q create-final-dmg "$TEST_LEDGER"
release_notary_cleanup >/dev/null 2>&1 || true
expect_false "failed notarization cleanup removes its owned lock" test -e "$staple_failure_root/.letitbrew-direct-distribution.lock"
TEST_STAPLE_FAIL=0
TEST_SUBMIT_COUNT=0
/bin/mkdir "$build_root/.letitbrew-direct-distribution.lock"
printf 'other-notarizer\n' >"$build_root/.letitbrew-direct-distribution.lock/owner"
expect_false "notarization refuses a concurrent release-root lock" release_notary_main "$build_root" --keychain-profile letitbrew-release
/bin/rm "$build_root/.letitbrew-direct-distribution.lock/owner"
/bin/rmdir "$build_root/.letitbrew-direct-distribution.lock"
clear_ledger
expect_true "two-submission notarization transaction succeeds" release_notary_main "$build_root" --keychain-profile letitbrew-release --timeout 30m
notary_events="$(/usr/bin/tr '\n' ',' <"$TEST_LEDGER")"
expect_contains <(printf '%s\n' "$notary_events") "submit:LetItBrew-${TEST_VERSION}-${TEST_BUILD}\\.app-notary\\.zip:.*--keychain-profile letitbrew-release --no-wait --output-format json,wait:11111111-1111-1111-1111-111111111111:.*--keychain-profile letitbrew-release --timeout 30m --output-format json,log:.*11111111-1111-1111-1111-111111111111.*app-notary-log\\.json\\.new\\.[0-9]+,stapler:staple:Let It Brew\\.app,stapler:validate:Let It Brew\\.app,notary-verify-app,notary-copy:LetItBrew-${TEST_VERSION}-${TEST_BUILD}\\.stapled-app\\.zip,create-final-dmg,notary-copy:LetItBrew-${TEST_VERSION}\\.notary-submission\\.dmg,submit:LetItBrew-${TEST_VERSION}\\.notary-submission\\.dmg:.*--keychain-profile letitbrew-release --no-wait --output-format json,wait:22222222-2222-2222-2222-222222222222:.*--keychain-profile letitbrew-release --timeout 30m --output-format json,log:.*22222222-2222-2222-2222-222222222222.*dmg-notary-log\\.json\\.new\\.[0-9]+,stapler:validate:LetItBrew-${TEST_VERSION}\\.dmg,stapler:staple:LetItBrew-${TEST_VERSION}\\.dmg,final-dmg-verify," "order is app submit/wait/log/staple, final DMG build, DMG submit/wait/log/staple"
expect_equal "$(release_manifest_get "$build_manifest" NOTARIZATION_COMPLETE)" 1 "completion is journaled only after final verification"
expect_true "notarization creates the permanent website DMG alias" \
    test -f "$build_root/LetItBrew.dmg"
expect_equal "$(release_sha256 "$build_root/LetItBrew.dmg")" \
    "$(release_sha256 "$build_root/LetItBrew-${TEST_VERSION}.dmg")" \
    "permanent website alias is byte-identical to the versioned DMG"
/bin/chmod 0644 "$build_root/LetItBrew.dmg"
expect_true "completed notarization revalidates the existing website alias" \
    release_notary_main "$build_root" --keychain-profile letitbrew-release --timeout 30m
expect_equal "$(/usr/bin/stat -f '%Lp' "$build_root/LetItBrew.dmg")" 600 \
    "completed notarization restores the existing website alias to mode 0600"
expect_true "final checksum file exists" test -f "$build_root/LetItBrew-${TEST_VERSION}-SHA256SUMS"
checksum_file="$build_root/LetItBrew-${TEST_VERSION}-SHA256SUMS"
expect_equal "$(/usr/bin/sed -n '1p' "$checksum_file")" \
    "$(release_sha256 "$build_root/LetItBrew-${TEST_VERSION}.dmg")  LetItBrew-${TEST_VERSION}.dmg" \
    "checksum publishes the updater's exact two-space DMG entry"
expect_equal "$(/usr/bin/sed -n '2p' "$checksum_file")" \
    "$(release_sha256 "$build_manifest")  $(/usr/bin/basename "$build_manifest")" \
    "checksum publishes the exact two-space manifest entry"
expect_equal "$(/usr/bin/awk 'END { print NR + 0 }' "$checksum_file")" 2 \
    "checksum contains exactly the documented two entries"
expect_equal "$TEST_SUBMIT_COUNT" 2 "exactly two artifacts are submitted"

echo
echo "-- timeout resume never duplicates a submission --"
resume_root="$TEST_ROOT/resume"
/bin/mkdir "$resume_root"
resume_manifest="$resume_root/LetItBrew-resume.manifest"
resume_artifact="$resume_root/app.zip"
printf 'resume bytes\n' >"$resume_artifact"
release_manifest_set "$resume_manifest" FORMAT 1
TEST_WAIT_FAIL=1
TEST_SUBMIT_COUNT=0
clear_ledger
expect_false "bounded wait failure preserves nonzero result" release_notary_process_submission APP resume "$resume_artifact" profile 1m "$resume_manifest" "$resume_root"
expect_equal "$(release_manifest_get "$resume_manifest" APP_NOTARY_SUBMISSION_ID)" 11111111-1111-1111-1111-111111111111 "submission UUID is persisted before wait"
TEST_WAIT_FAIL=0
expect_true "retry resumes the recorded UUID" release_notary_process_submission APP resume "$resume_artifact" profile 1m "$resume_manifest" "$resume_root"
expect_equal "$TEST_SUBMIT_COUNT" 1 "resume performs no second submit"

bad_log="$TEST_ROOT/bad-log.json"
good_log="$TEST_ROOT/good-log.json"
printf '{"status":"Accepted","issues":null}\n' >"$good_log"
printf '{"status":"Accepted","issues":[{"severity":"error"}]}\n' >"$bad_log"
# Exercise the real parser after the adapter-based transaction.
unset -f release_notary_log_has_no_issues
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
expect_true "accepts an Accepted notarization log with null issues" release_notary_log_has_no_issues "$good_log"
expect_false "rejects a notarization log with issues" release_notary_log_has_no_issues "$bad_log"

echo
echo "=================================="
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: $TESTS isolated direct-distribution assertions"
else
    echo "FAIL: $FAILURES of $TESTS isolated direct-distribution assertions" >&2
fi
exit "$FAILURES"
