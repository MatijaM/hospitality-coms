# Test Design Brief — #42, six constant pairs held together by prose

Issue: #42, "fix: six constant pairs held together by prose, and one that has already drifted".
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written and committed before any
production code, so the ordering is visible in the history rather than asserted.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before implementation
began. Recorded here because `AGENTS.md` requires the substitution to be visible in the artifact
rather than inferred from the absence of a review.

## What is being built

Six declarations in this tree say, in a comment, that they equal or bound some other declaration,
and nothing checks any of them. One has already drifted: `declared_entries.role_label` claims to
carry "the same bound `engagements.role_label` carries" and carries 120 where that column carries
160. The unit makes each of the six checkable by a mechanism, and corrects the one that is false.

The mechanism is chosen by what the relation actually is, which is the issue's own rule and PR
#41's precedent:

- **An equality** → derive at compile time, so there is one declaration and the other reads it.
- **An ordering** → keep both numbers declared and add a compile-time `raise`, because deriving a
  number that is only constrained from one side invents a precision that is not there.

And a third case the issue's suggested shape does not cover, which most of this unit turns out to
be: **the second declaration is a migration literal, which may not be derived and may not be
edited.** `AGENTS.md`: *"Never modify existing migrations — create new ones."* A migration must
replay to the schema it originally produced, so `Application.compile_env` and compile-time
derivation are both unavailable. What is available is to **read the live constraint back out of
Postgres and compare it against the module constant that claims it** — two genuinely independent
sources, one in Elixir and one in `pg_constraint`.

Four of the six land in that third case. That is the unit's main finding and it is why most of the
work is one new test file rather than six compile-time expressions.

## Decision 1 — 160 is correct, and the product owner has said so

`profiles/declared_entry.ex` and `*_create_profiles.exs` both declare `@max_label_length 120` under
the sentence *"The same bound `engagements.role_label` carries, so a declared entry and an attested
one render in the same width."* Measured against the live schema:

```
declared_entries_role_label_within_bound      CHECK ((length((role_label)::text) <= 120))
declared_entries_organisation_within_bound    CHECK ((length((organisation_name)::text) <= 120))
engagements_role_label_within_bound           CHECK ((length((role_label)::text) <= 160))
invitations_role_label_within_bound           CHECK ((length((role_label)::text) <= 160))
```

The sentence is the specification and the number is the defect. `DeclaredEntry` derives from
`Invitation.max_label_length/0` — the equality shape, and the same call `Engagement` already makes
— and a new migration widens both `declared_entries` bounds to match.

**`organisation_name` moves with `role_label`**, because the module attribute governs both
validations and always has. Widening one and not the other would need the attribute split into two,
which is a second declaration bought to avoid a one-line migration.

### ⚠️ POTENTIAL REGRESSION

- **Current behavior:** `declared_entries.role_label` and `.organisation_name` accept at most 120
  characters, refused by `validate_length/3` in the changeset and by a database CHECK behind it.
- **Proposed change:** both accept 160, the bound `engagements.role_label` and
  `invitations.role_label` already carry and the bound the code's own comment already claims.
- **What may stop working:** nothing on the widening path — every string valid at 120 is valid at
  160. **The `down` migration narrows back to 120 and will fail** with `check_violation` if any
  `declared_entries` row holds a label or organisation name longer than 120 characters, because
  Postgres validates an added CHECK against existing rows. A rollback would then have to shorten or
  delete those rows first. That is stated in the migration's own moduledoc rather than worked
  around: silently adding `NOT VALID` would make the `down` produce a constraint that does not hold,
  which is worse than a rollback that stops and says why. **On this tree it cannot fire** — the
  bound is only reachable at all after this migration, and `mix ecto.rollback` in the test suite
  runs against a database whose `declared_entries` rows the sandbox has already rolled back.
- **Affected callers or surfaces:** `Profiles.declare_entry/2` and `Profiles.amend_declared_entry/3`
  are the only writers; `HospitalityComsWeb.ProfileChannel` renders. No reader has a width
  assumption in code — the rendering claim is about a UI that does not exist yet.
