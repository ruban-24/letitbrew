#!/bin/bash
# Verifies the immutable Legal payload copied into a Let It Brew app bundle.
# It deliberately performs no signature, executable, or metadata verification;
# callers that require a production-artifact verdict must invoke
# verify-artifact.sh, which always runs this check before its remaining gates.
set -uo pipefail

APP="${1:?usage: verify-legal-resources.sh <Let It Brew.app>}"
[ "$#" -eq 1 ] || { echo "FATAL: expected exactly one app bundle path." >&2; exit 1; }
[ -d "$APP" ] || { echo "FATAL: $APP is not a bundle." >&2; exit 1; }
[ ! -L "$APP" ] || { echo "FATAL: refusing a symlinked app bundle." >&2; exit 1; }

fail=0
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc" >&2
        fail=1
    fi
}

legal_dir="$APP/Contents/Resources/Legal"
check "Legal directory present" test -d "$legal_dir"
check "Legal directory is not a symlink" test ! -L "$legal_dir"
if [ -d "$legal_dir" ] && [ ! -L "$legal_dir" ]; then
    legal_entries="$(/usr/bin/find "$legal_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null | /usr/bin/sed 's|.*/||' | /usr/bin/sort | /usr/bin/tr '\n' ',')"
    check "Legal contains exactly LICENSE, NOTICE, and TRADEMARKS.md" \
        test "$legal_entries" = "LICENSE,NOTICE,TRADEMARKS.md,"
    for legal_path in LICENSE NOTICE TRADEMARKS.md; do
        check "Legal/$legal_path present as an ordinary file" test -f "$legal_dir/$legal_path"
        check "Legal/$legal_path is not a symlink" test ! -L "$legal_dir/$legal_path"
        legal_mode="$(/usr/bin/stat -f '%Lp' "$legal_dir/$legal_path" 2>/dev/null)"
        check "Legal/$legal_path has mode 644" test "$legal_mode" = 644
    done
    check "Legal/LICENSE has the Apache 2.0 header" \
        /usr/bin/grep -Fq "Apache License" "$legal_dir/LICENSE"
    check "Legal/LICENSE names Version 2.0, January 2004" \
        /usr/bin/grep -Fxq "                           Version 2.0, January 2004" "$legal_dir/LICENSE"
    check "Legal/NOTICE attributes Ruban" \
        /usr/bin/grep -Fq "Copyright 2026 Ruban" "$legal_dir/NOTICE"
    check "Legal/TRADEMARKS.md has the trademark-policy heading" \
        /usr/bin/grep -Fxq "# Let It Brew Trademark Policy" "$legal_dir/TRADEMARKS.md"
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: embedded legal resource verification"
else
    echo "FAIL: embedded legal resource verification" >&2
fi
exit "$fail"
