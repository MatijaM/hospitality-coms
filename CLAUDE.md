# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is the authoritative standards document — type specs, testing posture, migration rules, git workflow. This file covers only what is specific to the current state of the tree.

## Status

Phoenix 1.8.9 application, scaffolded with `--binary-id --database postgres`, now a JSON API. The HTML layer existed only so `mix phx.gen.auth` would run — it refuses on a `--no-html` app — and U2 removed it: no browser pipeline, no LiveView, no templates, no asset pipeline, and none of the corresponding deps. `Phoenix.Component`, `~H`, and `.heex` are not available; do not reach for them.

The plan being executed is `docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md`. Read the unit you are working on plus its Key Technical Decisions before changing anything time- or boundary-related.

## Toolchain

`.tool-versions` pins `elixir 1.20.2-otp-28` / `erlang 28.5.0.3`. Both are installed, so `mix` works with no prefix.

Note the asdf naming: the Elixir install is `1.20.2-otp-28`, not `1.20.2` — a bare version never resolves and makes every `mix` invocation fail with "No version is set for command mix".

The plan asked for Elixir 1.20.2 on OTP 29. This is 1.20.2 on OTP 28, which Elixir 1.20 supports (27–29) and which delivers the point of the pin: off the 1.19 branch, which is security-patches-only. Moving to OTP 29 is a separate, deliberate step.

## Commands

```bash
mix setup                         # deps, database
mix ecto.setup                    # create, migrate, seed
mix phx.server                    # dev server on 4000
mix test test/path/file_test.exs  # PR-scoped test run (preferred locally)
mix quality                       # credo --strict + dialyzer
mix compile --warnings-as-errors
```

In dev, `/dev/mailbox` is the only way to read a magic link — nothing renders one.

## Layout worth knowing

- `lib/` — the application. Compiled in every environment, including `:prod`.
- `dev_support/` — compiled only in `:dev` and `:test`. Holds `HospitalityComs.Clock.Offset` and the project's Credo checks. Excluding this path from the production build is what makes the offsettable clock structurally absent from production rather than present and guarded; do not move anything from here into `lib/`.
- `credo_checks` does not exist; project checks live under `dev_support/hospitality_coms/credo/`.

## Time

`HospitalityComs.Clock` is the only source of the current instant. `HospitalityComs.Credo.Check.ClockAuthority` enforces it:

- `DateTime.utc_now/*` is flagged anywhere outside the `HospitalityComs.Clock` namespace.
- `Clock.now/0` is flagged outside the modules listed in the check's `:boundary_modules` parameter in `.credo.exs`. That list holds four entries: `HospitalityComsWeb.PersonAuth` (the HTTP boundary), the two Oban workers `Workers.ExpireEngagement` and `Workers.EngagementSweeper` — one job attempt is one unit of work, and a retry is a new one that correctly reads the clock again — and `HospitalityComsWeb.ChannelAuth`, the channel boundary U7 added. When you build another, add it there rather than working around the check.

  `ChannelAuth` is deliberately **one** entry for the seven modules that would otherwise need one: two sockets, four channels, and `RoomChannel`, which the two room channels share. Naming them all would turn the allowlist into an inventory of whatever happens to call the clock. Everything on the transport takes its instant from a scope `ChannelAuth` built.

Everywhere else, the instant arrives on the scope struct — `%HospitalityComs.Accounts.PersonScope{person: _, now: _}`, assigned as `:current_scope` by `PersonAuth.fetch_person_scope/2`, or `%HospitalityComs.Accounts.EmployerScope{venue_id: _, now: _}`. `EmployerRepo`'s transaction wrapper takes the instant off the scope for the same reason; a repo is not a unit of work, so it is not a boundary module.

`Ecto.Query.ago/2` and `from_now/2` are banned for the same reason `DateTime.utc_now/0` is: they expand to `DateTime.utc_now()` inside the query macro, where the offsettable clock cannot move them. `ClockAuthority` flags the call itself, both imported and fully qualified, because by expansion time it is too late to see. Compare against an instant taken from the scope.

`HospitalityComs.Accounts.Person` stamps `inserted_at`/`updated_at` explicitly too — Ecto's `timestamps()` autogenerate reads the wall clock from inside Ecto, which is also out of the check's reach.

## Database

Two repos, one database.

- `HospitalityComs.Repo` — the application's own role. The only repo in `:ecto_repos`, so migrations run through it alone.
- `HospitalityComs.EmployerRepo` — assumes the Postgres role `employer_role` via `after_connect`. Every read goes through `EmployerRepo.scoped_transaction/2`, which writes `app.employer_id` and `app.now` transaction-locally; an operation outside it raises `EmployerRepo.UnscopedError`, and a query reaching a person-zone table raises `EmployerRepo.ZoneViolationError` before Postgres is asked. Opening the wrapper again inside itself for a *different* employer raises `EmployerRepo.NestedScopeError`: there is no savepoint between the two, so the inner `set_config` would stay in force after the inner call returned. An identical scope nests freely and writes nothing.

PostgreSQL 17 is the minimum. `Zones.employer_privileges/1` asks about `MAINTAIN`, which does not exist before 17.

Neither guard is the boundary, and the boundary is not below them. Three escapes, each pinned by a test in `boundary_test.exs` rather than only described:

