defmodule HospitalityComsWeb.Locale do
  @moduledoc """
  Which language this request is answered in.

  The domain decides, and the domain reaches an API request as its `Origin`
  header. This plug resolves that through `HospitalityComs.Locales` and calls
  `Gettext.put_locale/1`, so everything downstream — a changeset error rendered
  by `HospitalityComsWeb.ErrorEnvelope`, an email written by
  `HospitalityComs.Accounts.PersonNotifier`, the notice
  `HospitalityComs.Profiles` carries — answers in that language without being
  handed a parameter.

  ## `Origin` rather than `Host` or `Referer`

  `Referer` is not available: `client/index.html` sets a `no-referrer` policy on
  purpose, to keep a magic-link token out of the headers of everything the
  redeem page loads next.

  `Host` names the server the request reached, which is the same thing for the
  client Phoenix serves and is *not* the same thing for an API called from
  elsewhere. `Origin` names where the page came from, which is what a magic
  link has to point back at, and the Fetch specification sends it on every
  request whose method is not `GET` or `HEAD` — which is every write on this
  API, `POST /api/log-in` included.

  A `GET` may therefore carry no `Origin` at all, and this plug answers the
  default for it rather than refusing. Nothing on the read side is
  locale-sensitive except copy the client already holds, so the default is
  always a correct answer; and an endpoint that 400'd on a missing optional
  header would be a new way for a public API to be unusable.

  ## It reads no clock

  Nothing here derives an instant, so it is deliberately **not** an entry in
  `.credo.exs`'s `:boundary_modules`. An entry appearing there would be the tell
  that it started reading one. This is the same posture
  `HospitalityComsWeb.LoginRateLimit` takes, which derives its window from the
  instant already on the scope.

  ## The locale is on the conn as well as in the process

  `Gettext.put_locale/1` is process-scoped, which is enough for everything that
  renders text. `conn.assigns.locale` is for the one caller that needs the value
  rather than the effect: building a magic link against the domain the request
  came from.
  """

  import Plug.Conn

  alias HospitalityComs.Locales

  @doc """
  Resolves the request's locale from `Origin`, and puts it in force.
  """
  @spec put_locale(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def put_locale(conn, _opts) do
    locale =
      conn
      |> get_req_header("origin")
      |> List.first()
      |> Locales.for_origin()

    Gettext.put_locale(locale)

    assign(conn, :locale, locale)
  end
end
