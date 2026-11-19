#!/bin/bash
# Release-grade staged upgrade for the production app. The ordinary app must
# already be stopped. Service changes are performed only by the signed app
# installed directly at /Applications/Let It Brew.app.
set -uo pipefail

UPGRADE_DEST="/Applications/Let It Brew.app"
UPGRADE_EXPECTED_ID="com.ruban24.letitbrew"
UPGRADE_EXPECTED_TEAM="MV2UL94MDC"
UPGRADE_LABEL="$UPGRADE_EXPECTED_ID.daemon"
UPGRADE_TIMEOUT=20
UPGRADE_LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
UPGRADE_PHASE="initial"
UPGRADE_WORKDIR=""
UPGRADE_STAGE=""
UPGRADE_BACKUP=""
UPGRADE_FAILED=""
UPGRADE_LOCK=""
UPGRADE_LOCK_TOKEN=""
UPGRADE_BASELINE=""
UPGRADE_RELAUNCH=0
UPGRADE_RELAUNCHED=0
UPGRADE_COMMAND_COUNTER=0
UPGRADE_LAST_OUTPUT=""
UPGRADE_OLD_PROBE_MODE=""
UPGRADE_PREPARED_BASELINE=""
UPGRADE_OLD_VERSION=""
UPGRADE_OLD_BUILD=""
UPGRADE_OLD_CDHASH=""
UPGRADE_ACTIVE_COMMAND_PID=""
UPGRADE_PRESERVE_DAEMON_STATE=0
UPGRADE_OLD_SERVICE_STATE="registered"

upgrade_note() { printf '%s\n' "$*"; }
upgrade_fail() { echo "FAIL: $*" >&2; return 1; }

upgrade_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

upgrade_native_cdhash() {
    /usr/bin/codesign -dvvv "$1" 2>&1 \
        | /usr/bin/awk -F= '/^CDHash=/{print tolower($2); exit}'
}

upgrade_team_id() {
    /usr/bin/codesign -dvvv --verbose=4 "$1" 2>&1 \
        | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}'
}

upgrade_executable_manifest() {
    local app="$1"
    /usr/bin/shasum -a 256 \
        "$app/Contents/MacOS/LetItBrew" \
        "$app/Contents/Library/LaunchServices/LetItBrewDaemon" \
        "$app/Contents/Helpers/letitbrew" \
        | /usr/bin/awk '{print $1}'
}

upgrade_verify_artifact() {
    "$UPGRADE_SCRIPT_DIR/verify-artifact.sh" "$@"
}

upgrade_build_is_strictly_newer() {
    local old_build="$1"
    local new_build="$2"
    case "$old_build" in ''|*[!0-9]*) return 2 ;; esac
    case "$new_build" in ''|*[!0-9]*) return 2 ;; esac
    [ "$new_build" -gt "$old_build" ]
}

upgrade_json_field() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

upgrade_run_bounded() {
    local timeout="$1"
    local output="$2"
    shift 2
    local pid status waited=0

    : >"$output" || return 1
    "$@" >"$output" 2>&1 &
    pid=$!
    UPGRADE_ACTIVE_COMMAND_PID="$pid"
    while /bin/kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$timeout" ]; then
            echo "TIMEOUT after ${timeout}s: $*" >>"$output"
            /bin/kill -TERM "$pid" 2>/dev/null || true
            /bin/sleep 2
            if /bin/kill -0 "$pid" 2>/dev/null; then
                # This PID is the precisely identified command-mode process
                # launched above, never the ordinary menu-bar app.
                /bin/kill -KILL "$pid" 2>/dev/null || true
            fi
            wait "$pid" 2>/dev/null || true
            UPGRADE_ACTIVE_COMMAND_PID=""
            return 124
        fi
        /bin/sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
    status=$?
    UPGRADE_ACTIVE_COMMAND_PID=""
    return "$status"
}

upgrade_run_app_command() {
    local app_bin="$1"
    shift
    UPGRADE_COMMAND_COUNTER=$((UPGRADE_COMMAND_COUNTER + 1))
    UPGRADE_LAST_OUTPUT="$UPGRADE_WORKDIR/command-$UPGRADE_COMMAND_COUNTER.log"
    upgrade_run_bounded "$UPGRADE_TIMEOUT" "$UPGRADE_LAST_OUTPUT" "$app_bin" "$@"
}

upgrade_stop_active_command() {
    local waited=0
    [ -n "$UPGRADE_ACTIVE_COMMAND_PID" ] || return 0
    if /bin/kill -0 "$UPGRADE_ACTIVE_COMMAND_PID" 2>/dev/null; then
        /bin/kill -TERM "$UPGRADE_ACTIVE_COMMAND_PID" 2>/dev/null || true
        while /bin/kill -0 "$UPGRADE_ACTIVE_COMMAND_PID" 2>/dev/null && [ "$waited" -lt 2 ]; do
            /bin/sleep 1
            waited=$((waited + 1))
        done
        if /bin/kill -0 "$UPGRADE_ACTIVE_COMMAND_PID" 2>/dev/null; then
            /bin/kill -KILL "$UPGRADE_ACTIVE_COMMAND_PID" 2>/dev/null || true
        fi
        wait "$UPGRADE_ACTIVE_COMMAND_PID" 2>/dev/null || true
    fi
    UPGRADE_ACTIVE_COMMAND_PID=""
}

