---
title: "profile.test.tsx beside profile.test.ts is one file to TypeScript and two to vitest"
summary: "tsconfig's include dedupes by path-without-extension, so a whole 62-test suite ran green while being typechecked and linted by nothing."
module: client
date: 2026-07-28
problem_type: test_failure
component: tooling
severity: high
source: "PR #35 (U12 profile)"
root_cause: config_error
resolution_type: test_fix
tags:
  - typescript
  - tsconfig
  - vitest
  - eslint
  - silent-failure
applies_when:
  - "naming a .tsx test file after an existing .ts module"
  - "eslint reports 'was not found by the project service'"
  - "auditing what a typechecker actually covers"
---

# A test file the typechecker cannot see

`tsconfig.json`'s `include` expands a directory glob and then **deduplicates by path without
the extension, keeping `.ts` over `.tsx`**. So a project containing both

```
src/features/profile/profile.test.ts
src/features/profile/profile.test.tsx
```

has, as far as `tsc` is concerned, only the first. The `.tsx` file is in neither
`tsc --noEmit` nor eslint's program — while vitest, which resolves its own globs, runs it and
reports it green.

In this project that file was a 62-test integration suite. It had been running green, and
typechecked and linted by nothing, for a whole unit. Two sibling surfaces escaped by luck
alone: their `.ts` and `.tsx` names differed by more than the extension
(`room.ts`/`rooms.test.tsx`).

## Why it does not look like what it is

It surfaces as eslint's **"was not found by the project service"**, which reads like a
`tsconfig` misconfiguration — a thing you go and adjust `parserOptions` for. It is not a config
problem. It is a file that is missing from the program.

## What to do differently

- **Do not name a `.tsx` test after a `.ts` module.** Give the component test a distinct stem
  (`profile-route.test.tsx`).
- **Verify the typechecker's actual file list rather than trusting the glob**:
  `npx tsc --noEmit --listFiles | grep <name>`. That one command settles it in seconds and is
  worth putting in a project README.
- Read "not found by the project service" as *this file is not in the program*, and go looking
  for a same-stem sibling before touching any config.
- More generally: **your test runner and your typechecker resolve files independently.** Any
  time they can disagree about which files exist, the disagreement is silent and always in the
  direction of less checking.
