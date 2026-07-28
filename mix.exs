defmodule HospitalityComs.MixProject do
  use Mix.Project

  def project do
    [
      app: :hospitality_coms,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs",
        # :credo is a build-time dependency, but the project's own checks in
        # dev_support are analysed alongside the application.
        plt_add_apps: [:mix, :ex_unit, :credo]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {HospitalityComs.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  @doc """
  The paths compiled in `env`.

  `dev_support` holds modules that must not reach production: the offsettable
  clock, whose demo control could otherwise trigger irreversible retention
  deletion; `HospitalityComs.Demo` and `HospitalityComsWeb.DemoController`,
  which are that control; and the project's own Credo checks, which depend on a
  dev-only package. Excluding the path is what makes their absence structural
  rather than a flag somebody can flip (KTD5b).

  Public because `HospitalityComs.DemoTest` asserts what `:prod` compiles, and
  the only honest way to assert it is to read the function Mix itself calls
  rather than a copy of the rule. Mix still reaches it through `project/0`.
  """
  @spec elixirc_paths(atom()) :: [String.t()]
  def elixirc_paths(:test), do: ["lib", "dev_support", "test/support"]
  def elixirc_paths(:dev), do: ["lib", "dev_support"]
  def elixirc_paths(_env), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:oban, "~> 2.23"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      quality: ["credo --strict", "dialyzer"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
