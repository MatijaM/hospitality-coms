# Test Design Brief — U5, Engagement lifecycle

Issue: #5. Plan: `docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md`, unit U5.
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written before any production
code; the orchestrator stands in for the human approver (issue #21 tracks the missing skill).

## What is being built

Invitation, claim, fixed-term period, derived activeness, renewal, ending, and the
scheduled revocation that follows expiry — plus the single bridge column that makes any
of it possible. `engagements.person_id` is the only crossing between the two zones
(KTD2), and this unit is the one that creates it.

## Acceptance criteria

1. An employer with a live grant can issue an invitation carrying an opaque single-use
   claim code, a role label, and a proposed fixed period. No contact identifier is
   stored and no person row is created.
2. A person holding the code can claim it once, producing exactly one engagement
   attached to their existing person record, and exactly one attested entry, in one
   transaction.
3. Activeness is derived: `period @> instant` with half-open `[)` bounds, never stored.
4. A person cannot hold two overlapping engagements at one venue; the constraint is a
   database exclusion constraint and its violation returns a tuple.
5. Renewal extends the same engagement's upper bound under an optimistic lock and does
   not create a second attested entry.
6. Ending an engagement closes its period at the unit of work's instant, at that venue
   only, and refuses to remove the venue's last grant-holding engagement (R22/KTD17).
7. The expiry worker writes nothing to `engagements`; it re-derives activeness and
   broadcasts only when false.
8. The sweeper is idempotent: two runs over the same expired engagement produce one
   revocation.
9. Advancing the injected clock past an engagement's upper bound excludes that person
   from every membership query with no job having run.

## Edge cases

- Two people race the same claim code. The engagements would carry *different*
  `person_id`s, so nothing overlaps and the exclusion constraint never fires. The guard
  has to be a unique index on `engagements.invitation_id` plus a conditional consume as
  the first Multi step.
- Two concurrent renewals of one engagement. A row does not conflict with itself, so the
  exclusion constraint is silent and one extension is lost.
- An expiry job enqueued before a renewal firing after it.
- Claim code already redeemed; claim code expired; claim code unknown. Three distinct
  refusals, one race-safe consume.
- Adjacent periods sharing a boundary instant — accepted, because bounds are half-open.
- Acceptance before the start date — confirmed, not active (KTD13).
- A failure between the engagement insert and the attested entry insert.
- An employer scope for venue B reaching venue A's engagement.

## Regression risks

- **U3's `boundary_test.exs`.** `engagements` is the deliberate single exception to "no
  employer-zone table holds a foreign key to `people`". It must be classified so the
  assertion stays satisfied on its own terms, not by being narrowed.
- **U4's `venues_test.exs`.** The last-grant invariant counts grant rows. Nothing in
  this unit may change what those tests assert.
- **The zone totality tests.** Every new table needs a classification, RLS where the
  employer zone's rule requires it, and a `(id, venue_id)` unique index.
- **U4's migration round-trip.** `engagements` references `venues` and `employer_grants`,
  so `CreateVenues.down` now has a dependent. The rollback order in `boundary_test.exs`
  has to grow, exactly as U4 grew U3's.
- **`Ecto.Migrator` rollback in `postgres_roles_test.exs`.** A second grant migration is
  a second `pg_shdepend` producer.

## Test matrix

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | Unclaimed invitation grants no access and creates no person row | engagements_test | unit | invitation being person-free |
| 2 | Claim attaches an engagement to the claiming person's existing record | engagements_test | unit | the bridge column |
| 3 | A claim code cannot be redeemed twice | engagements_test | unit | the conditional consume |
| 4 | Two concurrent claims produce one engagement; loser names a step | engagements_concurrency_test | race | unique index + first-step consume |
| 5 | An expired claim code is rejected | engagements_test | unit | `code_expires_at` in the consume predicate |
| 6 | Claim writes engagement and attested entry in one transaction | engagements_test | unit | one Multi |
| 7 | A failure after the engagement insert leaves neither | engagements_test | unit | one Multi |
| 8 | Exclusion violation returns a tuple rather than raising | engagements_test | unit | named constraint + `exclusion_constraint/3` |
| 9 | Two overlapping engagements at one venue are rejected | engagements_test | unit | the exclusion constraint |
| 10 | Two adjacent engagements sharing a boundary instant are accepted | engagements_test | unit | half-open bounds |
| 11 | Accepted before the start date is not active at acceptance | engagements_test | unit | KTD13 |
| 12 | `active_at/2` includes the lower bound and excludes the upper | engagements_test | unit | half-open bounds |
| 13 | Two concurrent renewals do not discard one extension | engagements_concurrency_test | race | `optimistic_lock` |
| 14 | Renewal extends the same engagement, one attested entry | engagements_test | unit | renewal not re-attesting |
| 15 | An expiry job after a renewal leaves the engagement untouched | engagement_sweeper_test | unit | the worker writing nothing |
| 16 | The sweeper run twice produces one revocation | engagement_sweeper_test | unit | job uniqueness |
| 17 | Ending at Venue B leaves Venue A active | engagements_test | unit | per-venue period close |
| 18 | Clock advance past the upper bound excludes the person, no job run | engagements_test | unit | activeness being derived |
| 19 | Ending the venue's last grant-holding engagement is refused | engagements_test | unit | R22/KTD17 |
| 20 | `employer_role`'s privileges on the shared zone are exactly SELECT and a column-scoped UPDATE | boundary_test | boundary | the grant inventory |
| 21 | `employer_role` holds nothing at all on `attested_entries` | boundary_test | boundary | KTD3 |
| 22 | An employer session cannot insert an engagement | engagements_test | boundary | the absent INSERT grant |
| 23 | `engagements` is the only table outside the person zone naming a person | boundary_test | boundary | the single-bridge rule |
| 24 | The bridge key is non-null and `ON DELETE RESTRICT` | boundary_test | boundary | KTD15 |
| 25 | Ending at the instant the term opened yields a term containing no instant | engagements_test | unit | half-open bounds |

Controls carried alongside, so no assertion can pass for the wrong reason:

- 9 has 10 next to it: a constraint that rejected everything would satisfy 9 alone.
- 12 asserts the lower bound *does* return the engagement, so an `active_at/2` that
  returned nothing would fail.
- 16 asserts one run produces one revocation, so a sweeper that produced none would fail.
- 18 asserts the same query returns the person *before* the advance.
- 20 has the existing grant-behind-the-back control in the same file.
- The concurrency file carries the barrier control both U4 concurrency files carry: a
  test that flunks unless both racers are demonstrably parked on the same lock.

## Implementation constraints

- `@spec` on every public function; error atoms enumerated.
- `Ecto.UUID.t()` for ids.
- Migrations via `mix ecto.gen.migration`, reversible `down`, U1–U4's untouched.
- `Clock.now/0` only from a unit-of-work boundary; the workers become the second and
  third entries in `.credo.exs`'s `:boundary_modules`. `Ecto.Query.ago/2` banned.
- `Ecto.Multi` with named steps for the claim.
- `engagements.person_id` non-null, `ON DELETE RESTRICT` (KTD15).
- `match: :full` on composite foreign keys except where a column of the key is
  legitimately null — the same documented exception U4 shipped.
- Concurrency tests non-sandboxed, following the two fixed precedents.

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed
from explicitly.

1. **Row 20 was wrong and is replaced.** It claimed `employer_role` should hold
   *no* privilege on the shared zone. It cannot: `engagements` is how a venue
   knows who is engaged, so the employer role needs `SELECT`, and renewal and
   ending need `UPDATE`. Granting nothing would make U6's venue-room membership
   query unwritable from an employer scope. What is asserted instead is the
   exact inventory — `SELECT`, plus `UPDATE` on `ends_at`, `lock_version` and
   `updated_at` alone, and **no `INSERT`**, so no employer session can
   manufacture a worker. Rows 21–24 were added alongside it, because the
   inventory only means something next to the absences it is measured against.

2. **Two tables the brief did not name.** `invitations` and `attested_entries`
   are both created here. The brief implied the first and required the second —
   scenarios 6, 7 and 14 are assertions about attested-entry rows — but neither
   was listed. Both are employer zone, both carry `venue_id`, neither names a
   person. `attested_entries` is granted nothing (KTD3); U9 owns its context and
   extends the schema.

3. **`Ecto.Multi.mode: :savepoint` is not used for the claim**, unlike U4's
   venue creation. That multi runs inside `EmployerRepo.scoped_transaction/2`
   and needs one; this is the outermost transaction there is, and asking
   DBConnection for a savepoint outside a transaction is an error.

4. **`engagements_term_not_reversed` is `>=`, not `>`.** Discovered by a failing
   test: ending an engagement at the instant its term opened produces
   `tstzrange(a, a, '[)')`, the empty range. An engagement cannot be *created*
   that way — an invitation's term is strictly ordered — so the empty case is
   reachable only by ending one, and it is the correct record of it: active at
   no instant, overlapping nothing. Row 25 covers it.

5. **`engagements_test.exs` is not sandboxed.** The claim spans both repos'
   connections; under the sandbox those are two transactions that cannot see
   each other's rows. The alternative was to run the claim as `employer_role`,
   which would mean granting that role `INSERT` on `attested_entries` — the one
   table KTD3 says it must hold nothing on — to make a test harness happier.

6. **U4's last-grant invariant is unchanged.** The brief flagged
   `venues_test.exs` as a regression risk and it stayed one: nothing in
   `HospitalityComs.Venues` changed except an additive
   `fetch_acting_grant/1`, so U5 does not duplicate U4's authorization check.
   R22/KTD17's other half lives in `end_engagement/2`.

## Quality scores (self-assessed)

- Coverage of stated scenarios: 16/16 named in the plan, plus 4 added.
- Assertion strength: every scenario asserts a state, not a return value alone, where a
  state exists to assert.
- Control coverage: 6 controls for the 6 assertions that could pass vacuously.
- Isolation: unit tests sandboxed and async where both repos allow it; races isolated by
  a name prefix and purged before and after.
