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

_Appended below in a later commit, per `AGENTS.md`. The sections above are not edited to agree
with what shipped._
