defmodule HospitalityComsWeb.EmployerController do
  @moduledoc """
  The employer's half of the API: the venues a session may act for, and the
  people engaged at one of them.

  Until now the employer's half of this application was asserted in tests and
  carried by a channel with no events. These are its first two routes, and the
  shape they establish is the one every later employer route copies.

      GET /api/employer/venues                          the venues this session may act for
      GET /api/employer/venues/:venue_id/engagements    that venue's people, now

  ## There is no employer pipeline, and there must not be one

  Both routes sit on `:authenticated_person`. Authority here is per venue and
  the venue is a path parameter, so a pipeline would have to know which venue
  before the router had parsed one. What replaces it is
  `HospitalityComsWeb.EmployerAuth.employer_scope/2`, called inside each action
  that names a venue, resolving the acting grant against the database on every
  request.

  The venue list needs no such resolution: it *is* the question "which venues",
  so it takes the person scope straight from `conn.assigns.current_scope`.

  ## Nothing rendered here names a human

  `HospitalityComs.Engagements.list_engagements/1` returns whole `Engagement`
  structs, and one of their fields is `person_id` — the globally stable
  cross-venue key that `CLAUDE.md` records as a live disclosure, because two
  venues comparing ids out of band can determine that the same human works at
  both. So this renders a **field list**: `engagement_id`, `role_label`,
  `starts_at`, `ends_at`, and nothing else.

  There is nothing else to withhold. `people` carries exactly one identifying
  column, `email`, and there is no person-name column anywhere in the schema
  (D2) — so a worker on this surface is a role label, a term, and a venue-local
  engagement id. The interface says that rather than papering over it.

  The `@spec` on each render function names every key, which is what Dialyzer
  checks; `employer_controller_test.exs` asserts the key set against a literal,
  which is what fails when a field is *added*. An absence assertion would not.

  ## Every refusal is `404`, and R17 forces it

  `HospitalityComs.Engagements.fetch_grant_holding_engagement/2` answers
  `:no_grant` identically for an ended engagement, an engagement holding
  nothing, a revoked grant, and a venue that does not exist. A status that
  varied by cause would break that flatness, and `403` would confirm the venue
  exists. So all of them, plus a malformed id, are one sentence: *no such venue,
  or it is not one you can act for.*

  `HospitalityComsWeb.EmployerVenueChannel` answers the same condition
  `unauthorized`. That divergence is deliberate and the argument is in
  `HospitalityComsWeb.EmployerAuth`'s moduledoc.

  ## The rate limiter is not extended to these routes

  `HospitalityComsWeb.LoginRateLimit` sits in front of `POST /api/log-in` alone,
  because that is "the only endpoint an anonymous caller can use to write a row
  and send an email" — the router's own words. Both routes here need a live
  session and write nothing. Considered, and deliberately not added; `CLAUDE.md`
  files fan-out and abuse control under issue #15, which is where a real answer
  belongs. **The employer surface's first *write* route is U2's, and that is the
  unit that has to revisit this paragraph rather than inherit it.**
  """

  use HospitalityComsWeb, :controller

  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Venues.Venue
  alias HospitalityComsWeb.EmployerAuth
  alias HospitalityComsWeb.EntityId
  alias HospitalityComsWeb.ErrorEnvelope

  @no_venue "no such venue, or it is not one you can act for"

  @doc """
  The venues this session may act for at the request's instant.

  Venues where this person holds an engagement carrying a grant the venue has
  not revoked — **suspensions not consulted**, which is the whole reason this is
  not `GET /api/venue-rooms`. See
  `HospitalityComs.Engagements.list_managed_venues/1`.

  A person who manages nothing gets `200` and an empty list rather than a
  refusal (AE10): having no authority anywhere is not an error, and the sentence
  that says so belongs on the page.
  """
  @spec venues(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def venues(conn, _params) do
    %PersonScope{} = scope = conn.assigns.current_scope

    json(conn, %{venues: Enum.map(Engagements.list_managed_venues(scope), &render_venue/1)})
  end

  @doc """
  The venue's engagements that are active at the request's instant, oldest first.

  Membership, in other words, and nothing stores it: the same request a minute
  after a term's upper bound returns a shorter list with no job having run.
  """
  @spec engagements(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def engagements(conn, %{"venue_id" => venue_id}) do
    %PersonScope{} = scope = conn.assigns.current_scope

    with {:ok, id} <- EntityId.cast(venue_id),
         {:ok, employer} <- EmployerAuth.employer_scope(scope, id),
         {:ok, engagements} <- Engagements.list_engagements(employer) do
      json(conn, %{engagements: Enum.map(engagements, &render_engagement/1)})
    else
      :error -> not_found(conn)
      {:error, :no_grant} -> not_found(conn)
    end
  end

  @spec render_venue(Venue.t()) :: %{venue_id: Ecto.UUID.t(), name: String.t()}
  defp render_venue(%Venue{} = venue) do
    %{venue_id: venue.id, name: venue.name}
  end

  # `engagement_id` rather than `id`, because a venue's people list is rendered
  # beside rosters and messages that already spell an engagement that way
  # (KTD15b's `author_engagement_id`), and one entity gets one key name across
  # this API.
  #
  # **No `person_id`, and the omission is the point.** The instants ship as
  # ISO-8601 and are formatted on the client, which is where the reader's
  # timezone is known — `HospitalityComsWeb.RoomController` says the same of a
  # shift room's term.
  @spec render_engagement(Engagement.t()) :: %{
          engagement_id: Ecto.UUID.t(),
          role_label: String.t(),
          starts_at: String.t(),
          ends_at: String.t()
        }
  defp render_engagement(%Engagement{} = engagement) do
    %{
      engagement_id: engagement.id,
      role_label: engagement.role_label,
      starts_at: DateTime.to_iso8601(engagement.starts_at),
      ends_at: DateTime.to_iso8601(engagement.ends_at)
    }
  end

  @spec not_found(Plug.Conn.t()) :: Plug.Conn.t()
  defp not_found(conn), do: refuse(conn, :not_found, @no_venue)

  # The status atom is the envelope's code, so the two cannot drift apart —
  # `HospitalityComsWeb.RoomController`'s shape, for the same reason.
  @spec refuse(Plug.Conn.t(), atom(), String.t()) :: Plug.Conn.t()
  defp refuse(conn, status, message) do
    conn
    |> put_status(status)
    |> json(ErrorEnvelope.new(status, message))
  end
end