- Raw `EmployerRepo.query/3`, `query!/3`, `query_many/3` and `to_sql/3` go to `Ecto.Adapters.SQL` without `default_options/1`, so the unscoped guard never sees them. That exemption is load-bearing — `write_settings/1` is a raw query issued before the scope is registered — so it is documented, not closed.
- A raw statement is not an `Ecto.Query`, so the zone guard never sees it either. Postgres refuses it.
- `RESET ROLE` returns the connection to the login role, which holds everything. The grant tier is therefore defeatable from the BEAM exactly as the guards are. The boundary is strong against *accident*, not against a caller who means to get out; closing this needs a dedicated login role for `EmployerRepo`, which is filed separately.

`employer_role` and `person_role` are created by `priv/repo/migrations/*_create_postgres_roles.exs`. Roles are cluster-global, not database-local; a test that drops one must run inside the sandbox transaction so it rolls back.

Grants are database-local while roles are not, so one privilege granted to `employer_role` in *any* database on the cluster makes `DROP ROLE employer_role` fail in every other — including the rollback `PostgresRolesTest` asserts on. `*_grant_zones.exs` deliberately creates no such dependency; `*_grant_employer_zone.exs` does, because the employer zone cannot be read without one.

**Consequence, and it will bite you.** `PostgresRolesTest` rolls every grant migration — `grant_employer_zone`, `grant_engagement_zone`, `grant_room_zone`, `grant_peer_zone` — down before it rolls the roles migration down, which is the real order Ecto uses. Every unit that adds a grant migration adds an entry to that list, `grant_peer_zone` included even though it grants nothing: the rule is "every grant migration", and a list with a judgement call in it is a list somebody gets wrong later. That fixes *this* database only. If you run `mix ecto.migrate` against `hospitality_coms_dev` (or any other database on the same cluster), its grants make `DROP ROLE employer_role` fail in the test database too, and no connection to the test database can revoke them. `PostgresRolesTest` detects that case and names the offending databases; the fix is to roll the grant migrations back there, or drop the database.

Grant explicitly, per table, per privilege. `ALTER DEFAULT PRIVILEGES` is the one thing that must never be used: it survives `REVOKE ALL ON TABLE` and is inherited by every table created afterwards, so it would hand `employer_role` person-zone tables that do not exist yet. `boundary_test.exs` asserts `pg_default_acl` names no role at all, with a control that grants one and watches the check catch it.

## Zones

`HospitalityComs.Zones` classifies every Ecto schema as person zone, employer zone, or shared, and `ZonesTest` fails on any schema in none of them. The shared zone has exactly one member and always will: `engagements`, the single bridge. U8's three peer tables are person zone and had no alternative — see **Peer graph** below. Adding a table is not finished until it is classified. Table names derive from `__schema__(:source)`; do not write a second list. That is nil for an embedded schema, and `Zones.tables/1` raises on it rather than handing Postgres a NULL the privilege sweep would silently skip.

The sweep asks `has_table_privilege` *and* `has_any_column_privilege`: a column grant is invisible to the first. `GRANT SELECT (email) ON people TO employer_role` must fail the suite, and so must `GRANT SELECT ON people TO employer_role`.

The boundary's proof suite is `test/hospitality_coms/boundary_test.exs`, with `boundary_lifetime_test.exs` holding the parts that cannot be asserted inside the sandbox — there, `EmployerRepo`'s transaction is a savepoint inside the test's own, so a `SET LOCAL` survives its commit and the production lifetime is not reproduced. Measured: with the wrapper writing session-level settings instead, the sandboxed file still passes everything and the non-sandboxed one fails.

`employer_role`'s lack of privilege on `people` is Postgres default-denying as much as it is the `REVOKE`. Every assertion in that suite that could pass for that reason carries a control that fails when it does; keep that property when extending it.

## Employer zone

`venues`, `employer_grants` and `shift_types` from `*_create_venues.exs`, reached only through `HospitalityComs.Venues`; `invitations` and `attested_entries` from `*_create_engagements.exs`, reached only through `HospitalityComs.Engagements`.

**No employer-zone table may name a person.** Not `person_id`, not `created_by`, not a foreign key to `people` under any name — `boundary_test.exs` asserts it against `pg_constraint`, and the employer zone being non-empty is what stopped that rule being vacuous. A person creates a venue and no row records which person: `engagements` is the single bridge and carries `grant_id` referencing `employer_grants (id, venue_id)`, so the association is made from the person's side. Arrows point *into* the employer zone, never out. `boundary_test.exs` now also asserts the positive form — `engagements` is the *only* table outside the person zone with a foreign key to `people`.

**Venue-to-venue tenancy has a database tier.** `*_enable_employer_zone_row_level_security.exs` and `*_enable_engagement_row_level_security.exs` put row-level security on all six tables — `venues`, `employer_grants`, `shift_types`, `invitations`, `attested_entries`, and the bridge itself, which is one of the six rather than an addition to them — with one policy each — `USING` and `WITH CHECK`, both on the row's venue equalling `app_current_employer_id()`. Before it, isolation rested entirely on `Venues` pinning `venue_id` by hand, and one `EmployerRepo.update_all(EmployerGrant, ...)` with no filter passed both guards, passed Postgres, and revoked every grant in the database.

It is deliberately **not** `FORCE`d. The tables are owned by the application's login role, so `Repo`, the migrator and the seeds bypass the policies while `employer_role` is bound by them; FORCE would bind the owner too, and the predicate raises wherever `app.employer_id` is unset. Policies are granted to `PUBLIC` rather than `TO employer_role`, so they write no `pg_shdepend` row. This is not KTD3 reversed — KTD3's view-not-RLS decision is about the per-row hidden-entry rule and stands.

