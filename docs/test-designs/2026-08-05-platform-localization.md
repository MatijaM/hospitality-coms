# Test Design Brief — platform localization: English and Serbian, chosen by domain

Plan: `docs/plans/2026-08-05-001-feat-platform-localization-plan.md`. Origin:
`docs/brainstorms/2026-08-05-platform-localization-requirements.md`. This brief covers all nine
implementation units, because they share one defect class and splitting the brief would split the
controls away from what they control.

Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate", and its subsection "The gate applies to
`client/`". Roughly half this work is under `client/`, so the five client prompts are answered in a
section of their own. Committed alone, first, ahead of every line of production code, so the
ordering is visible in `git log` rather than asserted. Nearest precedents read before writing:
`docs/test-designs/2026-07-30-73-peer-names-client.md` and
`docs/test-designs/2026-07-29-53-filter-credentials-from-logs.md`.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before implementation
began. Recorded here because `AGENTS.md` requires the substitution to be visible in the artifact
rather than inferred from the absence of a review.

## What is being built

Every user-facing string moves out of components and out of the error path into per-locale literal
files. The client builds once per locale and Phoenix serves the bundle matching the request host;
the server resolves the same locale from a request's `Origin` for validation messages, the three
magic-link emails and the profile incompleteness notice.

The defect class this whole unit is exposed to is **a test that passes because the two things it
compares are the same string**. A localization suite is unusually good at producing them: an
English fixture and a Serbian fixture that happen to carry the same value make every fallback
assertion, every locale-selection assertion and every drift assertion pass against a build that
does nothing at all. Three of the five decisions below exist to stop that, and the controls section
names the mutation for each.

## Decision 1 — no fixture in this unit may share a string between locales

Every locale fixture's Serbian value differs from its English value, and neither is a substring of
the other. This is the client gate's third prompt applied to the thing this unit is actually about.

It is not a style preference. A fixture where `en.greeting` and `sr-Latn.greeting` are both
`"Hello"` satisfies: "the Serbian build renders the Serbian string", "the English build renders the
English string", "an unmapped host falls back to English", and "a missing key falls back to
English" — all four, against a build that ignores the locale entirely. #74 shipped exactly this
shape against a different comparison and both preference mutations survived it.

The rule extends to the host fixtures: the two test hosts differ in more than a subdomain, so a
prefix-matching bug cannot pass.

## Decision 2 — the dev marker's absence is asserted against the built artifact, not the module

R9 says the marker is *structurally absent* from a production bundle rather than unreachable. A
test that imports the resolution module and asserts it returns English under a production flag
proves the branch was taken. It does not prove the marker string is gone, and the two are different
claims: Vite's static replacement of `import.meta.env.DEV` is what drops the branch, and a
refactor that reads the mode from a runtime variable instead would keep every module-level test
green while shipping the marker.

So the assertion reads the build output and requires the marker string to appear nowhere in it.
This is the same shape as `HospitalityComs.DemoTest`'s check that no module compiled from `lib/`
calls one compiled from `dev_support/`, and it has the same justification: absence enforced by a
build property needs a test that reads what the build produced.

## Decision 3 — validation messages are translated at the error boundary, and both declaration sites are proved to converge

`HospitalityComsWeb.ErrorEnvelope.changeset_errors/1` is the single traversal, so translation goes
there and the schemas keep emitting English msgids. The claim that makes this worth doing is that a
message declared twice — once on `validate_*`, once on the matching `check_constraint/3` — needs
one catalogue entry rather than two.

That claim is asserted directly rather than assumed: one test drives the changeset path and one
drives the database path for the same rule, and requires the same localized string out of both. If
the two declarations ever drift, that test fails, which is what replaces the agreement problem the
origin document expected to need a mechanism for.

The messages that currently interpolate a bound at compile time cannot be msgids, so they move to
the `%{count}` form. `test/hospitality_coms/constant_agreement_test.exs` reads CHECK constraints
back out of `pg_constraint` and compares them against module constants — it is the existing net
under this change and is run first, not last.

## Decision 4 — the static-serving tests use a fixture tree, not a real client build

U8 is Elixir and its tests must not require Node. So they point `Plug.Static` at a fixture
directory holding two locale subtrees with distinguishable index files, rather than at
`priv/static` populated by a real build.

The cost is real and is paid in U9: a fixture proves the host-to-bundle routing and proves nothing
about whether the build puts files where the routing expects them. U9's CI step is what closes
that, by building for real and exercising the same paths.

## Decision 5 — the email assertion reads the delivered message, not the plug

`Gettext.put_locale/1` is process-scoped and mail delivery is synchronous, which is what makes R13
work. A test asserting that the plug set the locale would pass even if delivery later moved to a
job and the emails silently reverted to English.