upgrade_validate_json_probe() {
    local json_file="$1"
    local expected_version="$2"
    local expected_build="$3"
    local expected_cdhash="$4"
    local protocol marketing build identity ready

    protocol="$(upgrade_json_field "$json_file" protocolVersion)" || return 1
    marketing="$(upgrade_json_field "$json_file" marketingVersion)" || return 1
    build="$(upgrade_json_field "$json_file" build)" || return 1
    identity="$(upgrade_json_field "$json_file" buildIdentity)" || return 1
    ready="$(upgrade_json_field "$json_file" reconciliationReady)" || return 1
    identity="$(printf '%s' "$identity" | /usr/bin/tr '[:upper:]' '[:lower:]')"

    case "$protocol" in ''|*[!0-9]*) return 1 ;; esac
    [ "$marketing" = "$expected_version" ] || return 1
    [ "$build" = "$expected_build" ] || return 1
    [ "$identity" = "$expected_cdhash" ] || return 1
    [ "$ready" = "true" ] || [ "$ready" = "1" ] || return 1
}

upgrade_probe_new_strict() {
    local app_bin="$1"
    local expected_version="$2"
    local expected_build="$3"
    local expected_cdhash="$4"

    if ! upgrade_run_app_command "$app_bin" --probe-daemon --json; then
        [ -f "$UPGRADE_LAST_OUTPUT" ] && /bin/cat "$UPGRADE_LAST_OUTPUT" >&2
        return 1
    fi
    if ! upgrade_validate_json_probe "$UPGRADE_LAST_OUTPUT" "$expected_version" "$expected_build" "$expected_cdhash"; then
        echo "FAIL: daemon probe JSON did not match the installed candidate exactly." >&2
        /bin/cat "$UPGRADE_LAST_OUTPUT" >&2
        return 1
    fi
    upgrade_note "ok: authenticated daemon identity matches native CDHash $expected_cdhash"
}

# Sets UPGRADE_PREPARED_BASELINE and UPGRADE_OLD_PROBE_MODE.
# A successful but non-JSON probe is accepted only for the legacy old bundle;
# this path is never used to validate the newly installed candidate.
upgrade_prepare_old() {
    local app_bin="$1"
    local expected_version="$2"
    local expected_build="$3"
    local expected_cdhash="$4"
    local returned_baseline first second

    if ! upgrade_run_app_command "$app_bin" --probe-daemon --json; then
        /bin/cat "$UPGRADE_LAST_OUTPUT" >&2
        return 1
    fi
    if upgrade_json_field "$UPGRADE_LAST_OUTPUT" protocolVersion >/dev/null 2>&1; then
        upgrade_validate_json_probe "$UPGRADE_LAST_OUTPUT" "$expected_version" "$expected_build" "$expected_cdhash" || {
            echo "FAIL: old daemon JSON identity did not match the installed old bundle." >&2
            return 1
        }
        UPGRADE_OLD_PROBE_MODE="strict"
        if ! upgrade_run_app_command "$app_bin" --prepare-daemon-upgrade --json; then
            /bin/cat "$UPGRADE_LAST_OUTPUT" >&2
            return 1
        fi
        upgrade_validate_json_probe "$UPGRADE_LAST_OUTPUT" "$expected_version" "$expected_build" "$expected_cdhash" || return 1
        returned_baseline="$(upgrade_json_field "$UPGRADE_LAST_OUTPUT" sleepDisabledBaseline)" || return 1
        case "$returned_baseline" in 0|1) ;; *) return 1 ;; esac
        first="$(baseline_read_sleepdisabled)" || return 1
        [ "$first" = "$returned_baseline" ] || {
            echo "FAIL: daemon prepared baseline $returned_baseline but pmset reports $first." >&2
            return 1
        }
        UPGRADE_PREPARED_BASELINE="$returned_baseline"
        return 0
    fi

    if ! /usr/bin/grep -Eq '^Let It Brew daemon protocol v[0-9]+ ready\.$' "$UPGRADE_LAST_OUTPUT"; then
        echo "FAIL: old daemon produced neither strict JSON nor the authenticated legacy probe." >&2
        /bin/cat "$UPGRADE_LAST_OUTPUT" >&2
        return 1
    fi
    UPGRADE_OLD_PROBE_MODE="legacy"
    echo "NOTICE: old candidate uses legacy authenticated protocol-only health; this exception applies only before swap and after restoring that same old bundle." >&2
    first="$(baseline_read_sleepdisabled)" || return 1
    /bin/sleep 1
    second="$(baseline_read_sleepdisabled)" || return 1
    [ "$first" = "$second" ] || {
        echo "FAIL: SleepDisabled was not stable while preparing the legacy old candidate." >&2
        return 1
    }
    UPGRADE_PREPARED_BASELINE="$first"
}