**Consequence for rollbacks.** The policies depend on `app_current_employer_id()`, which `grant_zones` drops with `RESTRICT` on purpose. Rolling `grant_zones` back without rolling this migration back first now fails loudly with `dependent_objects_still_exist` — which is that `RESTRICT` doing its job, and `boundary_test.exs` both rolls in the right order and pins the wrong one.

Every employer-zone table other than `venues`, and `engagements` too, carries `venue_id` and a unique index on `(id, venue_id)`, both asserted structurally. The composite index looks redundant next to the primary key and is what makes a composite foreign key possible — without it a later table can only reference `id`, and a row at venue A can point at a row belonging to venue B. `employer_grants.granted_by_grant_id` already uses one; it is `MATCH SIMPLE` rather than `MATCH FULL` because the founding grant has no parent and `venue_id` is `NOT NULL`, so MATCH FULL would reject the one row every venue must have. The rule is **MATCH FULL unless a column of the key is nullable**, and `boundary_test.exs` asserts it in that derived form plus the inventory it quantifies over — four keys are `MATCH SIMPLE` (`employer_grants.granted_by_grant_id` and `revoked_by_grant_id`, `invitations.grant_id`, `engagements.grant_id`) and three are `MATCH FULL`. Writing the inventory out is what found `revoked_by_grant_id`, which U4's own documentation does not mention.

`EmployerScope`'s tenancy field is `venue_id`, because that is what it holds: there is no `employers` table and an employer session is scoped to a venue. The Postgres session setting is still `app.employer_id` and the SQL function is still `app_current_employer_id()` — they are literal strings written by a committed migration, and renaming them would be a schema change bought for a nicety.

`EmployerScope` also gained `grant_id`. `for_employer/2` builds a scope with tenancy and no authority — enough for `EmployerRepo` and for U9's per-employer view — and `for_grant/3` builds one with both. Every `Venues` function *other than* `create_venue/2` heads on `grant_id` being a binary, so a grantless scope is refused by function clause, and the grant is then resolved against the database on every call: live at the scope's instant, and belonging to the scope's venue. Nothing caches it. `create_venue/2` is the exception, and heads on a `PersonScope`: the grant it acts under does not exist until it writes it.

`Venues.revoke_grant/2` refuses the venue's last live grant (KTD17, R22) and takes the venue's live grants under `FOR UPDATE`, ordered by `(granted_at, id)`, before counting — the acting grant is resolved out of that locked set rather than by a separate read in front of it. `venues_concurrency_test.exs` is not sandboxed and proves the lock matters: without it, two concurrent revocations of two grants both succeed and orphan the venue.

A survivor only counts if it carries no revocation at all, not merely if it is live at this instant: a grant revoked at 13:00 is live at 12:00, and counting it at 12:00 orphans the venue from 13:00. A grant that already carries a revocation is `{:error, :not_found}` whichever instant asks.

What a grant may revoke is itself and its transitive descendants through `granted_by_grant_id`, walked with a recursive CTE so that a descendant hanging off an already-revoked link is still reachable. Everything else — an ancestor, a peer, another venue's grant, an id that names nothing — is `{:error, :not_found}`, so the refusal enumerates nothing. Revocation is **not** transitive in the other direction: closing a grant leaves the grants it issued live.

## The bridge

`engagements` is the single crossing between the zones (KTD2) and the only column anywhere outside the person zone that names a human. It is classified `:shared`, not `:employer` — the distinction is what lets the employer zone's "no foreign key to `people`" rule be absolute. Everything is reached through `HospitalityComs.Engagements`; `Engagements.Records` owns every query.

**Three callers, three roles, and the claim is none of them.** An employer session issues invitations, renews and ends engagements, and lists the venue's own, through `EmployerRepo` under a grant resolved on every call (`Venues.fetch_acting_grant/1`, made public in U5 so the check is not duplicated). A person lists their own engagements and attested entries through `Repo`, filtered by `person_id`. The **claim** runs as the application's own role under a `PersonScope`: it consumes an invitation, writes the bridge row, writes an attested entry `employer_role` holds no privilege to write, and enqueues the expiry job — no session on either side holds the privileges for all four.

**Activeness is derived.** `starts_at <= t < ends_at`, half-open, nothing stored. The table keeps a `period tstzrange GENERATED ALWAYS AS (tstzrange(starts_at AT TIME ZONE 'UTC', ends_at AT TIME ZONE 'UTC', '[)')) STORED` for the exclusion constraint alone; queries use the two endpoints. `AT TIME ZONE 'UTC'` is what makes the expression IMMUTABLE enough for a generated column.

**Three races, three different guards, and none covers another.**

- Two people redeeming one code produce engagements for *different* people, so nothing overlaps and the exclusion constraint is silent. The guard is a conditional `UPDATE` requiring exactly one affected row as the **first** `Ecto.Multi` step, with a unique index on `engagements.invitation_id` underneath. The loser gets `{:error, :consume, :already_claimed, _}`.
- Two overlapping terms are `engagements_no_overlap`, an `EXCLUDE USING gist` over `(person_id, venue_id, period)` needing `btree_gist` (its own earlier migration). It is **named**, and `Engagement` declares a matching `exclusion_constraint/3`; without the pair the violation raises through the transaction.
- Two concurrent renewals do not conflict with themselves, so `optimistic_lock(:lock_version)` is what makes the loser `{:error, :stale}`.

`engagements_concurrency_test.exs` proves all three are load-bearing by parking both racers on one Postgres row lock. **Build the racer tasks inside the barrier's closure** — `Task.async/1` starts a process immediately, so a list built at the call site races the barrier itself and the file flakes about one run in three.

