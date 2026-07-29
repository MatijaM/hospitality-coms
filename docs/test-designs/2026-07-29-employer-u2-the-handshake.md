# Test Design Brief — employer U2, the handshake: invitations out, claims in

Plan: `docs/plans/2026-07-29-001-feat-crude-employer-view-plan.md`, section `### U2`, plus
KTD-E3, KTD-E4, KTD-E5 and KTD-E9.
Origin: `docs/brainstorms/2026-07-29-crude-employer-view-requirements.md` (R1–R6, R16, R18, R20;
AE1, AE2, AE3, AE4).
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Committed before any production code,
so the ordering is visible in the history rather than asserted. Nearest precedent:
`docs/test-designs/2026-07-29-employer-u1-scope-and-people.md`, whose branch this one is cut from.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before
implementation began. Recorded here because `AGENTS.md` requires the substitution to be visible in
the artifact rather than inferred from the absence of a review.

## What is being built

Two write routes, and they are the two halves of the one gesture this whole surface exists to
show. The employer offers; the worker accepts, in their own session, with their own account.

```
POST /api/employer/venues/:venue_id/invitations   -> 201 {invitation: {...}, claim_code: "..."}
POST /api/claims                                  -> 201 {engagement: {...}}
```

Both sit on the existing `:authenticated_person` pipeline. The first resolves an acting grant
through `HospitalityComsWeb.EmployerAuth.employer_scope/2`, U1's resolver, called per request; the
second needs no venue and no grant at all — a claimant needs no prior relationship to the venue,
which is A2 in the origin and the reason the route is not nested under one.

Nothing new is added to any context. `Engagements.issue_invitation/2` and
`Engagements.claim_invitation/2` exist, take the right scopes, and refuse correctly. This unit is
transport: two actions, two render shapes, six refusal mappings, and three server-side defaults.

## Decision 1 — the claim's failure shape is `Ecto.Multi`'s four-tuple

`claim_invitation/2` answers `{:ok, claim()}` or `claim_failure()`, and `claim_failure()` is
declared in `HospitalityComs.Engagements` as

```elixir
{:error, :consume, :unknown_code | :already_claimed | :code_expired, map()}
| {:error, :conferrable, :grant_not_live, map()}
| {:error, :engagement, Ecto.Changeset.t(Engagement.t()), map()}
| {:error, :attested_entry, Ecto.Changeset.t(AttestedEntry.t()), map()}
| {:error, :expiry_job, Ecto.Changeset.t(Oban.Job.t()), map()}
```

**A two-element `{:error, reason}` clause matches none of these.** It would compile, it would pass
every test that never reaches a refusal, and the first refusal in a demo would be a
`FunctionClauseError` rendered as `500`. The controller matches the four-tuple in every clause,
and the three changeset steps collapse into **one** clause keyed on the changeset rather than on
the step name — the step is not information a client can act on, and enumerating it would make two
of the three arms permanently untested rather than honestly uncovered.

## Decision 2 — R6 makes three refusals distinguishable, and on this API that means three statuses

R6: *"A code that is unknown, already claimed, or expired is refused with a sentence that
distinguishes those three, because none of them discloses anything the holder of a code does not
already know."*

This is the one place in the surface that is **deliberately not flat**, and it is the opposite of
KTD-E3's rule for the employer routes. The reason the two differ is that they protect different
things. `:no_grant` is flat because distinguishing its causes would tell a caller that a venue
exists. A claim code's three failures tell its holder nothing: they already hold the code, so
"there is an invitation behind it" is not news, and "it was taken" and "it lapsed" are facts about
their own offer.

`HospitalityComsWeb.ErrorEnvelope`'s contract is that `code` **is the response's status atom** —
that is what stops the two drifting. So "machine-distinguishable" and "distinct status" are the
same sentence here, and flattening the three onto one status with three messages would push a
client into parsing prose. The mapping:

| Context answer | Status | Why this one |
|---|---|---|
| `:consume, :unknown_code` | `404 not_found` | nothing matches the digest |
| `:consume, :already_claimed` | `409 conflict` | it exists; its state conflicts with the request |
| `:consume, :code_expired` | `410 gone` | it existed and its validity has lapsed, permanently |
| `:conferrable, :grant_not_live` | `409 conflict` | the offer stands, the venue's state refuses it |
| any changeset step | `422 unprocessable_entity` | with `for_changeset/3`'s `fields` |
| no `claim_code` key | `400 bad_request` | a client bug, distinct from a code that fails |

