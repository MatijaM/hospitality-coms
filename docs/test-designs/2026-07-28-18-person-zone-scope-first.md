# Test Design Brief — #18, the person zone's scope-first shape

Issue: #18, deferred out of #3 during code review. Found by the adversarial reviewer,
corroborated by security.
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written and committed before any
production code, so the ordering is visible in the history rather than asserted. Convention
established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md` through
`-u15-login-rate-limit-and-reapers.md`, including the "record revisions rather than applying them
silently" section at the end.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before
implementation began. Recorded here because `AGENTS.md` requires the substitution to be visible in
the artifact rather than inferred from the absence of a review.

## What is being built

Nothing new. Every `HospitalityComs.Accounts` function that reaches a repo takes a
`%PersonScope{}` as its first argument, so that an employer caller holding an `EmployerScope` is
refused **by function clause** — before the body runs, at the top of a function nobody had to
remember to guard.

U3 built that mechanism and it protects exactly one function today, and that function reads no
data: `Accounts.sudo_mode?/2`. Everything else takes a bare address, a bare token or a bare
`DateTime`, so an employer caller reaches the whole person zone with `employer_scope.now` and no
clause turns it away. `boundary_test.exs` pins that gap deliberately, so it is demonstrated rather
than theoretical.

This is a refactor. **No behaviour changes.** Same rows, same queries, same errors, same
transactions, same instants.

## The decision that matters most: what a scope means on an anonymous path

Registration and log-in are anonymous. `request_login_instructions/3` may be the call that creates
the `people` row; `get_person_by_email/1` is asked about an address that may name nobody; and
`get_person_by_session_token/2` is the call that *produces* the person a scope will carry, so it
cannot be handed one that already has it. A shape that assumed an authenticated person could not
cover any of them.

It does not have to. `PersonScope.for_person(nil, now)` is already a real value in this tree, not a
degenerate one: `PersonAuth.fetch_person_scope/2` assigns a scope for **every** request,
authenticated or not, because the log-in endpoint has no person and still needs the instant.
`PersonScope`'s own moduledoc says so — "a scope therefore always has an instant, including for a
caller who has not authenticated" — and `sudo_mode?/2` already answers an anonymous person scope
rather than refusing it, with `boundary_test.exs` depending on that as its control.

**So the scope answers three questions and only two of them are always answerable: which zone,
when, and — sometimes — who.** The refusal by function clause is about the first. The first is
answerable before the third is, and that is the whole of why the anonymous path is not an
exception to this refactor.

### Which gives two head shapes, not one, and the split is per function

**Family A — the scope's person is the subject.** The head destructures it and the person argument
disappears:

```elixir
def generate_person_session_token(%PersonScope{person: %Person{} = person, now: now})
```

`sudo_mode?/2` (already), `generate_person_session_token/1`, `update_person_email/2`,
`deliver_login_instructions/2`, `deliver_person_update_email_instructions/3`.

**Family B — the subject is a credential, an address or an id handed in.** The head constrains the
struct and nothing else:

```elixir
def get_person_by_email(%PersonScope{}, email) when is_binary(email)
```

`get_person_by_email/2`, `get_person!/2`, `register_person/2`, `request_login_instructions/3`,
`get_person_by_session_token/2`, `get_person_by_session_token_digest/2`,
`get_person_by_magic_link_token/2`, `login_person_by_magic_link/2`,
`delete_person_session_token/2`.

A Family A head on the log-in door would be a lie no caller could satisfy. A Family B head on
`generate_person_session_token` would keep a person argument beside a scope carrying a different
one, which is the shape that makes "whose session is this" answerable two ways.

### What Family B deliberately does *not* do: require `person: nil`

It would be one more constraint and it would be wrong. `delete_person_session_token/2` is called
from an authenticated request and its subject is that request's own credential;
`get_person_by_email/2` is called from inside `request_login_instructions/3`, whose scope is
whatever its caller handed down. Requiring nil would refuse legitimate callers for a property
nothing reads. The subject is the argument; the scope is the zone and the instant.

The residue, stated plainly: for a Family B function the scope's person is **ignored**, so passing
an authenticated scope and somebody else's token resolves somebody else's token. That is the
function's contract rather than a leak — the caller already holds the credential — and it is why
these heads do not pretend to be about the scope's person.

## The second decision: one clause, no guard macro

The issue asks whether every function needs two clauses (one accepting, one implicitly refusing)
or whether a shared guard macro is warranted. **Neither.** One clause, and the refusal is the
absence of a second.

- A second clause "refusing everything else" is exactly the runtime check U3 replaced. It puts the
  refusal in a body, where forgetting it is silent, and it turns a `FunctionClauseError` — which a
  caller cannot fail to notice — into a return value a caller can ignore.
- A `defguard is_person_scope(scope)` would expand to `is_struct(scope, PersonScope)`, which is
  **weaker** than the head pattern: it cannot destructure, so Family A would still need the
  `%Person{}` match, and Family B would gain a layer between the reader and the refusal for
  nothing. `Peers`, `Profiles`, `Rooms`, `Engagements` and `Lifecycle` all head on
  `%PersonScope{...}` directly, forty-odd times, with no macro. This context matching them is the
  answer to "has refusal-by-function-clause been shown to scale past one call site" — it has,
  everywhere but here.

## The third decision: the claim is total, so the conversion is

The issue names six functions. That list is incomplete —
`get_person_by_session_token_digest/2`, `get_person_by_magic_link_token/2`, `register_person/2`,
`get_person!/1`, `deliver_login_instructions/3` and
`deliver_person_update_email_instructions/4` all take a bare `DateTime` or a bare argument too, and
`get_person_by_session_token_digest/2` reads the same two rows as
`get_person_by_session_token/2`. Converting six and leaving those is the same half-true claim the
issue exists to close: an employer caller passes `employer_scope.now` to the digest form and gets
the same person back.

So the rule is **every `Accounts` function that reaches a repo**, and it is asserted as a
quantifier over the module's export list rather than as a hand-written list of six.

**One enumerated exception: `session_token_digest/1`.** It is `:crypto.hash(:sha256, token)` and
reaches no repo, no row and no clock. Requiring a scope for it would change the rule from "every
function that touches person-zone data" to "every function", which is a weaker rule wearing a
stronger one's clothes. The exception is written as a literal inside the assertion, so growing it
is an edit to the assertion.

## The trap this test must not fall into

**A test asserting `FunctionClauseError` for an employer scope can pass because the function would
have failed for any argument** — a `when is_binary(email)` guard, a `%Person{}` match further
along, a `FunctionClauseError` raised three frames deeper by something the employer scope happened
to reach. `docs/solutions/test-failures/tests-that-certify-nothing.md` catalogues twenty-one tests
in this project that read as coverage and provided none; most were controls that could not
control.

Three things close it, and all three are per function rather than once for the file:

1. **The raised error is checked to name the function under test.** `FunctionClauseError` carries
   `:module`, `:function` and `:arity`. Asserting all three is what distinguishes "this head
   refused" from "something down there refused". Without it, every row in the matrix below is
   satisfied by a crash.
2. **A control with the same arguments and a person scope, which must return without raising.**
   Not "does not raise `FunctionClauseError`" — *does not raise*. Every argument in the table is
   valid, so a control that raises anything is a row whose refusal was about the arguments.
3. **A second refusal, of a struct shaped exactly like a person scope but not one.** A test-local
   `%NotAScope{person: _, now: _}` is refused too, which is what makes the head's `PersonScope`
   name load-bearing rather than its `person:`/`now:` fields. Without it, `%{person: p, now: n}`
   would satisfy every Family A row.

## Where the tests live, and why not one new file

- **`test/hospitality_coms/accounts/person_zone_test.exs`** takes the totality sweep. It is already
  the person zone's own file, and it already makes the BEAM-side half of this claim structurally:
  "a privilege only helps if person data goes through the repo the privilege applies to, so the
  Accounts context is checked — from compiled code, not from a grep". The new sweep is the same
  sentence about the *argument* rather than the repo, and it quantifies over the export list the
  way the existing one quantifies over the application's module list.
- **`test/hospitality_coms/boundary_test.exs`**'s "the scope-first shape, where it is used" block
  is updated in place. It is the block that currently records the gap, and leaving it would make
  the boundary suite say something false. See "Regression risks" for exactly what changes and why
  it is not weaker.
- **`test/hospitality_coms/accounts_test.exs`** and the other seven call-site files change shape
  and assert the same things. No assertion there is added, removed or weakened.

## Acceptance criteria

1. Every public `Accounts` function that reaches a repo takes a `%PersonScope{}` first.
2. `session_token_digest/1` is the only exception, and it reaches no repo.
3. An `EmployerScope` passed to any of them raises `FunctionClauseError` **naming that function**.
4. A `PersonScope` passed to the same call with the same arguments returns without raising.
5. A struct with the same fields that is not a `PersonScope` is refused too.
6. Anonymous callers are covered: `PersonScope.for_person(nil, now)` reaches every Family B
   function, and the log-in door still works end to end.
7. The instant still arrives on the scope. No new `Clock` reader, no change to `.credo.exs`'s
   `:boundary_modules`, no `DateTime.utc_now/0` anywhere.
8. `ChannelAuth.join_scope/1` still re-derives the session per join against the same row and the
   same fourteen-day horizon — KTD8's refused rejoin is untouched, and `revocation_test.exs`
   proves it with no change to what it asserts.
9. `@spec` on every public function, `PersonScope.t()` first, error atoms enumerated. No
   `term()`/`any()`.
10. No behaviour change anywhere. Same rows, same errors, same transactions, same emails.
11. Every behavioural test proved load-bearing by mutation.

## Edge cases

- An **anonymous** person scope reaches every Family B function and is refused by every Family A
  one — `person: nil` does not match `%Person{}`, which is the same refusal by the same mechanism
  and must be asserted, not assumed.
- `sudo_mode?/1` and `sudo_mode?/2` are two exports from one definition with a default. Both must
  be covered or the sweep has a hole the export list will not show.
- `PersonAuth.fetch_person_scope/2` now builds an anonymous scope *before* authenticating and
  replaces it on success. An unauthenticated request must still get a scope with the instant, and
  an authenticated one must still get the person — the plug's two existing tests cover both and
  must not change.
- `ChannelAuth.resolve/1` (connect) and `join_scope/1` (join) both build anonymous scopes from
  `Clock.now()`. Both are inside the one boundary module and neither adds a clock read.
- `SessionController.confirm/2` issues the session token for a person the *request's* scope does
  not carry. It builds a scope for that person at the request's instant — which is what the
  session about to be issued is — rather than reaching past the shape.
- `Demo.register_people/1` is in `dev_support/` and builds scopes at historical instants already.
- `deliver_person_update_email_instructions/4` currently takes a person struct doctored to carry
  the *new* address plus the *old* address as a separate argument. Both are derivable from
  `scope.person` and the new address, and the token context must equal `"change:#{person.email}"`
  or the token can never be redeemed — so the freedom being removed is unusable. Recorded under
  regression risks.

## Regression risks — existing files at risk, by path

| Path | What is at risk |
|---|---|
| `test/hospitality_coms/boundary_test.exs` | the "scope-first shape" block records the gap being closed; one test **changes** — see below |
| `test/hospitality_coms/accounts_test.exs` | 40-odd call sites; every assertion must survive verbatim |
| `test/hospitality_coms/accounts_delivery_test.exs` | provider-outage paths through two converted functions |
| `test/hospitality_coms/accounts_concurrency_test.exs` | three racers on `login_person_by_magic_link/2`; the race must still be the same statement |
| `test/hospitality_coms/lifecycle_test.exs`, `lifecycle_reap_test.exs` | token lookups and the log-out table-count bound |
| `test/hospitality_coms_web/person_auth_test.exs` | the plug's scope assignment, both branches |
| `test/hospitality_coms_web/controllers/session_controller_test.exs` | the whole log-in door |
| `test/hospitality_coms_web/channels/sockets_test.exs`, `revocation_test.exs` | KTD7's socket id and KTD8's refused rejoin |
| `test/hospitality_coms/demo_test.exs` | `Demo.seed/0` writes people through `register_person/2` |
| `test/support/*.ex`, `test/support/fixtures/*.ex` | four call sites; a fixture that stopped stamping from the given instant would silently break every expiry test in the suite |
| `test/hospitality_coms/accounts/person_zone_test.exs` | the compiled-imports sweep must still find `Repo` and not `EmployerRepo` |

### The one assertion that changes, stated before it is changed

`boundary_test.exs`, "is not what keeps an employer caller out of the person zone". Today it reads
an address back through `get_person_by_email/1` using `employer_scope.now`, and the comment says
"`get_person_by_email/1` takes no scope at all — so there is no clause to refuse it".

After this branch there **is** a clause, so the call as written no longer compiles. The claim
underneath it is not about the absence of a clause; it is that **the argument shape is not the
boundary** — `Accounts` goes through `Repo`, which holds every privilege, and what closes the zone
is the grant on `EmployerRepo`'s role plus U3's `REVOKE`.

The replacement asserts the same claim in the only form left: an employer caller who *forges* a
person scope from their own instant still reads the address. **That is strictly stronger, not
weaker.** Before, it demonstrated that an employer needed to do nothing. Now it demonstrates
exactly what an employer must do — construct a `PersonScope` — and that doing it works, which is
the honest statement of what a BEAM-side refusal buys and what it does not. Nothing that was
asserted stops being asserted; the forgery is added.

## Test matrix

`person_zone_test.exs` is `async: false` and takes its own sandbox owners for both repos, which is
what the new sweep needs anyway — it writes people. `boundary_test.exs` is unchanged in kind.

Rows 1–5 are the sweep and each runs once per covered function, so one row is sixteen assertions.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | every repo-touching `Accounts` function refuses an `EmployerScope` | person_zone | unit | **the `%PersonScope{}` head** — the whole refactor |
| 2 | …and the `FunctionClauseError` names that function, arity included | person_zone | boundary | **control for 1** — a refusal three frames deeper satisfies 1 |
| 3 | …and the same call with a `PersonScope` returns without raising | person_zone | boundary | **control for 1** — a function that refuses everything satisfies 1 |
| 4 | …and a struct with the same fields that is not a `PersonScope` is refused | person_zone | boundary | **control for 1** — `%{person: _, now: _}` in the head satisfies 1 and 3 |
| 5 | the table covers every export but the enumerated exception | person_zone | unit | a function added later and silently uncovered |
| 6 | `session_token_digest/1` is a pure hash of its argument | person_zone | boundary | the exception in 5 being unjustified |
| 7 | an anonymous person scope reaches every Family B function | person_zone | unit | a head that required a person and broke the log-in door |
| 8 | an anonymous person scope is refused by every Family A function | person_zone | boundary | a Family A head that accepted `person: nil` and wrote a token for nobody |
| 9 | the context still calls `Repo` and never `EmployerRepo` (existing) | person_zone | unit | the compiled-imports sweep — unchanged, re-run as regression |
| 10 | `sudo_mode?/2` refuses an employer scope (existing) | boundary | unit | unchanged |
| 11 | `sudo_mode?/2` accepts an anonymous person scope (existing) | boundary | boundary | unchanged |
| 12 | a forged person scope built from an employer's instant still reads `people` | boundary | boundary | **the honest counterpart** — the claim that the shape is legibility, not the boundary |
| 13 | the log-in door still registers, mails and redeems end to end | session_controller | integration | any break in the anonymous path |
| 14 | an unauthenticated request still gets a scope carrying the instant | person_auth | unit | the plug building its scope only on success |
| 15 | an authenticated request still gets a scope carrying the person | person_auth | unit | the plug losing the person on the way through the anonymous scope |
| 16 | a channel join is still refused once the token row is gone (existing) | revocation | integration | KTD8 — `join_scope/1` re-deriving per join |
| 17 | every existing assertion in the nine call-site files still holds | (all) | regression | a refactor that changed behaviour |

## Controls, listed explicitly

- **Row 3 controls row 1.** A function that refused every argument would satisfy row 1. The person
  scope path must *return*, not merely fail differently.
- **Row 2 controls row 1** from the other side: it distinguishes the head refusing from anything
  below it refusing.
- **Row 4 controls rows 1 and 3.** Both are satisfied by a head that matched any map with
  `:person` and `:now`. `%NotAScope{}` is refused only if the head names `PersonScope`.
- **Row 5 controls the whole file.** Without it the sweep is a hand-written list of sixteen and the
  seventeenth function is uncovered on the day it is written.
- **Row 6 controls row 5's exception.** An exception with no justification is a hole.
- **Row 8 controls row 7.** Without it, "an anonymous scope reaches Family B" is satisfied by every
  head accepting `person: nil`, which would let a token be minted for nobody.
- **Row 11 controls row 10** (existing, unchanged).
- **Row 12 controls the entire branch.** It is the assertion that says what this refactor does
  *not* buy, and it is the one that stops the boundary suite growing a claim the grants have to
  keep honest.

## Implementation constraints

- **The instant arrives on the scope.** No new `Clock.now/0` caller.
  `HospitalityComs.Credo.Check.ClockAuthority` fails the build otherwise and `.credo.exs`'s
  `:boundary_modules` list must not grow.
- **`AGENTS.md`'s regression gate.** This should change no behaviour; anything that does is
  disclosed before it is applied.
- `@spec` with enumerated error atoms; `PersonScope.t()` first; no `term()`/`any()`.
- Moduledocs in `Accounts` and `PersonScope` currently *say* the refusal is available rather than
  in force. Both are now false and both must move, or the tree documents a gap it has closed.
  `CLAUDE.md` has no section on this and gains one sentence rather than a section.
- `mix format --check-formatted`, `mix compile --force --warnings-as-errors` in dev **and**
  `MIX_ENV=prod`, `mix quality`, `mix test`. Baseline is 1047 plus the three `PostgresRolesTest`
  failures issue #20 already owns.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 5/5 | quantified over the export list rather than the issue's list of six |
| Control discipline | 5/5 | four independent controls on the central claim, each killing a different false pass |
| Regression protection | 4/5 | rests on nine existing files continuing to pass; one assertion changes and is argued in advance |
| Falsifiability | 5/5 | every row names a mechanism whose removal fails it |
| Risk of a vacuous pass | 4/5 | the `FunctionClauseError` trap is closed three ways; the residue is that a control returning an error tuple is still a control |

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from explicitly.
The sections above are not edited to agree with what shipped.

1. **The literal exception list did not fail, and a mutation is what showed it.** The brief claimed
   writing `MapSet.new([{:session_token_digest, 1}])` inline meant "growing the exception list is an
   edit to this assertion and shows up in the diff". True, and not enough: **measured, deleting
   `get_person_by_email/2` from the table and adding it to the literal killed zero tests.** Two
   lines in one assertion, next to a comment saying not to, and a repo-touching function is
   uncovered with the suite green. That is the shape
   `docs/solutions/test-failures/tests-that-certify-nothing.md` catalogues — a control defeated by
   editing the control.

   Closed with a check the brief did not ask for: the set of `Accounts` exports whose **own body
   names a repo**, read out of the source AST, must be a subset of the table's keys. It is
   one-directional on purpose — `sudo_mode?/2` names no repo either and still takes a scope, so
   "names no repo" *permits* an exception rather than requiring one. Its known edge is
   `lifecycle_test.exs`'s: a body that delegates to a private helper names no repo of its own. Two
   test bodies rather than one, because the subset check passes trivially on an empty set: the
   control asserts the walk found at least twelve functions and names four of them, and both of the
   walk's own failure modes (an overwritten accumulator, a walk that stops matching `def`) kill it.

2. **Rows 1–5 became eight test bodies, not five.** The sweep splits three ways over the table
   (employer scope, person scope, impostor struct) plus coverage, the repo-touching subset and its
   control, and the two anonymous halves plus the label check. Twenty-one bodies in
   `person_zone_test.exs` against eleven before. Rows do not map one-to-one onto bodies, as U8, U9
   and U10 all recorded.

3. **The arity assertion needed a derivation the brief assumed away.** `sudo_mode?/1` and
   `sudo_mode?/2` are two exports of one definition, and a `sudo_mode?/1` call is refused by
   `sudo_mode?/2`'s head — so `error.arity` is 2 where the table's key says 1. Asserting the key's
   arity failed against correct code. `refusing_arity/1` takes the maximum exported arity for the
   name, which is where a definition's head is, and says so.

4. **The conversion covered sixteen exports rather than the issue's six**, as the brief said it
   would, and one signature narrowed beyond a scope argument.
   `deliver_person_update_email_instructions/4` took a `Person` doctored to carry the *new* address
   plus the *old* address beside it; it is `/3` now, taking the new address and deriving the rest
   from the scope. Flagged under regression risks in advance and measured: mutation 26, signing the
   token with the new address instead of the scope's person's, kills three tests in
   `accounts_test.exs`. There is no production caller.

5. **KTD8's session half is `sockets_test.exs`'s, not `revocation_test.exs`'s.** Criterion 8 named
   the wrong file. Measured: `join_scope/1` mutated to believe the socket's `person_id` instead of
   re-deriving from the digest leaves `revocation_test.exs` **fully green** — that file proves the
   *authorization* re-derivation (`Rooms.fetch_venue_room_membership/2` and friends), which this
   branch does not touch — and kills three tests in `sockets_test.exs`, which is where the deleted
   token and the aged-out horizon are asserted. Both files pass unchanged; the claim in the brief
   was pointed at the wrong one.

6. **The tree moved underneath this branch, as it did for #15.** It was cut from `origin/main` at
   `0e86221`; four pull requests landed there during implementation, #44 among them — which is
   issue **#17**, the one this issue's "Related" section names, giving `EmployerRepo` a login role
   of its own and closing the `RESET ROLE` escape. The branch is rebased onto `acee453`. Three
   files overlapped (`CLAUDE.md`, `boundary_test.exs`,
   `session_controller_test.exs`) and all three merged without conflict; nothing was rewritten
   beyond the rebase itself.

   It changes one sentence's weight rather than its truth. "What closes the person zone is the
   grant on `EmployerRepo`'s role" was, until #17, a claim with a hole in it — `RESET ROLE` put the
   connection back on a role that owned every table, so the grant tier was defeatable from the same
   code position as the BEAM-side guards. It is not any more, which makes the thing this branch
   deliberately does *not* claim to be a stronger tier than it was when the brief was written.

7. **Baseline arithmetic.** 1047 tests when the ticket was written, 1066 on `origin/main` after
   those four merges, 1076 here — ten new bodies in `person_zone_test.exs`. Four
   `PostgresRolesTest` failures rather than three: #17 added a fourth test to that file and it
   fails for the same documented reason as the other three, naming `hospitality_coms_dev`
   (issue #20). Nothing else is red.

## Mutation record

Thirty-two mutations, each applied to a clean tree, measured against the narrowest file that could
answer, then restored. Every one of the ten new test bodies is killed by at least one, and so is
`boundary_test.exs`'s changed counterpart.

| # | Mutation | Tests killed |
|---|----------|--------------|
| 1 | `get_person_by_email/2`'s head stops naming a scope | 2 |
| 2 | `get_person!/2`'s head stops naming a scope | 2 |
| 3 | `register_person/2`'s head is a bare map with `:now` — which an `EmployerScope` has | 2 |
| 4 | `request_login_instructions/3`'s head drops the struct; the private one keeps it | 2 |
| 5 | `get_person_by_session_token/2`'s head is a bare map with `:now` | 2 |
| 6 | `get_person_by_session_token_digest/2`'s head is a bare map with `:now` | 2 |
| 7 | `get_person_by_magic_link_token/2`'s head is a bare map with `:now` | 2 |
| 8 | `login_person_by_magic_link/2`'s head is a bare map with `:now` | 2 |
| 9 | `delete_person_session_token/2`'s head stops naming a scope | 2 |
| 10 | `sudo_mode?/2`'s terminal clause stops naming a scope | 2 |
| 11 | `generate_person_session_token/1`'s head is a bare map with `:person` and `:now` | 1 |
| 12 | `update_person_email/2`'s head is a bare map | 1 |
| 13 | `deliver_login_instructions/2`'s head is a bare map | 1 |
| 14 | `deliver_person_update_email_instructions/3`'s head is a bare map | 1 |
| 15 | `generate_person_session_token/1` stops requiring a person on the scope | 1 |
| 16 | `update_person_email/2` stops requiring a person on the scope | 1 |
| 17 | the table loses a row (`get_person!/2`) | 2 |
| 18 | the exception literal grows to hide a repo-touching function | 1 (**0** before revision 1) |
| 19 | `session_token_digest/1` stops being the SHA-256 of its argument | 1 |
| 20 | a Family A function is labelled `:anonymous` in the table | 1 |
| 21 | a third label appears in the table | 1 |
| 22 | `PersonAuth` stops authenticating and leaves every request anonymous | 3 |
| 23 | `PersonAuth` loses the request's instant when the lookup succeeds | 2 |
| 24 | `ChannelAuth.join_scope/1` believes the socket instead of re-deriving | 3 (`sockets_test`; **0** in `revocation_test` — see revision 5) |
| 25 | `SessionController` mints the session token at a fixed instant | 2 |
| 26 | `deliver_person_update_email_instructions/3` signs the token with the new address | 3 |
| 27 | the repo-touching walk's accumulator is overwritten by the next alias | 1 |
| 28 | the repo-touching walk stops matching `def` | 2 |
| 29 | **mutation 4 with the `module`/`function`/`arity` assertions removed** | 1 — and the main sweep **survives** |
| 30 | `get_person_by_email/2` refuses an anonymous scope | 1 |
| 31 | the same, against `boundary_test.exs`'s forged-scope counterpart | 1 |
| 32 | `get_person_by_email/2` refuses a scope that carries a person | 1 |

**Mutation 29 is the one worth reading twice.** It is mutation 4's code change — dropping
`request_login_instructions/3`'s struct from the head — with the three assertions that name the
refusing function taken out of the test. Under it, the employer scope falls through the public head
into `login_request_multi/2`, which still heads on `%PersonScope{}`, and raises
`FunctionClauseError` **one frame deeper**. `assert_raise FunctionClauseError` passes. The sweep
goes green on a function that no longer refuses anything. Those three assertions are what make the
difference between mutation 4 killing two tests and killing none of the one that matters.

Two things are deliberately **not** asserted. Nothing pins that `Accounts` reads no clock — that is
`HospitalityComs.Credo.Check.ClockAuthority`'s job and a test restating it would be a second
spelling of the same rule. And no test asserts that the *private* functions take scopes; they
thread whatever their public caller was handed, and a rule about private arity would be a rule
about how a body is written rather than about what the module's door refuses.