**The expiry worker writes nothing to `engagements`.** It re-derives activeness and broadcasts only when false, so a job scheduled for an upper bound a renewal has since moved is inert — which is also why nothing has to cancel one. It could not enqueue atomically from a renewal anyway: renewal runs inside an `EmployerRepo` transaction and Oban writes through `Repo`, so a job inserted there would commit even if the renewal rolled back. Only the claim enqueues. `ExpireEngagement`'s args carry `{engagement_id, venue_id, ends_at}` and no person; `ends_at` is a uniqueness discriminator the worker never reads, so a renewal produces a different job while two sweeps over one unrenewed engagement produce one.

**The revocation broadcast is best-effort and says so.** `Phoenix.PubSub.broadcast/3` can answer `{:error, term()}`; `Engagements` logs it and answers `:ok` rather than propagating, because the revocation is the rejoin `join/3` refuses (KTD8) and this message is only the nudge that makes an already-powerless socket notice. Failing `end_engagement/2` over a broadcast would roll back a term that is genuinely closed in order to report that nobody was told. `Oban.insert/2` in the claim's Multi has the same shape: under advisory-lock contention it answers `{:ok, job}` with `conflict?` set and nothing persisted, so a claim can report success for an announcement that does not exist. Left as-is on purpose — the sweeper's moving window picks it up on the next tick, which is what the window is for.

**KTD17 is enforced from both sides and neither rule changed.** `Venues.revoke_grant/2` still refuses the venue's last live grant *row*; `Engagements.end_engagement/2` refuses its last active *grant-holding engagement*, under `FOR UPDATE` on the locked set. Folding them together would make a venue whose sole manager's engagement expired both unadministrable and revocable.

**"Holding an authority" means a grant that is live**, not a `grant_id` that is set. An engagement whose grant was revoked is neither a survivor that lets the real manager be ended nor a target that can never be ended itself; `Records.decision_set/4` reuses `EmployerGrant.live_at/2` so "live" cannot come to mean two things. It is a subquery in `where` rather than a join, because `FOR UPDATE` over a join locks `employer_grants` too, in an order `Venues.revoke_grant/2` does not share. `claim_invitation/2` asks the same question again in its own Multi step (`:conferrable`), because an offer is good for as long as its code is and the grant it confers can be revoked in between.

`end_engagement/2`'s **target set is "the term has not closed"**, one state wider than active, and it closes at the later of the caller's instant and the engagement's own `starts_at`. So an engagement claimed before its term opens can be ended, producing `ends_at == starts_at` — the empty range, active at no instant and overlapping nothing, so the person's dates are free again. Before that it was `:not_found` while still occupying the exclusion constraint for the whole term, so a claim made in error reserved somebody's dates and nobody could take it back. The widening is on the ending path **alone**: `list_engagements/1`, `fetch_engagement/2` and `renew_engagement/3` all still answer on `active_at/2`. An already-closed term, another venue's engagement and an id that names nothing are all still `:not_found`, so the refusal enumerates nothing.

**Oban** is configured in `config/config.exs` with a five-minute cron sweep and `Oban.Plugins.Pruner` at seven days, and `config/test.exs` sets `testing: :manual` — no queue runs, no plugin ticks, and every worker in the suite is invoked by `Oban.Testing.perform_job/2`. `oban_jobs` and `oban_peers` are in no zone; `boundary_test.exs` names them in its infrastructure exclusion list and asserts `employer_role` holds nothing on either.

**Three numbers that are a set, not three independent settings.** `ExpireEngagement`'s uniqueness is `period: :infinity` over `Oban.Job.states() -- [:discarded, :cancelled]`; `EngagementSweeper` looks back one day; the pruner keeps seven.

- The two exclusions are what make the sweeper a backstop. Spanning *every* state — which `Oban.Job.states()` does — means a job that exhausted its attempts suppresses its own replacement for ever, and suppresses the sweeper's identical insert too.
- `:completed` is deliberately **kept**, which is where this parts company with Oban's `:incomplete` shorthand. Under `:incomplete` a finished announcement stops suppressing as well and every expiry inside the sweep's window is re-announced on every tick. There is a test for each direction.
- The lookback must stay comfortably shorter than the pruner's `max_age`: the completed announcement is what stops the re-announcement, and pruning it while the term is still inside the window would produce exactly that.

**The sweep is a window, not a floor.** `Engagements.list_expired/3` takes `(instant, since, limit)`, filters `since < ends_at <= instant` and orders `desc: ends_at, asc: id`. Filtering on `ends_at <= instant` alone under a limit pins the sweep to the same oldest rows for ever once more than `batch_size/0` engagements have ended — it keeps running, keeps reporting success, and never reaches a term that closed this morning. The index that serves it is `(ends_at, id)`; a `venue_id`-led one cannot, because the sweep is scoped to no venue. **Assumption on the record:** a term that closed more than a day ago is never swept again, which costs nothing because correctness never depended on the announcement.

**Oban's staging query is bound to real wall-clock time and `HospitalityComs.Clock` does not reach it.** Oban's engine asks `scheduled_at <= DateTime.utc_now()` inside its own code. So advancing `Clock.Offset` changes every membership query in the application *instantly* while a scheduled expiry announcement still waits for real time to arrive — and skipping that wait is exactly what the offsettable clock exists for. The suite steps around it by running workers through `Oban.Testing.perform_job/2`. **U11's demo controls must drive the sweep and the worker directly rather than advancing the clock and waiting for the queue.** Do not try to make Oban clock-aware to fix this.

