---
title: "Framework defaults encode a threat model that may not be yours, and stay inert until the first feature uses them"
summary: "A generator hashed one credential and stored another in plaintext; a websocket origin check sat at its default until the first socket shipped, where a wrong value fails silently and outside your logs."
module: lib/hospitality_coms_web
date: 2026-07-28
problem_type: best_practice
component: authentication
severity: high
source: "PR #16 (U2) and PR #28 (U7)"
root_cause: config_error
resolution_type: config_change
tags:
  - scaffolding
  - security-defaults
  - threat-model
  - websockets
  - generated-code
applies_when:
  - "using an authentication or scaffolding generator"
  - "adding the first user of a framework subsystem"
  - "a config default fails silently or outside your own logs"
---

# Framework defaults encode someone else's threat model

## Read your generator's security defaults against your own threat model

Phoenix's auth generator hashes email tokens at rest and stores **session tokens in plaintext**.
That is a defensible default if you assume the database is uniformly trusted. This product's
entire thesis is that it is not — and the session token *is* the API bearer credential, so a
`SELECT` leak would have yielded working credentials. Worse, the raw token was also used
verbatim as a pub/sub topic name, leaking the credential into a second namespace.

The generator also produced a password column, a password changeset and a hashing dependency for
an application with no HTML layer, where **no route could ever set one**. All of it was deleted:
an unreachable credential path inside an auth module is a liability, plus a column that a future
erasure feature has to remember to scrub.

- Audit what your scaffold protects and what it does not, against *your* threat model rather than
  the median one.
- **Delete generated capabilities you cannot reach.** They are not free; they are surface.

## A default is inert until the first feature uses it, and then it is live

`check_origin` sat at its framework default for production for six units, because nothing used
it. The first two websockets were the first thing it ever applied to — and the default checks the
`Origin` header against the endpoint's own configured host, so the browser client served from a
different origin would have had **its upgrade refused before any application code ran, with
nothing in the application's logs to say why**.

It is now an explicit environment variable, and boot **raises** without it. A value naming no
origin is refused too, because an empty allowlist refuses everything — the same silent failure by
another route.

- **When you add the first user of a framework subsystem, audit that subsystem's defaults.** They
  have been inert and untested until this moment, and nothing in your history tells you whether
  they are right.
- Where a wrong value **fails silently and outside your own logs**, make the config *required*
  rather than defaulted. A boot that raises is cheap; a websocket refused upstream of your
  application is close to undiagnosable.
- Refuse the degenerate value as well as the missing one.