# Updater-only preparation contract. Unlike the legacy/manual path above, this
# records actual service presence and refuses every ambiguous first-connect
# failure. The signed app owns the XPC domain/code absence classifier; shell
# never infers presence from UserDefaults or launchctl text.
upgrade_prepare_old_preserving_daemon_state() {
    local app_bin="$1"
    local expected_version="$2"
    local expected_build="$3"
    local expected_cdhash="$4"
    local state ready returned_baseline first second

    if ! upgrade_run_app_command "$app_bin" --prepare-update --json; then
        /bin/cat "$UPGRADE_LAST_OUTPUT" >&2
        return 1
    fi
    state="$(upgrade_json_field "$UPGRADE_LAST_OUTPUT" daemonState)" || return 1
    ready="$(upgrade_json_field "$UPGRADE_LAST_OUTPUT" reconciliationReady)" || return 1
    [ "$ready" = true ] || return 1

    case "$state" in
        registered)
            upgrade_validate_json_probe \
                "$UPGRADE_LAST_OUTPUT" \
                "$expected_version" "$expected_build" "$expected_cdhash" || return 1
            returned_baseline="$(upgrade_json_field "$UPGRADE_LAST_OUTPUT" sleepDisabledBaseline)" || return 1
            case "$returned_baseline" in 0|1) ;; *) return 1 ;; esac
            first="$(baseline_read_sleepdisabled)" || return 1
            [ "$first" = "$returned_baseline" ] || {
                echo "FAIL: daemon prepared baseline $returned_baseline but pmset reports $first." >&2
                return 1
            }
            UPGRADE_OLD_SERVICE_STATE="registered"
            UPGRADE_OLD_PROBE_MODE="strict"
            UPGRADE_PREPARED_BASELINE="$returned_baseline"
            ;;
        absent)
            first="$(baseline_read_sleepdisabled)" || return 1
            /bin/sleep 1
            second="$(baseline_read_sleepdisabled)" || return 1
            [ "$first" = "$second" ] || {
                echo "FAIL: SleepDisabled was not stable while proving the old daemon absent." >&2
                return 1
            }
            UPGRADE_OLD_SERVICE_STATE="absent"
            UPGRADE_OLD_PROBE_MODE=""
            UPGRADE_PREPARED_BASELINE="$first"
            ;;
        *)
            echo "FAIL: signed app returned unknown daemonState '$state'." >&2
            return 1
            ;;
    esac
}

upgrade_probe_restored_old() {
    local app_bin="$1"
    local expected_version="$2"
    local expected_build="$3"
    local expected_cdhash="$4"

    if [ "$UPGRADE_OLD_PROBE_MODE" = "strict" ]; then
        upgrade_probe_new_strict "$app_bin" "$expected_version" "$expected_build" "$expected_cdhash"
        return
    fi
    if ! upgrade_run_app_command "$app_bin" --probe-daemon; then
        /bin/cat "$UPGRADE_LAST_OUTPUT" >&2
        return 1
    fi
    /usr/bin/grep -Eq '^Let It Brew daemon protocol v[0-9]+ ready\.$' "$UPGRADE_LAST_OUTPUT"
}

upgrade_process_count_for_path() {
    local process_name="$1"
    local expected_path="$2"
    local expected_bundle_program=""
    local count=0 pid command
    if [ "$process_name" = "LetItBrewDaemon" ]; then
        case "$expected_path" in
            */Contents/*) expected_bundle_program="Contents/${expected_path#*/Contents/}" ;;
        esac
    fi
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        command="$(/bin/ps -p "$pid" -o command= 2>/dev/null)"
        case "$command" in
            "$expected_path"|"$expected_path "*) count=$((count + 1)) ;;
            "$expected_bundle_program"|"$expected_bundle_program "*)
                [ -n "$expected_bundle_program" ] && count=$((count + 1))
                ;;
        esac
    done < <(/usr/bin/pgrep -x "$process_name" 2>/dev/null || true)
    printf '%s\n' "$count"
}

upgrade_launch_job_matches_bundle_program() {
    local launch_state="$1"
    local expected_program="$2"
    local expected_build="$3"
    printf '%s\n' "$launch_state" \
        | /usr/bin/grep -Eq "^[[:space:]]*program identifier = ${expected_program//\//\\/} \\(mode: [0-9]+\\)$" \
        && printf '%s\n' "$launch_state" \
            | /usr/bin/grep -Fqx $'\t'"parent bundle identifier = $UPGRADE_EXPECTED_ID" \
        && printf '%s\n' "$launch_state" \
            | /usr/bin/grep -Fqx $'\t'"parent bundle version = $expected_build" \
        && printf '%s\n' "$launch_state" \
            | /usr/bin/grep -Fqx $'\tstate = running'
}

upgrade_wait_service_absent() {
    local daemon_path="$1"
    local waited=0
    while [ "$waited" -le "$UPGRADE_TIMEOUT" ]; do
        if ! /bin/launchctl print "system/$UPGRADE_LABEL" >/dev/null 2>&1 \
            && [ "$(upgrade_process_count_for_path LetItBrewDaemon "$daemon_path")" -eq 0 ]; then
            return 0
        fi
        /bin/sleep 1
        waited=$((waited + 1))
    done
    echo "FAIL: daemon job/process did not disappear within ${UPGRADE_TIMEOUT}s." >&2
    return 1
}