So the assertion is on the delivered `Swoosh.Email`'s subject and body. This is the shape
`docs/solutions/logic-errors/mechanisms-that-stop-working-while-reporting-success.md` describes: an
assertion on the mechanism rather than on the outcome goes green while the outcome stops happening.

## Acceptance criteria

1. A host named in the mapping resolves to its locale on both the Elixir side and the client build
   side, from the same file. (R2, R3)
2. A host the mapping does not name resolves to the default locale. (R4, AE3)
3. A key present in both locales renders the target locale's string in that locale's build. (R8)
4. A key present only in English renders English in a production build of the target locale. (R9,
   AE1)
5. The same key renders a visibly wrong marker in a development build. (R9, AE2)
6. The marker string appears nowhere in a production build's output. (R9)
7. A key present in the overlay but not in English is reported and not rendered. (R7, AE7)
8. The built page shell's language attribute and title match the built locale. (R10)
9. No user-facing English literal remains inline in a client component, enforced by a check that
   fails on each planted violation form. (R5)
10. A request whose `Origin` names a mapped host resolves to that locale; one with no `Origin`
    resolves to the default without raising. (R11, AE5)
11. A rejected write returns its `fields` messages in the request's locale while its `code` is
    unchanged. (R12, AE6)
12. A length violation renders the correct Serbian form at counts of 1, 3 and 5. (R12)
13. The changeset path and the database CHECK path for one rule return the same localized string.
    (R12)
14. A log-in requested from the Serbian domain produces a Serbian subject and body, with a link
    naming the Serbian domain. (R13, R15, AE4)
15. An asset request is served from the bundle matching its host, and from the default bundle when
    the host is unmapped. (R16, R17)
16. A client-side route, including the magic-link route, is answered with that bundle's app shell.
    (R21)
17. An unknown path under the API prefix still returns the JSON error envelope. (R21)
18. An edit confined to translated values leaves the build green. (R18)
19. A new English key with no translation leaves the build green and appears in the report. (R19,
    R20)

## Edge cases

- A host carrying a port, and a host differing only in letter case.
- A mapping whose default locale is absent from its own locale list — refused at load.
- An empty overlay: every key falls back and every key is reported.
- An `Origin` header that is malformed rather than absent.
- A non-GET request to an unrouted path, which must not receive the app shell.
- A request for a path that exists in one bundle and not the other.
- Serbian counts at 1, 2, 3, 4, 5, 11, 21 — the boundaries where its three forms change.
- A locale file containing a key whose value is the empty string, which is a translation decision
  rather than a missing key.

## Regression risks, by path

- `client/src/**/*.test.tsx` and `client/src/**/*.test.ts` — every surface test asserts rendered
  text. U4 changes where strings come from and must not change their values; any reworded string
  breaks the test that names it. Highest-volume risk in the unit.
- `client/src/app/failure-message.test.ts` and the four `refusal-message.test.ts` files — the
  switches stay, only the returned strings move. A switch that stops being exhaustive stops failing
  the build when an error code is added, which is a capability loss no test would report.
- `test/hospitality_coms_web/error_envelope_test.exs` — U6 changes the traversal these assert on.
- `test/hospitality_coms/constant_agreement_test.exs` — U6 edits messages whose literals this file
  reads back out of `pg_constraint`.
- `test/hospitality_coms_web/controllers/session_controller_test.exs` — U7 changes email bodies,
  and this file makes ten `POST /api/log-in` calls at one pinned instant, so it is also the file
  that fails first if the new plug interferes with the rate limiter's window.
- `test/hospitality_coms_web/controllers/error_json_test.exs` — U8's fallback must leave the 404
  shape untouched.
- `test/hospitality_coms_web/controllers/*_test.exs` generally — any test asserting a validation
  message's exact English text.
- `.github/workflows/ci.yml` — U9 edits it, and three properties must survive: the `--partitions`
  prohibition, the Postgres 17 service image, and the superuser role.

## Test matrix

`Fails without` names the mechanism whose removal or inversion makes that row fail. Every row was
chosen so the named mutation is applicable — a row I could not mutate is a row that certifies
nothing (`docs/solutions/test-failures/tests-that-certify-nothing.md`).

### U2 — `test/hospitality_coms/locales_test.exs` and `client/src/i18n/locale.test.ts`

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| A1 | a mapped host | resolves to its locale | the host lookup |
| A2 | an unmapped host | resolves to the default | the fallback clause |
| A3 | a mapped host in different letter case | same locale as A1 | case normalisation |
| A4 | a mapped host carrying a port | same locale as A1 | the port being stripped |
| A5 | a mapping whose default is absent from its locale list | refused at load, message naming the file | the load-time validation |
| A6 | every host in the artifact, read from both sides | the two readers agree | either reader being pointed at a copy rather than the artifact |

