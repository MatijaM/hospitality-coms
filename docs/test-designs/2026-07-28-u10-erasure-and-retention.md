# Test Design Brief — U10, Data lifecycle: erasure and retention

Issue: #10. Plan: `docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md`, unit U10.
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written and committed before any
production code; the orchestrator stands in for the human approver (issue #21 tracks the missing
skill). Convention established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md`
through `-u9-profile-disclosure-and-employer-view.md`, including the "record revisions rather
than applying them silently" section at the end.

The issue's execution note is stronger than the standing gate: **deletion is irreversible here,
so the failing test comes first without exception.** This file is its own commit, ahead of the
production code, so the ordering is visible in the history rather than asserted.

## What is being built

Two operations that destroy data, and the module that is the only place either of them lives
(KTD21).

**Erasure** pseudonymises a person row in place and never deletes it (KTD15). It ends every
engagement the person holds, reduces every engagement's role label to a non-identifying
constant, nulls the email, stamps `erased_at`, deletes the auth tokens explicitly, disconnects
every peer connection and deletes the erased person's own peer messages, deletes their declared
entries and their retained own-message copies, and deletes their scheduled Oban rows — one
`Ecto.Multi`, one transaction. It is exempt from the last-grant-holder invariant (KTD17) and
leaves the venue in an orphaned state that has a name rather than being inferred.

**Retention** is a bounded, unattended, recorded deleter reading **stamped** `delete_after`
columns. Four triggers (KTD16): own-message copies keyed to the person's engagement end, shift
history — messages *and* roster entries — keyed to the shift, venue-room history keyed to venue
closure, and engagements and attested entries never, deliberately.

## The single most important design constraint, stated first

**A deadline is a column written when the row is created (or when the closure happens), never a
join against a period that can still move.** Computing at sweep time lets a backdated engagement
end or a corrected shift time move a deadline into the past, and the next unattended run then
destroys a worker's messages with no notice. Every one of the four triggers therefore reads a
stamped column, and the suite proves it by moving the period *after* the stamp and watching the
sweep ignore the move (rows 24 and 27 below).

## Acceptance criteria

1. **Erasure never deletes the person row.** After it, `Repo.get(Person, id)` returns a row with
   `erased_at` set and `email` nil. The two check constraints
   (`people_erased_email_removed`, `people_present_email_required`) already hold the pair in
   opposition; U2 built them for this and U10 is the first caller.
2. **Two erased people do not collide.** `people_email_index` is partial on `erased_at IS NULL`,
   so any number of erased rows carry a null address.
3. **An erased person cannot authenticate.** Every `people_tokens` row is deleted inside the
   transaction — there is no person delete and therefore no cascade to rely on (KTD15).
4. **Every engagement ends in the same transaction, and the last-grant-holder invariant does not
   apply.** Erasing a venue's sole grant-holder succeeds. The venue is then *orphaned*: a live
   grant that no active engagement holds. That state gets a name (`Lifecycle.orphaned_venues/1`)
   rather than being something a reader has to derive, because KTD17 promises an operator
   re-seed path and a path to a state nobody can enumerate is not a path.
5. **Message authorship survives under a non-identifying label.** KTD15b put the display label on
   the engagement, so erasure reduces a number of rows proportional to engagements rather than to
   messages, and no `room_messages` row is touched at all. The label becomes
   `Lifecycle.erased_label/0`.
6. **A peer conversation is erased as a disconnect plus deletion of the erasing party's own
   messages.** The survivor keeps their own and loses nothing; the erasing party has no claim
   over the other person's words, which is KTD15c's reasoning applied one table over.
7. **Scheduled work for that person is cancelled by deleting the rows in the same transaction.**
   `Oban.cancel_job/1` is not transactional and would leave a cancelled job behind a rolled-back
   erasure, or an uncancelled one behind a committed erasure.
8. **The sweeper reads stamped columns, deletes in bounded batches, rolls back above a
   configured ceiling, and records every run** with the instant used and per-trigger counts.
9. **Half-open, as everywhere else.** A row whose `delete_after` is exactly the sweep's instant
   survives; the predicate is `delete_after < instant`.
10. **`Lifecycle` is the only module that deletes.** Asserted structurally out of the compiled
    `imports` chunk, the way `peers_test.exs` reads query builders and `person_zone_test.exs`
    reads repo calls — with one enumerated exemption, below.
11. **Every new table is classified** and `employer_role` holds nothing on either.
12. **KTD5 — one instant per unit of work.** The sweeper is a new unit of work and therefore a
    new `.credo.exs` `:boundary_modules` entry, exactly as `ExpireEngagement` and
    `EngagementSweeper` are. Nothing else gains a `Clock.now/0` call.
13. **No `{:error, term()}`.** Every refusal is an enumerated atom or a changeset.

## The one exemption to "only `Lifecycle` deletes", enumerated rather than described

`HospitalityComs.Accounts` calls `Repo.delete_all/1` in three places: magic-link redemption
claims the link, log-out deletes the session token, and an email change expires every token the
person holds. All three delete `people_tokens` and nothing else.

That is **credential expiry, not record destruction**, and it cannot move into `Lifecycle`
without routing log-out through a module about retention. KTD21's stated purpose is that "the two
operations that can destroy data [are] findable in one module, because one of them runs unattended
on a schedule"; a session token is neither of those. So the structural sweep asserts the offender
set is **exactly `[Accounts]`** — the shape `peers_test.exs` uses for `Filter`/`Select`/`Update` —
and a behavioural test pins that `Accounts`'s deletes reach `people_tokens` alone by counting every
other table across a log-out.

Recording it as an enumerated exemption is deliberate: a sweep with a silent carve-out is a sweep
that grows carve-outs.

## Where every deadline comes from

| Trigger | Table | Column | Stamped when | Window |
|---|---|---|---|---|
| own-message copies | `retained_message_copies` | `delete_after` | the copy is written, from the engagement's closed `ends_at` | 90 days |
| shift messages | `room_messages` (shift-room) | `delete_after` | the message is inserted, from `shift_rooms.closes_at` | 30 days |
| shift roster | `roster_entries` | `delete_after` | the entry is inserted, from `shift_rooms.closes_at` | 30 days |
| venue-room history | `room_messages` (venue-room) | `delete_after` | **venue closure**, and null until then | 30 days |
| engagements, attested entries | — | none | never | never |

The two shift windows and the venue window are 30 days; the worker's own copy is 90. **The
difference is load-bearing rather than decorative**: it is what makes KTD16's argument for
physically separate rows demonstrable — the venue's copy of a shift message dies at 30 days while
the worker's copy of the same message lives to 90, which a filtered view over one row carrying two
deadlines could not express, and where the shorter would have silently won.

Venue-room history has no clock while the venue exists, so `delete_after` is null and the sweep's
`delete_after < instant` never matches it. Closure stamps it, and stamps **only** where it is null,
so a shift message's already-stamped deadline is neither extended nor shortened by the venue
closing.

## Where the retained copy is written, and why not in the engagement-end transaction

KTD16 says "written inside the engagement-end transaction". **That is not available and the reason
is the zone partition, not an oversight.** `Engagements.end_engagement/2` runs inside
`EmployerRepo.scoped_transaction/2`, and `employer_role` holds no privilege on any person-zone
table — so the transaction that closes the term structurally cannot write the worker's copy. An
after-commit write through `Repo` would be a second connection's transaction with no backstop: a
silent partial failure that nothing detects and nothing retries.

So the copy is written by **`Workers.ExpireEngagement` on its `:revoked` path**, which is the one
event in the system that means "this engagement's term has closed", and which already has a
scheduled trigger, a periodic backstop (`EngagementSweeper`), and idempotence. It covers natural
expiry and explicit ending alike, because `end_engagement/2` rewrites `ends_at` to the closing
instant and the sweep's window then finds it.

**The permanent-loss gap CLAUDE.md records for announcements does not reach the archive.** That gap
is about a *broadcast* being lost; the job still ran. Uniqueness suppresses a replacement only once
the job has `:completed`, i.e. only after the copy was written, and `:discarded` is excluded so a
job that failed permanently is re-inserted by the sweeper. The copy write is idempotent
(`ON CONFLICT DO NOTHING` against a unique `(engagement_id, source_message_id)`), so a retry costs
nothing.

## `source_message_id` is deliberately not a foreign key

The copy carries the body, not a reference — that is what "physically separate rows" means and what
lets the two deadlines differ. It also carries `source_message_id` purely as the idempotence key,
as a plain `binary_id` with **no** foreign key into `room_messages`:

- a person-zone foreign key into the employer zone would be a second crossing, and
  `boundary_test.exs` asserts against `pg_constraint` that `engagements` is the only table outside
  the person zone referencing `people` and that no employer-zone table names a person — a key in
  this direction is the mirror image of the rule and would deserve the same scrutiny;
- an `ON DELETE RESTRICT` key would make the shift-history sweep fail the moment a worker's copy
  outlived the original, which is the entire point of the copy;
- an `ON DELETE CASCADE` key would delete the worker's copy on the venue's clock, which is exactly
  the "shorter deadline silently wins" failure KTD16 rejects.

Ownership is still a database rule and not an application one: `(engagement_id, person_id)` is a
MATCH FULL composite key into `engagements (id, person_id)`, reusing the unique index U9 created
for `attested_entry_disclosures`.

## The three inherited hazards, and how each is answered

**1. `Peers.disconnect/2` accepts only a live `PersonScope` acting for itself.** An erasure has no
such scope. `Peers` gains `disconnect_all/3`, taking the caller's repo, the person id and the
instant, closing every live connection that person is a party to and blocking each counterpart —
no scope, no announcement, and it runs inside the erasure's own transaction. `Lifecycle` announces
after the commit through a second new export, `Peers.announce_disconnection/1`, which is the split
`Engagements` already has between `close/2` and `announce/1`. The disconnect **is** the remedy
semantics (R15), so it stays in `Peers` rather than being reimplemented in `Lifecycle`; only the
deletion of the erased person's own messages happens in `Lifecycle`, per KTD21.

**2. `Peers.block_counterpart/4` asserts `{1, _} = repo.update_all(…)`.** Answered twice, because
one answer alone is a promise:

- **Erasure deliberately retains `connection_requests` rows.** They are the pair's block record
  (KTD19) and `peer_connections.request_id` is `NOT NULL ON DELETE RESTRICT`; deleting them would
  destroy the counterpart's protection and orphan the connection. A test pins that erasure leaves
  them, which is what keeps the `MatchError` unreachable.
- **The assertion becomes a refusal anyway.** `{0, _}` now answers `{:error, :request_gone}`,
  enumerated in `disconnect_failure()`, so an invariant that is currently held by a schema decision
  fails loudly rather than crashing a transaction if that decision is ever revisited.

**3. A channel derives its session per join, not per event.** CLAUDE.md names U10 as "the one to
watch" because erasure deletes the person rather than the session. The decision, written down:

- **Erasure returns the deleted token rows**, exactly as `Accounts.delete_person_session_token/1`
  does, so the surface that eventually exposes erasure disconnects the transports the same way
  log-out does. `Lifecycle` does not call `HospitalityComsWeb.PersonAuth` itself — a context calling
  the web layer would be backwards, and no existing context does.
- **The teardown is not what makes the channel powerless.** Erasure ends every engagement and
  disconnects every peer connection in the same transaction, and authorization is per inbound event
  (KTD5). So a channel that survives the broadcast can still *send* the frame and gets refused, on
  the same process, with nothing having rejoined. That is asserted rather than argued, in
  `revocation_test.exs`, which is where the same claim about engagement expiry already lives.

## U9's two referential obstacles

**`attested_entry_disclosures`** carries `audience_person_id` referencing `people` **and**
`(engagement_id, person_id)` MATCH FULL into `engagements (id, person_id)`.

- Rows where the erased person is the *subject* (`person_id`) are **kept**. Deleting them would
  *widen* disclosure — the ledger only ever narrows it, so removing a `disclosed = false` row
  re-reveals the entry it was hiding, to every audience, for the thirty days peer visibility runs
  past an engagement's end. Erasure must not be the one operation that discloses more.
- Rows where the erased person is the *audience* (`audience_person_id`) belong to somebody else and
  are kept for the same reason plus a stronger one: they are another person's decision.
- Neither is a referential obstacle to erasure, because erasure deletes no person and no
  engagement. Both are pinned by tests, because "we left them alone" and "we forgot them" look
  identical in a diff.

**`declared_entries.person_id`** references `people` with `ON DELETE RESTRICT`. A declared entry is
free text the person wrote about their own history and belongs to nobody else, so **erasure deletes
them**. That is where the line falls: KTD15c retains message bodies because deleting them would
destroy conversations belonging to other people, and a declared entry has no other party.

`correction_requests` is left alone on the same test — it is addressed to a venue, which is the
other party, and the venue's record of a contest is theirs.

## What erasure does **not** do, on the record

- It does not delete `room_messages`, `roster_entries`, `attested_entries`, `engagements`,
  `connection_requests`, `peer_connections` or `correction_requests`. KTD15c: erasure is
  *identifier* erasure, bodies survive on a legitimate-interest basis, and venue-room history
  therefore holds personal data indefinitely. Stated rather than assumed.
- It does not close the thirty-day peer-visibility tail. A peer co-engaged with the erased person
  keeps seeing their attested entries — venue names, employer-authored role labels, dates — for
  thirty days after the last engagement ends, with no email and no declared entries. That is the
  identifier-erasure position applied consistently; it is a disclosure, not a defect, and it is
  written down here rather than found later.
- It does not revoke `employer_grants`. The grant is a venue's row about a venue; erasing the human
  who held it leaves the venue orphaned (criterion 4) rather than un-administrable for ever.

## Venue closure is an operator action, not an employer one

`Lifecycle.close_venue/2` takes a venue id and an instant, holds no `EmployerScope`, and is exposed
on no transport. Three reasons, in order of weight:

1. `employer_role` holds **nothing** on `room_messages`, so an employer session structurally cannot
   stamp the deadlines closure exists to stamp.
2. Closing a venue destroys, on a clock, the conversation history of everybody who ever worked
   there. KTD21 confines that to `Lifecycle`, and U11's demo controls already run "under their own
   scope, not an employer scope" for the same class of reason.
3. The plan describes no employer endpoint for it.

It is idempotent by refusal: a second call is `{:error, :already_closed}`.

## Edge cases

- A person with no engagements, no tokens, no peers and no messages erases cleanly and the multi
  reports zeroes rather than failing on an empty step.
- Erasing twice is `{:error, :already_erased}`, decided under `FOR UPDATE` on the person row so two
  concurrent requests produce one erasure.
- An engagement that has not started yet closes at its own `starts_at` — the empty range — exactly
  as `end_engagement/2` does, so erasure frees the person's dates rather than reserving them for a
  term nobody will work.
- An engagement whose term already closed is not re-ended and its `ends_at` is not moved.
- A person holding a *revoked* grant is not a grant holder, so erasing them orphans nothing; the
  orphan list uses `EmployerGrant.live_at/2` so "live" does not come to mean two things.
- The sweep with nothing due deletes nothing and still writes a run record. A recorded zero and no
  record at all are different facts.
- A row whose `delete_after` is exactly the instant survives; one a microsecond earlier does not.
- `delete_after IS NULL` never matches, which is how venue-room history survives every sweep until
  closure.
- A run at the ceiling exactly is permitted; above it rolls back. Half-open in the same direction
  as everything else.
- A rolled-back run leaves **every** row in place — all four triggers, not only the one that
  overflowed — and still writes a record, with the counts it would have deleted.
- Closing a venue twice is refused, and the second call stamps nothing.
- Closing a venue does not touch a shift message that already carries a deadline.
- `retain_own_messages/2` for an engagement with no messages writes nothing and answers `{:ok, 0}`.
- Running it twice writes one copy per message, not two.
- Running it for an erased person's engagement writes nothing, however many times it runs.

## Regression risks

- **`boundary_test.exs`.** Two new person-zone tables, two new migrations, three new columns. The
  person-zone revoked-tables union grows by one migration's list; the composite-foreign-key
  inventory grows by `retained_message_copies_engagement_fkey` (MATCH FULL); the "engagements is
  the only table outside the person zone referencing `people`" test must still answer
  `["engagements"]`; every totality sweep must still be total. `retention_runs` holds no foreign
  key at all, which is the first table in the tree of which that is true — the sweeps must not
  assume otherwise.
- **`postgres_roles_test.exs`.** One new grant migration, one new entry in the unwind list, in the
  real order Ecto uses. The rule is "every grant migration", including one that grants nothing.
- **`zones_test.exs`.** Two schemas, and the totality check fails until both are placed.
- **`people_auth_tables_test.exs`.** `retained_message_copies` references `engagements`, not
  `people`, so the `@dependents` chain does not grow — asserted rather than assumed, because
  getting that wrong is a passing test that proves nothing.
- **`EngagementsFixtures.purge/0`.** Two more deletes, ahead of `engagements` and ahead of
  `people`, for the reason U6's four, U8's three and U9's three were added.
- **`Rooms.send_shift_room_message/3` and `Rosters.add_to_roster/3` now stamp a deadline.** Both
  already resolve the `ShiftRoom` before writing, so `closes_at` is in hand and no new query is
  needed. `rooms_test.exs` and `rosters_test.exs` must still pass unchanged.
- **`roster_entries.delete_after` is `NOT NULL`**, so the migration backfills from `shift_rooms`
  before adding the constraint. `employer_role`'s `INSERT` on that table is table-level, so the new
  column needs no grant change — checked, not assumed.
- **`Workers.ExpireEngagement` gains a side effect.** Its moduledoc's contract is "writes nothing
  **to `engagements`**", which is unchanged; `expire_engagement_test.exs`'s existing assertions must
  still hold, and the new write is to a person-zone table it did not previously touch.
- **`Peers`** gains two exports and one enumerated error atom. No existing behaviour changes;
  `peers_test.exs` and `peers_concurrency_test.exs` must pass unchanged.
- **`.credo.exs`** gains one `:boundary_modules` entry. `clock_authority_test.exs` must still pass.
- **`config/config.exs`** gains a queue and a cron entry. `config/test.exs`'s `testing: :manual`
  means no queue runs and every worker in the suite is driven by `Oban.Testing.perform_job/2`;
  Oban's staging query is bound to real wall-clock time and `Clock` does not reach it.

## Test matrix

`lifecycle_test.exs` and `workers/retention_sweeper_test.exs` are **not sandboxed** and take
`EngagementsFixtures.real_connections/0`, for U5's reason: the fixtures span both repos' connections
and under the sandbox those are two transactions that cannot see each other's rows.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | Erasure with a live engagement ends it in the same transaction | lifecycle_test | unit | **issue scenario 1** |
| 2 | …and leaves an already-closed term's `ends_at` where it was | lifecycle_test | boundary | the conditional on the ending update |
| 3 | …and closes a not-yet-started term at its own `starts_at`, the empty range | lifecycle_test | boundary | `GREATEST(starts_at, now)`, and the person's dates staying reserved |
| 4 | The person row is present, `erased_at` set, `email` nil | lifecycle_test | unit | **issue scenario 2**, KTD15 |
| 5 | Two erased people coexist on the partial unique index | lifecycle_test | unit | **issue scenario 3** |
| 6 | An erased person's tokens are gone and the session no longer authenticates | lifecycle_test | unit | **issue scenario 4** |
| 7 | Erasing a venue's sole grant-holder succeeds | lifecycle_test | unit | **issue scenario 5**, KTD17's exemption |
| 8 | …and the venue is then listed as orphaned | lifecycle_test | unit | criterion 4 — a state with no name |
| 9 | …and a venue whose manager is untouched is not listed (control) | lifecycle_test | boundary | an orphan list that returns everything |
| 10 | …and a venue whose only grant was revoked is not orphaned | lifecycle_test | boundary | `live_at/2` reuse — "live" meaning two things |
| 11 | Messages authored by the erased person are still readable, under the reduced label | lifecycle_test | unit | **issue scenario 6**, KTD15b |
| 12 | …and no `room_messages` row was written at all | lifecycle_test | boundary | KTD15b's "proportional to engagements" claim |
| 13 | Erasing a peer conversation leaves the survivor their own messages | lifecycle_test | unit | **issue scenario 7** |
| 14 | …and deletes the erased party's, from both sides' reads | lifecycle_test | unit | **issue scenario 7**, the deletion half |
| 15 | …and the connection is disconnected with the counterpart blocked | lifecycle_test | unit | hazard 1 — a scopeless disconnect |
| 16 | …and `connection_requests` rows survive | lifecycle_test | boundary | hazard 2 — the condition that makes the `MatchError` reachable |
| 17 | `Peers.disconnect/2` answers `{:error, :request_gone}` rather than crashing when the request is gone | peers_test | boundary | hazard 2 — a crash where a refusal belongs |
| 18 | Erasure deletes that person's scheduled expiry jobs | lifecycle_test | unit | **issue scenario 8** |
| 19 | …and leaves another person's alone | lifecycle_test | boundary | a `delete_all` with no filter |
| 20 | Erasure deletes the person's declared entries | lifecycle_test | unit | U9 obstacle 2 |
| 21 | …and leaves their disclosure ledger, as subject and as audience | lifecycle_test | boundary | U9 obstacle 1 — erasure widening disclosure |
| 22 | Erasing twice is `{:error, :already_erased}` | lifecycle_test | unit | idempotence, and a second pseudonymisation |
| 23 | A person with nothing at all erases cleanly | lifecycle_test | boundary | an empty step failing the multi |
| 24 | Own-message copies are deleted on their stamped deadline | retention_sweeper_test | unit | **issue scenario 9** |
| 25 | …and a backdated engagement end after the stamp does not move it | retention_sweeper_test | unit | **issue scenario 9**, the whole stamped-column decision |
| 26 | Shift messages and roster entries are deleted on the shift's clock | retention_sweeper_test | unit | **issue scenario 10** |
| 27 | …and a shift room's term moved after the stamp does not move it | retention_sweeper_test | unit | the same decision, second trigger |
| 28 | …and the worker's own copy of a deleted shift message survives to 90 days | retention_sweeper_test | unit | KTD16's reason for separate rows, made observable |
| 29 | Venue-room history survives every sweep while the venue is open | retention_sweeper_test | unit | **issue scenario 11** |
| 30 | …and is deleted thirty days after closure | retention_sweeper_test | unit | **issue scenario 11**, the other half |
| 31 | Closing a venue stamps only the null deadlines | retention_sweeper_test | boundary | a shift message's deadline being overwritten |
| 32 | Closing twice is `{:error, :already_closed}` | lifecycle_test | unit | idempotence |
| 33 | A deadline exactly equal to the instant survives | retention_sweeper_test | boundary | **issue scenario 12**, half-open |
| 34 | …and one microsecond earlier does not (control) | retention_sweeper_test | boundary | a sweep that deleted nothing at all |
| 35 | A run above the ceiling rolls back **every** trigger | retention_sweeper_test | unit | **issue scenario 13** |
| 36 | …and still writes a record saying so, with the counts it would have deleted | retention_sweeper_test | unit | **issue scenario 13** + 14, the trace |
| 37 | A run at exactly the ceiling commits | retention_sweeper_test | boundary | an off-by-one in the guard |
| 38 | Each run writes a record with the instant used and the four counts | retention_sweeper_test | unit | **issue scenario 14** |
| 39 | A sweep with nothing due writes a record of zeroes | retention_sweeper_test | boundary | "no rows, no record" |
| 40 | The batch bound caps a single trigger and the next run finishes the job | retention_sweeper_test | unit | "bounded batches" |
| 41 | The worker takes its instant from `Clock` and moving the offset moves the sweep | retention_sweeper_test | unit | KTD5 at a new unit-of-work boundary |
| 42 | The copy is written when the expiry is announced, once per message | retention_sweeper_test | unit | the archive existing at all |
| 43 | …and running the announcement twice writes no second copy | retention_sweeper_test | boundary | the idempotence key |
| 44 | …and writes nothing for an erased person, however often it runs | lifecycle_test | unit | **issue: "suppresses retained-copy creation"** |
| 45 | Erasure deletes retained copies that already existed | lifecycle_test | unit | the suppression being total rather than prospective |
| 46 | No module outside `Lifecycle` calls a delete, except `Accounts` | lifecycle_test | boundary | **issue scenario 15**, KTD21 |
| 47 | …and the sweep reads a chunk that says something (control) | lifecycle_test | boundary | a structural check nobody has watched fail |
| 48 | …and `Accounts`'s deletes reach `people_tokens` and no other table | lifecycle_test | boundary | the exemption being unbounded |
| 49 | An open channel cannot send across an erasure | revocation_test | unit | hazard 3, decided rather than inherited |
| 50 | The two new tables are classified and `employer_role` holds nothing on either | boundary_test | boundary | criterion 11 |
| 51 | …with a column-grant control on `retained_message_copies` | boundary_test | boundary | an audit that cannot answer true |
| 52 | The retention migration's revoked list, unioned with the rest, equals the person zone | boundary_test | boundary | a person-zone table nobody revoked on |
| 53 | `engagements` is *still* the only table outside the person zone referencing `people` | boundary_test | boundary | criterion 11, the crossing |
| 54 | `retained_message_copies` has a MATCH FULL composite key and no key into `room_messages` | boundary_test | boundary | the decision above, as a fact about `pg_constraint` |
| 55 | Both new migrations roll down and back up intact | boundary_test | unit | a `down` nobody ran |
| 56 | The roles migration still rolls back once every grant migration is unwound | postgres_roles_test | boundary | the unwind list growing with the unit |

Controls, so no assertion can pass for the wrong reason:

- 9 is the control for 8, and 10 is the control for both: an orphan list that returned every venue,
  or one that counted a revoked grant, satisfies 8 alone.
- 2 and 3 are the controls for 1: an ending update with no condition satisfies 1.
- 19 is the control for 18: `delete_all` on the whole table satisfies 18.
- 21 is the control for 20: deleting everything the person touches satisfies 20.
- 34 is the control for 33: a sweeper that deleted nothing satisfies 33.
- 37 is the control for 35: a guard that always rolled back satisfies 35.
- 39 is the control for 38.
- 43 is the control for 42; 45 is what makes 44 total rather than prospective.
- 29 is the control for 30; 31 is what makes 29 about *nullness* rather than about the window.
- 47 is the control for 46; 48 is what bounds the exemption 46 grants.
- 51 is the control for 50.
- 12 is the control for 11: an erasure that rewrote message bodies satisfies 11.
- 28 is the control that makes 26 about the shift's clock rather than about deletion in general.

## Implementation constraints

- `@spec` on every public function; error atoms enumerated, never `{:error, term()}` or `any()`.
  `Ecto.UUID.t()` for entity ids.
- New schemas stamp `inserted_at`/`updated_at` explicitly. Ecto's `timestamps()` autogenerate reads
  the wall clock from inside Ecto, out of the Credo check's reach.
- Migrations only through `mix ecto.gen.migration`, every `up` reversed by a `down`. Two of them:
  `*_add_retention_columns.exs` and `*_grant_retention_zone.exs`, in that order, so the grant
  migration is the only one touching privileges and therefore the only new entry in
  `PostgresRolesTest`'s unwind list.
- Erasure is one `Ecto.Multi` with named steps and the failing step in the error tuple.
- Every query lives in `HospitalityComs.Lifecycle.Records`, asserted structurally the way
  `profiles_test.exs` asserts it for `Profiles`.
- `Lifecycle` reaches `HospitalityComs.Repo` only. It holds no employer scope and never touches
  `EmployerRepo`: it is the application acting for itself, which is precisely what no employer
  session may do.
- The sweeper is the only new `Clock.now/0` caller and is added to `.credo.exs`'s
  `:boundary_modules`. `ago/2` and `from_now/2` stay banned.
- The ceiling and the batch size are read from application config so a test can lower them, with
  documented defaults. **The default ceiling is deliberately above what four full batches can
  reach** — it is a guard against a batch bound that is missing or wrong, not a throttle, and a
  ceiling a correct run could hit would deadlock the sweep for ever.
- `mix format`, `mix compile --warnings-as-errors`, `mix quality`, and a `MIX_ENV=prod` compile all
  pass. Never migrate `hospitality_coms_dev`.
- Every behavioural test is proved load-bearing by mutation: delete the code it covers, watch that
  specific test fail, restore. Reported per test.

## Quality scores (self-assessed)

- Coverage of stated scenarios: all 15 from the issue, plus the issue's stated verification, plus
  41 more.
- Assertion strength: the two stamped-deadline tests move the period after the stamp rather than
  asserting the column exists; the ceiling tests assert every trigger rolled back rather than one;
  the structural sweep enumerates its single exemption and bounds it behaviourally.
- Control coverage: 14 controls for the 14 assertions that could pass vacuously.
- Isolation: two new non-sandboxed files on the existing prefix purge, extended by two deletes.
- Regression: two tables, three columns, two migrations, two additive `Peers` exports, one new
  worker; no existing assertion weakened.

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from explicitly.

1. **Two guards made each other unreachable, and mutation testing is what found it.**
   `ExpireEngagement` dispatched the archive write on `:revoked` *and*
   `retain_own_messages/2` refused an engagement whose term had not closed. Deleting either
   one killed **no** test, because the other covered it — the sixth "reads as coverage,
   provides none" this project has produced, and the first found by mutation rather than by
   review. The dispatch is gone; the function decides, which is also the rule U11's demo
   control needs when it drives the worker directly. Both directions are now measured
   (mutations 25 and 26 below).

2. **An erased person has no email, so `EngagementsFixtures.purge/0` could not see them.**
   Not anticipated, and it would have been invisible: every prefix-based lookup in that file —
   the people delete, `purge_peer_graph/0`'s id list, `purge_profiles/1`'s — silently skipped
   the rows a lifecycle test made, and `confirm_purged/0` counts by the same prefix so it would
   have reported success. `prefixed_people/0` now matches the address **or** `erased_at`, which
   is the two states U2's check constraints hold in opposition; nothing else in the tree erases
   anybody, so it is not a widening.

3. **The half-open boundary is asserted a second apart, not a microsecond.** The brief said "one
   microsecond earlier". `delete_after` is `timestamp(0)` and Ecto truncates a `:utc_datetime`
   parameter, so a sub-second instant is indistinguishable from the deadline itself before it
   ever reaches Postgres — the test would have passed for the wrong reason. Rows 33 and 34 are
   `delete_after` exactly and `delete_after + 1 second`.

4. **`retention_runs` is deleted whole by the purge**, because it carries no venue, no person and
   no prefix, so there is no column a fixture could scope a delete to. Recorded here rather than
   left as an accumulation nobody notices: nothing outside the retention tests writes one.

5. **`add_retention_columns` is the outermost layer of `boundary_test.exs`'s rollback nest**, and
   two independent dependencies force it rather than one. The composite key needs
   `create_profiles`'s `(id, person_id)` index, and `roster_entries.delete_after` is `NOT NULL` —
   so rolling U6's tables underneath it would silently drop the column and leave every later
   assertion in the same body running against a schema `RosterEntry` no longer matches. The
   existing profile round-trip test had to be wrapped in it and says why.

6. **Two raw `INSERT INTO roster_entries` in the room tests had to learn the new column.**
   `rooms_test.exs`'s overlap matrix and `rooms_concurrency_test.exs`'s barrier write bypass the
   changeset on purpose, so a `NOT NULL` column with no default reaches them. Both now stamp what
   `join_changeset/3` would have.

7. **`Peers.disconnect_all/3` and `announce_disconnection/1` are two exports rather than one.**
   The brief anticipated the first; the second is what keeps the announcement after the commit
   without `Lifecycle` reimplementing the payload, and it is the split `Engagements` already has.

8. **The `:request_gone` test defeats a database constraint on purpose, and restores it
   idempotently.** There is no other way to reach the branch — that is the whole reason it was a
   `MatchError` waiting to happen — so `peers_test.exs` drops
   `peer_connections_request_id_fkey` for one call and puts it back through a `DO` block that
   also clears whatever made it unsatisfiable. The file is not sandboxed, so a restore that only
   ran on success would follow an aborted run into every other non-sandboxed file.

9. **Rows do not map one-to-one onto test bodies**, as U8 and U9 both recorded. The 56-row matrix
   produced **28** bodies in `lifecycle_test.exs`, **17** in `retention_sweeper_test.exs`, 6 in
   `boundary_test.exs`, 2 in `revocation_test.exs` and 1 in `peers_test.exs` — 54 against 56 rows,
   with rows 50–51 and 53–54 collapsing where the assertions are about one object, and bodies
   with no row including "is `:not_found` for an id that names nothing" and the archive's
   still-open control.

10. **Every behavioural claim was checked by breaking the code.** 33 mutations, each restored,
    reported per test in the final summary. One of them found revision 1.

## Revisions made after review

Three independent reviewers ran against the branch at 54765b8 and produced a fix brief; twenty-four
mutations were re-measured and six of them killed nothing. What follows is what changed and why,
recorded in the same spirit as the list above.

11. **The archive was written at the wrong event and lost data — KTD16's named failure, by the
    trigger rather than by the schema.** `ExpireEngagement` wrote the copy when the *engagement*
    closed, and a shift message's source row dies at `closes_at + 30 days`; every ordinary term
    outlives its shifts by months, so the venue's copy was swept before the announcement fired and
    the worker's copy was never created. Measured: 365-day term, shift on day one, sweep on day
    forty — one copy written, body `["in the venue"]`.

    Two directions were open. **Archiving at message insert was taken**, over "archive at shift
    close with a provisional deadline re-stamped at term end", for three reasons. It cannot be late,
    because there is no earlier instant than the one the source row is created at. It needs no new
    scheduled trigger, where the other direction needs one per shift room *and* a second at venue
    closure, because a venue-room message's source dies on the venue's clock and has exactly the
    same failure. And both rows go through `Repo`, so the copy is written in the same transaction as
    the message — which is closer to KTD16's "inside the engagement-end transaction" than the
    announcement ever was.

    The provisional-deadline problem the brief anticipated is **removed rather than managed**:
    `retained_message_copies.delete_after` is now nullable and null while the term is open, exactly
    as `room_messages.delete_after` is null while its venue trades. `ends_at` can move while a term
    is open and cannot once it has closed — `renew_engagement/3` answers on activeness,
    `end_engagement/2` on "has not closed" — so the deadline is stamped once, by
    `retain_own_messages/2`, from a value that can never be revised. No `GREATEST`, no re-stamp, no
    monotonicity argument. `retain_own_messages/2` keeps its place as the *backstop*: it stamps, and
    it copies anything with no copy yet.

12. **A closed venue kept trading and its new messages were undeletable.** `close_venue/2` stamps
    the rows that exist when it runs and then refuses to run again, and `delete_after < instant`
    never matches a null. `Rooms.send_venue_room_message/3` now refuses `:room_closed` — the atom
    already in `Rooms.refusal()` — and resolves the venue under `FOR SHARE` inside the transaction
    that writes the message, which also orders the pure-race form against the closure's own
    `FOR NO KEY UPDATE`. `VenueRoomChannel` answers it with the same sentence `:not_a_member` gets,
    for AE1's reason. Reads are untouched.

    **The shift-room send is deliberately not gated**: a shift message's deadline is stamped at
    insert, so there are no undeletable rows to prevent, and the room shuts by itself at
    `ends_at + grace`.

13. **Four tests certified nothing and were replaced or extended rather than reworded.** The 90-day
    window was pinned by nothing (30 and 2 both killed zero); the KTD21 carve-out bound was vacuous
    over fourteen empty tables; nothing asserted `attested_entries` survive erasure; and the erasure
    tests asserted what is nulled and never what survives on the person row. Each fix is a new or
    widened assertion with its own mutation, listed in the summary.

14. **The KTD21 sweep gained a second reader, over source rather than over the `imports` chunk.**
    The chunk cannot see `repo.delete_all/1` inside a `Multi.run`, which is the idiom `Lifecycle`
    itself uses five times. Making `Lifecycle` use `Multi.delete_all/4` instead — the brief's other
    option — would have removed the bad example without closing the hole, so the reader was built.

15. **"A person-zone key into the employer zone would be a second crossing" is wrong**, and the
    section above (`## source_message_id is deliberately not a foreign key`, first bullet) is one of
    the four places it was stated — the others being `add_retention_columns.exs`,
    `retained_message_copy.ex`, `zones.ex` and `CLAUDE.md`. KTD2's single crossing is about naming a
    **person**; arrows point into the employer zone freely, and
    `attested_entry_disclosures.audience_venue_id` is already exactly such a key, argued for at
    length by `create_profiles.exs`. The *decision* stands on the two `ON DELETE` reasons, each
    independently sufficient. The first bullet is struck rather than the body rewritten, so that a
    later unit cannot cite it to refuse a legitimate key.

