defmodule HospitalityComsWeb.LocaleTest do
  @moduledoc """
  Resolving a request's locale from `Origin`, and putting it in force.

  The assertions are on `Gettext.get_locale/0` and on text that came back
  translated, rather than on the conn alone. A plug that assigned the right
  string and never called `Gettext.put_locale/1` would satisfy an
  assigns-only test and leave every rendered message in the default language.
  """

  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]

  alias HospitalityComs.Locales
  alias HospitalityComs.Profiles
  alias HospitalityComsWeb.Locale

  defp resolve(origin) do
    :post
    |> conn("/api/log-in", %{})
    |> then(fn conn ->
      case origin do
        nil -> conn
        value -> Plug.Conn.put_req_header(conn, "origin", value)
      end
    end)
    |> Locale.put_locale([])
  end

  describe "put_locale/2" do
    test "an origin naming a mapped host puts that locale in force" do
      resolve("https://app.example.rs")

      assert Gettext.get_locale() == "sr-Latn"
    end

    test "an origin naming the other mapped host puts the other locale in force" do
      resolve("https://app.example.com")

      assert Gettext.get_locale() == "en"
    end

    test "a request with no origin resolves to the default and does not raise" do
      resolve(nil)

      assert Gettext.get_locale() == Locales.default()
    end

    test "an origin naming an unmapped host resolves to the default" do
      resolve("https://unknown.example.net")

      assert Gettext.get_locale() == Locales.default()
    end

    test "a malformed origin resolves to the default rather than raising" do
      for origin <- ["", "not a url", "://", "app.example.rs"] do
        resolve(origin)

        assert Gettext.get_locale() == Locales.default(),
               "#{inspect(origin)} should have resolved to the default"
      end
    end

    test "the resolved locale is on the conn as well as in the process" do
      conn = resolve("https://app.example.rs")

      assert conn.assigns.locale == "sr-Latn"
    end

    test "a port on the origin does not stop it resolving" do
      resolve("http://app.example.rs:4000")

      assert Gettext.get_locale() == "sr-Latn"
    end
  end

  describe "what the locale reaches" do
    test "the incompleteness notice comes back in the request's language" do
      resolve("https://app.example.rs")
      serbian = Profiles.incompleteness_notice()

      resolve("https://app.example.com")
      english = Profiles.incompleteness_notice()

      refute serbian == english
      assert english =~ "This record may be incomplete"
    end

    # The control for the row above. "Two strings differ" is satisfied by one of
    # them being empty, or by a lookup that returned the msgid unchanged, so the
    # Serbian one is required to be a real translation rather than merely not
    # the English.
    test "and the Serbian one is a translation rather than a blank or the msgid" do
      resolve("https://app.example.rs")
      serbian = Profiles.incompleteness_notice()

      assert serbian != ""
      refute serbian =~ "This record"
      assert serbian =~ "Ovaj zapis"
    end

    test "the notice is still arity zero, so it cannot become an oracle" do
      # `function_exported?/3` answers false for a module that is merely
      # compiled, so the load is what stops both assertions passing vacuously.
      {:module, _} = Code.ensure_loaded(Profiles)

      assert function_exported?(Profiles, :incompleteness_notice, 0)
      refute function_exported?(Profiles, :incompleteness_notice, 1)
    end
  end
end
