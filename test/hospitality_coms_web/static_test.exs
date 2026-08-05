defmodule HospitalityComsWeb.StaticTest do
  @moduledoc """
  Serving one bundle per locale, chosen by the request's host, and answering a
  client-side route with that bundle's page shell.

  ## The fixtures are written here rather than built

  These are Elixir tests and must not need Node, so they write two small
  bundles into `priv/static` and remove them again. The cost is real and is
  paid in CI: a fixture proves the host chooses the directory and proves
  nothing about whether the client build puts files where this expects them.
  The build step in `.github/workflows/ci.yml` is what closes that.

  ## No fixture shares a string between locales

  Every file below differs between the two bundles and neither value is a
  substring of the other. A fixture where they agree makes "the Serbian host is
  served the Serbian bundle" pass against a plug that always serves the same
  directory, which is the failure this file is most exposed to.
  """

  use HospitalityComsWeb.ConnCase, async: false

  alias HospitalityComsWeb.Static

  @en_shell "<!doctype html><html lang=\"en\"><title>Hospitality Coms</title></html>"
  @sr_shell "<!doctype html><html lang=\"sr-Latn\"><title>Ugostiteljske komunikacije</title></html>"
  @en_asset "console.log('english bundle');"
  @sr_asset "console.log('serbian bundle');"

  setup do
    write_bundle("en", @en_shell, @en_asset)
    write_bundle("sr-Latn", @sr_shell, @sr_asset)

    on_exit(fn ->
      File.rm_rf!(Static.bundle_dir("en"))
      File.rm_rf!(Static.bundle_dir("sr-Latn"))
    end)

    :ok
  end

  defp write_bundle(locale, shell, asset) do
    dir = Static.bundle_dir(locale)

    File.mkdir_p!(Path.join(dir, "assets"))
    File.write!(Path.join(dir, "index.html"), shell)
    File.write!(Path.join([dir, "assets", "app.js"]), asset)
  end

  defp on_host(conn, host), do: %{conn | host: host}

  describe "an asset request" do
    test "is served from the bundle its host names", %{conn: conn} do
      response =
        conn |> on_host("app.example.rs") |> get("/assets/app.js") |> response(200)

      assert response == @sr_asset
    end

    # The control. Without it, a plug hardcoded to one directory passes the row
    # above whenever that directory happens to be the Serbian one.
    test "and the other host gets the other bundle", %{conn: conn} do
      response =
        conn |> on_host("app.example.com") |> get("/assets/app.js") |> response(200)

      assert response == @en_asset
    end

    test "an unmapped host is served the default bundle", %{conn: conn} do
      response =
        conn |> on_host("unknown.example.net") |> get("/assets/app.js") |> response(200)

      assert response == @en_asset
    end

    test "a file neither bundle holds is a 404 rather than the shell", %{conn: conn} do
      conn = conn |> on_host("app.example.rs") |> get("/assets/missing.js")

      assert conn.status == 404
      refute conn.resp_body == @sr_shell
    end
  end

  describe "a client-side route" do
    test "is answered with the page shell", %{conn: conn} do
      response = conn |> on_host("app.example.rs") |> get("/rooms") |> response(200)

      assert response == @sr_shell
    end

    # Named separately from the row above because this is the one whose failure
    # breaks log-in outright: the link arrives from a mail client, and a 404
    # reads as a broken link rather than as a missing route.
    test "including the magic-link path, which is how log-in completes", %{conn: conn} do
      response =
        conn |> on_host("app.example.rs") |> get("/log-in/some-token") |> response(200)

      assert response == @sr_shell
    end

    test "in the language of the host that asked", %{conn: conn} do
      assert conn |> on_host("app.example.com") |> get("/profile") |> response(200) == @en_shell
      assert conn |> on_host("app.example.rs") |> get("/profile") |> response(200) == @sr_shell
    end

    test "and a 404 when that bundle has not been built", %{conn: conn} do
      File.rm_rf!(Static.bundle_dir("sr-Latn"))

      conn = conn |> on_host("app.example.rs") |> get("/rooms")

      assert conn.status == 404
    end
  end

  describe "what the fallback must not answer for" do
    test "an unknown API path keeps the JSON error envelope", %{conn: conn} do
      conn = conn |> on_host("app.example.rs") |> get("/api/nothing-here")

      assert json_response(conn, 404) == %{
               "error" => %{"code" => "not_found", "message" => "Not Found"}
             }
    end

    test "which is the same body a known-shape API 404 produces", %{conn: conn} do
      # The control for the row above: it pins the envelope's shape rather than
      # merely that the response was not HTML.
      conn = conn |> on_host("app.example.com") |> get("/api/also-nothing")

      refute conn.resp_body == @en_shell
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "a write to an unrouted path is not answered with the shell", %{conn: conn} do
      # The catch-all is `GET` only, so this reaches no route. What matters is
      # the answer rather than which exception carried it: a browser navigating
      # is a `GET`, and a write to an unknown path is a client bug.
      conn = conn |> on_host("app.example.rs") |> post("/rooms", %{})

      assert conn.status == 404
      refute conn.resp_body == @sr_shell
    end

    test "a real API route still works with the static plug in front of it", %{conn: conn} do
      # The plug runs before every request. This is the row that fails if it
      # ever starts consuming paths it should pass through.
      conn = conn |> on_host("app.example.rs") |> get("/api/me")

      assert conn.status == 401
    end
  end
end
