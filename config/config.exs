# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Read by `mix phx.gen.*` so that generated contexts and tests are scoped to a
# person by default.
config :hospitality_coms, :scopes,
  person: [
    default: true,
    module: HospitalityComs.Accounts.PersonScope,
    assign_key: :current_scope,
    access_path: [:person, :id],
    schema_key: :person_id,
    schema_type: :binary_id,
    schema_table: :people,
    test_data_fixture: HospitalityComs.AccountsFixtures,
    test_setup_helper: :register_and_log_in_person
  ]

# Where a magic link points. The application serves no page that redeems one —
# the React client does — so this is configuration rather than a route, and the
# host is **the client's origin, never this endpoint's**.
#
# 5173 is the client's Vite dev server (`client/vite.config.ts`), which proxies
# `/api` and `/socket` back to Phoenix on 4000. Pointing this at 4000 sends the
# worker to the API, which routes `/api/log-in/token` and nothing at
# `/log-in/:token` — so the link 404s and the only way in is to retype the host.
# It read as the obvious default for four units, because the port the server
# announces at boot is the one nothing about this value refers to.
config :hospitality_coms, :magic_link_base_url, "http://localhost:5173/log-in/"

config :hospitality_coms,
  # HospitalityComs.EmployerRepo addresses the same database and is
  # deliberately excluded: migrations run through the primary repo alone.
  ecto_repos: [HospitalityComs.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  clock: HospitalityComs.Clock.System

# Liveness for engagements (KTD6). Correctness is derived — an expired
# engagement is refused on the next request whether or not anything ran — so
# what the queue buys is that an already-powerless socket finds out. It runs
# through `HospitalityComs.Repo`, the application's own role: a sweep that sees
# every venue is precisely what no employer session may do.
#
# The cron entry is the idempotent periodic half. The scheduled half is
# inserted by the claim itself, in the claim's own transaction.
#
# The pruner is not housekeeping. `ExpireEngagement`'s uniqueness rule is
# `period: :infinity`, so without a pruner `oban_jobs` grows monotonically for
# the life of the installation and every insert scans all of it — correctness
# resting on retention, which is not a thing to rest correctness on.
#
# `max_age` and `EngagementSweeper`'s lookback are a pair and the order between
# them matters: a completed announcement is what stops the sweep re-announcing
# the same expiry every five minutes, so retention has to outlast the window the
# sweep looks back over. Seven days against one is the margin.
#
# **That ordering is now checked, and this comment is no longer what holds it.**
# `HospitalityComs.Workers.EngagementSweeper` reads the `max_age` below with
# `Application.compile_env/3` and raises at compile time if its lookback is not
# shorter (issue #42, item 2). The read goes lib→config and must never be
# reversed: config cannot depend on `lib`, and this file is loaded before any of
# it exists. Lowering `max_age` past a day fails the build.
config :hospitality_coms, Oban,
  repo: HospitalityComs.Repo,
  queues: [engagements: 5, lifecycle: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", HospitalityComs.Workers.EngagementSweeper},
       # Hourly, and a concurrency of one on its own queue. Retention deletion
       # is irreversible and bounded per run, so the cost of running it less
       # often is that a deadline is honoured up to an hour late — which is
       # nothing, since `delete_after` is stamped and does not move — while the
       # cost of running several at once is two passes taking the same batch.
       {"0 * * * *", HospitalityComs.Workers.RetentionSweeper},
       # Issue #15's reaper, hourly and on the same queue, at a minute of its
       # own because that queue has a concurrency of one and two jobs staged
       # together would simply queue behind each other. Nothing here is urgent:
       # a token past its horizon authenticates nothing whether or not anything
       # has deleted it, so being an hour late costs a row rather than a
       # session.
       {"30 * * * *", HospitalityComs.Workers.AccountReaper}
     ]},
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
  ]

# The retention sweeper's two bounds, and they are a pair rather than two
# settings. `batch_size` caps each trigger; `ceiling` is the total above which a
# run rolls **every** trigger back and records itself as refused.
#
# One full batch per trigger cannot reach the ceiling, so an ordinary run cannot
# either. That is deliberate: the ceiling is the guard that fires when a batch
# bound is missing or a later trigger is added without one, not a throttle. A
# ceiling an ordinary run could hit would refuse the same rows on every tick and
# the sweep would never make progress again.
#
# **These two values are what `HospitalityComs.Lifecycle.batch_size/0` and
# `ceiling/0` actually answer**, and no compile-time check reaches them: the
# module's `@default_*` attributes carry the same ordering and its `raise` covers
# those, but `setting/2` reads this file at runtime. So the ordering is asserted
# a second time over the effective pair, in
# `test/hospitality_coms/constant_agreement_test.exs`. The trigger count in both
# comes from `RetentionRun.triggers/0`; "four" used to be written out here and
# twice in `lifecycle.ex`, and a fifth trigger would have invalidated all three
# without anything noticing (issue #42, item 4).
config :hospitality_coms, HospitalityComs.Lifecycle, batch_size: 500, ceiling: 5_000

