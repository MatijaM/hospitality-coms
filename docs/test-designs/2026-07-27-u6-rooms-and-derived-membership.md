# Test Design Brief — U6, Rooms and derived membership

Issue: #6. Plan: `docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md`, unit U6.
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written before any production
code; the orchestrator stands in for the human approver (issue #21 tracks the missing
skill). Convention established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md`.

## What is being built

A venue room bounded by active engagements minus the person's own suspension, shift rooms
whose membership is roster periods overlapping the room's open interval, a grace window
that closes writes without closing reads, and the read scope KTD14 resolves.

**Nothing is materialised and no job runs.** KTD6b: an earlier design snapshotted a shift
room's membership at shift start so a later roster correction could not retroactively
withdraw access. It inverts under its own failure mode — a job firing ten minutes late
captures the roster *as corrected*, which is the exact retroactive withdrawal it existed
to prevent, and a missed run is indistinguishable from an empty roster so nothing can
detect it. Removal now closes a period instead of deleting a row, so non-retroactivity is
structural: there is no write that can withdraw access.

## Acceptance criteria

1. Venue-room membership at instant `t` is: an engagement active at `t`, minus a
   suspension period containing `t`. Nothing stores it.
2. A shift room carries a **stamped** `grace_period_minutes`, copied from its shift type
   at creation, and its open interval is `[starts_at, ends_at + grace)`, half-open.
3. Shift-room *membership* at `t` is a roster period containing `t`, intersected with the
   room being open at `t` and the engagement being active at `t`.
4. Shift-room *readability* at `t` is a roster period **overlapping** the room's open
   interval, intersected with an active engagement at `t`. That is KTD14's snapshot scope
   and R14/R16's resolution: the overlap set *is* the snapshot, derived rather than stored.
5. Venue-room readability carries no message-time filter — a person engaged today reads
   history from before their engagement (R14, full history, venue room only).
6. Removing a person from a roster closes their period; it never deletes the row and never
   removes readability already earned by overlap.
7. Sends into a shift room are refused once the instant reaches `ends_at + grace`; reads
   are not. A grace of zero closes writes at `ends_at`.
8. Suspension is reversible at will, affects the venue room alone, and is **structurally
   invisible to the employer** — it lives in the person zone, where `employer_role` holds
   no privilege and `EmployerRepo`'s query backstop refuses the join (KTD18).
9. The same person cannot hold two overlapping roster periods on one shift, enforced by a
   database exclusion constraint over a GiST index on
   `(shift_room_id, engagement_id, period)`.
10. Advancing the injected clock across `ends_at` and then across `ends_at + grace` changes
    send behaviour with no job having run.

## The overlap predicate, and why it is the risk

Two half-open intervals `[a1, b1)` and `[a2, b2)` overlap iff **both are non-empty** and
`a1 < b2 and a2 < b1`. The emptiness clause is not decoration: a roster entry added and
removed at the same instant is `[a, a)`, which contains no instant and must overlap
nothing — and the endpoint form without the clause reports an overlap for it.

Three spellings exist and all three must agree:

- `Engagements.Records.active_at/2` — `starts_at <= t and ends_at > t`, half-open
  containment of an instant.
- `Rooms.Records` — the same containment for a roster entry (`joined_at <= t and (left_at
  is null or left_at > t)`) and for a room (`starts_at <= t and closes_at > t`), plus the
  overlap form above with the emptiness clause written out.
- Postgres — `roster_entries.period && shift_rooms.open_period`, on two `GENERATED ALWAYS
  AS ... STORED` `tstzrange` columns with `'[)'` bounds. The exclusion constraint reads
  the first of them.

Containment is a special case of overlap (`period @> t` is `period && [t, t]`), which is
why one convention has to hold across all of them. **A membership query computed one way
and `active_at/2` computed another is the defect this unit exists to avoid**, so the
matrix in scenario 21 below asserts the Ecto predicate and Postgres's `&&` agree, case by
case, including the empty and unbounded ones.

## Edge cases

- A roster entry with `left_at == joined_at` — empty period. Overlaps nothing; the person
  is never a member and never a reader; a re-add over the same dates is accepted because
  an empty range conflicts with nothing.
- A roster entry with `left_at` null — unbounded above. Overlaps the room iff
  `joined_at < closes_at`.
- Rostered before the shift and removed before it starts: `[t0, t1)` with `t1 <= starts_at`
  — no overlap, so never in the room and never a reader. This is the case that
  distinguishes overlap from "was ever rostered".
- Removed *after* open: `[t0, t2)` with `t2 > starts_at` — overlaps, so readability
  survives the removal for ever. This is non-retroactivity.
- Added after open: `[t3, ∞)` with `starts_at < t3 < closes_at` — overlaps, readable after
  grace closes.
- Grace of zero — `closes_at == ends_at`; a send at exactly `ends_at` is refused, one a
  second before is accepted.
- A send at exactly `closes_at` is refused; at `closes_at - 1s` accepted. Half-open.
- A send before `starts_at` is refused: the room is not open yet.
- Suspending twice without resuming — refused by the exclusion constraint on
  `(engagement_id, period)`; resuming when not suspended — refused.
- An engagement that ends while a suspension is open: the person is out of the venue room
  because the engagement ended, and the suspension row is inert.
- A shift type's grace edited after a room is created must not move the room's boundary.
  The grace is stamped on the room, exactly as an invitation's term is copied onto the
  engagement rather than joined to.
- A roster entry naming an engagement at another venue — refused by the composite foreign
  key whatever the context believes.

## Regression risks

- **U3's `boundary_test.exs`.** Four new tables. Three are employer zone and need
  `venue_id`, a unique `(id, venue_id)`, RLS with exactly one non-FORCEd tenancy policy,
  and no foreign key to `people`. One is **person zone**, which is new territory: U3's
  `grant_zones` migration hard-codes `~w(people people_tokens)` and the suite asserts that
  list equals `Zones.person_zone_tables/0`. U1–U5's migrations are off-limits, so the
  assertion has to grow to a union over both revoking migrations — additively, in the same
  shape as `granted ++ @ungranted_tables == employer_zone ++ shared` already has.
- **The composite foreign-key inventory.** Four new composite keys, each named and each
  either `MATCH FULL` or — where a column of the key is legitimately nullable —
  `MATCH SIMPLE`. The derived-rule test decides; the inventory map must be extended.
- **The rollback chain.** The new tables reference `venues`, `shift_types` and
  `engagements`, so `create_engagements.down` and `create_venues.down` now have dependents.
  `round_trip_employer_zone/1` must unwind U6 first or `DROP TABLE` is refused, and the
  new employer-zone tables must be *absent* while rolled back.
- **`postgres_roles_test.exs`.** A third grant migration is a third `pg_shdepend` producer;
  `@grant_migrations` has to grow or `DROP ROLE employer_role` fails.
- **`EngagementsFixtures.purge/0`.** Every new table's rows hang off engagements through
  `ON DELETE RESTRICT`, so the purge must remove them first or U5's own suite starts
  failing on cleanup.
- **U4's `venues_test.exs` and U5's `engagements_test.exs`.** Nothing in this unit may
  change what they assert. `Venues` gains nothing; `Engagements` gains nothing.
- **The zone totality tests.** Four schemas, four classifications, zero exceptions.

## Test matrix

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | A person with an active engagement is in the venue room | rooms_test | unit | membership deriving from `active_at/2` |
| 2 | A person whose engagement ended is not | rooms_test | unit | membership deriving from `active_at/2` |
| 3 | A suspended person is absent from the venue room | rooms_test | unit | the suspension period |
| 4 | …but remains in shift rooms | rooms_test | unit | suspension not reaching shift membership |
| 5 | A resumed person sees full history, messages sent while suspended included | rooms_test | unit | history not filtered by membership-at-send-time |
| 6 | The employer scope cannot read the suspension flag: zero privilege | boundary_test | boundary | person-zone classification + revoke |
| 7 | The employer scope cannot read it through a join either | rooms_test | boundary | `EmployerRepo`'s zone backstop |
| 8 | A shift room's membership at open equals the rostered set with active engagements | rooms_test | unit | containment at the open instant |
| 9 | …and excludes a rostered person whose engagement has ended | rooms_test | unit | the intersection with `active_at/2` |
| 10 | Adding to the roster after open adds them to the room | rooms_test | unit | membership being derived, not snapshotted |
| 11 | …and keeps them readable after grace closes | rooms_test | unit | readability being overlap, not containment |
| 12 | Removing after open leaves access to already-sent messages intact | rooms_test | unit | removal closing a period, not deleting |
| 13 | Rostered before the shift and removed before it starts never appears | rooms_test | unit | overlap rather than "ever rostered" |
| 14 | The same person cannot hold two overlapping roster periods on one shift | rosters_test | unit | the exclusion constraint |
| 15 | …and a re-add after removal is accepted | rosters_test | unit | half-open bounds (control for 14) |
| 16 | A post-grace send is rejected | rooms_test | unit | the open interval's upper bound |
| 17 | A within-grace send is accepted | rooms_test | unit | grace being a write window (control for 16) |
| 18 | A shift-type grace of zero closes the room at shift end | rooms_test | unit | zero being a value, not an omission |
| 19 | A person outside the overlap set cannot read the closed shift room, active engagement notwithstanding | rooms_test | unit | KTD14's snapshot scope |
| 20 | A newly engaged person reads venue-room history predating their engagement | rooms_test | unit | R14 full history on the venue room |
| 21 | A newly engaged person cannot read closed shift rooms from before their engagement | rooms_test | unit | KTD14 |
| 22 | The Ecto overlap predicate agrees with Postgres `&&` over a matrix of interval pairs | rooms_test | unit | one convention across all three spellings |
| 23 | Clock advance across `ends_at`, then across `ends_at + grace`, changes send behaviour with no job run | rooms_test | unit | everything being derived |
| 24 | A shift room stamps its grace; editing the shift type afterwards does not move it | rooms_test | unit | the copy at creation |
| 25 | A roster entry naming another venue's engagement is refused | rosters_test | unit | the composite foreign key |
| 26 | Suspending twice without resuming is refused; resuming when not suspended is refused | rooms_test | unit | the suspension exclusion constraint |
| 27 | Every U6 employer-zone table carries `venue_id`, `(id, venue_id)`, one tenancy policy | boundary_test | boundary | the employer-zone rules |
| 28 | No U6 table holds a foreign key to `people`; `engagements` is still the only crossing | boundary_test | boundary | KTD2 |
| 29 | `employer_role` holds nothing on `room_messages` | boundary_test | boundary | the ungranted list |
| 30 | The employer-zone privilege inventory is exactly what U6's code exercises | boundary_test | boundary | the grant migration |
| 31 | The U6 migrations round-trip: down leaves no table, up restores privileges and policies | boundary_test | boundary | reversible `down` |
| 32 | A send naming another venue's room is `:not_found`, open or shut | rooms_test | boundary | the sender's-venues confinement |

Controls carried alongside, so no assertion can pass for the wrong reason:

- 1 is the control for 2, and 17 for 16 — a membership query that returned nothing, or a
  send path that refused everything, would satisfy the negative half alone.
- 15 is the control for 14: a constraint that rejected every second entry would satisfy 14.
- 10 is the control for 13: an overlap predicate that matched nothing would satisfy 13.
- 20 is the control for 21: a reader that could see nothing would satisfy 21.
- 4 is the control for 3: a suspension that removed the person from everything would
  satisfy 3.
- 22 carries its own control — the matrix includes pairs that *do* overlap, so a predicate
  returning false everywhere fails it.
- 6 sits next to the existing grant-behind-the-back control in `boundary_test.exs`, which
  is what makes an absent privilege evidence rather than an accident of default-deny.
- 23 asserts the send is accepted *before* each advance, so a send path that always refused
  would fail it.

## Implementation constraints

- `@spec` on every public function; error atoms enumerated, never `{:error, term()}`.
- `Ecto.UUID.t()` for ids; `@type t()` on every schema with every field listed.
- Migrations via `mix ecto.gen.migration`, reversible `down`, U1–U5's untouched.
- `Clock.now/0` is not called anywhere in this unit and no module joins
  `:boundary_modules`: **no job runs**, so there is no new unit-of-work boundary. The
  instant arrives on the scope. `Ecto.Query.ago/2` and `from_now/2` stay banned.
- `Ecto.Multi` with named steps wherever a write is multi-step, with `mode: :savepoint`
  made explicit on a constrained insert that is not the transaction's last statement.
- Composite foreign keys `match: :full` per KTD2, except where a column of the key is
  legitimately nullable — the derived rule the inventory test already asserts.
- Every new employer-zone table: `venue_id`, unique `(id, venue_id)`, one non-FORCEd
  tenancy policy on `app_current_employer_id()`.
- The person-zone table: no venue key, no grant, explicit `REVOKE`.
- Room and roster queries live in `Rooms.Records`, per U5's pattern; no query is rebuilt
  at a call site.
- Person-side and employer-side reads run through different repos, so the tests that span
  them are non-sandboxed and purge by name prefix, following `EngagementsFixtures`.

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from
explicitly.

1. **There is no `venue_rooms` table, and no `shifts` table.** The brief assumed both
   from the plan's file list. A venue room is one per venue and has nothing to store
   that `venues` and `engagements` do not already hold, so it is a derived struct —
   `Rooms.VenueRoom` — and a venue-room message is a `room_messages` row whose
   `shift_room_id` is null. A shift room *is* the shift; the plan's diagram listed
   `shifts` next to `membership_snapshots`, KTD6b deleted the second, and the first
   never had a field the room did not. Materialising either would have been the same
   mistake KTD6b rejects at full size, in miniature.

2. **U6 builds messages, which the plan's file list does not name.** Four of the unit's
   own test scenarios are assertions about messages — the post-grace send, the
   already-sent messages a removal leaves intact, the venue-room history a new hire
   reads. `room_messages` is one table for both room kinds, because the two differ in
   who may read them and in nothing else. No retention column: KTD16's stamped deadlines
   are U10's `*_add_retention_columns.exs`, and a deadline written before the sweeper
   that reads it exists is a column nobody could have tested.

3. **The grace is stamped on the room, not joined to its shift type.** The brief said
   "copied"; this records why it is load-bearing rather than tidy. A shift type edited on
   Tuesday would otherwise reopen Monday's closed room, and for every room of that type
   at once. Scenario 24 covers it.

4. **`employer_role` holds nothing at all on `room_messages`.** Not in the brief's
   inventory. Room conversation is worker-facing — R11's readers are the people who
   worked the shift, a manager among them, reading through their own engagement from the
   person's side. An employer *session* that can read a venue's conversation in bulk has
   no reason to exist, so no grant creates one. The same shape `attested_entries` has
   under KTD3, for a different reason.

5. **U3's `grant_zones` migration was not edited, and the assertion around it grew
   instead.** `boundary_test.exs` asserted `GrantZones.person_zone_tables() ==
   Zones.person_zone_tables()`; U6 adds the first person-zone table since U2 and U1–U5's
   migrations are off-limits. The comparison is now a union over every migration that
   revokes, which is the shape `granted ++ @ungranted_tables == employer_zone ++ shared`
   already had. A person-zone table covered by no migration still fails it.

6. **`privilege_snapshot/0` in `boundary_test.exs` now sweeps `GrantZones`'s own list
   rather than the whole classification.** It is taken while the later units' migrations
   are rolled off, and `Zones.privileges/2` raises on a missing table on purpose. The
   helper's own comment already said "everything the migration is responsible for"; this
   makes it true. Coverage is unchanged — `Zones.employer_privileges(Repo) == []` over
   the whole person zone is still asserted separately, and revision 5 ties the two lists
   together.

7. **An enumeration leak found in review, after the tests were green.**
   `send_shift_room_message/3` looked a room up by id alone, so `:room_closed` and
   `:not_rostered` — both statements that the named room exists — enumerated every
   venue's shifts one probe at a time. That is AE1's not-found-rather-than-forbidden rule
   lost at the one place a caller supplies the id. The lookup is now confined to the
   sender's own venues. Scenario 32 was added with its own control.

8. **`Rosters` is a context of its own and `Rooms` reads its consequences.** Rostering is
   an administrative act under an employer scope; "who is in this room" and "who may read
   it" are questions about rooms, and one of them subtracts a person-zone table no
   employer scope may reach.

9. **`EngagementsFixtures.purge/0` grew.** Every U6 table hangs off `engagements` or
   `venues` through `ON DELETE RESTRICT`, so U5's purge had to remove them first —
   `shift_types` included, which U5 never created and therefore never purged.

## Quality scores (self-assessed)

- Coverage of stated scenarios: 14/14 named in the plan and the issue, plus 18 added.
- Assertion strength: every scenario asserts a state or a set, not a return value alone.
- Control coverage: 9 controls for the 9 assertions that could pass vacuously.
- Isolation: tests that touch both repos are non-sandboxed and purged before and after;
  everything else is sandboxed.
- Suite: 517 tests, green over three seeded runs; `mix quality` and
  `mix format --check-formatted` clean; strict compile clean in `:dev` and `:prod`.
</content>
</invoke>
