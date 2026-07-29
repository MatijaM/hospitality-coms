import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :hospitality_coms, HospitalityComs.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  # A second checkout needs its own cluster, not its own database on the shared
  # one: worktree isolation isolates the filesystem and not Postgres, and a
  # second *database* holding grants makes `DROP ROLE` fail in both
  # (issue #20). `PGPORT` alone does not reach here — Ecto pins `:port` before
  # Postgrex would read the environment — so the override has to be explicit.
  port: String.to_integer(System.get_env("HC_TEST_PGPORT") || "5432"),
  database: "hospitality_coms_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# A different Postgres role from the one above, which is issue #17 and is the
# whole of what makes `RESET ROLE` futile on an employer connection. The
# password is not a secret and never was: it sits beside the `postgres` one, the
# local cluster authenticates with `trust` and ignores it, and CI's service
# container authenticates with `scram-sha-256` and needs it. The role is created
# by `*_create_employer_login_role.exs`, which reads this value.
config :hospitality_coms, HospitalityComs.EmployerRepo,
  username: "employer_login",
  password: "employer_login",
  hostname: "localhost",
  # Both repos or neither: a run with only one overridden reaches two clusters,
  # and the sandbox then sees rows the other connection cannot.
  port: String.to_integer(System.get_env("HC_TEST_PGPORT") || "5432"),
  database: "hospitality_coms_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Tests assert on boundary instants rather than approximating them.
config :hospitality_coms, clock: HospitalityComs.Clock.Offset

# U11's demo controls, so `HospitalityComsWeb.DemoControllerTest` exercises the
# routes rather than the controller functions. Same gate as `:dev`; see
# `HospitalityComs.Demo`.
config :hospitality_coms, demo_routes: true

# No queue runs and no plugin ticks. `testing: :manual` makes Oban start with
# `queues: []`, `plugins: []` and an isolated non-leader peer, so a job inserted
# by a test stays in `oban_jobs` until that test runs it with
# `Oban.Testing.perform_job/3`.
#
# This is not tidiness. A job that executes for real in the suite runs on a
# process the sandbox never lent a connection to, at an instant the injected
# clock did not choose, against rows another test is still holding — three
# independent sources of flake for a mechanism whose correctness this unit
# deliberately does not depend on. Every assertion about expiry here is an
# assertion about what the worker does when it is run, made by running it.
config :hospitality_coms, Oban, testing: :manual

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hospitality_coms, HospitalityComsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "9VvODzkDgBlp3nsDQ7yFStd+8zQTUhmSLxnO7CNCY+ITPcju7SiOU3FIcsOGEAyB",
  server: false

# In test we don't send emails
config :hospitality_coms, HospitalityComs.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
