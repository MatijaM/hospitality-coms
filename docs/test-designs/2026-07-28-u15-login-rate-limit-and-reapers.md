# Test Design Brief — #15, Rate-limiting and abuse control on `POST /api/log-in`

Issue: #15, deferred out of #2 during code review; found independently by the adversarial,
reliability and security reviewers.
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written and committed before any
production code, so the ordering is visible in the history rather than asserted. Convention
established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md` through
`-u11-seed-manifest-and-demo-controls.md`, including the "record revisions rather than applying
them silently" section at the end.

## What is being built

Three things, and only the first is a feature in the ordinary sense.

1. **A per-remote-IP rate limit in front of `POST /api/log-in`** — an ETS counter, refusing with
   `429` in the standard envelope. The dependency decision is made: **no `hammer`.** This is a
   POC and a fixed-window counter over one ETS table is the whole mechanism.
2. **A reaper for expired `people_tokens`**, riding Oban as a fourth worker beside
   `ExpireEngagement`, `EngagementSweeper` and `RetentionSweeper`.
3. **A reaper for unconfirmed `people` rows** past a horizon, in the same pass.

## The problem, restated so the tests can be read against it

`POST /api/log-in` merges registration and log-in on purpose, so the endpoint answers identically
for a known and an unknown address and closes an enumeration oracle. The cost is that
**anonymous, unauthenticated row creation in the person zone's root table is a first-class path**:
any caller can POST an arbitrary address and get a committed `people` row plus an outbound email
from our domain to a third party who never asked for it. Nothing limits it.

Compounding it, nothing reaps `people_tokens` past their validity horizons (15 minutes / 14 days /
7 days) except consumption, and nothing reaps unconfirmed `people`. Both tables grow monotonically.

**Nothing landed in #2 for the in-context half.** The issue says a duplicate-suppression attempt
was made there; `Accounts.request_login_instructions/3` on `main` inserts a token and mails a link
unconditionally, and there is no suppression anywhere in the path. Checked rather than assumed,
because a suppression that *changed the response* would already be the oracle this issue's limiter
must not become.

## The decision that matters most: where the deleting code goes

**In `HospitalityComs.Lifecycle`, and the rule it is the subject of does not change.**

KTD21 says `Lifecycle` is the only module permitted to delete, and `lifecycle_test.exs` asserts it
two independent ways: over the compiled `imports` chunk (offender set is exactly `[Accounts]`), and
over each library module's *source* AST, because the chunk cannot see `repo.delete_all/1` inside a
`Multi.run` — the idiom `Lifecycle` itself uses five times. The second sweep asserts the offending
**files** are exactly `lifecycle.ex` and `accounts.ex`.

Three placements were open:

- **In the worker.** Refused: a worker is a `lib/` module, so this widens the rule outright, and it
  puts an unattended deleter outside the one file the rule exists to make findable.
- **In `Accounts`.** Refused, and this is the near miss. `Accounts` is *already* the enumerated
  exemption and reaping expired tokens is a plausible reading of what that exemption is for —
  "credential expiry rather than record destruction". But the exemption is **bounded** by a second
  test that counts every base table across a log-out and asserts `people_tokens` is the only one
  that moved. Reaping unconfirmed `people` rows can never satisfy that bound, so this placement
  costs a widened exemption *and* a weakened bound. `lifecycle_test.exs`'s own comment is the
  argument: "a sweep with a silent carve-out is a sweep that grows carve-outs."
- **In `Lifecycle`.** Taken. No structural rule changes, no list grows, and the subject matches:
  the reaper is a bounded, unattended, irreversible deleter on a horizon, which is what the second
  half of that module already is.

### And why it is a second entry point rather than two more triggers on `sweep/1`

`Lifecycle.reap/1` is its own function, driven by its own worker. It is **not** two more triggers
inside `Lifecycle.sweep/1`, and the reason is the sentence `sweep/1` exists to make true:

> Four triggers, and **no join to the period a deadline came from**. That is the single most
> important decision in the unit.

Every one of those four reads a `delete_after` column that was **stamped once, by an event, from a
value that can no longer move**. The reaper's two horizons are **computed at sweep time** from
`inserted_at`. That is correct here for reasons that do not generalise — the column is written once
and never updated, no changeset rewrites it, and the horizon is a constant rather than another
row's period — but a list of six triggers, four of which must never compute and two of which do,
is a list a future author copies the wrong half of. The trigger list is the thing that gets copied.

Two smaller reasons point the same way: the retention ceiling rolls **every** trigger back, so an
abuse burst and a compliance deletion would share a blast radius they have no relationship to; and
`retention_runs` records what one *retention* pass did, with four columns named after four
triggers.

### No `retention_runs` row for the reaper, and no new table

`retention_runs` exists because retention destroys the only surviving copy of a person's words. The
reaper destroys (a) a credential the authenticator had already stopped honouring at the same
instant — see criterion 5, where the two predicates are asserted to be exact complements — and
(b) a `people` row carrying an address nobody ever confirmed, which the person recovers by typing
the same address into the same endpoint. A trace of a deletion the subject can undo by re-typing
their address is a log line, not a table. The counts are returned by `Lifecycle.reap/1` and logged
by the worker.

**Consequence, stated plainly rather than re-decided: sweeping unconfirmed `people` frees the
address, so an unconfirmed address becomes re-registerable.** `people_email_index` is partial on
`erased_at IS NULL` and the reaped row is *gone* rather than pseudonymised, so the address returns
to the pool exactly as if it had never been used. That is the accepted trade: an address that was
sent a link and never redeemed for a month is not in use, and the alternative — keeping the row for
ever so the address can never be re-registered — hands an anonymous caller a permanent way to burn
addresses for other people. Test 25 asserts the recycling rather than leaving it as a claim.

## How the limiter preserves the enumeration property

**The counter key is `conn.remote_ip` and nothing else.** No address, no digest of an address, no
person id. The refusal is therefore a function of `(remote IP, request count, window)` and is
independent of the request body — so the endpoint answers identically for a known and an unknown
address at every point on the curve: `202` for both below the limit, `429` for both at it.

The failure this avoids has a specific shape and it is the one #2 reached for: a **per-address**
limit ("one link per address per fifteen minutes") answers `429` for an address that was just used
and `202` for one that was not, which is a *better* oracle than the one the merged door closed —
it needs no timing analysis and no mailbox. Any future throttle keyed on the address must answer
`202` regardless, and suppress the *email* rather than change the *response*.

Two smaller properties keep it honest:

- **The plug counts requests, not successes**, and sits in front of the controller. A malformed
  address and a valid one consume the same budget, so the count carries no information about
  whether the body was well-formed either (test 10).
- **`retry-after` carries the window, not the caller's position in it.** Everybody refused in one
  window gets the same header value.

**Two residues, on the record.** The limiter does not close the pre-existing *timing* difference
between a known address (one `SELECT`) and an unknown one (`SELECT`, `INSERT`, unique-index check)
— that is `Accounts.request_login_instructions/3`'s shape and is out of this issue's scope. And
`conn.remote_ip` is the *peer* address: behind a load balancer it is the balancer's, and the limit
becomes global. `x-forwarded-for` is deliberately **not** consulted, because an unauthenticated
caller sets it freely and trusting it would let anybody mint a fresh bucket per request — which is
strictly worse than a shared bucket. Closing it properly needs a trusted-proxy configuration
(`Plug.RewriteOn` plus a peer allowlist), which is a deployment decision rather than an
implementation one.

## ETS is process- and node-local, and the suite runs files concurrently

Three separate problems, three separate answers.

1. **Ownership.** An ETS table dies with the process that created it, and a plug runs in a request
   process. The table is created by a small supervised GenServer in `HospitalityComs.Application`'s
   tree, next to `Presence`, which has the same shape.

2. **Cross-test interference.** The table is global to the node, so every test in every file shares
   it. The answer is that **the key space is partitioned by test**: `HospitalityComsWeb.ConnCase`'s
   setup gives each test's `conn` a unique `remote_ip`, so each test is a different client of the
   real, un-reset limiter. This is preferable to a reset hook — a reset is a second mechanism that
   can be forgotten, and a test that forgets it fails *later*, in whichever file happens to run
   next. It also keeps the counter's production code free of a test-only export.

   Every existing `POST /api/log-in` in `session_controller_test.exs` goes through the `conn` the
   setup built, so no existing test's budget is shared with another's. That is checked (test 35),
   not assumed: it is exactly the kind of change that goes green today and fails when somebody adds
   an eleventh log-in call to that file.

3. **The window is derived from the injected clock**, not from wall time, because the plug takes
   its instant from `conn.assigns.current_scope.now` — which `PersonAuth.fetch_person_scope/2` put
   there. So a test rolls the window by advancing `Clock.Offset` rather than by sleeping, and the
   limiter's own file is `async: false` for the reason every clock-moving file is. This is also
   what keeps the plug off `.credo.exs`'s `:boundary_modules` list: it reads no clock.

   **Residue:** the counter is keyed on a window index derived from that clock, so U11's
   `DELETE /api/demo/clock` can move an IP back into a window it has already spent, or forward into
   an empty one. Nothing in production reaches it (`Clock.Offset` is not compiled in `:prod`) and
   it costs at most one window's budget in the demo.

## The reaper's horizons, and the two directions half-open points

| What | Predicate | Half-open at |
|---|---|---|
| `login` tokens | `inserted_at <= instant - 15 minutes` | already expired at the horizon |
| `session` tokens | `inserted_at <= instant - 14 days` | already expired at the horizon |
| `change:…` tokens | `inserted_at <= instant - 7 days` | already expired at the horizon |
| any other context | `inserted_at <= instant - 14 days` (the longest) | — |
| unconfirmed `people` | `confirmed_at IS NULL AND erased_at IS NULL AND inserted_at < instant - 30 days` | survives at the horizon |

**The two rows differ by one instant and each matches its own governing rule, deliberately.**

`PersonToken.verify_session_token_digest_query/2` and its two siblings say a token is live when
`inserted_at > instant - validity` — strictly. So a token whose validity elapses *exactly* at the
instant asked about is already refused by the authenticator, and the reaper's predicate is the
exact complement of it: `<=`. Criterion 5 asserts that as complementarity rather than as two
constants that happen to agree, because two constants that happen to agree drift.

The unconfirmed-person horizon has no authenticator to complement, so it takes the convention
`Lifecycle.sweep/1` already uses (`delete_after < instant`, a row whose deadline is exactly the
instant survives), which in terms of a birth stamp is `inserted_at < instant - 30 days`.

**Thirty days is chosen against a constraint rather than picked**: it must exceed every token
horizon, so that reaping a person can never cascade away a *live* credential. `people_tokens
.person_id` is the only foreign key into `people` that is not `ON DELETE RESTRICT` — it is
`CASCADE` — so the person delete takes their tokens with it. Test 30 asserts the ordering of the
two constants rather than either number.

### Why an unconfirmed person can be deleted at all, and what happens if that stops being true

Every other foreign key into `people` — `engagements.person_id`, three on `connection_requests`,
three on `peer_connections`, `peer_messages.author_id`, `declared_entries.person_id`,
`attested_entry_disclosures.audience_person_id` — is `ON DELETE RESTRICT`. **An unconfirmed person
can hold none of them**, and the reason is structural rather than a survey: `confirmed_at` is set
by `Accounts.login_person_by_magic_link/2`, which is the only path that mints a session token, and
every context function that writes any of those tables takes a `PersonScope` carrying a real
person — which needs one. So the reaped row is referenced by `people_tokens` and nothing else.

That invariant is application-level, so the failure mode if a later unit breaks it is written down
here: the delete raises `foreign_key_violation`, the transaction rolls back, and the Oban job fails
and is retried. **A loudly failing unattended deleter is the right failure**, and it is why the
predicate is not padded with a list of `NOT EXISTS` subqueries — a list of five tables is a list
somebody gets wrong later, and getting it wrong is silent where the foreign key is not.

## "The sweep is a window, not a floor" — and why the reaper correctly has no floor

`Engagements.list_expired/3` needs a lower bound because it **does not consume** the rows it finds:
`ends_at <= now` matches every term that ever closed, so a `limit` on its own pins the sweep to the
same oldest batch for ever. Both reap statements **delete what they select**, so the next run
cannot see the same rows and the sweep advances by construction — the same property
`Lifecycle.sweep/1` has, and the same reason it has no lower bound either.

Adding one here would be the actual defect: a backlog older than the window would never be reaped,
which is the monotonic growth the issue is about, arriving through the fix. Test 27 asserts
progress across two runs of a deliberately lowered batch, which is what makes the absence of a
floor a measured property rather than an argument.

## Acceptance criteria

1. `POST /api/log-in` is rate limited per remote IP; nothing else on the router is.
2. The refusal is `429` and its body is `HospitalityComsWeb.ErrorEnvelope.new(:too_many_requests,
   …)` — one envelope, like every other error this API returns — with a `retry-after` header.
3. The response is a function of the IP, the count and the window, and **never of the address**.
4. The plug takes its instant from `conn.assigns.current_scope.now`. It reads no clock and is not
   added to `.credo.exs`'s `:boundary_modules`.
5. The token reaper's predicate is the **exact complement** of the predicate each token's own
   verify query enforces: what it deletes could not have authenticated anything at that instant,
   and what it keeps could.
6. Unconfirmed `people` past thirty days are deleted, with their tokens, and the address becomes
   re-registerable.
7. Deletion happens in `Lifecycle` and only there. `lifecycle_test.exs`'s two structural sweeps
   answer exactly what they answer today — `[Accounts]`, and `lifecycle.ex` plus `accounts.ex`.
8. The reaper is one new Oban worker on the existing `:lifecycle` queue, following
   `RetentionSweeper`'s uniqueness and attempt conventions, cron-scheduled, and added to
   `.credo.exs`'s `:boundary_modules` with a reason — one job attempt is one unit of work (KTD5).
9. Both reap statements are bounded by `Lifecycle.batch_size/0` and have no lower bound.
10. Half-open in the direction each rule dictates, per the table above.
11. `@spec` on every public function with enumerated error atoms. **No new tables**, therefore no
    `Zones` classification and no `PostgresRolesTest` entry; **no new grant migration**, therefore
    no change to that test's unwind list. One migration, adding two indexes.
12. Every behavioural test is proved load-bearing by mutation.

## Edge cases

- The limit is reached exactly: request `n` is allowed and request `n + 1` is refused. An
  off-by-one in either direction fails.
- A second IP is unaffected while the first is refused.
- A refused IP is admitted again in the next window, with nothing having run.
- The window rolls forward; the previous window's counters are pruned, so the table does not grow
  with every IP-window pair ever seen.
- A request with no `email` key, and one with a malformed address, both consume budget.
- `POST /api/log-in/token`, `GET /api/me` and `DELETE /api/log-out` are not limited.
- A `login` token exactly at fifteen minutes is reaped; one second younger survives.
- A `session` token exactly at fourteen days is reaped; one second younger survives.
- A `change:` token exactly at seven days is reaped; one second younger survives.
- A token whose context is none of the three is reaped at the longest horizon and not before.
- An unconfirmed person exactly at thirty days survives; one second older does not.
- A **confirmed** person of the same age survives, and an **erased** one survives.
- A reap with nothing due answers zeroes and deletes nothing.
- A backlog larger than one batch is cleared over two runs.
- A live session token belonging to a confirmed person is untouched by any of it.

## Test matrix

`login_rate_limit_test.exs` is `async: false` (it advances the clock) and sandboxed through
`ConnCase`. `lifecycle_reap_test.exs` is `async: false` and sandboxed through `DataCase`: it
reaches every `people` and `people_tokens` row in the database with no scoping, so it must not run
beside a file that has committed some — ExUnit finishes every async module before starting a
synchronous one, which is what makes that safe, and is the same reasoning
`test_database_guard_test.exs` records for its `TRUNCATE`.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | `limit` requests from one IP are all accepted | login_rate_limit | unit | a limiter that refuses below the limit |
| 2 | …and the next one is `429` | login_rate_limit | unit | **the limiter existing at all** |
| 3 | …in the standard envelope, code `too_many_requests` | login_rate_limit | unit | a hand-rolled body |
| 4 | …carrying `retry-after` | login_rate_limit | boundary | a refusal a client cannot back off from |
| 5 | A different IP at the same instant is accepted | login_rate_limit | boundary | **control for 2** — a global counter satisfies 2 |
| 6 | The same IP is accepted again one window later | login_rate_limit | unit | **control for 2** — a counter that never resets satisfies 2 |
| 7 | …and is still refused one second before the window rolls | login_rate_limit | boundary | a window that rolls early |
| 8 | At the limit, a known and an unknown address get identical responses | login_rate_limit | unit | **criterion 3** — a per-address limiter |
| 9 | Below the limit, a known and an unknown address get identical responses | login_rate_limit | boundary | the same, on the other side of the curve |
| 10 | A malformed address and a bodyless request both consume budget | login_rate_limit | unit | a limiter behind the controller |
| 11 | `POST /api/log-in/token` from a refused IP still answers | login_rate_limit | boundary | a limiter on the whole `:api` pipeline |
| 12 | The plug reads the instant off the scope, not the clock | login_rate_limit | unit | criterion 4 — two conns, one scope instant apart |
| 13 | The previous window's counters are pruned once the window rolls | login_rate_limit | unit | unbounded ETS growth, which is the same defect in memory |
| 14 | …and the current window's are not (control) | login_rate_limit | boundary | a prune that clears the table |
| 15 | A `login` token at exactly fifteen minutes is reaped | lifecycle_reap | unit | **issue: reaping expired tokens** |
| 16 | …and one a second younger survives | lifecycle_reap | boundary | **control for 15** — a `delete_all` satisfies 15 |
| 17 | A `session` token at exactly fourteen days is reaped, one a second younger survives | lifecycle_reap | unit | the per-context horizon |
| 18 | A `change:` token at exactly seven days is reaped, one a second younger survives | lifecycle_reap | unit | the per-context horizon |
| 19 | A token with an unrecognised context is reaped at the longest horizon and not before | lifecycle_reap | boundary | a context enumeration that grows a hole |
| 20 | **The reaper deletes exactly what the authenticator refuses, at one instant** | lifecycle_reap | unit | **criterion 5** — the two predicates drifting |
| 21 | An unconfirmed person past thirty days is deleted | lifecycle_reap | unit | **issue: reaping unconfirmed people** |
| 22 | …and their token goes with them | lifecycle_reap | boundary | the cascade, and an orphaned token |
| 23 | A **confirmed** person of the same age survives | lifecycle_reap | boundary | **control for 21** — reaping every old person |
| 24 | An **erased** person survives | lifecycle_reap | boundary | control — reaping the pseudonymised tombstone |
| 25 | The reaped address registers again cleanly | lifecycle_reap | unit | **the stated consequence**, asserted |
| 26 | Exactly at thirty days the person survives; a second older does not | lifecycle_reap | boundary | criterion 10, the other direction |
| 27 | A backlog of `2 × batch` clears over two runs, the second reaching rows the first did not | lifecycle_reap | unit | **criterion 9** — a floor, or an unbounded statement |
| 28 | A reap with nothing due answers zeroes and deletes nothing | lifecycle_reap | boundary | "no rows, no answer" |
| 29 | A live session token of a confirmed person is untouched | lifecycle_reap | boundary | control — the reap being a `delete_all` |
| 30 | The unconfirmed horizon exceeds every token horizon | lifecycle_reap | boundary | a person reap cascading a live credential |
| 31 | The worker takes its instant from `Clock`, and moving the offset moves the reap | lifecycle_reap | unit | KTD5 at a new unit-of-work boundary |
| 32 | The worker itself deletes nothing — `Lifecycle` does | lifecycle_test | boundary | **criterion 7**, via the two existing sweeps |
| 33 | `Accounts`'s deletes still reach `people_tokens` and no other table | lifecycle_test | boundary | the exemption widening (existing test, must hold) |
| 34 | The new migration rolls down and back up intact | boundary_test | unit | a `down` nobody ran |
| 35 | Every `POST /api/log-in` in the suite has its own IP budget | login_rate_limit | boundary | the ConnCase partition, asserted rather than assumed |

Controls, so no assertion can pass for the wrong reason:

- 5 and 6 are the two controls for 2: a *global* counter and a counter that *never resets* each
  satisfy 2 on their own. 1 is the third — a limiter that refuses everything satisfies 2 as well.
- 16 is the control for 15, 23 and 24 for 21, 29 for the whole reap, 14 for 13.
- 9 is the control for 8: an assertion that two responses match at the limit is satisfied by a
  limiter that refuses everybody always, so the same comparison is made below the limit too.
- 7 is the control for 6: a window that rolled at any advance satisfies 6.
- 19 is what makes 15, 17 and 18 total rather than a list.
- 30 is what makes 22 safe rather than lucky.

## Regression risks

- **`HospitalityComsWeb.ConnCase` gains a per-test `remote_ip`.** Every controller and channel test
  builds its conn there. Nothing in the tree reads `remote_ip` today (checked), so the change is
  additive — but `session_controller_test.exs` makes ten `POST /api/log-in` calls at one pinned
  instant, and without the partition they would share one budget and the file would go red at
  whichever call crossed the limit. Test 35 pins the partition.
- **`config/config.exs`** gains one cron entry on the existing `:lifecycle` queue, at a minute
  offset from `RetentionSweeper`'s, because that queue has a concurrency of one. `config/test.exs`'s
  `testing: :manual` means neither runs in the suite; every worker is driven by
  `Oban.Testing.perform_job/2`.
- **`.credo.exs`** gains one `:boundary_modules` entry, with a reason, exactly as the three
  existing workers have. `clock_authority_test.exs` must still pass.
- **`HospitalityComs.Application`** gains one child. It has no dependency on the repos or the
  endpoint and can sit before both; it is placed beside `Presence` for readability.
- **`lifecycle_test.exs`'s two KTD21 sweeps** must answer exactly what they answer today. The new
  worker and the new plug must reach no delete.
- **`Lifecycle` must still reach zero Ecto query builders** — `lifecycle_test.exs` asserts it — so
  both new queries live in `Lifecycle.Records`.
- **One migration, two indexes, no grants.** `PostgresRolesTest`'s unwind list is unchanged because
  the rule is "every grant migration" and this is not one; `zones_test.exs` is unchanged because
  there is no new schema; `boundary_test.exs`'s totality sweeps are unchanged because there is no
  new relation. All three are claims to check, not to assume.
- **`MIX_ENV=prod mix compile --warnings-as-errors`** must pass: nothing new may reach
  `dev_support/`.

## Implementation constraints

- `@spec` on every public function; enumerated error atoms, never `{:error, term()}`.
  `Ecto.UUID.t()` for entity ids.
- Migrations only through `mix ecto.gen.migration`, with a reversible `down`.
- Every `Lifecycle` query lives in `Lifecycle.Records`.
- `Lifecycle` reaches `HospitalityComs.Repo` only, never `EmployerRepo`.
- The worker is the only new `Clock.now/0` caller. `ago/2` and `from_now/2` stay banned.
- The plug builds its refusal through `ErrorEnvelope` and nowhere else.
- The token validity constants stay in `HospitalityComs.Accounts.PersonToken`, which already owns
  two of the three; the third is exported rather than copied.
- `mix format --check-formatted`, `mix compile --force --warnings-as-errors` in dev and `:prod`,
  `mix quality`, and `mix test` three times. Never migrate `hospitality_coms_dev`.
- Every behavioural test proved load-bearing by mutation: break the code it covers, watch that
  specific test fail, restore. Reported per test.

## Quality scores (self-assessed)

- Coverage of stated scope: all three items from the issue, plus both decisions the issue left
  open, plus the enumeration property the issue does not mention and the limiter could destroy.
- Assertion strength: the token reaper is asserted as the *complement of the authenticator* rather
  than against a repeated constant; the batch bound is asserted by clearing a backlog rather than
  by counting one run; the enumeration property is asserted on both sides of the limit.
- Control coverage: 8 controls for the 8 assertions that could pass vacuously, including the two
  the standards call out by name — a limit test that never reaches the limit (1 and 2 together)
  and a reset test where the counter was empty anyway (6 with 7).
- Isolation: no new non-sandboxed file; ETS partitioned by key rather than reset.
- Regression: one shared test-case change, one config entry, one Credo entry, one migration, one
  supervised child; no existing assertion weakened.

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from explicitly.

1. **The counter is one row per caller, not one per caller and window.** The brief did not say
   which, and the difference turned out to decide two other things. Keyed on `{ip, window}` the
   table grows with every pair since boot and needs a sentinel to know which windows are stale —
   and a sentinel keyed on "the newest window seen" is order-dependent, so the reclamation test
   would have raced whichever other test moved the clock first. Keyed on `ip`, with
   `{ip, window, count}`, a stale bucket is **reset in place** by the next request from that
   caller, so reclaiming it and leaving it are the same thing to the count. `prune/0` therefore
   needs no clock and no agreement with one, and the test that drives it is deterministic.

   The reset that follows a stale read is not atomic — the increment is, through
   `:ets.update_counter/4` reading the stored window in the same call — so a handful of increments
   can be lost by requests in flight exactly as a window rolls. Bounded, only reachable at the
   instant the budget resets anyway, and written into the moduledoc rather than closed with a lock
   in front of every log-in attempt.

2. **Row 12's assertion is against the plug directly rather than through the router.** "The plug
   reads the instant off the scope" cannot be shown end-to-end, because a request that reaches the
   pipeline has already had its scope built from the clock — the two agree by construction there.
   Two hand-built conns one window apart, with `Clock.now/0` asserted not to have moved between
   them, is the only shape that distinguishes the two sources.

3. **Rows 13 and 14 are one test body, not two.** They are the reclamation and its control, and as
   separate bodies they race each other for the table's newest window under ExUnit's shuffle. One
   body with two callers at two windows, based far enough in the future that no other file in the
   suite has written a later one, makes it order-independent.

4. **Two tests the brief did not ask for, both added because a mutation killed nothing.** The
   token statement's `limit` could be removed and no test failed — row 27's bounds test exercised
   the *people* statement alone, and two statements in one function are two bounds. And every
   assertion in the limiter's file derives its loop from `limit/0` and its advance from
   `window_seconds/0`, which is what stops those drifting and leaves both **unpinned**: `@limit`
   raised to a million passes all of them while limiting nothing. Both are now covered
   (mutations 30 and 32 below), the second in the form the moduledoc claims — the window *is* the
   magic link's validity, so "one caller can cause at most `limit` emails inside the lifetime of
   any link they caused" is a sentence about the pair.

5. **Row 34 landed in `boundary_test.exs`'s retention nest rather than as a standalone file.**
   The migration is index-only and depends on nothing in that nest — the indexes are on `people`
   and `people_tokens`, which no rollback there touches — so it rolls on its own, inside the file
   that already owns the migrator machinery. It compares `pg_indexes.indexdef` rather than the
   names, because the partial index's `WHERE` **is** the reap's own two `IS NULL` clauses and a
   predicate that drifted would still be present under the same name; mutation 34 is that drift.

6. **Rows do not map one-to-one onto test bodies**, as U8, U9 and U10 all recorded. The 35-row
   matrix produced **18** bodies in `lifecycle_reap_test.exs`, **15** in `login_rate_limit_test.exs`
   and **1** in `boundary_test.exs` — 34 against 35, with rows 13 and 14 collapsing (revision 3)
   and rows 32 and 33 needing no new body, because `lifecycle_test.exs`'s two existing KTD21 sweeps
   already quantify over every module compiled from `lib/` and therefore covered the new worker and
   the new plug on the day they were written. That is the property those sweeps were built for, and
   it is asserted by their continuing to answer `[Accounts]` and the same two files.

7. **The tree moved underneath this branch.** PR #39 was merged upstream during implementation and
   another checkout switched this working copy to `main` and pulled, so the first two commits
   landed on local `main` at `f8e6e87` rather than on the branch. Moved onto
   `feat/15-rate-limit-and-reapers` and `main` reset to `origin/main`; nothing was rebased and no
   commit was rewritten. The branch is therefore based on `f8e6e87` — current `origin/main`,
   including #39 — rather than on `5645223` as the ticket named it. Nothing in this unit touches
   `Profiles`, `PeerChannel` or `Rosters`.

## Mutation record

Thirty-four mutations, each applied, measured against the two new files (and `boundary_test.exs`
for the migration's two), then restored. Every one of the 34 test bodies is killed by at least one.

| # | Mutation | Tests killed |
|---|----------|--------------|
| 1 | `verdict(false)` answers `:admitted` — the limiter never refuses | 9 |
| 2 | `count <= @limit` → `count < @limit` — refuses one request early | 2 |
| 3 | the counter keyed on a constant rather than `conn.remote_ip` | 5 |
| 4 | the stored window ignored — a stale bucket is added to, never reset | 2 |
| 5 | the bucket reset on every request | 9 |
| 6 | the `retry-after` header dropped | 1 |
| 7 | the refusal body hand-rolled instead of `ErrorEnvelope` | 1 |
| 8 | `prune/0` reclaims nothing | 1 |
| 9 | `prune/0` reclaims the current window too | 1 |
| 10 | a row per caller *and* window rather than per caller | 2 |
| 11 | the counter keyed on the address in the body as well as the caller | 6 |
| 12 | the plug reads `Clock.now/0` rather than the scope's instant | 2 |
| 13 | the limiter applied to `POST /api/log-in/token` as well | 1 |
| 14 | `ConnCase` stops partitioning the key space | 4 (one in `session_controller_test`) |
| 15 | `ConnCase` hands every test the same address | 4 (one in `session_controller_test`) |
| 16 | login tokens reaped strictly past the horizon rather than at it | 2 |
| 17 | the `session` disjunct removed | 2 |
| 18 | the `change:` disjunct removed | 2 |
| 19 | the catch-all disjunct removed | 1 |
| 20 | the token predicate widened to every row | 16 |
| 21 | `confirmed_at IS NULL` dropped from the people reap | 1 |
| 22 | `erased_at IS NULL` dropped from the people reap | 1 |
| 23 | the people horizon inclusive rather than half-open | 1 |
| 24 | the unconfirmed horizon widened to sixty days | 6 |
| 25 | the unconfirmed horizon shortened below a session's validity | 3 |
| 26 | the people reap removed | 6 |
| 27 | the people statement's batch bound dropped | 1 |
| 28 | a **lower bound** added to the people reap — the floor the sweep must not have | 5 |
| 29 | the worker reaps at a fixed instant rather than the clock's | 1 |
| 30 | the token statement's batch bound dropped | 1 (0 before revision 4) |
| 31 | the limiter's window no longer the link's validity | 1 (0 before revision 4) |
| 32 | `@limit` raised to a million | 10 (0 before revision 4) |
| 33 | the migration's `down` drops nothing | 1 |
| 34 | the partial index's predicate drifts from the reap's clauses | 1 |

Two things are deliberately **not** asserted and are named rather than left to be discovered.
`schedule_prune/0`'s interval is not exercised — `prune/0` is, and the interval is a timer with no
decision in it. And `Workers.AccountReaper`'s `Logger.info` is not asserted; it is the trace, and
a test that read it back would be asserting a sentence.
