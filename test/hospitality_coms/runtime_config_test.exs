defmodule HospitalityComs.RuntimeConfigTest do
  @moduledoc """
  What `config/runtime.exs` insists on before a production node will boot.

  The magic link is the only credential this application issues, and its base
  URL is what a worker clicks. A wrong one does not fail loudly — it mails out
  links to a host that is not this application, so the failure is silent, on
  the recipient's side, and looks like "the email doesn't work". A production
  boot must therefore refuse the default the way it refuses a missing
  `SECRET_KEY_BASE`, rather than quietly shipping `localhost:4000`.

  This reads the real file rather than a copy of its rules, so a rule deleted
  from `runtime.exs` fails here.
  """

  use ExUnit.Case, async: false

  @runtime_config "config/runtime.exs"

  @required %{
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/hospitality_coms_prod",
    "SECRET_KEY_BASE" => String.duplicate("s", 64)
  }

  describe "the production block" do
    test "refuses to boot without a magic link base url" do
      assert_raise RuntimeError, ~r/MAGIC_LINK_BASE_URL/, fn -> read_prod(@required) end
    end

    test "takes the magic link base url from the environment" do
      config = read_prod(Map.put(@required, "MAGIC_LINK_BASE_URL", "https://app.example/log-in/"))

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
