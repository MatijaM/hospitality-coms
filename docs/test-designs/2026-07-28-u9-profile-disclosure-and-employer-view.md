# Test Design Brief — U9, Profile, disclosure, and the employer-visible view

Issue: #9. Plan: `docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md`, unit U9.
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written before any production
code; the orchestrator stands in for the human approver (issue #21 tracks the missing
skill). Convention established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md`
through `-u8-peer-graph.md`, including the "record revisions rather than applying them
silently" section at the end.

## What is being built

The worker's portable record and the rules about who may read it: attested entries the
employer wrote and the worker cannot edit, declared entries the worker wrote and can,
per-employer and per-peer disclosure over the attested ones, correction requests, and
**the view the employer role reads through** — which is KTD3 and the spine of the unit.

**The view is the tier, and on this deployment it is the only tier that could be.** U7's
review measured that `HospitalityComs.Repo` connects as `postgres`, for which
`pg_authid.usesuper` is true. A superuser bypasses row-level security whether or not a
policy is `FORCE`d, so an RLS-based hidden-entry rule would read as a tier in the migration
and provide none in the database. KTD3's argument was "a view has no equivalent of `FORCE`
to forget"; the measurement makes it stronger than that. The base table stays ungranted, the
view is owned by the role that owns the base table, and `employer_role` holds `SELECT` on the
view and nothing anywhere else.

## Acceptance criteria

1. **Attested entries are still written only by the claim.** U5 built the schema at the path
   the plan assigns U9; this unit extends it and adds no second write path. A person cannot
   edit one, and the only thing they can do about a wrong one is ask for a correction.
2. **The employer reads through a view and never the base table.** `employer_role` holds no
   privilege on `attested_entries` — asserted since U5 — and holds `SELECT` and only `SELECT`
   on `employer_visible_attested_entries`. The view is owned by the base table's owner, is not
   `security_invoker`, and is `security_barrier`.
3. **The concurrency default is computed inside the view from period overlap**, not
   materialised. An attested entry for venue A is hidden from venue B when the engagement it
   attests overlaps **any** engagement the same person holds at venue B. Overlap is a
   comparison of two stored periods and involves no instant, which is what makes "a hidden
   entry remains hidden after it stops being concurrent" true without anything being stored
   and "changing an engagement's dates corrects the default" true without anything running.
4. **The worker's disclosure overrides the default, per audience.** One row per
   (entry, audience) with a boolean; the audience is a venue or a person, never both and
   never neither. The employer default is computed; the peer default is disclosed.
5. **The per-employer and per-peer settings are independent.** They are different rows with
   different audience columns and different readers — the view for one, `Repo` for the other.
6. **Correction requests are visible to any viewer of the entry they are about**, which
   means a second view with the same disclosure rule rather than a second rule. Resolving one
   is the attesting venue's alone, and declining leaves both the entry and the request
   readable.
7. **The standing incompleteness notice is a UI constant and cannot become an oracle.**
   `Profiles.incompleteness_notice/0` takes no arguments, so it cannot depend on the worker
   it is shown next to; the view's column list is pinned so a "hidden count" cannot be added
   without a test failing; and two workers, one concealing and one not, produce reads that
   are indistinguishable in shape.
8. **Every new relation is classified.** Two person-zone tables, one employer-zone table, and
   — this is new — two **views**, which `Zones.tables/1` would happily name but which neither
   totality check currently reaches: `ZonesTest` quantifies over Ecto schemas and
   `boundary_test.exs`'s `database_tables/0` filters `relkind IN ('r','p','m')` with a comment
   that says U9 adds a view. So U9 adds a view classification and a totality check over
   `pg_class` relkind `'v'`, with a control.
9. **No second crossing.** `boundary_test.exs`'s positive form — `engagements` is the *only*
   table outside the person zone with a foreign key to `people` — must still return exactly
   `["engagements"]`. `attested_entry_disclosures` holds one to `people` and is person zone;
   `correction_requests` holds none and is employer zone, keyed on `engagements (id, venue_id)`
   like every employer-zone row that needs to name a working relationship (KTD2).
10. **KTD5 — the instant arrives on the scope.** No new `Clock.now/0` caller,
    `.credo.exs` unchanged. The view reads `app_current_instant()`, which
    `EmployerRepo.scoped_transaction/2` writes from the scope.
11. **No `{:error, term()}`.** Every refusal is an enumerated atom or a changeset, and every
    refusal about an id the caller supplied enumerates nothing.

## The disclosure model, stated precisely

Three questions, answered separately, because conflating them is how this goes wrong.

**Who may an employer session see at all?** The people holding an engagement at
`app_current_employer_id()` that is active at `app_current_instant()`. That half is
time-derived: an ex-worker drops out of the employer's reach with no job having run, which is
the same property U5 gives membership. The employer names the worker by **the viewer's own
engagement id**, which is venue-local by construction — the view exposes no `person_id`, which
is U9 acting on the third entry in CLAUDE.md's disclosure ledger.

**Which of that person's entries does the employer see?** Its own venue's, always. Every other
venue's, subject to:

| Override row for (entry, this venue) | Shown |
|---|---|
| `disclosed = true` | yes |
| `disclosed = false` | no |
| none | the computed default |

and the computed default is `NOT EXISTS` an engagement of the same person at the viewing venue
whose period overlaps the entry's. Overlap is `a.starts_at < b.ends_at AND b.starts_at < a.ends_at`
plus the two non-emptiness clauses U6 measured and U8 needed — `end_engagement/2` can produce
`ends_at == starts_at`, and the endpoint form without them reports an overlap for the empty range.

**What does a peer see?** Attested entries whose peer-audience row is absent or `disclosed = true`,
and every declared entry. Gated on the pair being visible to each other *or* connected —
connected as well as visible, because a connection outlives the visibility that produced it
(U8's R13) and a profile that vanished when the co-rostering lapsed would contradict it.

## Two things that are deliberately not stored, and one that is

**Not stored: whether an entry is concurrent.** It is two range comparisons in the view. A
materialised `concurrent` flag would be stale the first time a manager corrected a date, and
the plan says so in the unit's approach.

**Not stored: whether a worker is concealing anything.** No count, no flag, no column. The
notice is a constant. Computing it would make every employer read carry the answer to "is this
person hiding something", which is a strictly worse disclosure than the entries themselves.

**Stored: the worker's overrides.** They are decisions rather than derivations — nothing
computes "this worker chose to reveal their second job" — so they are rows, one per
(entry, audience), and revoking one is a write the very next read reflects.

## Why the audience venue is a column in the person zone, and why that is not a regression

`attested_entry_disclosures` is person zone, as the plan's own zone diagram has it, and it
carries `audience_venue_id` — the first employer key on a person-zone table in this tree.
The alternatives were considered and are worse:

- Naming the audience through one of the person's engagements at that venue keeps the person
  zone employer-key-free and re-discloses a hidden entry the moment the worker takes a *new*
  engagement at the same venue, unless the view resolves the venue off the engagement anyway —
  at which point the venue is reachable in one join and the property is identical, with the
  uniqueness guarantee lost.
- Putting the ledger in the employer zone hands every venue the answer to "who is concealing
  something from me", which is the oracle criterion 7 exists to prevent.

The reason a venue key here does not weaken the Problem Frame's inversion is the same reason
the table is person zone: an employer-scoped query over it *would* mean something, which is
precisely why `employer_role` holds nothing on it, `EmployerRepo`'s backstop refuses it, and
the only path to the disclosure rule is a view that returns the *result* of applying it and
never the ledger. This is recorded as a decision, with tests, rather than left to be noticed.

## Edge cases

- An entry at the viewing venue is always visible to it, including a past stint that a
  disclosure row says `false` about. The venue wrote the assertion; hiding it from them would
  hide their own record from them. The override applies to *other* venues.
- Overlap is inclusive-of-neither-endpoint on the same half-open convention: terms
  `[a, b)` and `[b, c)` are adjacent and **not** concurrent, so an entry ending exactly when
  the viewer's engagement begins is visible by default.
- An engagement ended before it started — `ends_at == starts_at` — overlaps nothing, so it
  neither hides anything nor is hidden by anything. Both non-emptiness clauses are needed and
  each must be exercised on its own side.
- A person with two stints at the viewing venue: the entry is hidden if it overlapped
  **either**, which is what `NOT EXISTS` over all of them gives and what a join to "the
  viewer's engagement" alone would not.
- The viewer's engagement must be active at the scope's instant. An employer whose worker's
  term ended yesterday sees nothing today, and the test moves the instant rather than a row.
- A disclosure row for a venue the worker has never worked at is writable and inert. It is
  refused only if the engagement is not the caller's.
- A disclosure whose audience is both a venue and a person, or neither, is refused by a CHECK
  written as `(a IS NULL) <> (b IS NULL)` — never as `a IS NULL OR b = c`, which is satisfied
  by NULL and is the shape U8 shipped and had caught.
- Resolving a correction request twice is `:already_resolved`; resolving another venue's, or
  one that does not exist, is `:not_found` and the two are indistinguishable.
- Reading the view outside `EmployerRepo.scoped_transaction/2` raises rather than returning
  an empty set — U3 built `app_current_employer_id()` to raise for exactly this, and the honest
  edge (a scan yielding no rows never calls the function) is already pinned in `boundary_test.exs`.
- A declared entry with `ends_at <= starts_at`, a blank label, or an over-long one is a
  changeset error, with the bound in the database as well.
- Updating somebody else's declared entry is `:not_found`.

## Regression risks

- **`boundary_test.exs`.** Three new tables and two new views. The employer-zone privilege
  inventory grows by `correction_requests`; the person-zone revoked-tables union grows by one
  migration's list; the composite-foreign-key inventory grows by two keys; every employer-zone
  table must carry a row-level security policy, so `correction_requests` needs one. The
  positive crossing test must still answer `["engagements"]`. **No existing assertion may be
  weakened**, and the "the shape the employer-visible view is built on" block — written by U3
  *for* this unit — must keep passing unchanged.
- **`postgres_roles_test.exs`.** One new grant migration, one new entry in the unwind list.
  Unlike `grant_peer_zone`, this one really grants — on a table and on two views — so
  `dependent_objects/0` grows and `dependent_zone_tables/0` has to learn that
  `pg_describe_object` says `view x` and not `table x`.
- **`people_auth_tables_test.exs`.** `declared_entries.person_id` and
  `attested_entry_disclosures.audience_person_id` are `ON DELETE RESTRICT` foreign keys to
  `people`, and the views depend on `engagements` and `attested_entries`, so `DROP TABLE people`
  now fails four migrations earlier than it did. The `@dependents` chain grows by four.
- **`EngagementsFixtures.purge/0`.** Three more deletes, ahead of `engagements` and ahead of
  `people`, for the reason U6's four and U8's three were added. Without them the first
  committing profile test makes every later non-sandboxed test fail on a foreign key.
- **`Zones`.** Three schemas and — new in kind — two view names. `ZonesTest`'s totality check
  fails until the schemas are placed; nothing fails until the views are placed, which is why
  U9 adds the check that does.
- **`grant_zones`'s `RESTRICT`.** The views depend on `app_current_employer_id()`, so every
  rollback path in `boundary_test.exs` that reaches that function has to roll U9's migrations
  off first. This is the same growth U4 forced on U3 and U5 on U4, one unit further along; the
  existing "cannot be rolled back under a live row-level security policy" test must still fail
  loudly for the *same* reason and not for a new one.
- **`Peers`.** One additive public predicate, `connected?/2`, so that a peer profile read can
  be gated on a live connection as well as on visibility. No existing `Peers` behaviour
  changes, and `peers_test.exs` gains a test for it rather than having one adjusted.
- **`Engagements.list_person_attested_entries/1`** already exists and stays. `Profiles` does
  not replace it; it renders the profile around it.
- **Every privilege probe re-run**: the person-zone set, `room_messages`,
  `venue_room_suspensions`, the three peer tables, plus `attested_entries` itself and the two
  new person-zone tables.

## Test matrix

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | Claiming an invitation produces one attested entry carrying the engagement's role label | profiles_test | unit | **issue scenario 1** |
| 2 | …and a renewal produces no second one | profiles_test | unit | **issue scenario 1**, the unique index (U5's, re-asserted from this side) |
| 3 | `Profiles` exposes no function that writes an attested entry | profiles_test | boundary | **issue scenario 2** |
| 4 | A correction request leaves the attested entry byte-identical | profiles_test | unit | **issue scenario 2** as behaviour rather than as an absent function |
| 5 | `employer_role` holds no privilege on `attested_entries` | boundary_test | boundary | **issue scenario 7**, the grant tier |
| 6 | …and the sweep catches `GRANT SELECT (attested_at)` on it (control) | boundary_test | boundary | an audit that cannot answer true |
| 7 | A raw `EmployerRepo.query!` on `attested_entries` is refused by Postgres | profiles_test | boundary | **issue scenario 7**, the tier below the backstop |
| 8 | `employer_role` holds `SELECT` and only `SELECT` on each employer view | boundary_test | boundary | criterion 2 |
| 9 | Both views are owned by the role that owns `attested_entries` | boundary_test | boundary | KTD3's mechanism — an unprivileged owner reads nothing |
| 10 | Neither view is `security_invoker`, and both are `security_barrier` | boundary_test | boundary | KTD3 inverted, and the leaky-view class |
| 11 | Every view in `public` is classified in `Zones.employer_views/0` | boundary_test | boundary | criterion 8 |
| 12 | …and an unclassified view is what that check reports (control) | boundary_test | boundary | a totality check nobody has watched fail |
| 13 | The view's column list is exactly what it is, and names no person | boundary_test | boundary | criterion 7's oracle, and the ledger's `person_id` note |
| 14 | The employer sees its own venue's entry for its own worker | profiles_test | unit | the whole read path (control for every negative below) |
| 15 | A concurrent engagement at another venue is absent from the view | profiles_test | unit | **issue scenario 3** |
| 16 | A non-concurrent past engagement at another venue is present by default | profiles_test | unit | **issue scenario 4** |
| 17 | An entry hidden by the concurrency default stays hidden once the terms stop overlapping | profiles_test | unit | **issue scenario 5** — the default being about periods, not about now |
| 18 | Adjacent terms sharing one instant are not concurrent, so the entry is visible | profiles_test | boundary | the half-open reading of overlap |
| 19 | An empty term (ended before it started) creates no concurrency, from either side | profiles_test | boundary | the two non-emptiness clauses, one test per side |
| 20 | An entry overlapping the *earlier* of two stints at the viewing venue is hidden | profiles_test | unit | `NOT EXISTS` over every stint rather than a join to one |
| 21 | Moving the entry's engagement out of overlap makes it visible with nothing having run | profiles_test | unit | "changing an engagement's dates corrects the default automatically" |
| 22 | The worker can disclose a concurrent entry, and the employer then sees it | profiles_test | unit | the override, positive direction |
| 23 | Revoking that disclosure removes it from the view on the next read | profiles_test | unit | **issue scenario 6** |
| 24 | The worker can hide a non-concurrent entry the default would have shown | profiles_test | unit | the override, negative direction |
| 25 | An override for venue B changes nothing for venue C | profiles_test | boundary | the audience being per venue |
| 26 | A disclosure naming an engagement that is not the caller's is `:not_found` | profiles_test | boundary | AE1 |
| 27 | A disclosure with two audiences, or none, is refused by the database CHECK | profiles_test | boundary | the NULL-tolerant CHECK class U8 shipped |
| 28 | Setting the same (entry, audience) twice updates one row rather than adding a second | profiles_test | unit | the partial unique indexes |
| 29 | An entry the venue itself attested stays visible to that venue whatever the ledger says | profiles_test | boundary | the own-venue branch |
| 30 | The employer sees nothing once the viewer's engagement has ended | profiles_test | unit | `app_current_instant()` in the view |
| 31 | The view returns only the scoped venue's rows, though its owner bypasses RLS | profiles_test | boundary | criterion 2 — the view's own filter being the tenancy |
| 32 | Selecting from the view outside the wrapper raises rather than returning nothing | profiles_test | boundary | U3's raising scoping function, now with a populated relation behind it |
| 33 | A worker requests a correction on an entry and it is readable by the attesting venue | profiles_test | unit | the correction path |
| 34 | …and by another venue that can see the entry | profiles_test | unit | **issue scenario 8** |
| 35 | …and is absent for a venue that cannot see the entry | profiles_test | boundary | the second view reusing the first rather than restating it |
| 36 | Declining leaves the entry and the request both visible, marked declined | profiles_test | unit | **issue scenario 9** |
| 37 | Accepting marks it accepted and changes no attested entry | profiles_test | unit | "attested entries are never written directly" surviving the correction path |
| 38 | Resolving twice is `:already_resolved` | profiles_test | unit | the conditional update |
| 39 | Resolving another venue's request, or an id that names nothing, is `:not_found` | profiles_test | boundary | AE1 |
| 40 | Requesting a correction on an engagement that is not the caller's is `:not_found` | profiles_test | boundary | AE1 |
| 41 | A peer sees the worker's attested entries by default | profiles_test | unit | the peer read (control for 42–44) |
| 42 | A peer-audience `false` hides one entry from that peer and from no one else | profiles_test | unit | **issue scenario 10** |
| 43 | …and the employer view is unchanged by it | profiles_test | unit | **issue scenario 10**, the independence |
| 44 | An entry hidden from an employer is still visible to a peer | profiles_test | unit | **issue scenario 10**, the other direction |
| 45 | A non-peer — neither visible nor connected — is refused | profiles_test | boundary | the peer gate |
| 46 | A connected peer whose visibility has lapsed still reads the profile | profiles_test | unit | connections outliving visibility (U8's R13) |
| 47 | Declared entries are created, listed and edited by their owner | profiles_test | unit | the declared half of the taxonomy |
| 48 | …and a blank label, a reversed term, or an over-long label is a changeset error | profiles_test | unit | the constraints, in the changeset and in the database |
| 49 | Editing somebody else's declared entry is `:not_found` | profiles_test | boundary | AE1 |
| 50 | Declared entries never appear in the employer view | profiles_test | boundary | the plan's diagram — the view carries employer assertions |
| 51 | `incompleteness_notice/0` is arity 0 and `Profiles` exports no other arity for it | profiles_test | boundary | **the oracle**, structurally |
| 52 | Two workers, one concealing and one not, produce employer reads of identical shape | profiles_test | boundary | **the oracle**, behaviourally |
| 53 | A manager's employer session and the same human's person session return different entry sets for the same worker | profiles_test | unit | **the issue's stated verification** |
| 54 | Queries live in `Profiles.Records` and nowhere in the `Profiles` namespace | profiles_test | boundary | the rule U8 made structural |
| 55 | The three new tables are classified, and the sweep finds nothing on the two person-zone ones | boundary_test | boundary | criterion 8 |
| 56 | …with a column-grant control on `attested_entry_disclosures` | boundary_test | boundary | an audit that cannot answer true |
| 57 | `engagements` is *still* the only table outside the person zone referencing `people` | boundary_test | boundary | criterion 9 |
| 58 | The profile migration's revoked list, unioned with U3/U6/U8's, equals the person zone | boundary_test | boundary | a person-zone table nobody revoked on |
| 59 | The employer-zone privilege inventory is exactly what U9's code exercises | boundary_test | boundary | a privilege nobody chose |
| 60 | `correction_requests` carries `venue_id`, a unique `(id, venue_id)`, and an RLS policy | boundary_test | boundary | the employer zone's structural rules |
| 61 | Its two composite foreign keys are MATCH FULL and MATCH SIMPLE per the nullability rule | boundary_test | boundary | KTD2's composite-key discipline |
| 62 | `create_profiles` and `create_employer_visible_view` roll down and back up intact | boundary_test | unit | a `down` nobody ran |
| 63 | `grant_zones` still cannot be rolled back under the views, and says so | boundary_test | boundary | the `RESTRICT` U3 chose, now with a second kind of dependent |
| 64 | `people` cannot be dropped under the new dependents, and comes back with them | people_auth_tables_test | unit | the chain |
| 65 | The roles migration still rolls back once every grant migration is unwound | postgres_roles_test | boundary | the unwind list growing with the unit |
| 66 | `Peers.connected?/2` answers true for a live connection and false after a disconnect | peers_test | unit | the peer gate's other half |

Controls, so no assertion can pass for the wrong reason:

- 14 is the control for 15, 17, 19, 25, 29, 30, 35 and 50 — a view that returned nothing
  satisfies every one of them alone.
- 16 is the control for 15: a default that hid everything satisfies "a concurrent engagement is
  absent".
- 18 and 19 are the boundary controls on the overlap predicate's two ends.
- 6, 12 and 56 are controls for 5, 11 and 55: each grants or creates behind the check's back.
- 22 is the control for 23 and 24 — an override path that did nothing satisfies both.
- 41 is the control for 42 and 44; 43 is what makes 42 about *independence* rather than about
  hiding.
- 52 is the control for the whole of criterion 7: a notice that was a constant but a *view* that
  carried a count would satisfy 51 alone.
- 31 is the control for 9 and 10 together: an owner without privilege, or a
  `security_invoker` view, makes it return nothing; an owner that bypasses RLS with no filter
  of its own makes it return every venue's.
- 66 is the control for 45 and 46.
- 59 is the control for 8: an inventory that swept nothing satisfies "holds only SELECT".

## Implementation constraints

- `@spec` on every public function; error atoms enumerated, never `{:error, term()}`.
- `Ecto.UUID.t()` for entity ids.
- Migrations only through `mix ecto.gen.migration`, with a reversible `down`. U1–U8's are on
  `main` and off-limits. Four new ones: the tables, the row-level security, the views, the
  grants — in that order, so the grant migration is the only one that touches privileges and
  is therefore the only new entry in `PostgresRolesTest`'s unwind list.
- A CHECK constraint over two nullable columns is written as `(a IS NULL) <> (b IS NULL)` or
  as paired `IS NULL` comparisons. Never `a IS NULL OR b = c`.
- Multi-step writes use `Ecto.Multi` with named steps and the failing step in the error tuple;
  `mode: :savepoint` explicit on a constrained insert that is not last.
- No new `Clock.now/0` caller and no change to `.credo.exs`. `ago/2` and `from_now/2` stay
  banned; the view compares against `app_current_instant()`, which the wrapper writes from the
  scope.
- Queries live in `HospitalityComs.Profiles.Records` and nowhere else in the namespace,
  asserted structurally out of the compiled `imports` chunk the way `peers_test.exs` does. The
  context should reach **zero** query builders, which is stricter than `Peers` manages and is
  achievable because every write here is a whole query `Records` hands over.
- Employer reads go through `EmployerRepo.scoped_transaction/2` and read the views. Person
  reads go through `Repo` under a `PersonScope`. Nothing reads `attested_entries` through
  `EmployerRepo`.
- `profiles_test.exs` is `async: false` with real connections through
  `EngagementsFixtures.real_connections/0`, for the reason U5 gives.
- No transport surface. The issue's file list names contexts, migrations and one test file;
  U12's client surfaces and any channel event are a separate unit's work, and the issue's
  stated verification is a context-level claim.

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from explicitly.

1. **"Extend `attested_entry.ex`, do not move it" turned out to mean documentation only.** The
   schema was already the right shape — keyed on `engagements (id, venue_id)`, unique on the
   engagement, written by the claim and by nothing else — so U9 added no field, no changeset,
   and no constraint to it. What changed is its moduledoc, which had a "Who owns this module"
   section written by U5 in the future tense and now records what the context actually does.
   The absence of a schema change is the finding: the unit's whole content is the rules about
   who may read the row.

2. **`app_current_instant()` has to be compared `AT TIME ZONE 'UTC'`, and this was a latent
   bug rather than a style choice.** Ecto's `:utc_datetime` is `timestamp` **without** time
   zone in Postgres while the function returns `timestamptz`; comparing them makes Postgres
   convert the `timestamp` using the session's `TimeZone`, which nothing in this application
   sets. Measured under `SET LOCAL TimeZone = 'America/New_York'` with `app.now` at
   `2026-03-01T12:00:00Z`: `timestamp '2026-03-01 12:00:00' <= app_current_instant()` answers
   **false**, and the same comparison with `AT TIME ZONE 'UTC'` answers **true**. This
   server's default `TimeZone` is `Etc/UTC`, so the suite would never have caught it. The
   view now converts, which is the manoeuvre `create_engagements` already uses for the
   generated `period` column, and CLAUDE.md records that any future comparison against that
   function needs the same.

3. **Every instant selected out of a view needs `type/2`.** A schemaless query carries no
   field types, so `timestamp` columns come back as `NaiveDateTime` — which meant the employer
   read and the person read were handing back two different types inside one `VisibleEntry`.
   Found by a failing assertion rather than by inspection, and the reason `VisibleEntry` exists
   at all is that three readers should produce one shape.

4. **The disclosure ledger governs attested entries alone, and declared entries carry none.**
   The brief left this implicit under criterion 4; it is a decision and is now written into
   `DeclaredEntry`'s moduledoc. A declared entry is a statement its author can amend or empty
   at will, so a per-audience switch over it would be a second mechanism for something the
   first already does. Peers see them whole; employers never see them, which follows the plan's
   own zone diagram — only `attested_entries` has an arrow into the view.

5. **There are no multi-step writes in this unit, so there is no `Ecto.Multi` and no fourth
   `.dialyzer_ignore.exs` entry.** The brief carried the constraint from `AGENTS.md`; it did
   not apply. Setting a disclosure is one `INSERT … ON CONFLICT`, resolving a correction is one
   conditional `UPDATE … RETURNING`, and every read is one statement. `returning: true` on the
   upsert **is** load-bearing: a `binary_id` primary key is generated in Elixir, so without it
   the struct that comes back carries the id the insert *attempted* rather than the id of the
   row `ON CONFLICT` updated.

6. **`conflict_target` uses `{:unsafe_fragment, …}`, because the index is partial.** Postgres
   needs the predicate to match a partial unique index and Ecto's keyword form cannot carry
   one. The fragment is a literal in `Disclosure.conflict_target/1`, next to the constraint
   names it has to agree with; nothing interpolates a caller's value into it.

7. **An employer scope cannot be placed before its venue's grant was issued**, which changed
   how the two emptiness tests are built. `Venues.fetch_acting_grant/1` resolves the grant
   live at the scope's instant, so `end_engagement/2` with a past-dated scope answers
   `:no_grant`. Both empty-term tests therefore use a term in the *future*, ended at the
   present instant — `end_engagement/2` closes at the later of the caller's instant and the
   engagement's own start, which is exactly how the empty range is reachable.

8. **A bare-struct insert raises `Ecto.ConstraintError`, not `Postgrex.Error`.** Row 27's test
   asserts the former. The distinction is the point of the test: the struct declares no
   constraints, so what refuses it is the database rather than the changeset.

9. **`session_controller_test.exs`'s `populated_tables/0` grew a `table_type = 'BASE TABLE'`
   filter.** Not anticipated. `information_schema.tables` lists views, U9's two are the first
   in the tree, and selecting from one on a connection with no scope raises
   `app.now is not set` — which is the guarantee U3 built that function to give, arriving in a
   test that never expected to meet a view. **This is not a weakened assertion:** before U9
   the catalogue returned exactly the base tables, and the filter restores that set precisely.

10. **`Peers.connected?/2` was added, as the brief anticipated**, plus two tests in
    `peers_test.exs` rather than one — the second is the control that it answers false for an
    id naming nobody and for the caller themselves, which `visible?/2` already has.

11. **Two rows of the matrix are one test body each in the other direction, and some bodies
    have no row.** The table implies a 1:1 mapping and U8 recorded that it is not one; the same
    correction applies here. 66 rows produced **53** bodies in `profiles_test.exs` plus 15 in
    `boundary_test.exs`, 2 in `peers_test.exs` and 1 in `people_auth_tables_test.exs` — 71
    bodies against 66 rows, and they do not line up row by row. Rows 5+6, 8+9+10, 55+56+57,
    59+60+61 and 62+63 each collapse where the assertions are about one object; rows 64 and 65
    are one body each in files that already existed; and bodies with no row include "refuses an
    employer scope holding no grant, by function clause", "refuse a blank body and one over the
    bound", "grant on the views the migration says it granted on", and the three structural
    `Records` tests.

12. **Every claim about what a test would catch was checked by breaking the code**, and each
    mutation was reverted. Recorded in the final report with the tests each one failed.

## Quality scores (self-assessed)

- Coverage of stated scenarios: all 10 from the issue, plus the issue's stated verification,
  plus 55 more.
- Assertion strength: the concurrency tests assert both open ends of the overlap rather than a
  midpoint; the view tests assert ownership and reloptions rather than behaviour alone; the
  oracle tests assert a column list and an arity rather than an intention.
- Control coverage: 11 controls for the 11 assertions that could pass vacuously.
- Isolation: one new non-sandboxed file using the existing prefix purge, extended.
- Regression: three tables, two views, four migrations, one additive `Peers` predicate; no
  existing assertion weakened.
