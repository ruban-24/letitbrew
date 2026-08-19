#!/bin/bash
# Regression for the one-click uninstall preflight used by certificate-free
# development builds. The test refuses to run when the app's daemon service is
# present, then exercises the real app command and requires affirmative absence.
set -uo pipefail

APP="${1:-/Applications/Let It Brew Dev.app}"
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/LetItBrew"

[ -f "$PLIST" ] || { echo "FATAL: missing $PLIST" >&2; exit 1; }
[ -x "$EXECUTABLE" ] || { echo "FATAL: missing executable $EXECUTABLE" >&2; exit 1; }

identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null)"
case "$identifier" in
    com.ruban24.letitbrew|com.ruban24.letitbrew.dev) ;;
    *) echo "FATAL: unsupported bundle identifier '$identifier'" >&2; exit 1 ;;
esac

signature="$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1)"
if ! /usr/bin/grep -q '^Signature=adhoc$' <<<"$signature" \
    || ! /usr/bin/grep -q '^TeamIdentifier=not set$' <<<"$signature"; then
    echo "FATAL: this regression requires an ad-hoc app with no Team ID" >&2
    exit 1
fi

service="$identifier.daemon"
if /bin/launchctl print "system/$service" >/dev/null 2>&1; then
    echo "FATAL: refusing to run while $service is registered" >&2
    exit 1
fi

test_root="$(/usr/bin/mktemp -d /private/tmp/letitbrew-adhoc-uninstall-preflight.XXXXXX)"
case "$test_root" in
    /private/tmp/letitbrew-adhoc-uninstall-preflight.*) ;;
    *) echo "FATAL: unexpected temporary path '$test_root'" >&2; exit 1 ;;
esac
trap '/bin/rm -rf "$test_root"' EXIT

status=0
"$EXECUTABLE" --prepare-update --json \
    >"$test_root/stdout" 2>"$test_root/stderr" || status=$?
if [ "$status" -ne 0 ]; then
    echo "FAIL: ad-hoc absent-service preflight exited $status" >&2
    /bin/cat "$test_root/stderr" >&2
    exit 1
fi

/usr/bin/python3 - "$test_root/stdout" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload == {"daemonState": "absent", "reconciliationReady": True}, payload
PY

echo "PASS: ad-hoc absent-service uninstall preflight continued automatically"
