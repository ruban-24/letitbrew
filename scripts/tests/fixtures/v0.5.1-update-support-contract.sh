# Frozen v0.5.1 UpdateSupport inventory predicate.
#
# This is test data derived from v0.5.1's
# scripts/verify-artifact.sh signed-update-support block. Keep it hermetic:
# direct-distribution tests must not fetch or inspect repository history in
# order to prove that a current candidate remains installable by v0.5.1.

v051_update_support_contract_accepts() {
    local app="${1:-}" support_dir support_count support support_path support_mode

    [ "$#" -eq 1 ] || return 1
    support_dir="$app/Contents/Resources/UpdateSupport"
    [ -d "$support_dir" ] && [ ! -L "$support_dir" ] || return 1

    support_count="$(/usr/bin/find "$support_dir" -mindepth 1 -maxdepth 1 -print | /usr/bin/awk 'END { print NR + 0 }')"
    [ "$support_count" -eq 4 ] || return 1
    for support in run-update.sh upgrade-installed-app.sh verify-artifact.sh lib-power-baseline.sh; do
        support_path="$support_dir/$support"
        [ -f "$support_path" ] && [ ! -L "$support_path" ] || return 1
    done
    for support in run-update.sh upgrade-installed-app.sh verify-artifact.sh; do
        support_mode="$(/usr/bin/stat -f '%Lp' "$support_dir/$support" 2>/dev/null)"
        [ "$support_mode" = 755 ] || return 1
    done
    support_mode="$(/usr/bin/stat -f '%Lp' "$support_dir/lib-power-baseline.sh" 2>/dev/null)"
    [ "$support_mode" = 644 ]
}