**Three test files are not sandboxed:** `engagements_test.exs`, `engagements_concurrency_test.exs` and `workers/engagement_sweeper_test.exs`. All three call `EngagementsFixtures.real_connections/0`. The claim spans both repos' connections, and under the sandbox those are two transactions that cannot see each other's rows. They commit for real and purge on a `u5-venue` / `u5-person` prefix before and after each test. That is also why `boundary_test.exs` asserts the bridge's row-level security structurally and leaves the behaviour to `engagements_test.exs`.

**A claim code's lifetime is bounded.** `Invitation.max_code_validity_in_days/0` is fourteen days, the same bound `PersonToken.session_validity_in_days/0` puts on the other bearer credential in the tree, enforced in the changeset and by `invitations_code_expiry_within_bound`. There is still no way to withdraw a code early; the bound is what stops one outliving the venue's interest in it.

## Rooms and rosters

`shift_rooms`, `room_messages` and `roster_entries` in the employer zone, `venue_room_suspensions` in the person zone — the first table added there since U2. There is no `venue_rooms` table and no `shifts` table: a venue room is derived from a venue, a shift room *is* the shift. Nothing stores membership and no job maintains it (KTD6b); every membership answer is a query over periods, and moving the instant changes it with nothing having run.

**The venue room's roll is the venue's active engagements, suspensions included, and that equality is KTD18.** `Records.venue_room_members/2` deliberately does *not* apply `unsuspended/2`, so it returns the same set `Engagements.list_engagements/1` already answers with. A manager is a worker too — they hold an engagement like anybody else — so one caller holds an employer scope and a person scope at the same venue; a roll that subtracted suspensions would differ from `list_engagements/1` by exactly the opt-out set, and the invisibility the person zone buys would be recoverable by subtraction with both tiers intact. `rooms_test.exs` pins the two lists returning the same ids. **Do not re-add the filter.** Suspension governs the suspended person's own access alone: `venue_room_membership/3` and `venues_of_person/2` keep `unsuspended/2`, so they cannot read, send, or see the room in their own list, and nobody else's answer changes. Nothing is lost — the venue room carries full history, so they read what was said while they were away the moment they resume.

**`room_messages` has a row-level security policy and no database tier behind the query filters.** `employer_role` holds nothing on the table and the policy is not `FORCE`d, so the only accessor — `Repo`, which owns it — is not bound. `FORCE` is not available: the predicate raises wherever `app.employer_id` is unset, which is every person-side read, and `Repo` connects as `postgres`, a superuser, which bypasses row-level security regardless. What is real is the composite keys: `room_messages_author_fkey` MATCH FULL into `engagements (id, venue_id)` and `room_messages_shift_room_fkey` into `shift_rooms (id, venue_id)`, which is why `Records.shift_room_messages/1` is safe with no venue filter and `venue_room_messages/1` rests on the `venue_id` its caller's resolved engagement carries. `*_enable_room_row_level_security.exs` says all of this; do not restore the "belt and braces" reading.

**`roster_entries.joined_at` and `left_at` are `:utc_datetime_usec` over `timestamp(6)`, alone in the schema, and neither is truncated.** Flooring the upper bound closes a period before the removal happened and shortens an overlap that has already elapsed, which is the one thing KTD6b says no write may do; flooring the lower bound backdates the rostering. `timestamp(0)` *rounds* where Ecto's `:utc_datetime` truncates, so the column type and the changeset had to move together. `venue_room_suspensions` deliberately stays whole-second: both its bounds move the person's own absence in the person's own favour and change nobody else's answer.

**Removal is one conditional statement, not a read then a write.** `Rosters.remove_from_roster/3` issues `UPDATE … WHERE left_at IS NULL` and answers `{:error, :not_rostered}` when it matches nothing — the same answer a period closed a moment ago already got. Before it, two managers removing at two instants both succeeded and the row carried whichever `left_at` committed last. There is no `lock_version` here on purpose: a renewal is a repeatable mutation where `:stale` is the only honest answer, while closing a period happens once.

**An `EXCLUDE` conflict between two uncommitted inserts is a deadlock, not a violation.** Measured at `40P01` with two live racers on `roster_entries_no_overlap`; `engagements_no_overlap` has the same property. The changeset error the moduledocs promise is what arrives when the conflicting row is committed, which is the ordinary case. `rooms_concurrency_test.exs` builds its two insert races that way — a caller parked on a `SHARE` lock, having demonstrably passed its friendly check against an empty table, then meeting a committed conflict — and says why.

**`Rosters.add_to_roster/3` refuses an engagement that has not started yet**, with `{:error, :not_found}`, so a hire whose term opens next Monday cannot go on next Tuesday's shift today and the operator cannot learn why. Recorded in the moduledoc as a limitation rather than fixed: nothing depends on it, because membership and readability already intersect with an engagement active at the instant asked about.

**Three more test files are not sandboxed:** `rooms_test.exs`, `rosters_test.exs` and `rooms_concurrency_test.exs`, all through `EngagementsFixtures.real_connections/0`, for the reason U5's three are.

## Peer graph

`connection_requests`, `peer_connections` and `peer_messages`, all **person zone**, all created by `*_create_peer_graph.exs` and reached only through `HospitalityComs.Peers`. There is no `peer_visibility` table and no `conversations` table: `Peers.Visibility` and `Peers.Conversation` are plain structs derived on every read, the way `Rooms.VenueRoom` is.

