defmodule HospitalityComsWeb.Static do
  @moduledoc """
  Serving the built client, one bundle per locale, chosen by the request's host.

  `mix compile` does not build the client and nothing here does either. The
  build emits `priv/static/<locale>/`, one directory per locale in
  `priv/locales.json`, and this module is what decides which of them a request
  reaches.

  ## How the bundle is chosen

  `Plug.Static` takes its source directory as configuration, so this delegates
  to it with a directory chosen from the request's host. A request for
  `/assets/app.js` on the Serbian domain is served from
  `priv/static/sr-Latn/assets/app.js`, and the URL carries no locale segment —
  the domain already said which language this is.

  The obvious alternative is to rewrite `path_info` to put the locale first and
  let one `Plug.Static` serve the whole tree. It was tried and is worse:
  `Plug.Static` leaves `path_info` alone when it does not find a file, so the
  rewritten path reaches the router, and every route in the application would
  then be looking at a path with a locale glued to the front of it.

  `Plug.Static.init/1` runs per request rather than once. It is a keyword
  massage next to a filesystem read, and computing the directory at call time is
  what makes this resolve inside a release as well as in a checkout.

  ## What it does not touch

  The API and socket prefixes are left alone. They are the two things on this
  endpoint that are not the client, and rewriting their paths would break
  routing rather than produce a 404 — which is a failure that looks like the
  router being broken rather than like static serving being wrong.

  ## The endpoint used to say there was no static file serving

  It did, and it was true for twelve units. What changed is that the client is
  built per locale and something has to map a domain to one of those builds;
  doing it here keeps that decision in the same tree as
  `HospitalityComs.Locales`, inside the test suite, and same-origin by
  construction — so the API needs no CORS, which `client/vite.config.ts`
  already assumes.
  """

  @behaviour Plug

  alias HospitalityComs.Locales

  # The two prefixes on this endpoint that are not the client.
  @passthrough ["api", "socket"]

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{path_info: [first | _rest]} = conn, _opts) when first in @passthrough do
    conn
  end

  def call(conn, _opts) do
    static = Plug.Static.init(at: "/", from: conn |> locale() |> bundle_dir(), gzip: false)

    Plug.Static.call(conn, static)
  end

  @doc """
  The locale a request's `Host` names, or the default.

  Public because the app-shell fallback resolves the same request the same way,
  and a second spelling of "which bundle is this" is how the shell comes to be
  served from one locale while its assets come from another.
  """
  @spec locale(Plug.Conn.t()) :: String.t()
  def locale(conn), do: Locales.for_host(conn.host)

  @doc """
  Where a locale's built bundle lives, as an absolute path.

  `Application.app_dir/2` rather than a path relative to the project root, so it
  resolves inside a release as well as in a checkout.
  """
  @spec bundle_dir(String.t()) :: Path.t()
  def bundle_dir(locale), do: Application.app_dir(:hospitality_coms, ["priv", "static", locale])

  @doc """
  The page shell for a locale, or `nil` when that bundle has not been built.

  `nil` rather than a raise: a checkout that has never run the client build is
  the ordinary state of a server-side test run and of `mix phx.server` before
  `npm run build`, and a 404 explains that better than a 500 does.
  """
  @spec shell(String.t()) :: binary() | nil
  def shell(locale) do
    path = Path.join(bundle_dir(locale), "index.html")

    case File.read(path) do
      {:ok, html} -> html
      {:error, _reason} -> nil
    end
  end
end
