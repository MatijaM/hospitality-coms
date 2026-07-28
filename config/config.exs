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
# the React client in U12 does — so this is configuration rather than a route.
config :hospitality_coms, :magic_link_base_url, "http://localhost:4000/log-in/"

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
# settings. `batch_size` caps each of the four triggers; `ceiling` is the total
# above which a run rolls **every** trigger back and records itself as refused.
#
# Four times 500 is 2000, so an ordinary run cannot reach 5000. That is
# deliberate: the ceiling is the guard that fires when a batch bound is missing
# or a later trigger is added without one, not a throttle. A ceiling an ordinary
# run could hit would refuse the same rows on every tick and the sweep would
# never make progress again.
config :hospitality_coms, HospitalityComs.Lifecycle, batch_size: 500, ceiling: 5_000

# The employer zone acts as a Postgres role that will hold no privilege on
# person-zone tables. The role is assumed on connection rather than logged in
# as, so there is no second credential to manage.
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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