upgrade_wait_service_current() {
    local daemon_path="$1"
    local expected_build="$2"
    local expected_program="Contents/${daemon_path#*/Contents/}"
    local waited=0 launch_state count
    while [ "$waited" -le "$UPGRADE_TIMEOUT" ]; do
        launch_state="$(/bin/launchctl print "system/$UPGRADE_LABEL" 2>/dev/null)" || launch_state=""
        count="$(upgrade_process_count_for_path LetItBrewDaemon "$daemon_path")"
        if [ "$count" -eq 1 ] \
            && upgrade_launch_job_matches_bundle_program "$launch_state" "$expected_program" "$expected_build"; then
            return 0
        fi
        /bin/sleep 1
        waited=$((waited + 1))
    done
    echo "FAIL: expected exactly one current daemon for $daemon_path (build $expected_build); observed process count $count." >&2
    return 1
}

upgrade_register_service() {
    local app_bin="$1"
    local expected_bin="$UPGRADE_DEST/Contents/MacOS/LetItBrew"

    [ "$app_bin" = "$expected_bin" ] || {
        echo "FAIL: refusing to register a service from anything except the exact installed app." >&2
        return 1
    }
    [ -d "$UPGRADE_DEST" ] && [ ! -L "$UPGRADE_DEST" ] || {
        echo "FAIL: installed app must be an ordinary bundle before LaunchServices registration." >&2
        return 1
    }
    [ -x "$UPGRADE_LSREGISTER" ] || {
        echo "FAIL: LaunchServices registration tool is unavailable at $UPGRADE_LSREGISTER." >&2
        return 1
    }
    "$UPGRADE_LSREGISTER" -f -R -trusted "$UPGRADE_DEST" || {
        echo "FAIL: LaunchServices did not accept the exact installed app bundle." >&2
        return 1
    }
    upgrade_run_app_command "$app_bin" --register-daemon || {
        /bin/cat "$UPGRADE_LAST_OUTPUT" >&2
        return 1
    }
}

upgrade_unregister_service() {
    local app_bin="$1"
    upgrade_run_app_command "$app_bin" --unregister-daemon || {
        /bin/cat "$UPGRADE_LAST_OUTPUT" >&2
        return 1
    }
}

upgrade_unregister_best_effort() {
    local app_bin="$1"
    upgrade_run_app_command "$app_bin" --unregister-daemon || {
        echo "NOTICE: unregister returned nonzero during rollback; absence will still be verified." >&2
        /bin/cat "$UPGRADE_LAST_OUTPUT" >&2
    }
}

upgrade_request_ordinary_quit() {
    /usr/bin/osascript -e 'tell application id "com.ruban24.letitbrew" to quit' >/dev/null 2>&1
}

upgrade_open_installed_app() {
    /usr/bin/open "$UPGRADE_DEST"
}

upgrade_quit_ordinary_app() {
    [ "$(upgrade_process_count_for_path LetItBrew "$UPGRADE_DEST/Contents/MacOS/LetItBrew")" -eq 0 ] && return 0
    upgrade_request_ordinary_quit || return 1
    local waited=0
    while [ "$waited" -le "$UPGRADE_TIMEOUT" ]; do
        [ "$(upgrade_process_count_for_path LetItBrew "$UPGRADE_DEST/Contents/MacOS/LetItBrew")" -eq 0 ] && return 0
        /bin/sleep 1
        waited=$((waited + 1))
    done
    return 1
}

upgrade_relaunch_exactly_one() {
    [ "$(upgrade_process_count_for_path LetItBrew "$UPGRADE_DEST/Contents/MacOS/LetItBrew")" -eq 0 ] || return 1
    upgrade_open_installed_app || return 1
    UPGRADE_RELAUNCHED=1
    local waited=0
    while [ "$waited" -le "$UPGRADE_TIMEOUT" ]; do
        [ "$(upgrade_process_count_for_path LetItBrew "$UPGRADE_DEST/Contents/MacOS/LetItBrew")" -eq 1 ] && return 0
        /bin/sleep 1
        waited=$((waited + 1))
    done
    return 1
}

upgrade_verify_installed() {
    local expected_manifest="$1"
    upgrade_verify_artifact "$UPGRADE_DEST" || return 1
    [ "$(upgrade_executable_manifest "$UPGRADE_DEST")" = "$expected_manifest" ] || {
        echo "FAIL: installed executable hashes differ from the verified stage." >&2
        return 1
    }
}

