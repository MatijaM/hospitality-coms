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
  database: "hospitality_coms_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :hospitality_coms, HospitalityComs.EmployerRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
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