# The employer zone acts as a Postgres role that holds no privilege on
# person-zone tables.
#
# It *authenticates* as `employer_login` and then assumes `employer_role`, and
# the two being different roles is issue #17. Until it landed, these connections
# borrowed the application's own superuser credentials, so `RESET ROLE` — over a
# raw query, which neither BEAM guard sees — put the owner of every table in
# this database back on the connection and the grant tier was defeatable from
# the same code position as the guards above it.
#
# `employer_login` is `NOINHERIT` and holds no privilege in its own name, so
# `RESET ROLE` now lands on a role holding *less* than `employer_role`. The
# credential itself is per-environment and lives in `config/dev.exs`,
# `config/test.exs` and `config/runtime.exs` beside the primary repo's.
config :hospitality_coms, HospitalityComs.EmployerRepo,
  after_connect: {Postgrex, :query!, ["SET ROLE employer_role", []]},
  priv: "priv/employer_repo"

# Configure the endpoint
config :hospitality_coms, HospitalityComsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: HospitalityComsWeb.ErrorJSON], layout: false],
  pubsub_server: HospitalityComs.PubSub

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :hospitality_coms, HospitalityComs.Mailer, adapter: Swoosh.Adapters.Local

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# What `Phoenix.Logger` may print out of a parameter map, and it is an
# **allowlist**: `{:keep, names}` inverts the filter, so every parameter not
# named below is `"[FILTERED]"`.
#
# Until issue #53 this was set nowhere, so Phoenix's own default applied — and
# that default is `["password", "token"]`, from `deps/phoenix/mix.exs`'s
# application environment, *not* the `["password"]` its moduledoc still claims.
# It covered `POST /api/log-in/token` by coincidence of spelling and covered
# nothing else: `email` printed in full, and `claim_code`, the one secret an
# invitation has, would have printed the moment the employer view added it.
#
# **The shape is the decision, not the list.** A denylist fails open and
# silently — a parameter nobody added a fragment for prints, nothing goes red,
# and you find out by reading a terminal. That is precisely how a filter
# protecting `password` survived four units after U2 deleted passwords from
# this application. An allowlist fails closed and visibly: the new parameter
# reads `[FILTERED]` where somebody wanted a value, and the fix is one name.
# The set of sensitive names is open and grows with the product; the set of
# names this API needs to read back is small, closed, and almost entirely
# `*_id`, so enumerating that side is the only version that stays true.
#
# **It is not only the HTTP dispatch line.** `Phoenix.Logger.filter_values/1`
# serves four sites, and two of them log at `:info`, which `config/prod.exs`
# does write:
#
#   * HTTP router dispatch — `:debug`
#   * socket connect — `:info`
#   * channel join — `:info`
#   * channel `handle_in` — `:debug`, and its params carry `body`, the free
#     text of every venue-room, shift-room and peer message
#
# A join payload is client-supplied and every `join/3` here ignores it, so
# nothing bounds what arrives there. The allowlist covers all four without
# anyone deciding to; a denylist written against `POST` bodies reaches one.
#
# Each name earns its place: six are ids or a closed enum (`extent` is
# `"all" | "recent"`), which `AGENTS.md` names as the spellings to reach for,
# and `vsn` is the serializer version the sockets carry — the one parameter
# that prints in production, where filtering it would make a failed connection
# harder to read for no gain. **Adding a name is a deliberate act**, and
# `test/hospitality_coms_web/parameter_filter_test.exs` pins the list so that
# widening it cannot pass unreviewed.
#
# Note for whoever adds one: `keep_values/2` tests membership at every depth,
# not only at the top, so a kept name is kept wherever it appears in the params
# tree. Keep the names specific — `"id"` would be a bad entry for that reason.
#
# **Scope, stated honestly.** This does not reach `HospitalityComs.Repo`'s own
# query log, which prints bound parameters at `:debug` and therefore prints
# email addresses and message bodies in development. That is a separate
# decision — turning it off costs the main debugging affordance in `:dev` — and
# is not made here.
config :phoenix,
       :filter_parameters,
       {:keep,
        [
          "connection_id",
          "extent",
          "person_id",
          "request_id",
          "shift_room_id",
          "venue_id",
          "vsn"
        ]}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
