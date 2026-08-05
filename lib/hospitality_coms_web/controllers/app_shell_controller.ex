defmodule HospitalityComsWeb.AppShellController do
  @moduledoc """
  The last route, and the one that makes client-side routing work.

  The client routes in the browser: `/rooms`, `/peers`, `/profile`, `/claim`,
  and `/log-in/:token`. None of those is a path this application knows, so a
  request for one — a bookmark, a refresh, and above all a magic link followed
  out of a mail client — reaches the router and matches nothing. Without this it
  is a 404 and log-in is broken outright, which is why the magic-link path has a
  test of its own rather than being covered by the general case.

  ## Why it is a route rather than a plug after the router

  A plug placed after `HospitalityComsWeb.Router` never runs for an unmatched
  request: Phoenix raises `NoRouteError` inside the router rather than passing
  the connection on. So the fallback has to be a route, and it has to be the
  last one, which is what makes every real route win.

  ## It must not answer for the API, and that is the whole risk

  A catch-all registered at `/` also matches `/api/anything-unknown`. Answering
  those with HTML would break the error envelope every client is written
  against, and would turn the API's deliberately flat 404 — which discloses
  nothing about whether a venue, room or engagement exists — into a page.

  So the API prefix is answered here with exactly the envelope
  `HospitalityComsWeb.ErrorJSON` would have produced. The socket prefix is not
  reachable: it is handled by the endpoint before the router.

  Only `GET` is routed here. A `POST` to an unrouted path still raises through
  to the 404 envelope, because a browser navigating is a `GET` and anything else
  reaching an unknown path is a client bug rather than a page load.
  """

  use HospitalityComsWeb, :controller

  alias HospitalityComsWeb.ErrorEnvelope
  alias HospitalityComsWeb.Static

  @doc """
  Serves the page shell for the request's locale.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(%Plug.Conn{path_info: ["api" | _rest]} = conn, _params) do
    not_found(conn)
  end

  def index(conn, _params) do
    if asset_request?(conn), do: not_found(conn), else: serve_shell(conn)
  end

  # A path whose last segment carries an extension is asking for a file, not for
  # a page.
  #
  # Without this a missing asset falls through to the shell and is answered with
  # HTML and a 200 — so the browser fetches `/assets/app.js`, receives a
  # document, and fails parsing it as a script. The console error names a syntax
  # problem in the bundle, which is not where the fault is, and the network tab
  # shows a success. Sending the 404 that the request deserves is what makes a
  # deploy that dropped a file diagnosable.
  @spec asset_request?(Plug.Conn.t()) :: boolean()
  defp asset_request?(%Plug.Conn{path_info: []}), do: false

  defp asset_request?(%Plug.Conn{path_info: segments}) do
    segments |> List.last() |> String.contains?(".")
  end

  @spec serve_shell(Plug.Conn.t()) :: Plug.Conn.t()
  defp serve_shell(conn) do
    case conn |> Static.locale() |> Static.shell() do
      nil -> not_found(conn)
      html -> conn |> put_resp_content_type("text/html") |> send_resp(200, html)
    end
  end

  @spec not_found(Plug.Conn.t()) :: Plug.Conn.t()
  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_resp_content_type("application/json")
    |> json(ErrorEnvelope.for_status(404))
  end
end