**The reason is written into the moduledoc**, because a later reviewer sweeping for consistency
with the flat refusals everywhere else would otherwise "fix" it, and the fix would delete a
requirement.

`:grant_not_live` shares `409` with `:already_claimed` and carries its own sentence. It is a
different family from the three R6 names — the code is fine and unspent, and re-issuing the grant
makes the same code good again — so it is not one of the three the requirement distinguishes, and
a fourth status invented for it would claim more precision than the requirement asks for.

## Decision 3 — the `:conferrable` arm **is** reachable from this transport, and the plan says it is not

The plan's U2 test scenarios carry a "reachability note": *"the `:conferrable, :grant_not_live`
arm is not reachable from this transport, because the crude form does not offer `grant_id`. Cover
the controller's clause by calling the private mapper directly, or state in the brief that the arm
is covered at the context level … and carried here untested."*

**Both options are unnecessary.** The claim route does not need the *invitation* to have been
issued through the employer route. A test issues a conferring invitation through
`EngagementsFixtures.invitation_fixture/2` — which is what `engagements_test.exs` already does —
revokes the conferred grant, and then drives `POST /api/claims` with that code. The arm is reached
end to end, through the real router, with no private function called and nothing stubbed.

What the plan's sentence is actually true of is the **employer** route's own `:grant_not_live`
arm: `issue_invitation/2` can answer it, and the controller must handle it, and no request this
route accepts can produce it because `grant_id` is not among the fields cast from the body. That
arm is carried untested and this brief says so rather than letting a test appear to reach it.

That asymmetry is worth one more test in its own right (row 10 below): a body **naming**
`grant_id` must confer nothing. The route takes exactly four fields off the body, and the
difference between taking four and taking five is the difference between a manager hiring a worker
and a client minting a manager through a form that does not offer the option.

## Decision 4 — two fixture designs, and both turn on needing two claimants

The plan caught these and they are the substance of the unit. Both are cases where the obvious
one-person fixture produces a green test that certifies nothing, and both fail for a reason that
reads like a controller bug.

