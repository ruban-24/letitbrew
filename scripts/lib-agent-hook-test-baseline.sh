# Test-harness-only baseline selection for the isolated agent-hook contract.
# Production and release scripts do not source this file.

agent_hook_test_read_sleepdisabled() {
    if [ "${LETITBREW_TEST_AGENT_HOOK_SLEEP_DISABLED_BASELINE+x}" = x ]; then
        case "$LETITBREW_TEST_AGENT_HOOK_SLEEP_DISABLED_BASELINE" in
            0|1)
                printf '%s\n' "$LETITBREW_TEST_AGENT_HOOK_SLEEP_DISABLED_BASELINE"
                return 0
                ;;
            *)
                echo "FATAL: LETITBREW_TEST_AGENT_HOOK_SLEEP_DISABLED_BASELINE must be exactly 0 or 1." >&2
                return 1
                ;;
        esac
    fi

    baseline_read_sleepdisabled
}