A6 is the drift control and is the reason the artifact exists. It is written to fail if either
reader is given its own literal.

### U3 — `client/src/i18n/copy.test.ts`

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| B1 | key in both locales, Serbian build | the Serbian string | the overlay being applied |
| B2 | same key, English build | the English string | the locale selecting the overlay |
| B3 | key only in English, production Serbian build | the English string | the fallback |
| B4 | same key, development Serbian build | the marker | the build-mode branch |
| B5 | production build output scanned for the marker string | absent everywhere | static replacement dropping the branch |
| B6 | key in the overlay that English lacks | not rendered, and named in the report | the key set coming from English |
| B7 | built shell per locale | language attribute and title match the build | the shell substitution |
| B8 | empty overlay | every key English, every key reported | — (control, see below) |

B1 and B2 together are what require Decision 1: with a shared fixture string they are the same
assertion written twice.

### U4 — `client/src/i18n/no-inline-copy.test.ts`

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| C1 | synthetic source: bare string as JSX text | flagged | the JSX-text rule |
| C2 | synthetic source: string in a rendered attribute | flagged | the attribute rule |
| C3 | synthetic source: string returned from a helper a component renders | flagged | the helper rule |
| C4 | synthetic source: `className`, test id, route path, object key | not flagged | the exclusion list being correct rather than empty |
| C5 | the real tree after extraction | passes | extraction being complete |
| C6 | catalogue keys versus keys referenced by surfaces | no unreferenced key | the key-set comparison |

C1–C4 are the "attack your own check" step from
`docs/solutions/best-practices/enforce-a-convention-structurally-then-attack-the-check.md`. C4 is
what stops the check being satisfied by flagging everything.

### U5 — `test/hospitality_coms_web/locale_test.exs`

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| D1 | `Origin` naming a mapped host | that locale is in force | the header read |
| D2 | no `Origin` | default locale, no raise | the absent-header clause |
| D3 | `Origin` naming an unmapped host | default locale | the fallback |
| D4 | malformed `Origin` | default locale, no raise | the parse guard |
| D5 | the incompleteness notice under each locale | two different strings | the notice being a catalogue lookup |
| D6 | the notice's arity | still zero | — (control) |

### U6 — `test/hospitality_coms_web/error_envelope_test.exs`

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| E1 | blank required field, Serbian locale | Serbian message | the traversal's lookup |
| E2 | same, English locale | English message | — (control for E1) |
| E3 | E1 and E2 responses | `code` identical | the code not being translated |
| E4 | length violation at counts 1, 3, 5 | three distinct Serbian forms | the plural lookup and the catalogue header |
| E5 | message with no catalogue entry | English, not the raw msgid | the fallback |
| E6 | one rule via changeset and via database CHECK | same localized string | the two declarations sharing a msgid |

E4 is the row that fails on a wrong `Plural-Forms` header, which nothing else in the suite would
notice.

### U7 — `test/hospitality_coms_web/controllers/session_controller_test.exs`

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| F1 | log-in from the Serbian domain | delivered subject and body are Serbian | the locale reaching the notifier |
| F2 | same | the link's host is the Serbian domain | the per-locale base URL |
| F3 | log-in with no `Origin` | default locale and default base URL | the fallback |
| F4 | responses across locales | identical status and body | the merged door being untouched |
| F5 | production config missing the per-locale value | boot raises, naming the variable | the raise |

F4 matters more than it looks: the log-in door answers the same for a known and an unknown address
on purpose, and a locale-dependent response body would be a new enumeration oracle.

### U8 — `test/hospitality_coms_web/static_test.exs`

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| G1 | asset request on the Serbian host | served from the Serbian fixture subtree | the host-to-path rewrite |
| G2 | same path on the English host | served from the English subtree | — (control for G1) |
| G3 | asset request on an unmapped host | default subtree | the fallback |
| G4 | a client-side route | 200 with the app shell | the fallback plug |
| G5 | the magic-link route specifically | 200 with the app shell | the fallback plug |
| G6 | unknown path under the API prefix | JSON error envelope, not the shell | the fallback's prefix scoping |
| G7 | unknown socket path | unchanged | the prefix scoping |
| G8 | non-GET to an unrouted path | not the shell | the method guard |

G5 is named separately from G4 because it is the one whose failure breaks log-in outright, and a
reviewer scanning the file should see it by name.

### U9 — `client/src/i18n/report.test.ts` and CI

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| H1 | edit confined to a translated value | build green | — (control) |
| H2 | new English key, no translation | build green, key in the report | the tolerant fallback |
| H3 | the report | names every untranslated key and no translated one | the report's diff |
| H4 | the report per locale | emitted separately | per-locale invocation |
| H5 | real Serbian catalogue at counts 1, 3, 5 | three correct forms | the catalogue's header |

