---
title: "A test against a fake checks your model of the library, not the library"
summary: "Three artifacts agreed with each other and all three were wrong about the library underneath; and a guess recorded as a guess is what makes it findable later."
module: client
date: 2026-07-28
problem_type: best_practice
component: testing_framework
severity: high
source: "PR #27 and PR #30 (U12)"
root_cause: incomplete_setup
resolution_type: test_fix
tags:
  - test-doubles
  - fakes
  - assumptions
  - integration-testing
  - parallel-work
applies_when:
  - "testing an integration entirely against a fake or mock"
  - "building a client against a server another team is designing concurrently"
  - "you must assume something about a system you cannot yet observe"
---

# Building against a system that does not exist yet

## A fake can only confirm your model of the library

A client passed its session credential to a socket library as connection **params**. In that
library, params *are* the URL query string — which is exactly what the server had gone out of
its way to avoid, because query strings land in access and proxy logs.

The instructive part is why nothing caught it. The test asserted that the socket

> carries the session token in the socket params rather than the URL

which is a **false dichotomy, since params are the URL**. The module doc and the README repeated
the same sentence. Three artifacts agreed with each other and all three were wrong about the
library underneath — and **a fake socket can never reveal it, because the fake never builds a
URL.**

What to do differently:

- Where the property under test is *what the library emits on the wire*, assert against the real
  thing at least once. A fake proves your code calls your model correctly and nothing else.
- Fix it structurally: `params` was removed from the option **type**, so reintroducing it is
  something somebody has to deliberately type.
- **Name the old sentence as wrong rather than quietly replacing it.** A silent correction
  teaches nobody, and the same wrong sentence in three files is evidence they were copied from
  each other rather than each checked.

## Record a guess as a guess, and prefer a hole to an invention

Two halves of this system were built concurrently in separate worktrees, and the client was
explicitly told **not to guess at the server's vocabulary**, on the reasoning that

> a wrong guess is worse than an absence: the next unit has to find and undo it, whereas a gap
> is visible.

Where a guess was unavoidable — the socket's mount path, the credential's carrier, a landing
origin — each was written down *as a guess*, with the unit that owned the decision named. That
paid off immediately: the socket turned out to be mounted at a prefixed path, not the framework
default. The symptom was a 404 on upgrade with the library retrying forever and an empty screen,
which is close to undiagnosable — and the note saying "this is a guess, unit N owns it" is what
made it findable.

Later units went further and **measured** the absence rather than assuming it: before writing a
contract against a transport that did not exist, they grepped for it and checked the route table
at a named commit, then put the whole contract in one file so whoever adds the transport has
exactly one thing to satisfy.

- Write assumptions down **as assumptions**, next to the code, naming who owns the decision.
- Prefer a visible hole to a plausible invention.
- When you can, check the assumption cheaply and record *how* you checked it, not just the
  conclusion.
