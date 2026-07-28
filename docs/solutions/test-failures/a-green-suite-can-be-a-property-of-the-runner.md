---
title: "A test must establish the environment it depends on, never assert what the runner provides"
summary: "A two-branch fallback was green on both machines and covered on neither, because each runner could only ever reach one branch."
module: client/session
date: 2026-07-28
problem_type: test_failure
component: testing_framework
severity: high
source: "PR #33, commit 1b31d63 — the pull request that first added CI"
root_cause: test_isolation
resolution_type: test_fix
tags:
  - ambient-globals
  - ci
  - vitest
  - environment-dependent-tests
  - feature-detection
applies_when:
  - "testing code that feature-detects an ambient global"
  - "a suite has only ever run on one machine"
  - "adding CI to an existing project"
---

# A green suite can be a property of the runner

Nine units and roughly 825 tests shipped on one developer's machine before this project had
CI. CI's very first run went red on one line:

```ts
expect(globalThis.localStorage).toBeUndefined();
```

That holds locally, where Node starts without `--localstorage-file`. It does not hold on the
CI runner, where the global is a real `Storage`.

## The failing line was the small half

The function under test, `createBrowserTokenStore()`, has two branches: use storage when it
works, fall back to memory when it does not. The assertion established neither.

- Locally, `localStorage` was absent, so **only the memory fallback could ever run** and the
  storage path had never executed once.
- On CI, `localStorage` was present, so **only the storage path could run** and the fallback
  could not.

Both machines reported a green file over half a function. The test read as coverage of a
fallback while being a coincidence of the machine. A sibling, `createBrowserRoomStore()` —
the same shape over different data — had **no test at all**, for the same reason: nothing
could cover both branches without saying which one it wanted, so nobody wrote one.

## What to do differently

- **Stub the ambient global, do not assert it.** `vi.stubGlobal` (or your framework's
  equivalent) with an `afterEach` unstub, once per branch: present and working, absent, and
  present but throwing. The answer then does not depend on where the suite runs.
- **This applies to everything ambient**, not just storage: `navigator`, `window.*`, the time
  zone, the locale, the file system, `process.env`, the DNS resolver.
- **A "feature is missing" assertion is never a test of the fallback.** It is a test of the
  runner.
- **When a suite has only ever run on one machine, treat the first second machine as a
  coverage audit, not a chore.** Run it deliberately: this project now runs its client suite
  twice on every change, once under each runner shape
  (`NODE_OPTIONS="--localstorage-file=$(mktemp)"`), and the two counts must match.
- Each new branch test was then checked by mutation **in both runner shapes** — returning
  memory unconditionally kills only the storage test; removing the `catch`, and separately
  removing the probe inside it, kill only the fallback tests.