upgrade_rollback() {
    local reason="$1"
    local old_version="$2"
    local old_build="$3"
    local old_cdhash="$4"
    local rollback_ok=1

    echo "ROLLBACK: $reason" >&2
    UPGRADE_PHASE="rolling-back"
    if [ "$UPGRADE_RELAUNCHED" -eq 1 ]; then
        upgrade_quit_ordinary_app || { echo "FAIL: could not gracefully quit the newly relaunched app; preserving backup without moving a live binary." >&2; return 1; }
        UPGRADE_RELAUNCHED=0
    fi

    if [ -x "$UPGRADE_DEST/Contents/MacOS/LetItBrew" ]; then
        upgrade_unregister_best_effort "$UPGRADE_DEST/Contents/MacOS/LetItBrew"
    fi
    upgrade_wait_service_absent "$UPGRADE_DEST/Contents/Library/LaunchServices/LetItBrewDaemon" || {
        echo "FAIL: failed new daemon is still live; backup remains at $UPGRADE_BACKUP." >&2
        return 1
    }

    baseline_assert "$UPGRADE_BASELINE" "pre-rollback baseline" || rollback_ok=0
    [ -d "$UPGRADE_BACKUP" ] || { echo "FAIL: rollback backup is missing at $UPGRADE_BACKUP." >&2; return 1; }
    if [ -e "$UPGRADE_FAILED" ]; then
        echo "FAIL: rollback quarantine path already exists: $UPGRADE_FAILED" >&2
        return 1
    fi
    if [ -e "$UPGRADE_DEST" ]; then
        /bin/mv "$UPGRADE_DEST" "$UPGRADE_FAILED" || return 1
    fi
    if ! /bin/mv "$UPGRADE_BACKUP" "$UPGRADE_DEST"; then
        if [ -e "$UPGRADE_FAILED" ]; then
            /bin/mv "$UPGRADE_FAILED" "$UPGRADE_DEST" 2>/dev/null || true
        fi
        echo "FAIL: could not restore the old bundle; preserved available bundles in $UPGRADE_WORKDIR." >&2
        return 1
    fi

    # The restored bundle may predate the notifications framework (1.0.x).
    upgrade_verify_artifact "$UPGRADE_DEST" --restored || rollback_ok=0
    upgrade_establish_old_daemon_state \
        "$old_version" "$old_build" "$old_cdhash" || rollback_ok=0
    baseline_assert "$UPGRADE_BASELINE" "rolled-back exact baseline" || rollback_ok=0

    if [ "$rollback_ok" -eq 1 ] && [ "$UPGRADE_RELAUNCH" -eq 1 ]; then
        upgrade_relaunch_exactly_one || rollback_ok=0
    fi
    if [ "$rollback_ok" -eq 1 ]; then
        UPGRADE_PHASE="rolled-back"
        if [ -e "$UPGRADE_FAILED" ]; then
            echo "ROLLBACK COMPLETE: old app/service restored; failed new bundle preserved at $UPGRADE_FAILED." >&2
        else
            echo "ROLLBACK COMPLETE: old app/service restored; the staged candidate remains at $UPGRADE_STAGE." >&2
        fi
        return 0
    fi
    UPGRADE_PHASE="rollback-failed"
    echo "ROLLBACK INCOMPLETE: inspect $UPGRADE_DEST and $UPGRADE_WORKDIR; nothing further was deleted." >&2
    return 1
}

upgrade_after_swap_failure() {
    local reason="$1"
    shift
    upgrade_rollback "$reason" "$@" || true
    return 1
}

upgrade_recover_while_moving_old() {
    if [ -d "$UPGRADE_BACKUP" ]; then
        upgrade_rollback "interrupted while moving old bundle" \
            "$UPGRADE_OLD_VERSION" "$UPGRADE_OLD_BUILD" "$UPGRADE_OLD_CDHASH"
    else
        upgrade_restore_old_state_in_place \
            "$UPGRADE_OLD_VERSION" "$UPGRADE_OLD_BUILD" "$UPGRADE_OLD_CDHASH"
    fi
}

upgrade_establish_old_daemon_state() {
    local old_version="$1"
    local old_build="$2"
    local old_cdhash="$3"
    local ok=1

    case "$UPGRADE_OLD_SERVICE_STATE" in
        registered)
            upgrade_register_service "$UPGRADE_DEST/Contents/MacOS/LetItBrew" || {
                echo "NOTICE: old-service registration returned nonzero; current-service health will decide recovery." >&2
            }
            upgrade_wait_service_current \
                "$UPGRADE_DEST/Contents/Library/LaunchServices/LetItBrewDaemon" \
                "$old_build" || ok=0
            upgrade_probe_restored_old \
                "$UPGRADE_DEST/Contents/MacOS/LetItBrew" \
                "$old_version" "$old_build" "$old_cdhash" || ok=0
            ;;
        absent)
            upgrade_wait_service_absent \
                "$UPGRADE_DEST/Contents/Library/LaunchServices/LetItBrewDaemon" || ok=0
            ;;
        *)
            echo "FAIL: unknown old daemon state '$UPGRADE_OLD_SERVICE_STATE'." >&2
            ok=0
            ;;
    esac
    [ "$ok" -eq 1 ]
}

upgrade_restore_old_state_in_place() {
    local old_version="$1"
    local old_build="$2"
    local old_cdhash="$3"
    local ok=1

    upgrade_establish_old_daemon_state \
        "$old_version" "$old_build" "$old_cdhash" || ok=0
    baseline_assert "$UPGRADE_BASELINE" "old service recovery baseline" || ok=0
    if [ "$ok" -eq 1 ] && [ "$UPGRADE_RELAUNCH" -eq 1 ]; then
        upgrade_relaunch_exactly_one || ok=0
    fi
    [ "$ok" -eq 1 ]
}

