# Task 9 fix report

## GREEN

Task 9 policy now limits nil migration internally to supported Claude/Codex,
ignores unknown IDs, and deterministically retains the first duplicate
inspection. Temporary negative compatibility shims/visibility overloads keep
the shipping app compiling without pulling Task 10 model integration forward.
Their deletion is explicitly deferred to Task 10.

```text
AgentConnectionSelectionPolicyTests  PASS (7 tests)
AgentHelperBatchRunnerTests          PASS (3 tests)
AgentSessionVisibilityPolicyTests    PASS (7 tests)
unsigned Debug app build             PASS
```

The batch test intentionally proves only pure selection helpers; executable
selection-before-helper effect ordering is deferred to the Task 10 coordinator.

DONE