**The classification was not a judgement call.** Each of the three holds two or three foreign keys to `people` and holds no employer key of any kind, so a peer table anywhere but the person zone would be a second crossing and `boundary_test.exs`'s positive form — `engagements` is the *only* table outside the person zone that references `people` — would fail. `employer_role` holds nothing on any of them, `EmployerRepo`'s backstop raises naming the table, `EmployerSocket` routes no `peer` topic, and every `Peers` function heads on a `PersonScope`. `peers_test.exs` asserts the last three against a conversation that actually exists, because `boundary_test.exs` cannot populate one.

**Visibility is `[max(their two starts_at), min(their two ends_at) + 30 days)`, derived per pair per venue.** "Co-rostered" is read as *concurrent engagement at one venue*, not as a shared shift: the plan says "per pair per **venue**" and "the first of the two **engagements** to end", and a shift-level reading would leave the engagement endpoints doing nothing. It also lands where U6 already is — the venue room's roll is the venue's active engagements, so the people a worker can see are the people they are already in a room with, plus thirty days. The tail keys on the **first** engagement to end, so somebody who left in January stops being visible to a colleague still employed there.

`Records.co_engagements/1` writes the interval as four comparisons rather than `GREATEST`/`LEAST` — `max(a) <= t` is `a1 <= t and a2 <= t`; `min(b) + 30d > t` is `b1 > t-30d and b2 > t-30d` — so the predicate stays in plain Ecto and the thirty days live in one function, `Visibility.cutoff/1`, that the rendered struct calls too. `peers_test.exs` compares the SQL spelling against the struct over a matrix of term pairs and instants, which is U6's manoeuvre against the generated `open_period` column. **Both emptiness clauses are load-bearing**: `end_engagement/2` can produce `ends_at == starts_at`, and the endpoint form without them reports an overlap for it.

**A pair's whole state is one `connection_requests` row.** `superseded_at IS NULL` with a partial unique index on the generated `(pair_low_id, pair_high_id)`, so "the pair's current row" is a database guarantee. Reading "the latest row" by `(requested_at, id)` was rejected and the reason is specific to this tree: the clock is injectable and tests pin it, so a decline and the counterpart's answering request can share an instant exactly, and `id` is random on a `binary_id` schema — the tie-break would be a coin toss in precisely the case KTD19 is about.

**KTD19's block is `blocked_initiator_id` on that row.** The party who refused keeps the initiative; the party who was refused does not. A decline blocks the requester (a check constraint enforces exactly that); a disconnect blocks the counterpart of whoever disconnected, because disconnection is the origin document's only stated remedy for harm and a symmetric reading hands it back to the person it was used against. It is a column rather than a rule over engagements, and that is the whole of "the block survives new co-rostering". Blocks are read off the *current* row only — KTD19 governs "the next request", and accumulating them would make a pair who each declined the other once permanently unreachable to both.

**`:lapsed` is derived, so it can un-lapse.** A pending request whose pair cannot see each other at the asking instant reports `:lapsed` and cannot be accepted; it *can* still be declined, because an addressee may always say no and refusing would leave a row nobody could clear. If the pair is co-rostered again the same row reports `:pending` again. That is the consequence of deriving rather than storing, written down as a decision: a stored `expired_at` would have needed a job visiting every outstanding request whenever any engagement moved.

**Visibility gates discovery and requests, and gates nothing about a conversation that already exists.** A connection survives both engagements ending and both parties keep writing to it — which is what makes the demo's payoff moment reachable. After a disconnect each party reads *their own* messages and only their own; nothing is deleted (KTD21), and `peers_test.exs` asserts the row count as the control for that.

**Two partial unique indexes carry the races.** `connection_requests_one_current_per_pair` is what makes crossed simultaneous requests resolve to one; `peer_connections_one_live_per_pair` is underneath the one connection they then produce. `peers_concurrency_test.exs` is not sandboxed and proves both, plus the conditional closes on accept and disconnect. Unlike U6's insert races it can carry two real racers: a unique index makes the second inserter wait and then raise `unique_violation`, where an `EXCLUDE` conflict between two uncommitted inserts deadlocks.

**Two more test files are not sandboxed:** `peers_test.exs` and `peers_concurrency_test.exs`, for U5's reason — visibility is derived from engagements, and an engagement spans both repos.

## Realtime

Two sockets, declared in `HospitalityComsWeb.Endpoint` with `auth_token: true` so the session token arrives on the `Sec-WebSocket-Protocol` header instead of a query parameter that lands in access logs. It reaches `connect/3` as `connect_info[:auth_token]`.

**`PersonSocket` routes `venue_room:*`, `shift_room:*` and the exact topic `peer`. `EmployerSocket` routes `employer_venue:*` and nothing else** (KTD9). The absences are the design: no `peer`, so an employer session's join is refused in Phoenix's dispatch with no application code running; no room topic, because room conversation is worker-facing and `employer_role` holds nothing on `room_messages`. Adding a route to `EmployerSocket` is a boundary change, not a feature. `sockets_test.exs` asserts against `__channel__/1` — the table itself — with the person socket's matching entry as the control, so an empty table cannot pass it.

**`check_origin` is explicit for production and a boot raises without it.** `WEBSOCKET_ORIGINS` is a comma-separated allowlist, handled exactly as `MAGIC_LINK_BASE_URL` is and for the same reason: Phoenix's default of `true` checks `Origin` against the endpoint's `:url` host, so a browser client served from anywhere else has its upgrade refused *before* `connect/3` runs, with nothing in this application's logs to say why. A value naming no origin is refused too — `check_origin: []` refuses everything, which is the same silent failure by another route.