16. **`{:error, :request_gone}` is already tested** (`peers_test.exs:863`, revision 8 above), so
    that residual is declined rather than acted on. `retention_runs_counts_not_negative` gained its
    `check_constraint/3` declaration and a test; the other two constraints are unreachable from
    Elixir, because `outcome` and `ceiling` are guarded in `changeset/4`'s own head.

17. **No `expire_engagement_test.exs` was created.** Both of that worker's jobs are driven through
    `Oban.Testing.perform_job/2` in `retention_sweeper_test.exs` — the announcement by "are dated by
    the expiry announcement, once, and stay so", the refusal by "carry no deletion clock at all
    while the term is still open" — and by `lifecycle_test.exs`'s erased-person suppression. A third
    file naming the module would hold the same three assertions in a different place.

18. **One guard is deliberately unobservable and is not claimed to be otherwise.**
    `stamp_undated_copies/3`'s `is_nil(delete_after)` cannot be reached twice with two different
    values, because a closed term's `ends_at` cannot move — so removing it kills no test. It stays
    as the property that makes the stamp idempotent by construction rather than by argument.

## Revisions made after the second review

A fourth reviewer read the branch at 5f25bd0 and raised two findings. Both were acted on; one of
the two was acted on in the opposite direction to the one suggested, and says why.