upgrade_transaction() {
    local old_version="$1"
    local old_build="$2"
    local old_cdhash="$3"
    local new_version="$4"
    local new_build="$5"
    local new_cdhash="$6"
    local staged_manifest="$7"
    local old_bin="$UPGRADE_DEST/Contents/MacOS/LetItBrew"
    local old_daemon="$UPGRADE_DEST/Contents/Library/LaunchServices/LetItBrewDaemon"
    local new_bin new_daemon

    upgrade_note "-- stop/unregister old service --"
    UPGRADE_PHASE="stopping-old-service"
    if ! upgrade_unregister_service "$old_bin"; then
        upgrade_restore_old_state_in_place "$old_version" "$old_build" "$old_cdhash" || true
        UPGRADE_PHASE="pre-swap"
        return 1
    fi
    if ! upgrade_wait_service_absent "$old_daemon"; then
        echo "FAIL: old service stop could not be proven; the bundle was not moved." >&2
        return 1
    fi
    UPGRADE_PHASE="old-service-stopped"
    if ! baseline_assert "$UPGRADE_BASELINE" "after old service stop"; then
        upgrade_restore_old_state_in_place "$old_version" "$old_build" "$old_cdhash" || true
        UPGRADE_PHASE="pre-swap"
        return 1
    fi

    upgrade_note "-- atomic staged replacement --"
    UPGRADE_PHASE="moving-old"
    if ! /bin/mv "$UPGRADE_DEST" "$UPGRADE_BACKUP"; then
        upgrade_restore_old_state_in_place "$old_version" "$old_build" "$old_cdhash" || true
        UPGRADE_PHASE="pre-swap"
        return 1
    fi
    UPGRADE_PHASE="old-moved"
    if ! /bin/mv "$UPGRADE_STAGE" "$UPGRADE_DEST"; then
        upgrade_after_swap_failure "could not install the staged bundle" "$old_version" "$old_build" "$old_cdhash" || true
        return 1
    fi
    UPGRADE_PHASE="swapped"
    new_bin="$UPGRADE_DEST/Contents/MacOS/LetItBrew"
    new_daemon="$UPGRADE_DEST/Contents/Library/LaunchServices/LetItBrewDaemon"

    upgrade_verify_installed "$staged_manifest" || upgrade_after_swap_failure "installed verification failed" "$old_version" "$old_build" "$old_cdhash" || return 1
    case "$UPGRADE_OLD_SERVICE_STATE" in
        registered)
            upgrade_register_service "$new_bin" || upgrade_after_swap_failure "new daemon registration failed" "$old_version" "$old_build" "$old_cdhash" || return 1
            upgrade_wait_service_current "$new_daemon" "$new_build" || upgrade_after_swap_failure "new daemon did not become current" "$old_version" "$old_build" "$old_cdhash" || return 1
            upgrade_probe_new_strict "$new_bin" "$new_version" "$new_build" "$new_cdhash" || upgrade_after_swap_failure "new daemon identity probe failed" "$old_version" "$old_build" "$old_cdhash" || return 1
            ;;
        absent)
            upgrade_wait_service_absent "$new_daemon" || upgrade_after_swap_failure "new daemon was not absent after replacement" "$old_version" "$old_build" "$old_cdhash" || return 1
            ;;
        *)
            upgrade_after_swap_failure "unknown preserved daemon state '$UPGRADE_OLD_SERVICE_STATE'" "$old_version" "$old_build" "$old_cdhash" || true
            return 1
            ;;
    esac
    baseline_assert "$UPGRADE_BASELINE" "new service exact baseline" || upgrade_after_swap_failure "new service changed SleepDisabled" "$old_version" "$old_build" "$old_cdhash" || return 1

    if [ "$UPGRADE_RELAUNCH" -eq 1 ]; then
        upgrade_relaunch_exactly_one || upgrade_after_swap_failure "exactly-one app relaunch failed" "$old_version" "$old_build" "$old_cdhash" || return 1
    fi

    # This is the only successful path that deletes the old bundle.
    UPGRADE_PHASE="committed"
    if ! /bin/rm -rf "$UPGRADE_BACKUP"; then
        UPGRADE_PHASE="success-backup-retained"
        echo "FAIL: new app/service are healthy, but the verified backup could not be removed; retained at $UPGRADE_BACKUP." >&2
        return 1
    fi
    UPGRADE_PHASE="success"
    upgrade_note "PASS: installed $new_version ($new_build), daemon CDHash $new_cdhash"
}

upgrade_release_lock() {
    [ -n "$UPGRADE_LOCK" ] || return 0
    if [ -f "$UPGRADE_LOCK/owner" ] \
        && [ "$(/bin/cat "$UPGRADE_LOCK/owner" 2>/dev/null)" = "$UPGRADE_LOCK_TOKEN" ]; then
        /bin/rm -f "$UPGRADE_LOCK/owner"
        /bin/rmdir "$UPGRADE_LOCK" 2>/dev/null || true
    fi
}