## Controls, listed explicitly

Every assertion below could pass vacuously; each is paired with the one that fails when it does.

| Assertion at risk | Control |
|---|---|
| B3/B4 fallback rows | B1/B2, proving the two locales render differently at all — without them a build ignoring the locale passes both |
| B5, "the marker is absent from the production build" | B4, proving the marker exists in some build; an absence assertion against a build that emitted nothing passes |
| B8, the empty-overlay row | B1, proving a non-empty overlay does something |
| C5, "the real tree passes the check" | C1–C3, proving the check can fail at all |
| C4, "these forms are not flagged" | C1–C3, proving the check is not simply inert |
| D5, two notice strings | D2, proving the default locale is reachable, so "different" is not "one of them is empty" |
| E1, the Serbian message | E2, the English message from the same code path |
| E6, "both declarations converge" | E1, proving translation happens at all |
| G1, Serbian bundle served | G2, the same path on the other host — without it, a hardcoded subtree passes |
| G6, the API 404 is untouched | G4, proving the fallback fires for something |
| H3, the report's contents | H1, proving a fully translated locale reports nothing |
| Any "no inline English" or "marker absent" absence assertion | the corresponding planted-violation row in the same file |

## The five client prompts, answered

**Which render state is being claimed?** The copy itself is synchronous — there is no fetch behind
a string, so the four-state predicate the prompt was written for does not arise in U4. It arises
twice elsewhere in a disguised form. R9's two *build* modes render identically to a test that only
imports the module, which Decision 2 addresses by reading the build output. And U8's fallback has
three states — asset found, asset absent, path under the API prefix — of which the second and third
are the pair that looks identical until the API's 404 shape is asserted (G6).

**What proves the fixture could have failed?** The controls table above, row by row. The two
highest-risk absence assertions in this unit are "the marker appears nowhere in the production
build" and "no inline English remains", and both are the shape that passes against a build or a
scan that produced nothing at all. Each is paired with a positive row in the same file.

**Can the fixture distinguish the two things being compared?** This is the unit's central risk and
Decision 1 is the answer. Locale fixtures never share a string across locales, and the two test
hosts differ by more than a subdomain. Stated as a rule rather than left to each test's author,
because the failure is invisible: a suite built on shared fixture strings is fully green against a
build that ignores the locale.

**Does the persisted shape change?** No, and the reason is worth writing down rather than leaving
as an absence. The locale is derived from the domain on every request and every build, so nothing
about it is stored — no `localStorage` key, no cookie, no column. `client/src/features/rooms/room-store.ts`
is untouched, so the decoder that drops the whole array on one bad row is not exercised by this
change. If a language switcher is ever added, this answer changes and the store gains a field.

**Would a fake transport see this at all?** Two places, and both push assertions down a level.
Surface tests fake the API client, so nothing at the surface level can prove the `Origin` header is
sent or read — D1–D4 sit at the plug level against a real conn. And the email's language is a
property of the delivered message rather than of any client call, so F1 asserts on the `Swoosh.Email`
Swoosh captured, not on a response body. A surface test would see neither and would go green.

## Implementation constraints

- `AGENTS.md`: every public function carries a `@spec`; error atoms are enumerated rather than
  `term()`.
- The clock authority check: the new plug reads no clock and must not appear in `.credo.exs`'s
  `:boundary_modules`. D6's sibling control asserts this.
- `mix format --check-formatted` reads `.formatter.exs`, whose inputs are `{config,dev_support,lib,test}/**`
  — a new top-level directory would sit in a blind spot.
- `mix compile --warnings-as-errors` runs under both `:test` and `:prod` in CI. Nothing added here
  may be compiled only in one.
- The client's exhaustive switches are load-bearing: extracting their strings must not turn a
  `switch` over a union into a map lookup, or the build stops failing when an error code is added.
- `priv/static` must be gitignored for build output while `priv/locales.json` stays tracked.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Requirements coverage | 5/5 | every R1–R21 has at least one row; AE1–AE7 each map to a named row |
| Control discipline | 5/5 | twelve pairings listed; the two absence assertions most likely to be vacuous are each paired |
| Mutation applicability | 4/5 | every row names a mutation; H1 and B8 are controls whose own mutation is the row they protect |
| Edge-case reach | 4/5 | Serbian plural boundaries and host-shape variants covered; a third locale is out of scope and untested by design |
| Risk naming | 5/5 | eight existing test paths named, with the reason each is at risk |

## Revisions made during implementation

_(appended during implementation; the sections above are not edited to agree with what shipped)_