- **Evidence and remaining uncertainty:** measured against `pg_constraint` above. The uncertainty is
  the product call, and the issue records it as made: 160.
- **Safer alternative, if available:** narrow `engagements.role_label` to 120 instead. Rejected —
  it is the destructive direction, it would need `invitations.role_label` and every stored label
  checked, and the product owner chose 160.
- **Regression coverage needed:** a 160-character label accepted end to end through
  `Profiles.declare_entry/2`; the existing over-long refusal still refusing; both `declared_entries`
  CHECKs read out of Postgres and compared against the module constant.

## Decision 2 — three of the six get a database read, not a derivation

Items 1, 3 and 5 all have the same shape: a module constant and a migration literal that must
agree, where the migration literal cannot move. The test reads `pg_get_constraintdef/1` for the
named constraint and parses the number out of it.

This is not a weaker mechanism than derivation; against this pair it is the only honest one, and
it reaches something derivation cannot. A compile-time derivation among the *lib* constants would
leave the database — the thing that actually enforces the bound, and the thing that has already
drifted — unchecked. The reverse is not true: the database read covers the lib constant too,
because the lib constant is one side of the comparison.

**It is not self-agreeing.** One side is an Elixir module attribute; the other is a string Postgres
generates from a catalogue row written by a migration that ran months ago. The trap named in
`docs/solutions/test-failures/tests-that-certify-nothing.md` — a test that derives both sides of an
equality from one source and then agrees with itself — is structurally unavailable here.

**Two controls are needed and are not optional.** The parser is the vacuity risk:

- a constraint name that matches nothing must **raise**, not answer `nil`, or a typo makes every
  row of the file pass against `nil == nil`;
- the parser must be shown returning **two different numbers** for two different constraints, or a
  helper that always answered `160` would pass every label row.

## Decision 3 — the pruner check goes in `lib`, and the issue's "cannot have a test" is imprecise

Item 2 links `Oban.Plugins.Pruner`'s `max_age` (7 days, `config/config.exs`) to
`EngagementSweeper`'s `@lookback_seconds` (1 day). The relation is an **ordering**: the sweep's
window must stay comfortably shorter than retention, because the completed announcement is what
stops the sweep re-announcing the same expiry every five minutes.

The check lives in `engagement_sweeper.ex` and reads config with `Application.compile_env/3` —
lib→config, never the reverse, because config may not depend on lib and because a `raise` at
compile time is what makes the relation unshippable rather than merely reported on.

**The issue says "It cannot have a test: `config/test.exs` sets `testing: :manual`, so plugins never
load." That is half right and the half that is wrong matters.** Measured in `MIX_ENV=test`:

```
Application.get_env(:hospitality_coms, Oban)[:plugins]
#=> [{Oban.Plugins.Cron, [crontab: [...]]}, {Oban.Plugins.Pruner, [max_age: 604800]}]
```

`testing: :manual` deep-merges into the keyword list from `config/config.exs` and makes Oban *start*
with `plugins: []`; it does not remove the configured value. So a runtime test is available. It is
still not written, for a better reason than "impossible": a compile-time `raise` fails the **build**
in every environment, which strictly dominates a test that fails in one. A duplicate runtime
assertion would add a second declaration of the same relation, which is the disease.

The `raise` is proved by making the relation false and watching `mix compile` fail — from **both**
sides, since a check that only reacts to the lib constant has not demonstrated that it reads config
at all.

## Decision 4 — "four triggers" is derived from the run record, and the ordering is raised on

Item 4: `@default_batch_size 500` × four triggers must stay under `@default_ceiling 5_000`, written
in prose in `lifecycle.ex` twice and `config/config.exs` once, enforced nowhere.

Two separate defects, and the second is the one the issue points at: **"four" is itself a prose
literal.** It is derived from `RetentionRun.triggers/0` — a new export naming the four count columns
the run record keeps, which is what a trigger *is* in this design: a thing that gets its own count.
A fifth trigger has to have a column to be recorded in, so the list cannot drift from the schema
without the run record failing to store the count.

