import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/hospitality_coms start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :hospitality_coms, HospitalityComsWeb.Endpoint, server: true
end

config :hospitality_coms, HospitalityComsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :hospitality_coms, HospitalityComs.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # Same database, different Postgres role — and since #17, a different
  # *credential*, which is the point rather than a detail.
  #
  # `EmployerRepo` used to share `DATABASE_URL` and assume `employer_role` with
  # `SET ROLE`. Its session user was therefore the application's own role, and a
  # single `RESET ROLE` over a raw query — which neither BEAM guard sees — put
  # every privilege back. It now authenticates as `employer_login`, a NOINHERIT
  # role holding no privilege in its own name, so `RESET ROLE` lands somewhere
  # strictly worse than where it started.
  #
  # A second URL rather than a second password beside `DATABASE_URL`, and the
  # reason is mechanical: `Ecto.Repo.Supervisor.init_config/4` merges the parsed
  # URL *over* explicit options, so a `username: "employer_login"` written next
  # to the shared URL would be silently overwritten by that URL's own userinfo
  # and the repo would go on connecting as the owner with nothing to say so.
  # Required rather than defaulted for the same reason MAGIC_LINK_BASE_URL is:
  # falling back to `DATABASE_URL` would not fail, it would quietly undo #17.
  employer_database_url =
    System.get_env("EMPLOYER_DATABASE_URL") ||
      raise """
      environment variable EMPLOYER_DATABASE_URL is missing.
      It is the connection HospitalityComs.EmployerRepo authenticates with, and
      it must name the `employer_login` role — not the role DATABASE_URL names,
      which owns every table in the database.
      For example: ecto://employer_login:PASS@HOST/DATABASE

      Provision that role's password out of band before migrating. The role is
      created by priv/repo/migrations/*_create_employer_login_role.exs, which
      writes a password only when the role does not already exist — so a
      pre-provisioned role keeps a secret that never reaches a migration, and
      therefore never reaches the Postgres statement log.
      """

  config :hospitality_coms, HospitalityComs.EmployerRepo,
    # ssl: true,
    url: employer_database_url,
    pool_size: String.to_integer(System.get_env("EMPLOYER_POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Where a magic link points. The default in config/config.exs is
  # `localhost:4000`, which is right for dev and test and catastrophic in
  # production: it does not fail, it mails working-looking links to a host that
  # is not this application, and the failure surfaces on the recipient's side
  # as "the email doesn't work". So it is required here rather than defaulted.
  magic_link_base_url =
    System.get_env("MAGIC_LINK_BASE_URL") ||
      raise """
      environment variable MAGIC_LINK_BASE_URL is missing.
      It is the prefix a magic link token is appended to, and it must end in a
      slash. For example: https://app.example.com/log-in/
      """

  config :hospitality_coms, :magic_link_base_url, magic_link_base_url

  # Which origins may open a websocket. U7 put two sockets on this endpoint and
  # they are the first thing `:check_origin` has ever applied to here.
  #
  # Phoenix's default is `true`, which checks the request's `Origin` against the
  # endpoint's own `:url` host — set just below from `PHX_HOST`. A browser
  # client served from any other origin therefore has its upgrade refused
  # *before* `connect/3` runs, by the transport, with no application code
  # involved and nothing in this application's logs to say why. That is the same
  # class of failure as the magic link's default and it is required here for the
  # same reason: it fails silently, on somebody else's side, and looks like the
  # client being broken.
  #
  # A list rather than a boolean, so the answer is written down. An empty list
  # refuses everything, which is the identical failure by another route, so a
  # variable that names no origin is refused rather than accepted.
  websocket_origins =
    System.get_env("WEBSOCKET_ORIGINS") ||
      raise """
      environment variable WEBSOCKET_ORIGINS is missing.
      It is the comma-separated list of origins allowed to open a websocket
      against /socket/person and /socket/employer, and it must name at least
      one. An origin is scheme, host and port with no path.
      For example: https://app.example.com,https://staging.app.example.com
      """

  check_origin =
    websocket_origins
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  if check_origin == [] do
    raise """
    environment variable WEBSOCKET_ORIGINS names no origin.
    It was #{inspect(websocket_origins)}. An empty allowlist refuses every
    websocket upgrade, which is the failure this variable exists to prevent
    rather than a way to switch the sockets off.
    """
  end

  host = System.get_env("PHX_HOST") || "example.com"

  config :hospitality_coms, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :hospitality_coms, HospitalityComsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :hospitality_coms, HospitalityComsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :hospitality_coms, HospitalityComsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :hospitality_coms, HospitalityComs.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