19. **A `RETURNING` clause was declared by a function that did not know it was declaring one.**
    `Records.open_venue/1` carried `select: venue`, `close_venue/2` composed an `update:` on top of
    it, and `Lifecycle.closed_or_diagnose/3` — in another file — matched `{1, [%Venue{}]}` on the
    result. So a two-line predicate carried an obligation to a caller it had never heard of, and
    the obvious edit to it (reuse it as a subquery, drop the select) broke a pattern match a file
    away. Measured on the old arrangement: dropping it killed **five** tests in `lifecycle_test.exs`,
    every one of them with a `FunctionClauseError` on `{1, nil}` that named neither the select nor
    the query — so the finding's "silent clause mismatch" is wrong about the silence and right about
    everything else.

    Three options were open — state the dependency in both docstrings, assert it structurally, or
    remove it — and the third was taken because a warning is not a failure. `open_venue/1` is now a
    predicate with no select and `close_venue/2` declares its own, so the function whose result
    depends on the clause is the function that asks for it. That also buys a failure in the *other*
    direction for free: Ecto refuses two selects in one query, so re-adding one to `open_venue/1`
    raises `Ecto.Query.CompileError` on the next composition rather than shadowing the move.
    Verified by putting one back.

    The new test asserts the pair — `close_venue/2` carries a select, `open_venue/1` carries none —
    before it asserts the behaviour, because the structural failure names what is missing where a
    `FunctionClauseError` out of `Ecto.Multi` does not. Both halves are load-bearing: dropping the
    select from `close_venue/2` kills the first assertion, moving it back to `open_venue/1` kills
    the second, and the second is what stops the first passing on an inherited select.