upgrade_exit_cleanup() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        upgrade_stop_active_command
        case "$UPGRADE_PHASE" in
            old-moved|swapped)
                trap - EXIT INT TERM HUP
                upgrade_rollback "unexpected nonzero exit" \
                    "$UPGRADE_OLD_VERSION" "$UPGRADE_OLD_BUILD" "$UPGRADE_OLD_CDHASH" || true
                ;;
            stopping-old-service|old-service-stopped)
                trap - EXIT INT TERM HUP
                upgrade_restore_old_state_in_place \
                    "$UPGRADE_OLD_VERSION" "$UPGRADE_OLD_BUILD" "$UPGRADE_OLD_CDHASH" || true
                ;;
            moving-old)
                trap - EXIT INT TERM HUP
                upgrade_recover_while_moving_old || true
                ;;
        esac
    fi
    case "$UPGRADE_PHASE" in
        initial|pre-swap|success)
            if [ -n "$UPGRADE_WORKDIR" ] && [ -d "$UPGRADE_WORKDIR" ]; then
                /bin/rm -rf "$UPGRADE_WORKDIR"
            fi
            ;;
        *)
            [ -n "$UPGRADE_WORKDIR" ] && echo "NOTICE: recovery material preserved at $UPGRADE_WORKDIR" >&2
            ;;
    esac
    upgrade_release_lock
    return "$status"
}

upgrade_handle_signal() {
    trap - INT TERM HUP
    echo "INTERRUPTED: entering phase-aware recovery." >&2
    upgrade_stop_active_command
    case "$UPGRADE_PHASE" in
        stopping-old-service|old-service-stopped)
            upgrade_restore_old_state_in_place \
                "$UPGRADE_OLD_VERSION" "$UPGRADE_OLD_BUILD" "$UPGRADE_OLD_CDHASH" || true
            ;;
        old-moved|swapped)
            upgrade_rollback "upgrade interrupted" \
                "$UPGRADE_OLD_VERSION" "$UPGRADE_OLD_BUILD" "$UPGRADE_OLD_CDHASH" || true
            ;;
        moving-old)
            upgrade_recover_while_moving_old || true
            ;;
        rolling-back|rollback-failed|rolled-back|committed|success|success-backup-retained)
            echo "NOTICE: current phase is $UPGRADE_PHASE; preserving all remaining recovery material." >&2
            ;;
    esac
    exit 130
}

