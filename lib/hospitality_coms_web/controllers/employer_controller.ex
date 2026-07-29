defmodule HospitalityComsWeb.EmployerController do
  @moduledoc """
  The employer's half of the API: the venues a session may act for, the people
  engaged at one of them, and the offer that brings somebody new onto it.

  Until now the employer's half of this application was asserted in tests and
  carried by a channel with no events. These are its first routes, and the shape
  they establish is the one every later employer route copies.

      GET  /api/employer/venues                          the venues this session may act for
      GET  /api/employer/venues/:venue_id/engagements    that venue's people, now
      POST /api/employer/venues/:venue_id/invitations    an offer, and the code that redeems it

  ## There is no employer pipeline, and there must not be one

  Every route sits on `:authenticated_person`. Authority here is per venue and
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

  `Invitation` is the second whole-struct disclosure `CLAUDE.md` records, for a
  different reason: `employer_role` holds table-level `SELECT` on `invitations`,
  so `claim_code_digest` comes back with every row. It is SHA-256 of 32 random
  bytes and cannot be turned back into a code, but a response rendering the
  struct wholesale ships it anyway. So the issued offer is a field list too, and
  the plaintext code sits **beside** the invitation rather than inside it — the
  row holds only a digest, and the shape says so.

  The `@spec` on each render function names every key, which is what Dialyzer
  checks; `employer_controller_test.exs` asserts the key set against a literal,
  which is what fails when a field is *added*. An absence assertion would not.

  ## The offer takes four fields off the body, and `grant_id` is not one

  An invitation that carries a `grant_id` is an invitation to *manage* rather
  than to work: it is what makes the next holder of an administrative authority
  (KTD17). `HospitalityComs.Engagements.issue_invitation/2` accepts one and
  checks it against the venue's live grants, and the crude form does not offer
  it — so this action casts exactly `role_label`, `starts_at`, `ends_at` and
  `code_expires_at`, and a body naming anything else is ignored rather than
  passed through. Widening that list is how a form that hires a worker comes to
  mint a manager.

  **The consequence is that `issue_invitation/2`'s `:grant_not_live` arm is
  unreachable from this route**, and it is handled anyway, because a clause that
  does not exist would return the error tuple out of the action and Phoenix
  would raise on a connection nothing had sent. It is carried untested and this
  is where that is recorded; the arm itself is covered at the context level in
  `engagements_test.exs`. The *claim* route's matching arm **is** reachable and
  is tested — see `HospitalityComsWeb.ClaimController`.

  ## The three instants are defaulted here, not in a browser

  A crude form cannot ask for three date-times, and a client that computed them
  would be a second clock: `HospitalityComs.Clock.Offset` moves this server's
  instant and would not move a browser's, so U11's demo controls would
  desynchronise the two. All three are optional and filled from the scope's
  instant — `starts_at` now, `ends_at` in ninety days, `code_expires_at` in
  seven.

  `starts_at` is *now* rather than any later instant because
  `list_engagements/1` is active-at-instant: a term opening tomorrow would
  produce, on claim, an engagement the issuing manager's own people list does
  not show, which reads as the claim having failed.

  **Seven and fourteen are independent constants** (issue #42). The default is
  not derived from `Invitation.max_code_validity_in_days/0`, and the only
  relationship asserted between them is a test: the default lands strictly
  inside the bound. A checkable relationship rather than a sentence.

  A body carrying an explicit `null` for one of the three is **not** defaulted —
  `Map.put_new/3` does not replace a present key — so it casts to nil and comes
  back a field error. A client sending null is a client bug and `422` naming the
  field is the honest answer.

  ## Every refusal about a venue is `404`, and R17 forces it

  `HospitalityComs.Engagements.fetch_grant_holding_engagement/2` answers
  `:no_grant` identically for an ended engagement, an engagement holding
  nothing, a revoked grant, and a venue that does not exist. A status that
  varied by cause would break that flatness, and `403` would confirm the venue
  exists. So all of them, plus a malformed id, are one sentence: *no such venue,
  or it is not one you can act for.*

  A rejected *offer* is a different thing and answers `422` with the fields it
  rejected, through `HospitalityComsWeb.ErrorEnvelope.for_changeset/3`. Nothing
  is disclosed by it: the session has already proved it may act for the venue,
  so the only news in the body is what it just sent.

  `HospitalityComsWeb.EmployerVenueChannel` answers the same `:no_grant`
  condition `unauthorized`. That divergence is deliberate and the argument is in
  `HospitalityComsWeb.EmployerAuth`'s moduledoc.

  ## The rate limiter, revisited now that this surface writes

  `HospitalityComsWeb.LoginRateLimit` sits in front of `POST /api/log-in` alone,
  because that is "the only endpoint an anonymous caller can use to write a row
  and send an email" — the router's own words. U1 left this paragraph saying the
  first employer *write* route was the unit that had to revisit it rather than
  inherit it. This is that unit, and the answer is still no.

  The offer route writes one row, needs a live session **and** a live grant at
  the named venue resolved against the database, and sends no mail. What it can
  be abused for is fan-out: a manager issuing unbounded offers at their own
  venue, each of which is unclaimed, names nobody and grants nothing until
  somebody redeems it. That is the same unbounded-outstanding-requests shape
  `CLAUDE.md` records for peer requests and files under issue #15, and it wants
  one answer for the whole API rather than a counter bolted onto this action.

  Recorded rather than left implicit: a per-venue cap on outstanding invitations
  is the obvious mitigation and is not built here.
  """

  use HospitalityComsWeb, :controller

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Invitation
  alias HospitalityComs.Venues.Venue
  alias HospitalityComsWeb.EmployerAuth
  alias HospitalityComsWeb.EntityId
  alias HospitalityComsWeb.ErrorEnvelope

  @no_venue "no such venue, or it is not one you can act for"
  @rejected_offer "the offer was not accepted"
  @grant_not_live "the authority this offer would confer is no longer live"

  # KTD-E5. Independent constants: the seven is not derived from
  # `Invitation.max_code_validity_in_days/0` and must not become so (issue #42).
  @default_term_in_days 90
  @default_code_validity_in_days 7

  # Exactly what a caller may name. `grant_id` is deliberately absent — see the
  # moduledoc.
  @offer_fields ~w(role_label starts_at ends_at code_expires_at)

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

  @doc """
  Issues an offer at this venue and returns the code that redeems it, once.

  `role_label` is the only field a caller must send. The three instants default
  from the request's instant, and the code is plaintext in this response and
  nowhere else: the row keeps only its SHA-256 digest, so nothing — not this
  API, not a `SELECT`, not a backup — can produce it again (D4).

  No contact identifier is stored and no person row is created (R1). An
  unclaimed invitation names nobody and grants nothing.
  """
  @spec create_invitation(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_invitation(conn, %{"venue_id" => venue_id} = params) do
    %PersonScope{} = scope = conn.assigns.current_scope

    with {:ok, id} <- EntityId.cast(venue_id),
         {:ok, employer} <- EmployerAuth.employer_scope(scope, id),
         {:ok, issued} <- Engagements.issue_invitation(employer, offer(params, employer)) do
      conn
      |> put_status(:created)
      |> json(%{invitation: render_invitation(issued.invitation), claim_code: issued.claim_code})
    else
      :error -> not_found(conn)
      {:error, :no_grant} -> not_found(conn)
      {:error, :grant_not_live} -> refuse(conn, :conflict, @grant_not_live)
      {:error, %Ecto.Changeset{} = changeset} -> rejected(conn, changeset)
    end
  end

  # Four fields off the body and three defaults, and neither half is negotiable:
  # `Map.take/2` is what stops a `grant_id` reaching the changeset, and the
  # instant is the scope's rather than a second reading of the clock (KTD-E1).
  @spec offer(map(), EmployerScope.t()) :: map()
  defp offer(params, %EmployerScope{now: now}) do
    params
    |> Map.take(@offer_fields)
    |> Map.put_new("starts_at", now)
    |> Map.put_new("ends_at", DateTime.add(now, @default_term_in_days, :day))
    |> Map.put_new("code_expires_at", DateTime.add(now, @default_code_validity_in_days, :day))
  end

  # **No `claim_code_digest`**, which is the omission this shape exists for, and
  # no `venue_id`: the caller named it in the path. `invitation_id` rather than
  # `id`, for the reason an engagement is `engagement_id`.
  @spec render_invitation(Invitation.t()) :: %{
          invitation_id: Ecto.UUID.t(),
          role_label: String.t(),
          starts_at: String.t(),
          ends_at: String.t(),
          code_expires_at: String.t()
        }
  defp render_invitation(%Invitation{} = invitation) do
    %{
      invitation_id: invitation.id,
      role_label: invitation.role_label,
      starts_at: DateTime.to_iso8601(invitation.starts_at),
      ends_at: DateTime.to_iso8601(invitation.ends_at),
      code_expires_at: DateTime.to_iso8601(invitation.code_expires_at)
    }
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

  @spec rejected(Plug.Conn.t(), Ecto.Changeset.t(Invitation.t())) :: Plug.Conn.t()
  defp rejected(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorEnvelope.for_changeset(:unprocessable_entity, @rejected_offer, changeset))
  end

  # The status atom is the envelope's code, so the two cannot drift apart —
  # `HospitalityComsWeb.RoomController`'s shape, for the same reason.
  @spec refuse(Plug.Conn.t(), atom(), String.t()) :: Plug.Conn.t()
  defp refuse(conn, status, message) do
    conn
    |> put_status(status)
    |> json(ErrorEnvelope.new(status, message))
  end
end
