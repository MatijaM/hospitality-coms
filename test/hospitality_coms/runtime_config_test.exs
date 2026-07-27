defmodule HospitalityComs.RuntimeConfigTest do
  @moduledoc """
  What `config/runtime.exs` insists on before a production node will boot.

  The magic link is the only credential this application issues, and its base
  URL is what a worker clicks. A wrong one does not fail loudly — it mails out
  links to a host that is not this application, so the failure is silent, on
  the recipient's side, and looks like "the email doesn't work". A production
  boot must therefore refuse the default the way it refuses a missing
  `SECRET_KEY_BASE`, rather than quietly shipping `localhost:4000`.

  `WEBSOCKET_ORIGINS` is the second rule of that kind and was added for the same
  reason. U7 put two sockets on this endpoint, and they are the first thing
  Phoenix's `:check_origin` has ever applied to here; its default of `true`
  checks the request's `Origin` against the endpoint's own `:url` host, which
  `runtime.exs` sets from `PHX_HOST`. A browser client served from anywhere else
  has its upgrade refused *before* `connect/3` runs, with no application code
  involved and nothing in this application's own logs to say why. Another silent
  failure on somebody else's side, so it is required rather than defaulted.

  This reads the real file rather than a copy of its rules, so a rule deleted
  from `runtime.exs` fails here.
  """

  use ExUnit.Case, async: false

  @runtime_config "config/runtime.exs"

  @credentials %{
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/hospitality_coms_prod",
    "SECRET_KEY_BASE" => String.duplicate("s", 64)
  }

  @required Map.merge(@credentials, %{
              "MAGIC_LINK_BASE_URL" => "https://app.example/log-in/",
              "WEBSOCKET_ORIGINS" => "https://app.example"
            })

  describe "the production block" do
    test "refuses to boot without a magic link base url" do
      assert_raise RuntimeError, ~r/MAGIC_LINK_BASE_URL/, fn ->
        @required |> Map.delete("MAGIC_LINK_BASE_URL") |> read_prod()
      end
    end

    test "takes the magic link base url from the environment" do
      config = read_prod(@required)

      assert config[:hospitality_coms][:magic_link_base_url] == "https://app.example/log-in/"
    end

    test "still refuses to boot without a secret key base" do
      # Guards the test above from passing because the whole prod block stopped
      # being evaluated.
      assert_raise RuntimeError, ~r/SECRET_KEY_BASE/, fn ->
        @required |> Map.delete("SECRET_KEY_BASE") |> read_prod()
      end
    end
  end

  describe "the websocket origin allowlist" do
    test "refuses to boot without one" do
      # The two sockets U7 added are the first thing `:check_origin` applies to,
      # and its default silently refuses the upgrade of any client not served
      # from `PHX_HOST`. Left implicit, the first anybody knows is a client that
      # cannot connect and a server with nothing to say about it.
      assert_raise RuntimeError, ~r/WEBSOCKET_ORIGINS/, fn ->
        @required |> Map.delete("WEBSOCKET_ORIGINS") |> read_prod()
      end
    end

    test "sets check_origin to the list it was given" do
      config = read_prod(@required)

      assert endpoint(config)[:check_origin] == ["https://app.example"]
    end

    test "splits a comma-separated list and trims each entry" do
      # More than one origin is the ordinary case: the web client and whatever
      # the native app reports.
      config =
        read_prod(
          Map.put(
            @required,
            "WEBSOCKET_ORIGINS",
            "https://app.example, https://staging.app.example ,https://admin.example"
          )
        )

      assert endpoint(config)[:check_origin] == [
               "https://app.example",
               "https://staging.app.example",
               "https://admin.example"
             ]
    end

    test "refuses a value that names no origin at all" do
      # `check_origin: []` refuses every upgrade, which is the same silent
      # failure arrived at by a different route — and it is what a trailing
      # comma or an empty variable would otherwise produce.
      for blank <- ["", "   ", ",", " , "] do
        assert_raise RuntimeError, ~r/WEBSOCKET_ORIGINS/, fn ->
          @required |> Map.put("WEBSOCKET_ORIGINS", blank) |> read_prod()
        end
      end
    end

    test "never sets check_origin to true, which is the default it exists to replace" do
      config = read_prod(@required)

      refute endpoint(config)[:check_origin] == true
    end
  end

  defp endpoint(config), do: config[:hospitality_coms][HospitalityComsWeb.Endpoint]

  test "leaves the development default alone" do
    config = read_env(:dev, %{})

    refute Keyword.has_key?(config[:hospitality_coms] || [], :magic_link_base_url)
  end

  defp read_prod(env), do: read_env(:prod, env)

  defp read_env(config_env, env) do
    previous = Enum.map(env, fn {key, _value} -> {key, System.get_env(key)} end)
    on_exit(fn -> Enum.each(previous, &restore/1) end)

    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
    Config.Reader.read!(@runtime_config, env: config_env)
  end

  defp restore({key, nil}), do: System.delete_env(key)
  defp restore({key, value}), do: System.put_env(key, value)
end
