#!/bin/bash
# Detached bridge from the ordinary app to the guarded upgrade transaction.
# This file and its three siblings are copied only from the signed app bundle
# into a private per-update workspace. It never executes content from the DMG.
set -uo pipefail

RUNNER_TIMEOUT=30
RUNNER_INSTALLED_BIN="/Applications/Let It Brew.app/Contents/MacOS/LetItBrew"

update_runner_kill_zero() { /bin/kill -0 "$1" 2>/dev/null; }
update_runner_ps_command() { /bin/ps -p "$1" -o command= 2>/dev/null; }
update_runner_sleep() { /bin/sleep "$1"; }
update_runner_upgrade() {
    "$RUNNER_SUPPORT_DIR/upgrade-installed-app.sh" \
        "$1" --relaunch --preserve-daemon-state
}

update_runner_fail() {
    printf 'FATAL: %s\n' "$*" >&2
    return 1
}

update_runner_canonical_existing() {
    local path="$1" parent name
    [ -e "$path" ] && [ ! -L "$path" ] || return 1
    parent="$(cd "$(dirname "$path")" && /bin/pwd -P)" || return 1
    name="$(basename "$path")"
    printf '%s/%s\n' "$parent" "$name"
}

update_runner_canonical_new() {
    local path="$1" parent name
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    parent="$(cd "$(dirname "$path")" && /bin/pwd -P)" || return 1
    name="$(basename "$path")"
    [ "$name" != . ] && [ "$name" != .. ] || return 1
    printf '%s/%s\n' "$parent" "$name"
}

update_runner_require_inside_root() {
    case "$1/" in
        "$RUNNER_ROOT/"*) return 0 ;;
        *) return 1 ;;
    esac
}

update_runner_wait_for_app_exit() {
    local pid="$1" waited=0 command
    command="$(update_runner_ps_command "$pid")" || return 1
    [ "$command" = "$RUNNER_INSTALLED_BIN" ] || return 1

    while update_runner_kill_zero "$pid"; do
        command="$(update_runner_ps_command "$pid" 2>/dev/null || true)"
        # PID reuse means the exact app exited; never wait on or signal the
        # unrelated replacement process.
        [ "$command" = "$RUNNER_INSTALLED_BIN" ] || return 0
        [ "$waited" -lt "$RUNNER_TIMEOUT" ] || return 1
        update_runner_sleep 1
        waited=$((waited + 1))
    done
}

update_runner_write_result() {
    local result="$1" status="$2" temp outcome
    case "$status" in
        0) outcome=success ;;
        *) outcome=failure ;;
    esac
    temp="${result}.new.$$"
    [ ! -e "$temp" ] && [ ! -L "$temp" ] || return 1
    printf '{"status":"%s","exitCode":%s}\n' "$outcome" "$status" >"$temp" || return 1
    /bin/chmod 600 "$temp" || return 1
    # A hard link publishes without ever replacing a path created after the
    # initial validation. The temporary and result files share one directory,
    # so they are necessarily on the same filesystem.
    /bin/ln "$temp" "$result" || { /bin/rm -f "$temp"; return 1; }
    /bin/rm -f "$temp"
}

update_runner_main() {
    local candidate="" app_pid="" result="" log="" argument status
    while [ "$#" -gt 0 ]; do
        argument="$1"
        shift
        case "$argument" in
            --candidate|--app-pid|--result|--log)
                [ "$#" -gt 0 ] || { update_runner_fail "missing value for $argument"; return 2; }
                case "$argument" in
                    --candidate) [ -z "$candidate" ] || return 2; candidate="$1" ;;
                    --app-pid) [ -z "$app_pid" ] || return 2; app_pid="$1" ;;
                    --result) [ -z "$result" ] || return 2; result="$1" ;;
                    --log) [ -z "$log" ] || return 2; log="$1" ;;
                esac
                shift
                ;;
            *) update_runner_fail "unknown argument '$argument'"; return 2 ;;
        esac
    done

    [ "$(/usr/bin/id -u)" -ne 0 ] || { update_runner_fail "do not run updates as root"; return 1; }
    case "$app_pid" in ''|*[!0-9]*) update_runner_fail "invalid app PID"; return 2 ;; esac
    [ "$app_pid" -gt 1 ] || { update_runner_fail "invalid app PID"; return 2; }

    RUNNER_SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)" || return 1
    RUNNER_ROOT="$(cd "$RUNNER_SUPPORT_DIR/.." && /bin/pwd -P)" || return 1
    for support in upgrade-installed-app.sh verify-artifact.sh verify-legal-resources.sh lib-power-baseline.sh; do
        [ -f "$RUNNER_SUPPORT_DIR/$support" ] && [ ! -L "$RUNNER_SUPPORT_DIR/$support" ] || {
            update_runner_fail "signed update support is incomplete"
            return 1
        }
    done
    [ -x "$RUNNER_SUPPORT_DIR/upgrade-installed-app.sh" ] || return 1
    [ -x "$RUNNER_SUPPORT_DIR/verify-artifact.sh" ] || return 1
    [ -x "$RUNNER_SUPPORT_DIR/verify-legal-resources.sh" ] || return 1

    candidate="$(update_runner_canonical_existing "$candidate")" || {
        update_runner_fail "candidate is missing or unsafe"
        return 1
    }
    result="$(update_runner_canonical_new "$result")" || {
        update_runner_fail "result path exists or is unsafe"
        return 1
    }
    log="$(update_runner_canonical_new "$log")" || {
        update_runner_fail "log path exists or is unsafe"
        return 1
    }
    update_runner_require_inside_root "$candidate" || return 1
    update_runner_require_inside_root "$result" || return 1
    update_runner_require_inside_root "$log" || return 1
    [ -d "$candidate" ] && [ "$(basename "$candidate")" = "Let It Brew.app" ] || return 1

    umask 077
    : >"$log" || return 1
    if ! update_runner_wait_for_app_exit "$app_pid"; then
        printf 'FATAL: the exact installed Let It Brew process did not exit safely.\n' >>"$log"
        status=1
    else
        update_runner_upgrade "$candidate" >>"$log" 2>&1
        status=$?
    fi
    update_runner_write_result "$result" "$status" || return 1
    return "$status"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    update_runner_main "$@"
    exit $?
fi