**`id/1` is the session, never the person** (KTD7): `HospitalityComsWeb.PersonAuth.session_topic/1` of the token's digest, which is the exact string `disconnect_sessions/1` already broadcasts `"disconnect"` to. Both sockets return the same string for the same token, so logging out drops both transports of that session and neither transport of any other. There is one spelling of it; two that drifted would make log-out a silent no-op against an open socket.

**Connect authenticates; join re-authenticates *and* authorises.** Nothing is cached on a socket except the person's **id** and the session token's **digest** — no `Person` struct, because a channel crash report is `inspect/1` of the socket, and no raw token, because U2 hashes session tokens at rest so that a leak yields digests.

`join/3` asks two questions again, every time. `ChannelAuth.join_scope/1` re-derives the session from the digest against the same `people_tokens` row and the same fourteen-day horizon an HTTP request is checked against; then `Rooms.fetch_venue_room_membership/2`, `Rooms.fetch_shift_room_reader/2` or `Engagements.fetch_grant_holding_engagement/2` re-derives the authority. Together they are what makes the *refused rejoin* the revocation (KTD8). `revocation_test.exs` asserts that rejoin without looking at the channel process at all: deleting the `{:stop, …}` leaves it passing, deleting the re-derivation is what makes it fail. Both measured.

The session is re-derived **per join, not per event** — deliberately, with the residue written out in `ChannelAuth`'s moduledoc. Authorization *is* per event.

**The instant is per inbound event, not per join** (KTD5). `ChannelAuth.person_scope/1` reads the clock at the top of every `handle_in/3`, and `join_scope/1` does the same for a join. A channel joined at 22:00 has its 23:31 send refused by a room that closed at 23:30, on the same process, with no rejoin and no job.

**A topic suffix is user input.** `ChannelAuth.topic_id/1` is the only way one becomes an id: `byte_size(id) == 36` and then `Ecto.UUID.cast/1`, which is `EmployerScope.uuid!/1`'s shape without the raise. The byte size is load-bearing rather than a pre-filter — `cast/1` alone accepts sixteen raw bytes and encodes them. A malformed suffix gets the same sentence an id that names nothing gets (AE1); before this it raised `Ecto.Query.CastError` out of `join/3`.

**Every channel answers what it does not know.** `Phoenix.Channel.Server` dispatches to `handle_in/3` unconditionally, so all four carry a terminal clause returning the `bad_request` envelope. Both room channels carry a catch-all `handle_info/2`: the engagement topic is shared by every channel that engagement opened, so an unmatched message there crashes the venue room *and* every shift room at once.

There is no separate employer credential. An employer session is a person session plus a venue on the channel topic; `Engagements.fetch_grant_holding_engagement/2` resolves the engagement at that venue holding a grant the venue has not revoked, and `ChannelAuth.employer_scope/2` turns it into an `EmployerScope`. **U9 must call it per event and must not read `socket.assigns.grant_id`**, which is written once at join and never refreshed.

`HospitalityComs.PubSub` is both the module and the registered name of the PubSub server. `subscribe(scope, target)` keys on the scope struct and pins the id where the scope carries one — an employer scope handed a peer topic, or a person scope handed another person's, is a `FunctionClauseError` before a registration exists. **It is not the only way a process becomes a subscriber** (`Phoenix.Channel.Server` subscribes every joined channel to its own topic), and **it gates three of its five targets not at all**: `{:venue_room, _}`, `{:shift_room, _}` and `{:engagement, _}` accept any id from any person scope, authorized by the caller that resolved it and by nothing here. Read those clauses as a type check, never as an access check — `subscribe` issues no query, so no privilege and no RLS policy would notice. `{:engagement, id}` resolves through `Engagements.topic/1`: U5's after-commit broadcast, not a second mechanism.

**Suspension nudges the channels it closes.** `Rooms.suspend_venue_room/2` broadcasts `{:venue_room_suspended, …}` on the engagement's topic after the write and only if it happened, best effort and logged. `VenueRoomChannel` pushes `"access_suspended"` and stops with `{:shutdown, :suspended}`; `ShiftRoomChannel` ignores it in a clause of its own, because KTD18 confines suspension to the venue room and the nudge only reaches shift rooms because one engagement opens both.

**Presence is keyed on `engagement_id`, never `person_id`** (KTD15b), and lives only on person-socket topics. That is what stops it becoming the arithmetic U6 closed: a suspended person is absent from presence and still on the room's roll, and no employer surface can reach the diffs. There is no `untrack` call anywhere; the tracker monitors the channel process, and `presence_test.exs` proves it by killing a channel outright and watching the leave arrive. Three residues are recorded in `HospitalityComsWeb.Presence` — a manager is also a worker and can watch the diffs over time, metas stamp `role_label` at join and never refresh, and `Phoenix.Tracker`'s twenty-minute `:permdown_period` keeps a partitioned node's presences listed.

`max_channels_per_transport` is at Phoenix's default of 100, and **KTD10's argument for that number is wrong**: multiplexing is worker-side, `EmployerVenueChannel` is one channel per venue with none, and the person socket's readable shift-room set is unbounded and grows with every shift ever rostered. Clients must open shift rooms on demand rather than joining the list. At the limit Phoenix answers `%{reason: "too many channels joined"}` — **not an `ErrorEnvelope`**. The real bound and who can exceed it are written out in `endpoint.ex`.

**`PeerChannel` is the multiplexing point U7 left empty, and U8 filled it.** Nine events and a terminal clause; every one names its conversation in the payload and none in the topic, so conversations are not part of the channel count and no per-conversation topic name exists for a later unit to copy into an employer socket's table. `join/3` authorises nothing beyond the session — there is no membership behind `"peer"` — so **every event authorises itself in the context**, which is the only shape that works when one channel carries conversations with different people opened and closed at different times. The instant is per event as everywhere else: `peer_channel_test.exs` disconnects a conversation *after* the channel joined and watches the next send refused.