Then the ordering is a compile-time `raise` in `Lifecycle`, over
`@default_batch_size * length(RetentionRun.triggers()) < @default_ceiling`.

**The compile-time check reaches the defaults only, and the effective values are runtime.**
`Lifecycle.batch_size/0` and `ceiling/0` go through `Application.get_env/3`, and `config/config.exs`
sets both to values that duplicate the defaults. So the same ordering is asserted a second time
over the **effective** settings, in a test. That is not a duplicate declaration — it is the same
relation applied to a different pair of numbers, and only the test can reach the runtime pair.

`RetentionRun.triggers/0` gets its own pin against `__schema__(:fields)`, with the six non-count
fields written out as a literal in the test so the test can disagree with the schema.

## Decision 5 — items 3 and 5 keep their cross-module pairs *undivided*, and this refutes part of the issue

Two of the six name a second pair beyond the module↔database one, and neither should be derived.

**`Invitation.@max_code_validity_in_days` must not derive from
`PersonToken.session_validity_in_days/0`.** The moduledoc says *"The same fourteen days
`PersonToken.session_validity_in_days/0` gives a session, and for the same reason: both are bearer
credentials."* Read closely, that is a **rationale**, not a constraint: nothing anywhere compares a
claim code's horizon to a session's, and the two are separate product choices about separate
credentials.

Deriving them would be actively harmful, and the harm is item 3's own headline failure arriving by
a new route. `invitations_code_expiry_within_bound` is a committed migration literal that cannot
move. If the invitation bound were derived from `PersonToken`, then raising the *session* horizon —
a change in a module that has nothing to do with invitations, made by somebody who has never read
`Invitation` — would move the changeset bound away from the database CHECK and produce exactly the
silent divergence the issue is about. The declaration stays; the sentence is corrected so it stops
implying a link that must hold.

**`PeerMessage`, `RoomMessage` and `CorrectionRequest` keep three separate `@max_body_length 4000`
declarations.** Nothing depends on those three agreeing. Deriving two of them from the third would
create compile-time dependencies `Peers → Rooms` and `Profiles → Rooms` to enforce an agreement no
mechanism needs, and would still leave all four migration literals — the ones that are actually
enforced — unchecked. Each is pinned to its own table's CHECK instead, which covers all seven
declarations the issue counts.

**The one body-length relation that is real is an ordering, and it is item 5's sharpest instance.**
`RetainedMessageCopy` holds a verbatim copy of a `room_messages.body`, has no length validation, and
is written with `insert_all`, so its CHECK is reached with no changeset in front of it. The relation
is `retained_message_copies` bound **≥** `RoomMessage.max_body_length/0`, and it is asserted in that
form rather than as an equality. It is a migration literal against a lib constant, so it gets the
database read rather than a `raise`.

## Decision 6 — `peers_test.exs` keeps all nine literals, and gains one assertion

This is a partial refutation of item 6, and it follows from the issue's own counter-examples.

The issue says `peers_test.exs` "redeclares `@tail_days 30` nine times, instead of calling the
exported `Visibility.tail_days/0`". Measured: it **declares it once**, at line 56, and uses it nine
times. Three of those uses are assertions that pin the tail's length —

```elixir
lapse = DateTime.add(ends_at, @tail_days, :day)
assert Peers.visible?(person_at(first, DateTime.add(lapse, -1, :second)), second.person.id)
refute Peers.visible?(person_at(first, lapse), second.person.id)
```

and

```elixir
assert peer.visible_until == @term_ends |> DateTime.truncate(:second) |> DateTime.add(@tail_days, :day)
```

— where `visible_until` is computed by `Visibility` from `@tail_days` in the module under test.
**Rewriting those to call `Visibility.tail_days/0` is precisely the trap the issue's own
counter-example section names**: both sides would come from one source and the assertion would
agree with itself for any value, including a wrong one. `retention_sweeper_test.exs` uses literal
day counts for this reason and the issue says not to fix it.

So the file's own copy of the number is correct and stays. What is missing is that the copy is
**silent** — nothing says it must equal the production one, and if `Visibility.@tail_days` changed
the file would fail in six confusing places with no line naming the number. One assertion fixes
that:

