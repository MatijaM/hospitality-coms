defmodule HospitalityComs.LocalesTest do
  @moduledoc """
  The domain-to-locale mapping, and the control that stops it being restated.

  `priv/locales.json` exists so that the rule lives in one place. A module that
  answered from its own literals would pass every behavioural test in this file
  and defeat the reason the artifact exists — so the last block reads the
  artifact independently and requires the module to agree with it. That is the
  test that fails when somebody inlines the map.
  """

  use ExUnit.Case, async: true

  alias HospitalityComs.Locales

  # Read independently of the module, so the two cannot agree by construction.
  defp artifact do
    "priv/locales.json" |> File.read!() |> Jason.decode!()
  end

  describe "for_host/1" do
    test "a host the artifact names resolves to its locale" do
      assert Locales.for_host("app.example.rs") == "sr-Latn"
      assert Locales.for_host("app.example.com") == "en"
    end

    test "a host the artifact does not name resolves to the default" do
      assert Locales.for_host("unknown.example.net") == Locales.default()
    end

    test "the host is matched without regard to case" do
      assert Locales.for_host("APP.EXAMPLE.RS") == "sr-Latn"
      assert Locales.for_host("App.Example.Rs") == "sr-Latn"
    end

    test "a port is not part of the host" do
      assert Locales.for_host("app.example.rs:4000") == "sr-Latn"
      assert Locales.for_host("localhost:5173") == "en"
    end

    test "an empty or nil host resolves to the default rather than raising" do
      assert Locales.for_host("") == Locales.default()
      assert Locales.for_host(nil) == Locales.default()
    end
  end

  describe "for_origin/1" do
    test "an origin naming a mapped host resolves to that host's locale" do
      assert Locales.for_origin("https://app.example.rs") == "sr-Latn"
      assert Locales.for_origin("http://app.example.rs:4000") == "sr-Latn"
    end

    test "an origin naming an unmapped host resolves to the default" do
      assert Locales.for_origin("https://unknown.example.net") == Locales.default()
    end

    test "a malformed origin resolves to the default rather than raising" do
      for origin <- ["", "not a url", "://", "app.example.rs"] do
        assert Locales.for_origin(origin) == Locales.default()
      end
    end

    test "a nil origin resolves to the default" do
      assert Locales.for_origin(nil) == Locales.default()
    end
  end

  describe "the catalogue" do
    test "default/0 is one of the locales" do
      assert Locales.default() in Locales.all()
    end

    test "all/0 answers every locale the artifact names" do
      assert Enum.sort(Locales.all()) == ["en", "sr-Latn"]
    end

    test "known?/1 distinguishes a locale from a string that is not one" do
      assert Locales.known?("sr-Latn")
      refute Locales.known?("sr_Latn")
      refute Locales.known?("de")
    end
  end

  describe "validate!/1 refuses an artifact that cannot be honoured" do
    test "a default absent from the locale list" do
      assert_raise ArgumentError, ~r/default locale/, fn ->
        Locales.validate!(%{"default" => "de", "locales" => %{"en" => %{"hosts" => ["a"]}}})
      end
    end

    test "a locale naming no host" do
      assert_raise ArgumentError, ~r/no host/, fn ->
        Locales.validate!(%{"default" => "en", "locales" => %{"en" => %{"hosts" => []}}})
      end
    end

    test "one host claimed by two locales" do
      assert_raise ArgumentError, ~r/more than one locale/, fn ->
        Locales.validate!(%{
          "default" => "en",
          "locales" => %{
            "en" => %{"hosts" => ["shared.example.com"]},
            "sr-Latn" => %{"hosts" => ["shared.example.com"]}
          }
        })
      end
    end

    test "no locale at all" do
      assert_raise ArgumentError, ~r/at least one locale/, fn ->
        Locales.validate!(%{"default" => "en", "locales" => %{}})
      end
    end

    # The control for the four above: the artifact this application actually
    # ships passes the same function. Without it, a validator that raised on
    # everything would satisfy every row here.
    test "the shipped artifact passes" do
      assert Locales.validate!(artifact()) == :ok
    end
  end

  describe "the module does not restate the artifact" do
    test "every host in the artifact resolves to the locale the artifact gives it" do
      for {locale, %{"hosts" => hosts}} <- artifact()["locales"], host <- hosts do
        assert Locales.for_host(host) == locale,
               "#{host} is #{locale} in priv/locales.json and #{Locales.for_host(host)} in Locales"
      end
    end

    test "all/0 is exactly the artifact's locale keys" do
      assert Enum.sort(Locales.all()) == artifact()["locales"] |> Map.keys() |> Enum.sort()
    end

    test "default/0 is the artifact's default" do
      assert Locales.default() == artifact()["default"]
    end
  end
end
