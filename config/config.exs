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
    module: HospitalityComs.Accounts.Scope,
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