```elixir
assert Visibility.tail_days() == @tail_days
```

One side is the test's literal, the other is read from production. That is the same shape as
Decision 2's database read, and it is the only shape that satisfies "one number, one place" without
making the test unable to disagree.

The six setup-only uses (`@tail_days + 1`, meaning "past the tail") are left alone too. Converting
them would leave a file where some uses derive and some do not, for no detection gained: the pin
above is what names the change, and it names it in one line.

## Acceptance criteria

1. `DeclaredEntry.max_label_length/0` answers `Invitation.max_label_length/0`, derived at compile
   time, with no second literal in the module.
2. A new reversible migration widens `declared_entries_role_label_within_bound` and
   `declared_entries_organisation_within_bound` to 160; its `down` restores 120.
3. `Profiles.declare_entry/2` accepts a 160-character role label and a 160-character organisation
   name, and still refuses one character more.
4. Every `*_within_bound` CHECK named below is read out of `pg_constraint` and equals the module
   constant that claims it: `declared_entries` ×2, `engagements`, `invitations`,
   `invitations_code_expiry`, `room_messages`, `peer_messages`, `correction_requests`.
5. `retained_message_copies_body_within_bound` is **at least** `RoomMessage.max_body_length/0`.
6. `EngagementSweeper` fails to compile when `@lookback_seconds` is not shorter than the configured
   `Oban.Plugins.Pruner` `max_age`, from either side of the pair.
7. `RetentionRun.triggers/0` names every count column the schema keeps, and nothing else.
8. `Lifecycle` fails to compile when `@default_batch_size * length(RetentionRun.triggers())` reaches
   `@default_ceiling`.
9. The same ordering holds for the **effective** `Lifecycle.batch_size/0` and `ceiling/0`.
10. `peers_test.exs` asserts its `@tail_days` equals `Visibility.tail_days/0`.
11. `Invitation`'s moduledoc no longer implies its horizon is bound to `PersonToken`'s.

## Edge cases

- **A constraint name that matches nothing.** The reader raises. Without this the whole new file
  passes against `nil`.
- **Two constraints with different bounds.** 160 and 4000 are both live, so the reader can be shown
  discriminating rather than returning a constant.
- **`interval` spelling.** Postgres normalises `interval '14 days'` to `'14 days'::interval` and
  would render a one-day bound as `'1 day'`. The parser accepts both.
- **`::text` casts.** `length((role_label)::text)` for a `varchar` column and `length(body)` for
  `text`. One parser, both shapes.
- **No pruner configured.** `Application.compile_env` answers a plugin list with no Pruner entry.
  That removes the constraint rather than violating it — nothing deletes the completed announcement,
  so nothing can un-suppress the sweep — so the check skips rather than raises.
- **A bare `Oban.Plugins.Pruner` atom in the plugin list.** Oban's own default is `max_age: 60`,
  which the current lookback *does* violate. Read from `%Oban.Plugins.Pruner{}` rather than
  restated, so the check is right about a configuration this tree does not currently use.
- **`mix ecto.rollback` of the new migration against rows longer than 120.** Fails with
  `check_violation`. Documented in the migration; unreachable in this tree.

## Regression risks — existing files at risk, by path

- `test/hospitality_coms/profiles_test.exs` — owns every declared-entry assertion, including
  `String.duplicate("x", DeclaredEntry.max_label_length() + 1)` at line 1346, whose meaning changes
  from 121 to 161 characters. It still asserts what it asserted; note that it is an example of a
  test that *cannot* detect the constant moving, which is why criterion 3 uses a literal.
- `test/hospitality_coms/boundary_test.exs` — quantifies over tables and constraints and rolls
  migrations up and down. A new migration lands in that sequence. It grants nothing, so
  `postgres_roles_test.exs`'s grant-migration list is unchanged.
