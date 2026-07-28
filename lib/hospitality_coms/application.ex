defmodule HospitalityComs.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HospitalityComsWeb.Telemetry,
      HospitalityComs.Repo,
      HospitalityComs.EmployerRepo,
      {DNSCluster, query: Application.get_env(:hospitality_coms, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: HospitalityComs.PubSub},
      # After PubSub, which it broadcasts diffs through, and before the
      # endpoint, because a socket that accepted a connection before the tracker
      # existed would have a channel calling `track/3` against a missing
      # process. The name it is registered under is the module's own.
      HospitalityComsWeb.Presence,
      # Before the endpoint, because it owns the ETS table the log-in limiter
      # writes to and a request that arrived first would find no table. It
      # depends on neither repo — the counter is in memory and node-local.
      HospitalityComsWeb.LoginRateLimit,
      # After both repos, because Oban connects on start, and before the
      # endpoint, because a request that enqueues a job needs somewhere to
      # enqueue it. In `:test` the configuration is `testing: :manual`, so this
      # starts with no queues and no plugins and executes nothing on its own.
      {Oban, Application.fetch_env!(:hospitality_coms, Oban)},
      # Start to serve requests, typically the last entry
      HospitalityComsWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HospitalityComs.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HospitalityComsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
