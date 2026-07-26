# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

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
  render_errors: [
    formats: [html: HospitalityComsWeb.ErrorHTML, json: HospitalityComsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: HospitalityComs.PubSub,
  live_view: [signing_salt: "ivgeD9bJ"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :hospitality_coms, HospitalityComs.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  hospitality_coms: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  hospitality_coms: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
