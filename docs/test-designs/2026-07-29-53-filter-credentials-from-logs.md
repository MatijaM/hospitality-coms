# Test Design Brief — #53, keep credentials out of the parameter log

Issue: #53, "fix: bearer credentials are logged in plaintext — the default parameter filter
protects a field this app deleted".
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written and committed before any
production code, so the ordering is visible in the history rather than asserted. Convention
established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md` onwards.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before
implementation began. Recorded here because `AGENTS.md` requires the substitution to be visible in
the artifact rather than inferred from the absence of a review.

## What is being built

One configuration line and the test that makes it checkable. `config :phoenix, :filter_parameters`
is set nowhere in this tree, so `Phoenix.Logger.filter_values/1` — the function every parameter map
Phoenix prints goes through — runs on whatever default the framework ships. That default is a
denylist of key-name fragments, and this application deleted the field it was written for.

The fix is to declare the filter, and to declare it in the shape that fails safe when a future unit
adds a parameter nobody updates the list for.

## Correction to the issue's premise, measured before anything was written

The issue says Phoenix's default is `["password"]` and that the magic-link token therefore prints.
**Half of that is wrong, and the half that is wrong is the headline.**

`deps/phoenix/lib/phoenix/logger.ex:92` does say *"Phoenix's default is `["password"]`"* — that
moduledoc is stale. The value that actually applies is the application environment baked into
`deps/phoenix/mix.exs:72`:

```elixir
env: [
  ...
  filter_parameters: ["password", "token"],
```

Measured on this tree, at Phoenix 1.8.9, with no configuration of our own:

```
[debug] Processing with HospitalityComsWeb.SessionController.confirm/2
  Parameters: %{"token" => "[FILTERED]", "venue_id" => "abc-123"}
```

So `POST /api/log-in/token` does **not** print the magic-link token today. It is covered by
coincidence: the parameter happens to be spelled `token`, and `token` happens to be one of the two
fragments Phoenix ships.

**Everything else the issue is about survives that correction, and the correction sharpens it.**
Measured against the same shipped default:

| Parameter | Where it arrives | Shipped default |
|---|---|---|
| `email` | `POST /api/log-in` | **prints** |
| `claim_code` | `POST /api/claims`, the employer view's plan | **prints** |
| `code` | any short-form spelling of the above | **prints** |
| `body` | `send` on all three message channels | **prints** |
| `token` | `POST /api/log-in/token` | filtered, by luck |

A denylist of two fragments covering one of five parameters, one of them by accident, is the
argument for changing the shape rather than lengthening the list. It is also why the mutation
record below reports that deleting our configuration does **not** kill the magic-link test: the
framework catches that one either way, and a brief that claimed otherwise would be claiming
coverage it does not have.

## Decision 1 — an allowlist, `{:keep, [...]}`, not a longer denylist

Both shapes are available. `{:keep, names}` inverts `filter_values/1` to an allowlist: every
parameter not named is `"[FILTERED]"`.

**The question is which shape fails safe when somebody adds a parameter and updates no list**, and
the two answers are not symmetric:

- **A denylist fails open, silently.** The new parameter prints. Nothing says so, nothing goes red,
  and the leak is discovered by reading a terminal. This is not hypothetical — it is the state of
  the tree, and it is how `["password"]`-shaped configuration went four units without anyone
  noticing that the field had been deleted from the application.
- **An allowlist fails closed, visibly.** The new parameter reads `"[FILTERED]"` where somebody
  wanted a value. The cost is a lost diagnostic; the fix is one name.

The asymmetry is structural rather than a matter of taste. **The set of sensitive names is open and
grows with the product; the set of safe names in this API is small, closed, and almost entirely
`*_id`.** Enumerating the tractable side is the only version of this that stays true.

Three further facts, each measured, that point the same way:

1. **`filter_values/1` serves four log sites, not one**, and two of them log at `:info` — which
   `config/prod.exs` does write. From `deps/phoenix/lib/phoenix/logger.ex`:

   | Site | Level | Default from |
   |---|---|---|
   | HTTP router dispatch (`Parameters:`) | `:debug` | `Phoenix.Router`, `:log` |
   | Socket connect | `:info` | `phoenix/socket.ex:524` |
   | Channel join | `:info` | `phoenix/channel.ex:469`, `log_join` |
   | Channel `handle_in` | `:debug` | `phoenix/channel.ex:470`, `log_handle_in` |

   The issue's scope paragraph — "dev and test in practice" — is right about the HTTP surface and
   incomplete about the other three. A join payload is client-supplied and this application's
   `join/3` clauses ignore it, so nothing bounds what a client can put there, and it prints in
   production. A denylist author writing against `POST` bodies never reaches that surface. An
   allowlist covers it without anyone deciding to.

2. **`handle_in` params carry `body`** — the free text of every venue-room, shift-room and peer
   message. `AGENTS.md`: *"Free-text user input is dangerous in logs."* No plausible denylist
   fragment catches a parameter named `body`; the allowlist catches it by not naming it.

3. **The compiled form is only readable for one of the two shapes.** `Phoenix.start/2`
   (`deps/phoenix/lib/phoenix.ex:21`) rewrites the configured value into a compiled form at boot.
   For a denylist that is `{:compiled, {:ac, #Reference<...>}, {:ac, #Reference<...>}}` — opaque, so
   a test cannot pin what was configured. `compile_filter({:keep, params})` returns `{:keep,
   params}` unchanged, so the allowlist is still legible to a test at runtime. The shape that can
   be pinned is the shape that can be reviewed.

### The list, and why each name is on it

Every parameter name this application's own surfaces accept today, from a sweep of
`lib/hospitality_coms_web/controllers/`, `lib/hospitality_coms_web/channels/` and
`dev_support/hospitality_coms_web/controllers/`:

```elixir
{:keep, ["connection_id", "extent", "person_id", "request_id", "shift_room_id", "venue_id", "vsn"]}
```

- Six are ids or a closed enum (`extent` is `"all" | "recent"`). `AGENTS.md` names `*_id` as the
  non-redacted spelling to reach for, and every one of these is the thing you would need to read a
  log line at all.
- `vsn` is the only parameter the sockets carry, and it is the one that prints in **production**
  at `:info`. Filtering the serializer version would make a connection failure harder to read for
  no gain.

**Deliberately not on it:** `email`, `token`, `body`, `instant`, `advance` — and nothing from the
employer view's plan. `claim_code` is filtered by *not being added*, which is the property this
whole decision exists to buy, so pre-populating for a route that does not exist yet would spend it.

### The names match at every depth, and that is checked

`keep_values/2` recurses into nested values and tests `k in match` at each level, so a kept name is
kept wherever it appears in the params tree. Measured: `{:keep, ["day"]}` over
`%{"advance" => %{"day" => 31}}` answers `%{"advance" => %{"day" => 31}}`. None of the seven names
is a plausible nested key under a sensitive parent, but the property is why the list must stay
short and specific — `"id"` would have been a bad entry for exactly this reason.

## Decision 2 — one list, and it is not `AGENTS.md`'s

`AGENTS.md` line 312 says these names are *"auto-redacted via `@sensitive_key_fragments`"*.

**`@sensitive_key_fragments` does not exist.** `grep -rn "sensitive_key_fragments"` over `lib/`,
`dev_support/`, `config/` and `test/` returns the `AGENTS.md` line and nothing else. It is
inherited template prose describing a curated-logging redactor this project never built.

That settles the "do not create issue #42's seventh instance" question in the strongest available
way: **there is no second declaration in code to keep in agreement, and writing an Elixir copy of
that fragment list would create one.** So none is written.

They are also genuinely different concerns, in opposite directions:

| | `filter_parameters` | `AGENTS.md`'s list |
|---|---|---|
| Governs | inbound parameter maps the framework prints for you | outbound metadata an author writes by hand |
| Names chosen by | the client | the author |
| Name set | open — a client may send anything | closed at the call site |
| Therefore | must fail closed → allowlist | can be a naming convention → denylist |

An allowlist is not derivable from a fragment denylist in either direction: the complement of an
open set is not a set you can write down. Deriving one from the other would be dishonest in
issue #42's own terms, which distinguish an **equality** (derive) from an **ordering** (declare and
raise) and cover neither of those here.

What is done instead is the honest, cheap half: **`AGENTS.md` is corrected to describe the
mechanism that exists.** Its naming guidance is kept — the curated `Logger` calls in `lib/` already
follow it, using `reason_code`, `*_id` and counts, and `person_notifier.ex` says in a comment that
the recipient address is deliberately not logged — but the false claim that something redacts them
automatically is removed. `tests-that-certify-nothing.md`'s closing section is about exactly this:
a documentation claim about what a mechanism does is the highest-risk sentence in a repository,
because it is the one that stops anyone going to look.

## Decision 3 — the test must lower the log level itself, and that is the trap

`config/test.exs:74` sets `config :logger, level: :warning`. `ExUnit.CaptureLog`'s own docs:
*"this setting does not override the overall `Logger.level/0` value. Therefore, if `Logger.level/0`
is set to a higher level than the one configured in this function, no message will be captured."*

Measured, all three variants, in one throwaway file:

| Approach | Captured |
|---|---|
| `with_log([level: :debug], …)` | `""` |
| `Logger.put_process_level(self(), :debug)` then the same | `""` |
| `Logger.configure(level: :debug)` then the same | the full dispatch line |

**So a test written the obvious way captures an empty string, and `refute log =~ token` passes
against it.** That is the generative shape in
`docs/solutions/test-failures/tests-that-certify-nothing.md` — an absence assertion satisfied by a
run that logged nothing — arriving in the one file whose entire subject is an absence.

The file therefore lowers the primary level around each capture and restores it, is `async: false`,
and **every capture carries a control that reads a value out of the same log line.**

## Acceptance criteria

1. `config :phoenix, :filter_parameters` is set in `config/config.exs`, in the `{:keep, [...]}`
   shape, and its value is exactly the seven names above.
2. A real magic-link token redeemed over `POST /api/log-in/token` does not appear in the log, and
   the parameter reads `"[FILTERED]"`.
3. An email address posted to `POST /api/log-in` does not appear in the log, and the parameter reads
   `"[FILTERED]"`. **This is the criterion the shipped default fails.**
4. `claim_code` — the parameter the employer view will add and that no list here names — is filtered
   against the live configured filter, with no edit to the filter.
5. `body` is filtered against the live configured filter.
6. A kept parameter appears **verbatim** in the same captured log line as a filtered one.
7. `AGENTS.md` describes the mechanism that exists.

## Edge cases

- **Empty params.** `filter_values(%{}, {:keep, _})` is `%{}` — no crash, no `[FILTERED]` for a map
  with nothing in it. Measured.
- **Unfetched params.** `Phoenix.Logger.params/1` short-circuits `%Plug.Conn.Unfetched{}` to
  `"[UNFETCHED]"` before `filter_values/1` sees it, so the `keep_values` struct clause is not
  reached from the HTTP path. Measured both ways.
- **Nested maps.** Covered above; the demo route's `%{"advance" => %{"day" => 31}}` is the only
  nested body in the tree and its leaf is filtered.
- **A value that is not a binary.** `keep_values(_other, _match)` answers `"[FILTERED]"`, so
  integers and booleans under an unnamed key are filtered too rather than passed through.

## Regression risks — existing files at risk, by path

- `test/hospitality_coms_web/controllers/session_controller_test.exs` — the only existing file that
  captures a log around an HTTP request (`with_log/1`, the mailer-outage test). It asserts on the
  response, not the log, so a filter change cannot reach it; re-run as the proof.
- `test/hospitality_coms/boundary_test.exs`, `postgres_roles_test.exs`,
  `people_auth_tables_test.exs` — `capture_log` around migrations. Migration logs are not parameter
  maps. Re-run the first as the proof, since it is the largest capture in the suite.
- `test/hospitality_coms_web/channels/` — nothing asserts on channel log output, but
  `filter_values/1` now applies to `handle_in` params. Re-run `peer_channel_test.exs` and
  `venue_room_channel_test.exs`.
- `config/config.exs` — a `:phoenix` key added beside `:json_library`. Nothing reads it but
  `Phoenix.start/2`.

## Test matrix

New file: `test/hospitality_coms_web/parameter_filter_test.exs`, `use HospitalityComsWeb.ConnCase,
async: false` — sync because it mutates the primary `Logger` level, and `ConnCase` because two rows
go over a real request.

| # | Scenario | Kind | Fails without |
|---|----------|------|---------------|
| 1 | the configured value is exactly `{:keep, [seven names]}` | unit | the config line; also the change-detector on any widening |
| 2 | a real magic-link token redeemed over HTTP: the token's bytes are absent from the log and `"token" => "[FILTERED]"` is present | integration | **nothing in this diff** — Phoenix's own default covers it. Recorded as such rather than claimed as coverage |
| 3 | …and `"venue_id" => "<the id>"` appears verbatim **in the same capture** | integration | **control for 2 and 4** — proves the capture is non-empty, the request logged, and the filter is not blanket redaction |
| 4 | …and the dispatch line naming `SessionController.confirm/2` is present | integration | **control for 2** — proves the line we are asserting the absence *in* exists |
| 5 | an email address posted to `POST /api/log-in`: absent from the log, `"email" => "[FILTERED]"` | integration | **our configuration**; the shipped default prints it |
| 6 | …with the same two controls as rows 3–4, against `SessionController.create/2` | integration | control for 5 |
| 7 | `claim_code` against the **live** configured filter → `[FILTERED]` | unit | our configuration; the parameter no list names |
| 8 | `body` against the live configured filter → `[FILTERED]` | unit | our configuration |
| 9 | `password`, `code`, `secret`, `authorization` against the live filter → `[FILTERED]` | unit | the allowlist shape; a denylist naming only some of them passes partly |
| 10 | each of the seven kept names against the live filter → verbatim | boundary | **control for 7–9** — a filter that redacts everything passes all of them |
| 11 | with the primary level left at `:warning`, the capture is empty | boundary | **the meta-control**: it demonstrates on the record that rows 2–6 would pass vacuously without the level change |
| 12 | `session_controller_test.exs` unchanged and green | regression | a filter that broke the mailer-outage capture |
| 13 | `boundary_test.exs` unchanged and green | regression | a filter reaching migration logs |

## Controls, listed explicitly

- **Row 3 controls rows 2 and 4, and it is the row the file turns on.** It reads a value *out of*
  the log rather than asserting something is missing from it. Without it, every absence assertion in
  the file is satisfied by an empty string — and an empty string is exactly what this file gets if
  the `Logger.configure` call is dropped, which is a one-line edit somebody will plausibly make.
  It is deliberately in the **same capture and the same log line** as the assertion it controls,
  rather than in a separate test: a control in another test proves another request logged.
- **Row 4 controls row 2 from the second direction.** Row 3 proves *a* line was captured; row 4
  proves it was *the parameter line for this request*, so a capture polluted by another test's
  output cannot stand in for it.
- **Row 10 controls rows 7, 8 and 9.** `{:keep, []}` — or any bug that filtered unconditionally —
  passes every one of them. Asserting the kept names come back verbatim is what distinguishes "the
  right things are filtered" from "everything is filtered".
- **Row 11 controls the whole file.** It asserts the empty capture explicitly, so the trap is
  documented by a passing test rather than by a comment. If someone later removes the level
  handling, row 11 still passes and rows 2–6 go green-for-nothing — which is why row 3 exists as
  well. The two together are the pair.
- **Row 2 is not a control for anything and is not claimed as coverage.** It is the issue's
  headline case and it is killed by no mutation of this diff. Saying so here is the point.
- **Row 1 is a change-detector, stated as one.** Its job is to make any widening of the allowlist
  fail a test so a reviewer has to look, in the same way `boundary_test.exs` pins the employer
  views' column lists. It proves nothing about behaviour on its own.

## Implementation constraints

- **No new list.** Nothing in `lib/` or `test/` may declare a second copy of `AGENTS.md`'s
  fragments. Issue #42.
- **`config/config.exs`, not an environment file.** The filter must not differ by environment: the
  whole finding is that a filter which is only correct in production is a filter nobody checks.
- The test file writes the seven names out as a literal. It must not read them from
  `Application.get_env` and compare against themselves — `tests-that-certify-nothing.md`, "never
  derive a test's inputs from the constant it is pinning".
- `Logger.configure/1` must be restored in `on_exit`, and the file must be `async: false`, or it
  changes the level under whatever else is running.
- Gates: `mix format --check-formatted`, `mix compile --force --warnings-as-errors` in `dev` and
  `MIX_ENV=prod`, `mix quality`, `mix test`.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 4/5 | HTTP end to end plus the live filter for the three surfaces that have no route yet; the channel `handle_in` site is covered through `filter_values/1` rather than through a real channel, because the wiring is proved once over HTTP and the second site is Phoenix's code |
| Control discipline | 5/5 | the verbatim-value control sits in the same log line as the absence it controls, and the empty-capture case is asserted rather than described |
| Regression protection | 4/5 | four existing capture-bearing files named and re-run; none asserts on parameter output |
| Falsifiability | 4/5 | eleven of thirteen rows name a mechanism whose removal fails them; row 2 names none and says so |
| Risk of a vacuous pass | 5/5 | the file's central hazard is identified, measured three ways, and closed by a control plus an explicit test of the failure mode |

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from explicitly.

### 1. Row 2 *is* killed by a mutation. The brief was wrong about which one.

The brief said the magic-link test "is killed by no mutation of this diff" and listed that as an
honest gap. **Measured, it is killed by M3** — adding `"token"` to the allowlist — which is a
one-word edit somebody would plausibly make while chasing a log line. What is true is the narrower
claim: *deleting this configuration entirely* does not kill it, because Phoenix's own default
covers that one parameter. The two are different statements and only the second one holds.

The residue is worth keeping in mind. Row 2's value is that it pins a **live bearer credential**
end to end over a real redemption; its mutation kill comes from the allowlist, not from the fact
that the credential is real.

### 2. A *sufficiently complete* denylist passes both behavioural tests, and only the shape pin sees it

M2 replaced the allowlist with `["password", "token", "email", "claim_code", "code", "body"]` — the
denylist somebody would write if they read this issue and reached for the other shape. It kills
three tests and **leaves both HTTP tests green**, because it names every parameter they use.

That is not a weakness in the tests; it is the finding restated. The behavioural tests prove *these
parameters are filtered*. Nothing behavioural can prove *the shape fails closed*, because the
difference between the two shapes is only visible on a parameter nobody has written a rule for —
which is, by construction, a parameter no test can name. **Row 1, the shape pin, is the only
assertion in the file that distinguishes them.** The brief filed it as "a change-detector, proves
nothing about behaviour on its own"; that is right, and it undersold why it has to be there.

### 3. The absence is asserted against the parameter *line*, not the whole capture

The brief's rows 2 and 5 both said "absent from the log". Implementation asserts `refute
parameters(log) =~ email` — against the dispatch line alone — and the reason is measured:
**`HospitalityComs.Repo` prints its own bound parameters at `:debug`**, so one `POST /api/log-in`
puts the address into three SQL statements in the same capture:

```
SELECT p0."id", p0."email", … FROM "people" AS p0 WHERE (p0."email" = $1) ["person226@example.com"]
SELECT TRUE FROM "people" AS p0 WHERE (p0."email" = $1) LIMIT 1  ["person226@example.com"]
INSERT INTO "people" ("inserted_at","updated_at","email","id") VALUES … ["person226@example.com", …]
```

`refute log =~ email` over the whole capture is therefore **false**, and would have been written as
a failing test rather than a discovered limitation. `filter_parameters` governs none of that, so
the assertion is scoped to what the mechanism actually controls, and the residue is written into
`AGENTS.md` so nobody reads a filtered parameter line as a promise about the log as a whole.

The token test keeps `refute log =~ token` over the **whole** capture, and the asymmetry is real
rather than an oversight: `people_tokens` stores the SHA-256 digest, so what reaches the SQL line
is `<<157, 146, 56, …>>` and not the credential. Measured both ways.

### 4. `@filtered` carries nine names, not five

The brief listed five. The file also asserts `secret`, `authorization` and `otp` — names from
`AGENTS.md`'s convention list that no route accepts — precisely because the allowlist covers
parameters that do not exist yet, and a sample drawn only from what exists cannot show that.

## Mutation record

Six mutations plus one trap demonstration, each applied to a clean tree, measured against
`test/hospitality_coms_web/parameter_filter_test.exs`, then restored. Every one of the seven tests
is killed by at least one mutation.

| # | Mutation | Killed | Which |
|---|---|---|---|
| 1 | the whole `filter_parameters` block deleted — Phoenix's shipped default applies | 4 | shape pin, filters-what-it-does-not-name, nested, **email over HTTP** |
| 2 | replaced by an equivalent **denylist** naming today's sensitive parameters | 3 | shape pin, filters-what-it-does-not-name, nested |
| 3 | `"token"` added to the allowlist | 3 | shape pin, filters-what-it-does-not-name, **token over HTTP** |
| 4 | `"venue_id"` removed from the allowlist | 4 | shape pin, keeps-verbatim, **both HTTP controls** |
| 5 | the allowlist emptied to `{:keep, []}` — redact everything | 4 | shape pin, keeps-verbatim, both HTTP controls |
| 6 | `with_debug_log/1` stops lowering the primary `Logger` level | 2 | both HTTP tests |

**Mutation 5 is the one that proves the control is a control.** `{:keep, []}` filters every
parameter in the tree and still passes "filters every parameter it does not name" — the assertion a
reader would call the coverage. Only "keeps every parameter it does name, verbatim" separates a
filter that works from one that has stopped discriminating.

**Mutation 6 is the trap, and it was measured directly rather than argued.** A throwaway file
holding the obvious shape —

```elixir
{_c, log} = with_log(fn -> post(conn, ~p"/api/log-in", %{"email" => email}) end)
refute log =~ email
```

— was run twice: once against this branch, and once against the tree with the configuration
**deleted**, i.e. with the bug present and the address printing in full. **It passed both times.**
That is the twenty-second instance of `tests-that-certify-nothing.md`'s generative shape, caught
before it was written rather than after, and it is why every capture in the file reads a value out
of the log before asserting anything is missing from it.

## Revisions made after review