**`"peer"` has no suffix, so every person's peer channel is on the same Phoenix topic.** `broadcast/3` from that channel would deliver to every peer channel in the cluster. There is none in the file and there must never be one: all fan-out goes through `Peers`, which publishes on `PubSub.topic({:peer, person_id})`, and `subscribe/2` pins the id to the scope. A disconnect **does not stop** the channel, unlike a room revocation — the topic is the person, not the conversation, and stopping would take down every other conversation on it.

**Seven more test files are not sandboxed**, through `HospitalityComsWeb.ChannelCase`: `sockets_test.exs`, `presence_test.exs`, `revocation_test.exs`, `venue_room_channel_test.exs`, `shift_room_channel_test.exs`, `peer_channel_test.exs` and `employer_venue_channel_test.exs`. It takes real connections like `EngagementsFixtures.real_connections/0`, then makes ownership `{:shared, self()}` because a channel runs in a process of its own with no connection checked out, and pins `Clock.Offset` to the fixtures' instant because a channel reads the clock. Getting the shared ownership wrong does not look like a failure — it looks like `DBConnection.OwnershipError` inside `join/3`, which the channel reports as a crash, which reads like the join being refused.

## Four disclosures on the record

None is a bug and none is closed here. All are written down so a later unit decides about them deliberately.

**`engagements.person_id` is a globally stable UUID and `employer_role` can read it.** Two venues comparing ids out of band can therefore determine that the same human works at both — which is precisely the concurrency U9's disclosure default is meant to hide. It is inherent to the single-bridge design: the exclusion constraint keys on `(person_id, venue_id, period)`, so the person key has to be the same value at every venue. A per-venue pseudonym would need a second crossing or a per-venue mapping table, which is a KTD2 decision rather than an implementation one. **U9 governs it.**

**`employer_role` holds table-level `SELECT` on `invitations`, and that includes `claim_code_digest`.** The digest is SHA-256 of 32 random bytes, so it is not a working credential and cannot be turned back into one — but `Records.outstanding_invitations/2` returns whole `Invitation` structs, so **a U6 endpoint that renders one wholesale ships the digest to the client.** Render a field list, not the struct. Narrowing the grant to named columns is the alternative and was not taken, because the digest is also what the claim looks the invitation up by.

**`Rooms.list_venue_room_members/2` hands every member of a room the `person_id` of every other member.** It returns whole `Engagement` structs and it is the only list in the tree that discloses one worker's identity key to another. U8/U9 render it: project a field list, and attribute on the engagement's `id` — the `author_engagement_id` a message already carries (KTD15b), venue-local by construction — rather than on `person_id`. The same shape as the `claim_code_digest` note above, aimed at a different consumer.

U8 acted on this half. `Peers.list_visible_peers/1` selects a field list rather than structs, and what it carries about a counterpart — their `person_id`, the shared venue, the employer-authored `role_label` — is exactly what the venue room's roll already discloses. **No email address**, which is the only other identifying column `people` has, and `peers_test.exs` asserts its absence with the positive test as the control. `Rooms.list_venue_room_members/2` itself is unchanged and still returns structs; U9 is where that lands.

**A channel derives its session per join, not per event.** So a token deleted while a channel is open leaves that channel able to send until it next joins, unless `PersonAuth.disconnect_sessions/1` reached it — which log-out, magic-link redemption and email change all do. The uncovered case is a future deletion path that does not, and **U10's erasure is the one to watch**, because it deletes the person rather than the session. The reasoning for per-join, and what it does and does not cost, is in `HospitalityComsWeb.ChannelAuth`'s moduledoc.

## Authentication

Magic link in, bearer token out. `POST /api/log-in` registers the address if it is new and mails a link; `POST /api/log-in/token` redeems it and returns the API token; `GET /api/me` and `DELETE /api/log-out` require it. There is no password anywhere in the tree and no cookie session — the generator's password column, changeset, and `bcrypt_elixir` were removed, because with no HTML layer nothing could ever set one.

The API token *is* the generated session token: a row in `people_tokens`, base64url on the wire and SHA-256 in the column. Every context stores a digest, session included — the column is the bearer credential for this API, so a `SELECT` leak must not yield a working one. Deleting the row ends the session on the next request **and on the next channel join**, because a socket keeps the token's digest and `ChannelAuth.join_scope/1` looks it up again against the same row and the same horizon. `disconnect_sessions/1`'s broadcast drops the transports promptly; it is not what makes them powerless.

Every error the API returns is one envelope, built only by `HospitalityComsWeb.ErrorEnvelope`: `{"error": {"code": <status atom>, "message": ..., "fields": {...}}}`, with `fields` present only for per-field validation failures. Controllers, `PersonAuth`, `ErrorJSON` and every channel refusal go through it; do not hand-roll a body. `ErrorEnvelope.for_changeset/3` is the one place Ecto's `%{count}` placeholders are interpolated.

Production requires `MAGIC_LINK_BASE_URL` — `config/runtime.exs` raises without it, because the `localhost:4000` default in `config/config.exs` fails silently by mailing links to the wrong host.

`people` is already shaped for U10 erasure: `email` is nullable, its unique index is partial on `WHERE erased_at IS NULL`, and two check constraints hold `erased_at` and `email` in opposition. Erasure nulls the address; nothing else may.