upgrade_main() {
    local source_bundle=""
    local argument
    for argument in "$@"; do
        case "$argument" in
            --relaunch) UPGRADE_RELAUNCH=1 ;;
            --preserve-daemon-state) UPGRADE_PRESERVE_DAEMON_STATE=1 ;;
            --*) echo "FATAL: unknown option '$argument'." >&2; return 1 ;;
            *)
                [ -z "$source_bundle" ] || { echo "FATAL: provide exactly one candidate bundle." >&2; return 1; }
                source_bundle="$argument"
                ;;
        esac
    done
    [ -n "$source_bundle" ] || { echo "usage: upgrade-installed-app.sh <new-Let It Brew.app> [--relaunch] [--preserve-daemon-state]" >&2; return 1; }
    [ "$(/usr/bin/id -u)" -ne 0 ] || { echo "FATAL: do not run this script as root; Service Management must run in the logged-in user context." >&2; return 1; }
    [ -d "$source_bundle" ] && [ ! -L "$source_bundle" ] || { echo "FATAL: candidate must be a real app directory, not a symlink." >&2; return 1; }
    [ -d "$UPGRADE_DEST" ] && [ ! -L "$UPGRADE_DEST" ] || { echo "FATAL: production app must exist directly at $UPGRADE_DEST." >&2; return 1; }

    UPGRADE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    # shellcheck source=lib-power-baseline.sh
    source "$UPGRADE_SCRIPT_DIR/lib-power-baseline.sh"

    source_canonical="$(cd "$(dirname "$source_bundle")" && pwd)/$(basename "$source_bundle")" || return 1
    [ "$source_canonical" != "$UPGRADE_DEST" ] || { echo "FATAL: candidate source must be separate from the installed bundle." >&2; return 1; }
    case "$source_canonical/" in
        "$UPGRADE_DEST/"*)
            echo "FATAL: candidate source must not be nested inside the installed bundle." >&2
            return 1
            ;;
    esac

    [ "$(upgrade_process_count_for_path LetItBrew "$UPGRADE_DEST/Contents/MacOS/LetItBrew")" -eq 0 ] || {
        echo "FATAL: quit the ordinary Let It Brew app and all command-mode instances before upgrading." >&2
        return 1
    }

    UPGRADE_LOCK="/Applications/.letitbrew-upgrade.lock"
    UPGRADE_LOCK_TOKEN="$$-$(/usr/bin/uuidgen)"
    /bin/mkdir "$UPGRADE_LOCK" 2>/dev/null || { echo "FATAL: another upgrade lock exists at $UPGRADE_LOCK; inspect it rather than deleting it automatically." >&2; return 1; }
    if ! printf '%s\n' "$UPGRADE_LOCK_TOKEN" >"$UPGRADE_LOCK/owner"; then
        /bin/rmdir "$UPGRADE_LOCK" 2>/dev/null || true
        return 1
    fi
    trap upgrade_exit_cleanup EXIT
    trap upgrade_handle_signal INT TERM HUP

    upgrade_verify_artifact "$source_bundle" || return 1
    UPGRADE_WORKDIR="$(/usr/bin/mktemp -d "/Applications/.letitbrew-upgrade.XXXXXX")" || return 1
    UPGRADE_STAGE="$UPGRADE_WORKDIR/staged.app"
    UPGRADE_BACKUP="$UPGRADE_WORKDIR/previous.app"
    UPGRADE_FAILED="$UPGRADE_WORKDIR/failed-new.app"
    /usr/bin/ditto "$source_bundle" "$UPGRADE_STAGE" || return 1
    upgrade_verify_artifact "$UPGRADE_STAGE" || return 1

    source_manifest="$(upgrade_executable_manifest "$source_bundle")" || return 1
    staged_manifest="$(upgrade_executable_manifest "$UPGRADE_STAGE")" || return 1
    [ "$source_manifest" = "$staged_manifest" ] || { echo "FATAL: staged executable hashes differ from source candidate." >&2; return 1; }

    old_info="$UPGRADE_DEST/Contents/Info.plist"
    new_info="$UPGRADE_STAGE/Contents/Info.plist"
    old_id="$(upgrade_plist_value "$old_info" CFBundleIdentifier)" || return 1
    new_id="$(upgrade_plist_value "$new_info" CFBundleIdentifier)" || return 1
    old_team="$(upgrade_team_id "$UPGRADE_DEST")"
    new_team="$(upgrade_team_id "$UPGRADE_STAGE")"
    [ "$old_id" = "$UPGRADE_EXPECTED_ID" ] && [ "$new_id" = "$UPGRADE_EXPECTED_ID" ] || { echo "FATAL: production bundle identifier mismatch." >&2; return 1; }
    [ "$old_team" = "$UPGRADE_EXPECTED_TEAM" ] && [ "$new_team" = "$UPGRADE_EXPECTED_TEAM" ] || { echo "FATAL: Team ID mismatch." >&2; return 1; }

    old_version="$(upgrade_plist_value "$old_info" CFBundleShortVersionString)" || return 1
    old_build="$(upgrade_plist_value "$old_info" CFBundleVersion)" || return 1
    new_version="$(upgrade_plist_value "$new_info" CFBundleShortVersionString)" || return 1
    new_build="$(upgrade_plist_value "$new_info" CFBundleVersion)" || return 1
    old_cdhash="$(upgrade_native_cdhash "$UPGRADE_DEST/Contents/Library/LaunchServices/LetItBrewDaemon")"
    new_cdhash="$(upgrade_native_cdhash "$UPGRADE_STAGE/Contents/Library/LaunchServices/LetItBrewDaemon")"
    [ -n "$old_cdhash" ] && [ -n "$new_cdhash" ] || { echo "FATAL: could not obtain native daemon CDHash." >&2; return 1; }
    upgrade_note "old: $old_version ($old_build), native daemon CDHash $old_cdhash"
    upgrade_note "new: $new_version ($new_build), native daemon CDHash $new_cdhash"
    if ! upgrade_build_is_strictly_newer "$old_build" "$new_build"; then
        echo "FATAL: candidate CFBundleVersion '$new_build' must be a strictly greater decimal build than installed '$old_build'." >&2
        return 1
    fi
    upgrade_note "ok: candidate build $new_build is strictly newer than installed build $old_build"

    UPGRADE_OLD_VERSION="$old_version"
    UPGRADE_OLD_BUILD="$old_build"
    UPGRADE_OLD_CDHASH="$old_cdhash"

    if [ "$UPGRADE_PRESERVE_DAEMON_STATE" -eq 1 ]; then
        upgrade_prepare_old_preserving_daemon_state \
            "$UPGRADE_DEST/Contents/MacOS/LetItBrew" \
            "$old_version" "$old_build" "$old_cdhash" || return 1
    else
        UPGRADE_OLD_SERVICE_STATE="registered"
        upgrade_prepare_old \
            "$UPGRADE_DEST/Contents/MacOS/LetItBrew" \
            "$old_version" "$old_build" "$old_cdhash" || return 1
    fi
    UPGRADE_BASELINE="$UPGRADE_PREPARED_BASELINE"
    case "$UPGRADE_BASELINE" in 0|1) ;; *) echo "FATAL: invalid prepared baseline '$UPGRADE_BASELINE'." >&2; return 1 ;; esac
    upgrade_note "exact reconciled SleepDisabled baseline: $UPGRADE_BASELINE"
    UPGRADE_PHASE="pre-swap"

    upgrade_transaction \
        "$old_version" "$old_build" "$old_cdhash" \
        "$new_version" "$new_build" "$new_cdhash" \
        "$staged_manifest"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    upgrade_main "$@"
    exit $?
fi
