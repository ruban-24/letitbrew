# Task 9 fix report

## GREEN

Task 9 policy now limits nil migration internally to supported Claude/Codex,
ignores unknown IDs, and deterministically retains the first duplicate
inspection. Temporary negative compatibility shims/visibility overloads keep
the shipping app compiling without pulling Task 10 model integration forward.
Their deletion is explicitly deferred to Task 10.

Focused policy suites and unsigned app build were rerun after the fix.

DONE