- `test/hospitality_coms/postgres_roles_test.exs` — four failures at baseline, all naming
  `hospitality_coms_dev` (issue #20's condition, not this branch's). Must still be four.
- `test/hospitality_coms/lifecycle_test.exs`, `test/hospitality_coms/workers/retention_sweeper_test.exs`
  — exercise `sweep/1` and the counts map. `RetentionRun` gains an export and no field.
- `test/hospitality_coms/workers/engagement_sweeper_test.exs` — `EngagementSweeper` gains a
  compile-time attribute and no behaviour.
- `test/hospitality_coms/peers_test.exs` — gains one assertion in an existing describe block.
- `config/config.exs` — the Oban section's prose changes. **PR #55 is open against the same file**,
  in the `:phoenix` section. Expect to rebase; the sections do not overlap.

## Test matrix

New file: `test/hospitality_coms/constant_agreement_test.exs`, `use HospitalityComs.DataCase,
async: true`. Reads the catalogue only, so the sandbox is enough.

| # | Scenario | Kind | Fails without |
|---|----------|------|---------------|
| 1 | `declared_entries_role_label_within_bound` == `DeclaredEntry.max_label_length()` | unit | the widening migration, or the derivation in `DeclaredEntry` — either half alone breaks it |
| 2 | `declared_entries_organisation_within_bound` == `DeclaredEntry.max_label_length()` | unit | the same, for the column that moves with it |
| 3 | `engagements_role_label_within_bound` == `Invitation.max_label_length()` | unit | a change to `Invitation.@max_label_length` with no migration |
| 4 | `invitations_role_label_within_bound` == `Invitation.max_label_length()` | unit | the same, second table |
| 5 | `invitations_code_expiry_within_bound` interval days == `Invitation.max_code_validity_in_days()` | unit | **item 3's whole defect** — raise the module constant and this is the only thing that fails |
| 6 | `room_messages_body_within_bound` == `RoomMessage.max_body_length()` | unit | a raised body bound with no migration |
| 7 | `peer_messages_body_within_bound` == `PeerMessage.max_body_length()` | unit | the same, second table |
| 8 | `correction_requests_body_within_bound` == `CorrectionRequest.max_body_length()` | unit | the same, third table |
| 9 | `retained_message_copies_body_within_bound` >= `RoomMessage.max_body_length()` | unit | **item 5's sharpest instance** — a raised room bound that would `Postgrex.Error` inside the retention transaction |
| 10 | the three anchor numbers the database holds are 160, 14 and 4000, written as literals | change-detector | a migration that alters a bound without a review; killed by rolling the new migration back |
| 11 | reading a bound whose constraint does not exist raises | **control for 1–10** | a reader that answers `nil`, against which every row above passes |
| 12 | the reader answers two different numbers for two different constraints | **control for 1–10** | a reader that returns a constant |
| 13 | `RetentionRun.triggers()` == the schema's fields minus the six named non-count columns | unit | a fifth count column added without extending the list |
| 14 | `batch_size() * length(triggers()) < ceiling()` on the **effective** settings | unit | a `config/config.exs` or `config/test.exs` ceiling an ordinary run could reach |

Existing files:

| # | File | Scenario | Kind | Fails without |
|---|------|----------|------|---------------|
| 15 | `profiles_test.exs` | a **160**-character role label and a **160**-character organisation name are accepted through `Profiles.declare_entry/2` | integration | the migration (database refuses) **or** the derivation (changeset refuses) — each alone |
| 16 | `profiles_test.exs` | the existing over-long refusal at `max_label_length() + 1` still refuses | regression | the validation being dropped rather than widened |
| 17 | `peers_test.exs` | `Visibility.tail_days() == @tail_days` | unit | a change to `Visibility.@tail_days`, named in one line instead of six |

Compile-time, proved by build failure rather than by a test:

| # | Relation | Proved by |
|---|----------|-----------|
| 18 | `EngagementSweeper.@lookback_seconds` < pruner `max_age` | raise the lookback past 7 days → `mix compile` fails |
| 19 | …and the check really reads config | lower `config/config.exs`'s `max_age` below the lookback → `mix compile` fails |
| 20 | `@default_batch_size * length(triggers()) < @default_ceiling` | lower `@default_ceiling` below 2000 → `mix compile` fails |
| 21 | …and the trigger count really comes from `RetentionRun` | with the ceiling at 2100, add a fifth trigger → `mix compile` fails |

## Controls, listed explicitly

- **Rows 11 and 12 control every row from 1 to 10, and the file is worthless without them.** Row 11
  is the vacuity control: a helper that answered `nil` for an unmatched constraint name would make
  a typo in any of ten constraint names pass silently, and every one of those names is a long
  string nobody will re-read. Row 12 is the discrimination control: it proves the parser is reading
  the definition rather than returning something fixed, by requiring two different answers from two
  different constraints in one assertion.
- **Row 10 controls rows 1–9 from the other direction, and is the file's one deliberate literal.**
  Rows 1–9 all compare the database to a module constant, so a change made in *both* places passes
  every one of them. Row 10 is the assertion that has to be edited on purpose, and it is exactly the
  shape `retention_sweeper_test.exs` and `boundary_test.exs` use deliberately: a test that can
  disagree with the thing it pins.
- **Row 15 is its own control in both directions**, which is why it is written with literal 160
  rather than `max_label_length()`. Reverting the derivation makes the changeset refuse; rolling the
  migration back makes the database refuse. A version written as
  `String.duplicate("x", DeclaredEntry.max_label_length())` would pass under both mutations, and
  line 1346 of the same file is the standing example of that shape.
- **Row 16 controls row 15.** Without it, a change that deleted `validate_length/3` outright would
  pass row 15 and read as success.
- **Row 19 controls row 18, and row 21 controls row 20.** A compile-time check that only reacts to
  the constant declared beside it has not been shown to read the other side of the pair at all —
  which is the entire claim being made about it.
- **Row 14 is not a control for row 20 and does not replace it.** They cover different numbers: the
  compile-time raise covers the defaults, the test covers the configured values, and today those
  happen to be equal. A future `config/prod.exs` making them differ is what the pair is for.
- **Row 17 controls nothing and is controlled by nothing.** It is a pin on an equality between a
  test literal and a production constant, and it fails if and only if they differ.

## Implementation constraints

- **No migration is edited.** `AGENTS.md`. The widening is a new file from `mix ecto.gen.migration`
  with a reversible `down`, and every existing migration literal stays where it is — which is why
  four of the six items are tested rather than derived.
- **`Application.compile_env`, lib→config, never config→lib.** Config may not read `lib`.
- **The new test file writes its anchor numbers out as literals** (row 10) and derives everything
  else from the module under test. Deriving both sides of any single assertion is forbidden.
- **`@spec` on every new public function** — `RetentionRun.triggers/0`. `AGENTS.md` calls this
  non-negotiable.
- **The clock is untouched.** Nothing here reads an instant.
- **`CLAUDE.md` is updated** where it states the numbers that move: the declared-entry bound and the
  "three numbers that are a set" paragraph, which now names the mechanism rather than the prose.
- Gates: `mix format --check-formatted`, `mix compile --force --warnings-as-errors` in `dev` and
  `MIX_ENV=prod`, `mix quality`, `mix test`. Baseline measured at 1108/1112 with four
  `PostgresRolesTest` failures naming `hospitality_coms_dev`.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 5/5 | all six items reach a mechanism; the two the issue rules out are left alone and the two it prescribes that measurement refutes are argued rather than skipped |
| Control discipline | 5/5 | the parser has both a vacuity control and a discrimination control; the widening test fails under each half of its own change; each compile-time raise is proved from both sides |
| Regression protection | 4/5 | six existing files named by path; the widening's `down` is the one edge nothing exercises, and it is documented rather than tested because reaching it needs a row the tree cannot hold |
| Falsifiability | 5/5 | every row names a mutation, and the four compile-time relations are proved by build failure rather than by assertion |
| Risk of a vacuous pass | 4/5 | the file's central hazard — a parser that answers `nil` — is closed by an explicit control; the residual risk is that rows 1–9 all pass under a coordinated two-place change, which row 10 is there to catch and catches only for the three anchors |