20. **`cancel_jobs/2` deletes in every job state, and the reviewer's suggested filter would have
    made things worse rather than better.** The finding is that an `:executing` job has its row
    deleted underneath it. That was checked rather than assumed, three ways.

    *What the row costs.* On the pinned Oban (2.23) `Oban.Engines.Basic.complete_job/2` is an
    `update_all` whose affected count it discards, returning `:ok` unconditionally, and
    `Oban.Queue.Executor.ack_event/1` discards that answer in turn. Driven directly at a deleted
    row it answers `:ok` and logs nothing with the test environment's logger at `:warning` — so the
    finding's "log a warning or silently no-op depending on the version" resolves to *silent* here.
    No orphan either: the producer's running set is in memory and no `Lifeline` plugin is
    configured.

    *What the job could still write.* Not the retained copy, and not because of `erased_at` being
    set first — because of the lock pair. `retain_own_messages/2` resolves the person under
    `FOR SHARE` and `erase_person/1` holds `FOR UPDATE` on the same row for its whole transaction,
    so the archive write either commits before the erasure begins, and is deleted by it, or parks
    and finds the person erased. Both directions already have tests (revision 11's parking test and
    the erased-person suppression test); the state of a queue row decides none of it.

    *What a filter would cost.* Excluding `:executing` leaves a row that reaches `:completed` and
    then **suppresses** the sweeper's replacement under `ExpireEngagement`'s `period: :infinity`
    uniqueness — the reverse of what "leave the row behind" sounds like — while keeping only the
    incomplete states leaves an erased person's completed announcements in `oban_jobs` for the
    pruner's seven days. Either way it puts a second enumeration of Oban's states in the tree, in a
    module about retention, answering a different question from the one `ExpireEngagement`'s
    `:unique` states answer.

    So the query is unchanged and the decision is written into `jobs_for_engagements/1`'s docstring
    and pinned by a test that erases across `executing`, `completed` and `discarded`. It is not
    padding: `where: job.state != "executing"` kills it on the first state and Oban's `:incomplete`
    shorthand kills it on the second, so a future filter fails rather than passes quietly.