**AE3 — one code, two claimants.** The guard under test is `claim_invitation/2`'s conditional
`UPDATE` (`Records.claimable/2`'s `is_nil(claimed_at)` clause), which is the first step of the
Multi. The obvious fixture is one person claiming the same code twice. It is worthless: two claims
by one person build engagements with identical `person_id`, `venue_id` and term, which collide on
`engagements_no_overlap` — so **deleting the conditional clause entirely still leaves the count at
one**, and the second call still fails, at a different step, with a different error. Two claimants
produce non-overlapping engagements, so with the guard deleted the count is 2 and both calls
succeed. The guard is then the only thing holding the count at 1. Predicted and to be **measured**
in both directions.

**AE2 — two invitations, two claimants.** Under KTD-E5 both invitations carry `starts_at = now`
and `ends_at = now + 90 days` by default, so one person claiming both collides on the exclusion
constraint and the test fails with a `422` naming `period` — a failure that reads as a bug in the
route rather than as the fixture being wrong. Two claimants is the only shape in which "an
invitation is an offer and nothing deduplicates offers" is what the test is about.

That collision is itself worth asserting, in its own test (row 17), because it is the reachable
`{:error, :engagement, changeset, _}` arm and it documents in the tree why AE2's fixture looks the
way it does.

**A third place needs two claimants and the plan does not mention it:** AE4's both-directions
expiry test. Accepting at `expiry - 1s` consumes an engagement for that person; the refusal at
`expiry` must therefore come from a *second* person, or the second call would be refused by the
overlap it hits after the consume rather than by the expiry it is meant to be about. It would
still be `410` — `:consume` is the first step, so the expiry answer arrives before the engagement
is built — which is exactly what makes the one-claimant version dangerous: it passes, and it
passes for a reason the test does not name.

## Decision 5 — the three defaults, and the one relationship asserted between two constants

KTD-E5. `issue_invitation/2` requires `role_label`, `starts_at`, `ends_at` and `code_expires_at`
with no defaults. A crude form cannot ask for three date-times, and a client that computes them is
a second clock: `HospitalityComs.Clock.Offset` moves the server's instant and would not move a
browser's, so U11's demo controls would desynchronise the two.

| Field | Default | Why |
|---|---|---|
| `starts_at` | `scope.now` | `list_engagements/1` is active-at-instant, so a term opening tomorrow produces an engagement the issuing manager's own people list does not show — which in a demo reads as the claim having failed. U1 pinned that behaviour, so this default rests on a checked claim. |
| `ends_at` | `scope.now + 90 days` | long enough that nothing in a demo expires under it |
| `code_expires_at` | `scope.now + 7 days` | the changeset bounds validity at `issued_at + 14 days` **inclusive**, and a default sitting on a bound breaks the first time somebody rounds |

**The seven and the fourteen are independent constants** (issue #42). The default is not derived
from `Invitation.max_code_validity_in_days/0`, and the only relationship asserted between them is
a **test**: the defaulted expiry lands strictly inside the bound and strictly after the instant. A
checkable relationship rather than a sentence.

**The durations are written out in the test file**, not read from the controller's module
attributes. A test that reads the constant it pins asserts only that the constant equals itself.
The same applies to the bound: `engagements_test.exs`'s existing both-sides tests derive their
input from `Invitation.max_code_validity_in_days/0` and therefore *move with it*, which the
function's own docstring says. The controller test writes `14` and the message string out
literally, so it is the first test in the tree that would fail if the changeset's bound moved
without the migration's CHECK moving with it.

**What this pins is the changeset's bound and nothing else.** `invitations_code_expiry_within_bound`
is a separate declaration of the same number, is item 3 of issue #42, and is covered by
`constant_agreement_test.exs`. This unit does not claim it.

## Decision 6 — `config/config.exs` drops off the file list, and the filter test changes shape

The plan says: *"`claim_code` must be added to `filter_parameters`, and today nothing would redact
it. Verified: there is no `config :phoenix, :filter_parameters` line anywhere in `config/`."*

**That was true when the plan was written and is false now.** Issue #53 landed as PR #55.
`config/config.exs` carries

```elixir
config :phoenix, :filter_parameters, {:keep, ["connection_id", "extent", "person_id",
                                              "request_id", "shift_room_id", "venue_id", "vsn"]}
```

an **allowlist**. `claim_code` is filtered because it is *not named*, so there is nothing to add
and adding it to the keep list would be the bug. `config/config.exs` is therefore not in this
unit's file list. Verified by reading the file, and by
`test/hospitality_coms_web/parameter_filter_test.exs`, which already carries `claim_code` in its
`@filtered` list with the comment *"the whole argument for the allowlist shape is that it is
covered here without anybody having added a rule for it."*

So the unit-level assertion the plan asked for **already exists**. What does not exist, and is
what R20 actually asks for, is the end-to-end one: a **live** claim code, in a real request to the
route this unit ships, absent from the dispatch line. That test goes in
`claim_controller_test.exs` (row 23), because a real claim spans both repos and cannot run under
`ConnCase`'s sandbox.

Its controls are the ones `parameter_filter_test.exs`'s moduledoc insists on, and they are not
optional: every assertion in that family is an absence, and an absence assertion passes against a
log that captured nothing — which is the default outcome, since `config/test.exs` pins the suite
at `:warning` and the dispatch line is `:debug`. So the capture goes through a local
`with_debug_log/1`, the dispatch line is asserted **present**, and a kept parameter is asserted
**verbatim in the same line**.

The allowlist reaches four `Phoenix.Logger` sites, two of which log at `:info` and reach
production. Nothing in this unit adds a fifth.

## Decision 7 — what the two responses carry, and what they must not

KTD-E4, and U1's discipline applied to two new shapes. `Invitation` carries
`claim_code_digest`; `Engagement` carries `person_id`, `invitation_id`, `grant_id` and
`lock_version`. Both are whole-struct disclosures `CLAUDE.md` records.

```
201 {invitation: {invitation_id, role_label, starts_at, ends_at, code_expires_at},
     claim_code: "<plaintext, once>"}

201 {engagement: {engagement_id, venue_id, role_label, starts_at, ends_at, accepted_at}}
```

`claim_code` sits **beside** the invitation rather than inside it, because it is not a property of
the row — the row holds only a digest, and D4 says the code is unrecoverable the moment the
response is lost. The shape says that structurally.

The pins, three per shape, each catching what the others cannot: a structural `@spec` naming every
key (Dialyzer), an exact key-set equality against a literal written out in the test file (fails
when a field is **added**, which is the direction a disclosure arrives from), and a control
asserting the source schema still carries the withheld field, so an empty render cannot pass for a
redacted one.

**And a fourth for the invitation, which no other shape in the tree needs:** the returned code is
asserted to be the real credential, by hashing it and comparing against the row's
`claim_code_digest`. Without it, "the response carries a plaintext code" and "the response carries
a string" are the same green.

The claim response goes to the *person*, so R18's "employer-facing" does not strictly reach it. It
is pinned anyway: it is the one response in this plan whose source is a whole schema and whose
shape U4's client will be written against.

## Acceptance criteria

1. `POST /api/employer/venues/:venue_id/invitations` with only `role_label` answers `201` carrying
   a plaintext claim code and an invitation whose key set equals a literal (AE1, R1).
2. No rendered invitation payload carries `claim_code_digest` (R4), and the source schema still
   does.
3. The returned code hashes to the row's stored digest.
4. Absent `starts_at`, `ends_at` and `code_expires_at` default to the request's instant, `+90
   days` and `+7 days` (R3, KTD-E5).
5. The defaulted code expiry lands strictly inside the fourteen-day bound and strictly after the
   instant.
6. All three instants are overridable from the body.
7. `code_expires_at` at exactly `issued_at + 14 days` is accepted; one second later is a field
   error naming `code_expires_at`. **Both directions.**
8. `ends_at` at or before `starts_at` is a field error naming `ends_at`; a missing `role_label` is
   a field error naming `role_label`.
9. A body naming `grant_id` confers nothing.
10. A venue this session holds no grant at, and a malformed venue id, are `404` with byte-identical
    bodies (R17 on a write route).
11. `POST /api/claims` with a good code answers `201` carrying the engagement, key set equal to a
    literal, no `person_id` (R5).
12. F1 end to end: the issuing manager's people list gains the claimed engagement, at the same
    instant, with no job having run.
13. Two invitations for one role produce two different codes and both claim, **from two
    claimants** (AE2).
14. One code, **two claimants**: the second is refused `409` and exactly one engagement exists from
    that invitation (AE3).
15. One person claiming two overlapping offers is `422` naming `period`.
16. A code past its expiry is refused `410` naming expiry; the same code one second earlier is
    accepted (AE4). **Both directions.**
17. An unknown code is `404` and **no engagement row is written**, counted before and after.
18. A claim whose conferred authority was revoked since issue is `409` naming the authority.
19. A request carrying no `claim_code` is `400`, with a body distinct from an unknown code's.
20. Neither route answers anything without a bearer token; both answer with one.
21. Every refusal body is `ErrorEnvelope`'s, with `code` equal to the status atom; every field
    error goes through `for_changeset/3`.
22. A live claim code does not reach the request log (R20), with the dispatch line asserted present
    and a kept parameter asserted verbatim beside it.
23. `@spec` on every public function with error atoms enumerated; `Ecto.UUID.t()` for ids.
24. `.credo.exs` unchanged, `config/config.exs` unchanged, zero migrations.
25. Every behavioural test proved load-bearing by mutation.

## Edge cases

- **A claim code presented twice by the same person.** Refused `409` — but by the consume, not by
  the overlap, and the test that says which is row 14's two-claimant version rather than this one.
  Not tested separately: it cannot distinguish the two mechanisms, which is the entire finding.
- **An explicit `null` instant in the body.** `Map.put_new/3` does not replace a present key, so
  `{"starts_at": null}` casts to nil and fails `validate_required` with a field error. A client
  sending null is a client bug and `422` is the honest answer; recorded in the moduledoc rather
  than special-cased.
- **A `code_expires_at` before the instant.** Already covered at the context level and reachable
  here; folded into row 7's file rather than given a row, since it is the same validation.
- **An invitation issued at one venue, claimed by a person engaged at another.** Nothing refuses
  it and nothing should — a claimant needs no prior relationship (A2). Covered implicitly by every
  claim test, whose claimant holds nothing anywhere.
- **A term whose `starts_at` is in the future.** Claimable, and the resulting engagement is absent
  from the manager's people list until the instant passes. U1 pinned exactly that, which is why
  KTD-E5's default is `scope.now`; not re-tested here.
- **Two managers at one venue issuing at once.** No shared row, no constraint between two
  invitations, nothing to race. Deliberately not tested.

## Regression risks — existing files at risk, by path

| Path | What is at risk |
|---|---|
| `test/hospitality_coms_web/controllers/employer_controller_test.exs` | thirteen existing assertions; this unit adds a `describe` block and must change none of them |
| `test/hospitality_coms_web/parameter_filter_test.exs` | `config/config.exs` is unchanged, so this file must stay green untouched. **If it moves, the allowlist moved and this unit had no business moving it.** |
| `test/hospitality_coms/engagements_test.exs` | `issue_invitation/2` and `claim_invitation/2` are called, not changed; every existing assertion must hold |
| `test/hospitality_coms/engagements_concurrency_test.exs` | the three races are the context's; nothing here may make a sequential test look like proof of one |
| `test/hospitality_coms_web/controllers/session_controller_test.exs`, `room_controller_test.exs` | the router gains two routes; no existing route may be shadowed |
| `test/hospitality_coms/boundary_test.exs` | no migration, no table, no grant, no view. **If this file moves, something was done that this unit did not intend.** |
| `test/hospitality_coms/constant_agreement_test.exs` | the fourteen-day bound is pinned there against the migration; this unit adds a literal in a third place and must not change either of the two |

## Test matrix

`test/hospitality_coms_web/controllers/claim_controller_test.exs` is **new and non-sandboxed**
(KTD-E9), and `employer_controller_test.exs` already is. Both take
`EngagementsFixtures.real_connections/0`, pin `Clock.Offset`, and mint sessions locally. The claim
spans both repos' connections; under the sandbox they are two transactions that cannot see each
other's rows, so **every list would come back empty and every negative assertion would pass for
the wrong reason**.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | `role_label` alone answers `201`; top-level key set is `{invitation, claim_code}` and the invitation's equals a literal | employer | integration | the route and the render |
| 2 | **control:** `Invitation.__schema__(:fields)` contains `:claim_code_digest` | employer | boundary | **control for 1** — an empty render passes 1 alone |
| 3 | the returned code hashes to the row's stored digest | employer | boundary | a render that returned any string; also proves the row holds only the digest |
| 4 | the three defaults are `now`, `+90 days`, `+7 days`, written out in the test | employer | boundary | the defaulting; KTD-E5 |
| 5 | the defaulted expiry is strictly inside `now + 14 days` and strictly after `now` | employer | boundary | the *relationship* between two independent constants (issue #42) |
| 6 | explicit instants override all three | employer | unit | `Map.put_new` being `Map.put` |
| 7 | `code_expires_at` at exactly `+14 days` is accepted | employer | boundary | the bound being exclusive; **one half of the pair** |
| 8 | at `+14 days + 1 second` it is a field error naming `code_expires_at` | employer | boundary | the bound at all; **the other half** |
| 9 | `ends_at <= starts_at`, and a missing `role_label`, are field errors naming the field | employer | unit | `for_changeset/3` reaching the response |
| 10 | a body naming `grant_id` produces an invitation conferring nothing | employer | boundary | the four-field `Map.take`; **control:** the same grant conferred through the context does produce one |
| 11 | no grant at that venue, and a malformed venue id, give **byte-identical** `404`s | employer | boundary | R17 on a write route; equality rather than two matches |
| 12 | …**control:** the same session at the venue it does manage gets `201` | employer | boundary | **control for 11** — a route that refused everything passes 11 |
| 13 | a good code answers `201`; engagement key set equals a literal | claim | integration | the route and the render |
| 14 | **control:** `Engagement.__schema__(:fields)` contains `:person_id` | claim | boundary | **control for 13** |
| 15 | **F1 end to end**: issue over HTTP, claim over HTTP, the manager's people list gains the row with the offered role label | claim | integration | `starts_at` defaulting to `now`; a tomorrow default leaves the list unchanged |
| 16 | **AE2, two invitations and two claimants**: two different codes, both `201` | claim | integration | distinct code generation; one claimant makes this `422` |
| 17 | one person claiming two overlapping offers is `422` naming `period` | claim | boundary | the reachable changeset arm; **and it is why row 16 needs two claimants** |
| 18 | **AE3, one code and two claimants**: the second is `409`, and **exactly one** engagement exists from that invitation | claim | boundary | `Records.claimable/2`'s `is_nil(claimed_at)`. **One claimant certifies nothing here** — see Decision 4 |
| 19 | **AE4**: a code claimed at `expiry - 1s` succeeds; a second claimant at `expiry` gets `410` | claim | boundary | half-open expiry; **both directions**, two claimants |
| 20 | an unknown code is `404` and the engagement count is unchanged | claim | boundary | the count is the control — a `404` with a row written would pass the status half |
| 21 | a conferring invitation whose grant was revoked since issue is `409` | claim | boundary | the `:conferrable` arm reaching the transport. **The plan says this is unreachable; it is not** |
| 22 | a request with no `claim_code` is `400`, body **not equal** to an unknown code's | claim | boundary | the guard clause; inequality is what proves the two are distinct |
| 23 | a live claim code is `[FILTERED]` in the dispatch line | claim | boundary | the allowlist. **Controls:** the dispatch line is present, and `venue_id` prints verbatim in it |
| 24 | neither route answers without a bearer token; both answer with one | both | boundary | the pipeline; the `201` half is the control |
| 25 | `employer_controller_test.exs`'s thirteen existing tests pass unchanged | employer | regression | this unit touching U1's actions |
| 26 | `engagements_test.exs`, `parameter_filter_test.exs`, `boundary_test.exs` green and unchanged | (three) | regression | this unit changing a context or a config it has no business changing |

## Controls, listed explicitly

- **Row 2 controls row 1** and **row 14 controls row 13.** `AGENTS.md` singles this shape out:
  without the `__schema__` line, "the render omits the digest" and "there is nothing to render"
  are the same green.
- **Row 3 is the control nothing else provides.** An exact key set says a `claim_code` key exists;
  only the digest comparison says the value in it is the credential.
- **Row 12 controls row 11.** The same session, two venues, two answers.
- **Row 10 carries its own control** — the context conferring the same grant successfully — so
  "the route ignores `grant_id`" cannot pass because conferring is broken everywhere.
- **Row 18's count is the control on its status assertion**, and the two-claimant fixture is what
  makes the count mean anything. With one claimant the count is 1 whether or not the guard exists.
- **Row 20's count controls its status.** A `404` is satisfied by a route that refuses everything;
  "and nothing was written" is what makes it a statement about the claim.
- **Row 22 asserts *inequality* of two bodies**, which is the mirror of row 11's equality. Both
  are claims about flatness — one that two causes are indistinguishable, one that two causes are
  not the same cause.
- **Row 23's two controls are mandatory**, per `parameter_filter_test.exs`'s moduledoc: an absence
  assertion over an empty capture passes, and `config/test.exs` makes the empty capture the
  default.
- **Row 24's control is its own second half.**
- **Every list and every count is asserted non-empty or non-zero before anything is asserted about
  it**, because KTD-E9's environment failure has exactly one signature.

## Implementation constraints

- **No new clock read.** Both actions take their instant from `conn.assigns.current_scope`, and
  the employer action from the `EmployerScope` U1's resolver built off it. `.credo.exs`'s
  `:boundary_modules` must not grow (KTD-E1).
- **The claim failure is matched as a four-tuple.** Decision 1.
- **Every error body through `ErrorEnvelope`**, status atom *being* the envelope's code;
  `for_changeset/3` for every field error.
- **`EntityId.cast/1` for the venue id**, byte-size guard included.
- **Exactly four fields are taken off the invitation body.** `grant_id` is not one of them.
- **Zero migrations, zero new tables, zero new grants, and `config/config.exs` untouched.**
  **Never migrate `hospitality_coms_dev`.**
- `mix format --check-formatted`, `mix compile --force --warnings-as-errors` in dev **and**
  `MIX_ENV=prod`, `mix quality`, `mix test`. Baseline on this branch's parent is **1144/1148**,
  the four `PostgresRolesTest` failures being issue #20's documented `hospitality_coms_dev`
  condition and not this branch's.
- **The rate-limiter paragraph in `EmployerController`'s moduledoc must be revisited, not
  inherited.** U1 wrote *"the employer surface's first write route is U2's, and that is the unit
  that has to revisit this paragraph"*. Two write routes arrive here; the paragraph either changes
  or says why it does not.
- **No client work.** U4 owns it.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 5/5 | both routes, six refusal mappings, three defaults, two bounds, both response shapes |
| Control discipline | 5/5 | every negative carries a positive; the three assertions most likely to be vacuous (two key sets, the log absence) each carry a named control, and the two-claimant fixtures exist *because* the cheap ones are vacuous |
| Regression protection | 4/5 | rests on seven existing files, two of which (`parameter_filter_test.exs`, `boundary_test.exs`) are asserted by *not moving* |
| Falsifiability | 5/5 | every row names a mechanism whose removal fails it; rows 18 and 16 name the fixture design as the mechanism, which is the unit's finding |
| Risk of a vacuous pass | 4/5 | closed on the headline rows; the residue is that rows 4–8 assert against a response rather than against the row, so a render that echoed the request would pass them — row 3 and row 10 are what reach the row |

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from explicitly.
The sections above are not edited to agree with what shipped.

1. **Decision 4's AE3 argument is wrong in its mechanism and in its conclusion, and the plan is
   wrong with it — measured.** The plan says: *"Two claimants produce non-overlapping engagements,
   so the count is 2 without the consume step and the guard is the only thing holding it at 1."*

   **Measured: with the consume's `claimed_at IS NULL` clause deleted, the count is 1 with two
   claimants as well as with one.** One invitation can produce at most one engagement whatever the
   consume does, because `engagements.invitation_id` carries a unique index — the backstop
   `HospitalityComs.Engagements`'s moduledoc names in "Three races" and
   `*_create_engagements.exs` documents under *"The unique index on `invitation_id` is the race
   guard"*. The plan attributes the one-claimant floor to `engagements_no_overlap`; the observed
   refusal is `invitation_id has already been taken`, from the index, in both fixtures.

   So the **count certifies nothing in either fixture**, and the assertion that kills the mutation
   in both is the **status**: `409 conflict` becomes `422 unprocessable_entity`. Both fixtures
   kill it.

   The two-claimant fixture is kept, on a weaker and true claim rather than the plan's: with one
   claimant *three* mechanisms refuse the second call — the consume, the unique index and the
   exclusion constraint — and a green test cannot say which it exercised. Two claimants remove one
   of the three. The test's comment and the file's moduledoc now say exactly this, and the count
   is labelled as AE3's literal requirement rather than as the proof.

2. **The plan's AE2 prediction is exactly right, and is now measured.** A one-claimant version of
   the two-offers test was written, run against a **correct** tree, and fails with
   `422 {"period": ["overlaps an engagement this person already holds at this venue"]}` — a
   failure that reads as a bug in the route. The probe file was deleted after measuring.

3. **KTD-E5's claim about which bound the both-directions test pins is wrong.** The plan says
   *"U2's both-directions test pins the **changeset's** bound"*. **Measured: neutering
   `Invitation.validate_code_validity/2` kills nothing** — `declare_constraints/1` attaches
   `invitations_code_expiry_within_bound` with the *same message string*, so Postgres refuses and
   Ecto returns an identical field error. No route-level test can attribute the refusal to either
   declaration, by construction.

   That is `docs/solutions/test-failures/what-a-zero-kill-mutation-means.md`'s case (b) — a
   redundant guard — but **not** its remedy: the two guards protect different entry points on
   purpose (the changeset for callers, the CHECK for a `Repo.insert_all` that never passed through
   one), and `engagements_test.exs` has the test that bypasses the changeset to prove the second.
   So nothing is deleted; the claim is corrected. What the test does pin is *the bound, as
   observed from the route*, and it is load-bearing: moving `@max_code_validity_in_days` to 21
   while the migration's literal stays at 14 kills it, alongside `constant_agreement_test.exs`.
   It is a second tripwire on issue #42's pair, from a third place.

4. **Decision 3 held: the `:conferrable, :grant_not_live` arm is reachable and is tested.** The
   plan's instruction to state it as untested was not followed, and the test kills a mutation
   (M19). The *employer* route's own `:grant_not_live` arm is the one that is genuinely
   unreachable, and it is recorded in `EmployerController`'s moduledoc rather than given a test
   that appears to reach it.

5. **`config/config.exs` is untouched, as Decision 6 predicted.** The allowlist already covers
   `claim_code`, and M21 — adding `claim_code` to the keep list, which is literally what the plan
   asked for — **kills the new log test**. The plan's instruction would have introduced the bug
   its own requirement forbids.

6. **One row moved file.** Row 24's employer half lives in `employer_controller_test.exs` and its
   claim half in `claim_controller_test.exs`, one test each rather than one row spanning two
   files.

7. **Rows do not map one-to-one onto test bodies**, as every unit since U8 has recorded.
   Twenty-six rows became **twenty-two** new Elixir bodies — eleven added to
   `employer_controller_test.exs` and eleven in the new `claim_controller_test.exs`. Rows 7 and 8
   are one body (a bound is one test, read from both sides), rows 1–2 and 13–14 are one body each
   with their control inline, and rows 25–26 are whole existing files rather than new bodies.

8. **One new test passes against a tree with no route at all**, and it is worth naming rather than
   leaving for somebody to find. "Refuses a code that names nothing, and writes no engagement"
   asserts `404` with `code: "not_found"`, which is exactly what Phoenix's own router answers for
   an unrouted path — so during the red run it was the single green test in the file. It is
   load-bearing now (M16 kills it), but the file's other refusal tests are what distinguish "the
   route exists and refused" from "there is no route".

9. **Baseline arithmetic.** **1144/1148** before, **1166/1170** after — twenty-two new bodies, and
   the same four `PostgresRolesTest` failures naming `hospitality_coms_dev` (issue #20), which are
   a developer's local migration rather than this branch's.

10. **A note on running this suite locally.** The Postgres cluster is shared with other projects,
    `max_connections` is 100, and one `mix test` here opens `System.schedulers_online() * 2`
    connections **per repo** — 64 on a sixteen-core machine. With two other suites running, that
    does not fit and every run dies at `ecto.create` with `53300 too_many_connections`, which
    reads like a broken database rather than a busy one. `ELIXIR_ERL_OPTIONS="+S 4:4"` brings it
    to 16 and is what the mutation runs below used.

## Mutation record

Twenty-three mutations, each applied to a clean tree, measured against the narrowest file that
could answer, then restored. Every new behavioural test is killed by at least one.

| # | Mutation | Tests killed |
|---|----------|--------------|
| 1 | `Records.claimable/2` drops `is_nil(claimed_at)` — the consume guard | 1 |
| 2 | `render_invitation/1` grows `claim_code_digest` | 1 |
| 3 | `render_invitation/1` loses `code_expires_at` | 5 |
| 4 | `claim_code` carries the digest rather than the code | 2 |
| 5 | `offer/2` uses `Map.put/3` rather than `Map.put_new/3` | 3 |
| 6 | `offer/2` defaults nothing | 9 |
| 7 | `@offer_fields` widened to include `grant_id` | 1 |
| 8 | the code-expiry default moves from 7 to 14 — onto the bound | 2 |
| 9 | the term default moves from 90 days to 1 | 1 |
| 10 | `starts_at` defaults to tomorrow | 2 |
| 11 | `Invitation.validate_code_validity/2` neutered | **0** — see revision 3 |
| 11b | `@max_code_validity_in_days` moves to 21, the migration's literal does not | 2 (one of them `constant_agreement_test.exs`'s) |
| 12 | `create_invitation/2` skips `EntityId.cast/1` | 1 |
| 13 | `create_invitation/2`'s `:no_grant` answers `403` | 1 |
| 14 | `:already_claimed` maps to `404` like an unknown code | 1 |
| 15 | `:code_expired` maps to `409` | 1 |
| 16 | `:unknown_code` maps to `409` | 2 |
| 17 | the claim's render grows `person_id` | 1 |
| 18 | the changeset arm maps to `409` with no fields | 1 |
| 19 | the `:conferrable` arm maps to `404` | 1 |
| 20 | a missing `claim_code` answers like an unknown code | 1 |
| 21 | **`claim_code` added to the allowlist — what the plan asked for** | 1 |
| 22 | `POST /api/claims` leaves the `:authenticated_person` pipeline | 1 |
| 23 | the claim's render loses `accepted_at` | 1 |

**Mutations 1, 11 and 21 are the ones worth reading twice.** The first disproves the plan's
account of AE3 while confirming its instinct. The second is a zero-kill that is *not* a coverage
hole, and the reasoning for leaving it is revision 3. The third is the plan's own instruction,
applied as a patch, breaking the requirement it was written to satisfy.

Two things are deliberately **not** asserted, following U1. Nothing pins `.credo.exs`'s contents
from a test — the rule is that the file does not change, which a diff shows and a test would only
restate. And nothing asserts the absence of a `grant_id` field on the *form*, only that a body
naming one confers nothing; a test for the absence of a thing passes for ever whether or not
anything prevents it.
