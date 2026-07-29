defmodule HospitalityComsWeb.EmployerController do
  @moduledoc """
  The employer's half of the API: the venues a session may act for, the people
  engaged at one of them, and the offer that brings somebody new onto it.

  Until now the employer's half of this application was asserted in tests and
  carried by a channel with no events. These are its first routes, and the shape
  they establish is the one every later employer route copies.

      GET    /api/employer/venues                        the venues this session may act for
      GET    .../venues/:id/engagements                  that venue's people, now
      POST   .../venues/:id/invitations                  an offer, and the code that redeems it
      GET    .../venues/:id/shift-types                  the kinds of shift this venue runs
      POST   .../venues/:id/shift-rooms                  tonight's shift
      GET    .../venues/:id/shift-rooms                  the venue's shifts, most recent first
      POST   .../shift-rooms/:id/roster                  put an engagement on one
      GET    .../shift-rooms/:id/roster                  who is on it now
      DELETE .../shift-rooms/:id/roster/:engagement_id   take them off it

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

  ## A shift room *is* the shift, and its list is bounded

  There is no `shifts` table and there never was one: a shift room is a term, a
  shift type, and the grace its type gives it. So `POST shift-rooms` names a
  type and two instants, and `venue_id` and `grace_period_minutes` are **not
  castable** — both come off the shift type
  `HospitalityComs.Rooms.create_shift_room/3` resolves inside its own
  transaction. A `venue_id` arriving in user attributes is a cross-tenant write
  waiting for somebody to forget to strip it, and a castable grace would let one
  room outlive the type that justified it.

  The list is bounded to `HospitalityComs.Rooms.recent_shift_room_limit/0` and
  `?extent=all` lifts it, exactly as `HospitalityComsWeb.RoomController`'s
  history reads work, through the same `HospitalityComsWeb.Extent`. **The bound
  selects the venue's *latest* rooms**, which is R11 and is not what a limit on
  the rota's own order would have done — see
  `HospitalityComs.Rooms.Records.most_recent_rooms/2`.

  ## The roster's refusals are flat, and that includes "already rostered"

  R15: *"Rostering an engagement that is already rostered, or naming a shift
  room or engagement that does not belong to this venue, is refused without
  disclosing which."* Four conditions, one answer — the same `404` and the same
  sentence an id naming nothing gets. `HospitalityComs.Rosters` distinguishes
  `:already_rostered` from `:not_found` internally and this is where the
  distinction stops.

  **The counter-argument is recorded rather than acted on**, because it is a
  good one and reversing this is a requirement change rather than a bug fix.
  `:already_rostered` is reachable only after both ids have resolved *inside the
  caller's own venue* — `add_to_roster/3` checks the grant, then the room at
  this venue, then a live engagement at this venue, and only then whether an
  open entry exists — so it would disclose nothing the same session cannot read
  from `GET …/roster`. That is exactly `HospitalityComsWeb.ClaimController`'s
  argument for R6's three distinguishable refusals. What flatness costs is
  operator feedback: a manager who adds the same person twice is told there is
  no such shift room or engagement, which is true and unhelpful.

  **The changeset arm collapses into the same answer**, and that is not
  sloppiness. `HospitalityComs.Rosters.RosterEntry.join_changeset/3` casts
  nothing from user attributes, so the only changeset `add_to_roster/3` can
  produce is `roster_entries_no_overlap` — which is `:already_rostered` reached
  by losing a race rather than by the friendly check. One condition, one answer.
  It needs two concurrent callers and is therefore carried untested here;
  `HospitalityComs.RostersTest` and `HospitalityComs.RoomsConcurrencyTest` own
  it.

  ## Removing closes a period, so the answer is `204` and not the row

  `remove_from_roster/3` sets `left_at` and keeps the row (KTD6b) — access
  somebody has already earned by overlapping a room's open window cannot be
  withdrawn by any write this application permits. Handing the closed entry back
  would give a client a row it must not render, so the answer is `204` with no
  body and the client re-reads the roster.

  ## A missing id in a body is `400`; a present one that names nothing is `404`

  `shift_type_id` and `engagement_id` arrive in request bodies rather than
  paths, so there are two distinct failures. Naming nothing at all is a client
  bug and answers `400` with the field's name, which is
  `HospitalityComsWeb.ClaimController`'s shape for a request carrying no
  `claim_code`. Naming something malformed, something unknown, or something
  belonging to another venue is the flat `404` — `HospitalityComsWeb.EntityId`
  is what keeps the malformed one out of Ecto's query builder, where it would
  raise and answer `500`, telling a caller malformed from unknown by the status.

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
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.MessagePage
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rooms.ShiftRoomPage
  alias HospitalityComs.Rosters
  alias HospitalityComs.Rosters.RosterEntry
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.ShiftType
  alias HospitalityComs.Venues.Venue
  alias HospitalityComsWeb.EmployerAuth
  alias HospitalityComsWeb.EntityId
  alias HospitalityComsWeb.ErrorEnvelope
  alias HospitalityComsWeb.Extent
  alias HospitalityComsWeb.RoomController

  @no_venue "no such venue, or it is not one you can act for"
  @no_shift_type "no such shift type at this venue"
  @no_shift_room "no such shift room at this venue"
  @no_roster_target "no such shift room or engagement here, or the roster already says otherwise"
  @rejected_offer "the offer was not accepted"
  @rejected_shift "the shift was not accepted"
  @grant_not_live "the authority this offer would confer is no longer live"
  @shift_type_required "shift_type_id is required"
  @engagement_required "engagement_id is required"

  # KTD-E5. Independent constants: the seven is not derived from
  # `Invitation.max_code_validity_in_days/0` and must not become so (issue #42).
  @default_term_in_days 90
  @default_code_validity_in_days 7

  # Exactly what a caller may name. `grant_id` is deliberately absent — see the
  # moduledoc.
  @offer_fields ~w(role_label starts_at ends_at code_expires_at)

  # And exactly what a caller may name about a shift. `venue_id` and
  # `grace_period_minutes` are absent because both come off the resolved shift
  # type; `shift_type_id` is absent because it is an argument rather than an
  # attribute, cast before the context is called.
  @term_fields ~w(starts_at ends_at)

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

  @doc """
  The kinds of shift this venue runs, oldest first.

  A venue with none answers `200 []` rather than a refusal: the venue exists and
  this session may act for it, and having configured nothing is not an error. It
  does mean no shift can be created there, which is a gap in the seed rather
  than in this route.
  """
  @spec shift_types(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def shift_types(conn, %{"venue_id" => venue_id}) do
    %PersonScope{} = scope = conn.assigns.current_scope

    with {:ok, id} <- EntityId.cast(venue_id),
         {:ok, employer} <- EmployerAuth.employer_scope(scope, id),
         {:ok, types} <- Venues.list_shift_types(employer) do
      json(conn, %{shift_types: Enum.map(types, &render_shift_type/1)})
    else
      :error -> not_found(conn)
      {:error, :no_grant} -> not_found(conn)
    end
  end

  @doc """
  Creates tonight's shift: a room of the named type, over the named term.

  The type is resolved against the database at this venue, and the room's
  `venue_id` and `grace_period_minutes` come from it rather than from the body.
  See the moduledoc.
  """
  @spec create_shift_room(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_shift_room(conn, %{"venue_id" => venue_id, "shift_type_id" => type} = params) do
    %PersonScope{} = scope = conn.assigns.current_scope

    with {:ok, id} <- EntityId.cast(venue_id),
         {:ok, employer} <- EmployerAuth.employer_scope(scope, id),
         {:ok, type_id} <- named(type),
         {:ok, room} <- Rooms.create_shift_room(employer, type_id, term(params)) do
      conn
      |> put_status(:created)
      |> json(%{shift_room: RoomController.rendered_shift_room(room)})
    else
      :error -> not_found(conn)
      {:error, :no_grant} -> not_found(conn)
      {:error, :not_found} -> no_shift_type(conn)
      {:error, %Ecto.Changeset{} = changeset} -> rejected_shift(conn, changeset)
    end
  end

  def create_shift_room(conn, _params), do: refuse(conn, :bad_request, @shift_type_required)

  @doc """
  The venue's shift rooms, most recent first and bounded unless `extent=all`.

  "Most recent" is by the shift's own start, and the page comes back earliest
  first within itself so that a rota reads forwards. `complete` says whether the
  page is the lot; a caller cannot work that out from the list, because a full
  page and a full history of the same length are the same list.
  """
  @spec shift_rooms(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def shift_rooms(conn, %{"venue_id" => venue_id} = params) do
    %PersonScope{} = scope = conn.assigns.current_scope

    with {:ok, id} <- EntityId.cast(venue_id),
         {:ok, extent} <- Extent.cast(params),
         {:ok, employer} <- EmployerAuth.employer_scope(scope, id),
         {:ok, %ShiftRoomPage{} = page} <- Rooms.list_shift_rooms(employer, extent) do
      json(conn, %{
        shift_rooms: Enum.map(page.rooms, &RoomController.rendered_shift_room/1),
        complete: page.complete
      })
    else
      :error -> refuse_cast(conn, params)
      {:error, :no_grant} -> not_found(conn)
    end
  end

  @doc """
  Puts an engagement on a shift room's roster, from this request's instant.

  The entry has no upper bound until somebody removes it, so a person added
  mid-shift is a member for the rest of the room's open window. An engagement
  whose term has not opened yet is accepted — that is what a rota is for — and
  confers nothing until it does.
  """
  @spec create_roster_entry(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_roster_entry(
        conn,
        %{
          "venue_id" => venue_id,
          "shift_room_id" => shift_room_id,
          "engagement_id" => engagement_id
        }
      ) do
    %PersonScope{} = scope = conn.assigns.current_scope

    with {:ok, id} <- EntityId.cast(venue_id),
         {:ok, employer} <- EmployerAuth.employer_scope(scope, id),
         {:ok, room_id} <- named(shift_room_id),
         {:ok, held} <- named(engagement_id),
         {:ok, entry} <- Rosters.add_to_roster(employer, room_id, held) do
      conn
      |> put_status(:created)
      |> json(%{roster_entry: render_roster_entry(entry)})
    else
      :error -> not_found(conn)
      {:error, :no_grant} -> not_found(conn)
      {:error, :not_found} -> no_roster_target(conn)
      {:error, :already_rostered} -> no_roster_target(conn)
      {:error, %Ecto.Changeset{}} -> no_roster_target(conn)
    end
  end

  def create_roster_entry(conn, _params), do: refuse(conn, :bad_request, @engagement_required)

  @doc """
  The shift room's roster at this request's instant, earliest joined first.

  Entries whose period contains the instant, each naming the engagement and its
  role label. Not the room's membership — an entry can be live before the room
  opens — and not its readers, which includes closed periods that overlapped.
  """
  @spec roster(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def roster(conn, %{"venue_id" => venue_id, "shift_room_id" => shift_room_id}) do
    %PersonScope{} = scope = conn.assigns.current_scope

    with {:ok, id} <- EntityId.cast(venue_id),
         {:ok, employer} <- EmployerAuth.employer_scope(scope, id),
         {:ok, room_id} <- named(shift_room_id),
         {:ok, entries} <- Rosters.list_roster(employer, room_id) do
      json(conn, %{roster: Enum.map(entries, &render_roster_entry/1)})
    else
      :error -> not_found(conn)
      {:error, :no_grant} -> not_found(conn)
      {:error, :not_found} -> no_shift_room(conn)
    end
  end

  @doc """
  Takes an engagement off a shift room's roster, closing its period at this
  request's instant.

  `204`, and the row stays. See the moduledoc.
  """
  @spec delete_roster_entry(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_roster_entry(conn, %{
        "venue_id" => venue_id,
        "shift_room_id" => shift_room_id,
        "engagement_id" => engagement_id
      }) do
    %PersonScope{} = scope = conn.assigns.current_scope

    with {:ok, id} <- EntityId.cast(venue_id),
         {:ok, employer} <- EmployerAuth.employer_scope(scope, id),
         {:ok, room_id} <- named(shift_room_id),
         {:ok, held} <- named(engagement_id),
         {:ok, _entry} <- Rosters.remove_from_roster(employer, room_id, held) do
      send_resp(conn, :no_content, "")
    else
      :error -> not_found(conn)
      {:error, :no_grant} -> not_found(conn)
      {:error, :not_found} -> no_roster_target(conn)
      {:error, :not_rostered} -> no_roster_target(conn)
    end
  end

  # An id a client named, refused the way the context refuses one that names
  # nothing.
  #
  # **The venue is cast separately, before this, and that ordering is the
  # design.** A malformed venue id has to answer what an unresolvable venue
  # answers (R17); a malformed *shift room* or *engagement* id has to answer
  # what an id naming nothing answers, which is a different sentence and a
  # different requirement (R15). One `EntityId.cast/1` in a `with` cannot tell
  # the two apart, because both arms are `:error`.
  @spec named(String.t()) :: {:ok, Ecto.UUID.t()} | {:error, :not_found}
  defp named(id), do: id |> EntityId.cast() |> cast_or_refuse()

  @spec cast_or_refuse({:ok, Ecto.UUID.t()} | :error) ::
          {:ok, Ecto.UUID.t()} | {:error, :not_found}
  defp cast_or_refuse({:ok, id}), do: {:ok, id}
  defp cast_or_refuse(:error), do: {:error, :not_found}

  # Two instants off the body and nothing else. The shift type is a positional
  # argument to `create_shift_room/3` and the room's venue and grace come off
  # it, so `Map.take/2` here is what stops either arriving from a client.
  @spec term(map()) :: map()
  defp term(params), do: Map.take(params, @term_fields)

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

  # `venue_id` is *not* rendered: the caller named it in the path, and a shift
  # type has no other field. `grace_period_minutes` is here because it is the
  # only thing that distinguishes two types with similar names, and because it
  # is what a manager is choosing between.
  @spec render_shift_type(ShiftType.t()) :: %{
          shift_type_id: Ecto.UUID.t(),
          name: String.t(),
          grace_period_minutes: non_neg_integer()
        }
  defp render_shift_type(%ShiftType{} = shift_type) do
    %{
      shift_type_id: shift_type.id,
      name: shift_type.name,
      grace_period_minutes: shift_type.grace_period_minutes
    }
  end

  # **A field list off a preloaded `Engagement`**, and that is the reason for
  # the shape rather than tidiness: an `Engagement` carries `person_id`, the
  # globally stable cross-venue key `CLAUDE.md` records as a live disclosure. A
  # roster rendered wholesale would hand a manager the identity key of everybody
  # on the shift.
  #
  # `engagement_id` is the entry's identity on this API — it is what the
  # removal route names, and `roster_entries_no_overlap` plus
  # `Records.rostered_at/2` mean at most one live entry per engagement per room,
  # so it is unique within the response. The entry's own id is not rendered
  # because no route takes one.
  #
  # `left_at` is not rendered either: every entry in this list is live at the
  # request's instant, so the column is null or in the future, and shipping it
  # would invite a client to render a closed period.
  @spec render_roster_entry(RosterEntry.t()) :: %{
          engagement_id: Ecto.UUID.t(),
          role_label: String.t(),
          joined_at: String.t()
        }
  defp render_roster_entry(%RosterEntry{engagement: %Engagement{} = engagement} = entry) do
    %{
      engagement_id: entry.engagement_id,
      role_label: engagement.role_label,
      joined_at: DateTime.to_iso8601(entry.joined_at)
    }
  end

  @spec not_found(Plug.Conn.t()) :: Plug.Conn.t()
  defp not_found(conn), do: refuse(conn, :not_found, @no_venue)

  @spec no_shift_type(Plug.Conn.t()) :: Plug.Conn.t()
  defp no_shift_type(conn), do: refuse(conn, :not_found, @no_shift_type)

  @spec no_shift_room(Plug.Conn.t()) :: Plug.Conn.t()
  defp no_shift_room(conn), do: refuse(conn, :not_found, @no_shift_room)

  # **R15's four conditions, one answer**: a shift room that is not this
  # venue's, an engagement that is not, an id that names nothing, and an
  # engagement already on this roster. Also the removal's `:not_rostered`,
  # which covers an entry closed a moment ago and a room that never existed.
  #
  # The sentence is its own rather than `@no_venue` because by this point the
  # *venue* has resolved — the session proved it may act for it — so a sentence
  # about the venue would be one the caller can see is false. That the venue
  # resolved is not a disclosure: they hold the grant, so they knew.
  @spec no_roster_target(Plug.Conn.t()) :: Plug.Conn.t()
  defp no_roster_target(conn), do: refuse(conn, :not_found, @no_roster_target)

  # `HospitalityComsWeb.RoomController`'s manoeuvre, for the same reason: both
  # casts answer `:error` and the two mistakes are not the same mistake. A
  # malformed id is `404`; an unknown extent is `400`.
  @spec refuse_cast(Plug.Conn.t(), map()) :: Plug.Conn.t()
  defp refuse_cast(conn, params), do: refuse_extent(conn, Extent.cast(params))

  @spec refuse_extent(Plug.Conn.t(), {:ok, MessagePage.extent()} | :error) :: Plug.Conn.t()
  defp refuse_extent(conn, :error), do: refuse(conn, :bad_request, Extent.refusal())
  defp refuse_extent(conn, {:ok, _extent}), do: not_found(conn)

  @spec rejected(Plug.Conn.t(), Ecto.Changeset.t(Invitation.t())) :: Plug.Conn.t()
  defp rejected(conn, changeset), do: rejected_with(conn, @rejected_offer, changeset)

  @spec rejected_shift(Plug.Conn.t(), Ecto.Changeset.t(ShiftRoom.t())) :: Plug.Conn.t()
  defp rejected_shift(conn, changeset), do: rejected_with(conn, @rejected_shift, changeset)

  # A rejected *write* is `422` with the fields it rejected, and nothing is
  # disclosed by it: the session has already proved it may act for the venue, so
  # the only news in the body is what it just sent.
  @spec rejected_with(Plug.Conn.t(), String.t(), Ecto.Changeset.t()) :: Plug.Conn.t()
  defp rejected_with(conn, message, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorEnvelope.for_changeset(:unprocessable_entity, message, changeset))
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
