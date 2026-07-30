defmodule HospitalityComs.Rooms do
  @moduledoc """
  Two kinds of room, and not one row of membership between them.

  ## What is stored and what is not

  Stored: a shift room's term and the grace it was created with, a roster
  entry's period, a message, and a person's own suspension period. That is all.

  Not stored, and never: who is in a room. The venue room's roll is
  `active engagement at this instant`; whether *this* person may reach it is
  that, minus a suspension containing the instant. Shift-room membership is
  `roster period containing this instant, in a room
  open at it, holding an engagement active at it`. Shift-room *readability* is
  `roster period overlapping the room's open window, holding an engagement
  active now`. Every one of them is a query, and the same call at a later
  instant returns a different answer because the instant moved — **with no job
  having run**, which is this unit's verification condition.

  KTD6b is why there is no job, and the argument bears repeating because the
  alternative is the obvious design. Materialising a shift room's membership at
  shift start protects against a later roster correction withdrawing access
  retroactively; it inverts under its own failure mode, because a job firing ten
  minutes late captures the roster *as corrected* — the withdrawal it existed to
  prevent — and its absence is indistinguishable from an empty roster, so
  nothing downstream can detect the miss. A period that only ever closes forward
  makes non-retroactivity structural instead.

  ## Grace closes writes, not reads

  R11. A shift room accepts messages while the instant is inside
  `[starts_at, ends_at + grace)` and stays readable afterwards to everyone whose
  roster period overlapped that same window. Closing writes has a clock; closing
  reads does not happen at all.

  The grace is stamped on the room from its shift type at creation, never joined
  to. Editing a shift type on Tuesday would otherwise reopen Monday's closed
  room — or shut one somebody is standing in — for every room of that type at
  once. It is the rule U5 applied to an invitation's term, with a sharper edge.

  ## Full history in the venue room, and only there

  KTD14 resolves the origin document's contradiction between R14 and R16 in the
  venue room's favour: a venue room is the venue's standing conversation and a
  new hire joins it where it is, history included. Taking R14 literally for
  shift rooms would let a day-one hire read every shift conversation the venue
  has ever held, which contradicts the document's own privacy posture — so a
  shift room's readers are the people whose roster periods overlapped it, and
  that set *is* the snapshot KTD14 asks for, derived rather than stored.

  ## Three callers, and the reason the person's side runs as the application

  An employer session creates shift rooms and lists them: those run through
  `HospitalityComs.EmployerRepo` inside `scoped_transaction/2`, under a grant
  resolved against the database on every call. `HospitalityComs.Rosters` is the
  other half of the same surface.

  **Everything a person does here runs through `HospitalityComs.Repo` as the
  application's own role**, under a `HospitalityComs.Accounts.PersonScope`, and
  it is the same reason U5's claim does: the work spans both zones. Sending a
  message reads the bridge, reads `venue_room_suspensions` in the person zone,
  writes `room_messages` in the employer zone, and — since U10 — writes the
  author's own copy of it into `retained_message_copies` in the person zone.
  No session on either side holds the privileges for all four. `employer_role`
  deliberately holds nothing at all on `room_messages`, so the send could not
  run as the employer even if a caller wanted it to.

  **Both sends are `Ecto.Multi`s rather than a single insert**, and each of the
  two extra steps is a KTD16 rule: the archive is taken in the same transaction
  as the message, because a copy cannot be taken later than the instant its
  source may be deleted; and the venue-room send resolves its venue under
  `FOR SHARE`, because a venue-room message written after — or during — a
  closure carries a deadline nothing can ever match.

  There is deliberately **no employer-side venue-room membership function**, and
  it would be redundant rather than dangerous: the venue room's roll is the
  venue's active engagements, which is exactly what
  `HospitalityComs.Engagements.list_engagements/1` already answers. Keeping the
  two sets identical is the point — see below. Shift-room membership is
  answerable from both sides for a different reason: the employer wrote the
  roster, so nothing in the answer is theirs to learn.

  ## Suspension

  KTD18: the venue room only, reversible at will, invisible to the employer. It
  is a period rather than a flag, in a person-zone table, so no employer session
  can read the row — `employer_role` holds no privilege on
  `venue_room_suspensions` and `HospitalityComs.EmployerRepo`'s query backstop
  refuses any query that reaches it. See
  `HospitalityComs.Rooms.VenueRoomSuspension`.

  **Suspension closes the suspended person's own access and nothing else.** They
  cannot read the venue room, cannot send to it, and do not see it in
  `list_venue_rooms/1`. What it deliberately does *not* do is take them off the
  room's roll: `list_venue_room_members/2` answers with the venue's active
  engagements, unfiltered, which is the same set the employer can already list.

  That is the guarantee rather than a hole in it. A grant tier that hides the
  suspension rows still leaks the fact if some other list is visibly one person
  short — and a manager is a worker too, holding an employer scope and a person
  scope at the same venue, so "read both lists and subtract" is one caller away.
  The roll and `list_engagements/1` returning the same ids is what closes that,
  and `HospitalityComs.RoomsTest` pins it.

  Nothing is lost by the roll being wider than the set that can read the room at
  this instant. The venue room carries full history, so on resuming a person
  sees everything sent while they were away — the roll was never a list of who
  is looking, and no venue-room message goes unread because of a suspension.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms.MessagePage
  alias HospitalityComs.Rooms.Records
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rooms.ShiftRoomPage
  alias HospitalityComs.Rooms.VenueRoom
  alias HospitalityComs.Rooms.VenueRoomSuspension
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.ShiftType
  alias HospitalityComs.Venues.Venue

  @typedoc """
  Why a person-side room operation was refused.

  `:not_found` covers a room that does not exist and one the caller may not
  reach, so a refusal enumerates nothing. `:not_a_member` is only ever returned
  about a room the caller can already name — their own venue — where saying so
  discloses nothing they did not supply.
  """
  @type refusal() :: :not_found | :not_a_member | :room_closed

  @recent_message_limit 50
  @recent_shift_room_limit 30

  @doc """
  How many messages a default history read answers with.

  **The number lives here and no caller may pass one.** A route passing
  `limit: 50` would leave the unbounded read one forgetful caller away from
  production, which is exactly how both history functions came to be
  `Repo.all/1` over a room's entire life. So `list_venue_room_messages/3` and
  `list_shift_room_messages/3` take an *extent* — `:recent` or `:all` — and this
  is what `:recent` means.

  Exported because a caller has to be able to say "and there is more" without
  restating the number, and because a test asserting a bound against a fixture
  smaller than the bound certifies nothing.
  """
  @spec recent_message_limit() :: pos_integer()
  def recent_message_limit, do: @recent_message_limit

  @doc """
  How many shift rooms a default employer-side read answers with.

  Roughly a month of daily shifts at one venue, which is the window a manager
  has open while they are building next week's rota.

  **It is not derived from `recent_message_limit/0` and no relationship between
  the two is asserted anywhere.** Issue #42 is a live sweep of constant pairs
  held together by prose, and two lists that happened to share a number would be
  one more. The rule they *do* share is the one above: the number lives here and
  no caller may pass one.

  Exported for the same two reasons the message bound is — a caller has to be
  able to say "and there is more" without restating it, and a bound asserted
  against a fixture smaller than the bound certifies nothing.
  """
  @spec recent_shift_room_limit() :: pos_integer()
  def recent_shift_room_limit, do: @recent_shift_room_limit

  ## Shift rooms, from the employer's side

  @doc """
  Creates a shift room of `shift_type_id`, over the term in `attrs`.

  `attrs` carries `:starts_at` and `:ends_at`. The venue and the grace come from
  the shift type, resolved against the database inside the transaction, so
  neither is castable: a `venue_id` arriving in user attributes is a cross-tenant
  write waiting for somebody to forget to strip it, and a castable grace would
  let a caller give one room two hours where its type allows none.

  The grace is **copied**, not referenced. See the moduledoc.

  Refuses a scope with no grant by function clause, and a shift type belonging
  to another venue with `:not_found` — the same answer an id naming nothing
  gets.
  """
  @spec create_shift_room(EmployerScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, ShiftRoom.t()}
          | {:error, :no_grant | :not_found | Ecto.Changeset.t(ShiftRoom.t())}
  def create_shift_room(%EmployerScope{grant_id: grant_id} = scope, shift_type_id, attrs)
      when is_binary(grant_id) and is_binary(shift_type_id) and is_map(attrs) do
    EmployerRepo.scoped_transaction(scope, &write_shift_room(&1, shift_type_id, attrs))
  end

  @spec write_shift_room(EmployerScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, ShiftRoom.t()}
          | {:error, :no_grant | :not_found | Ecto.Changeset.t(ShiftRoom.t())}
  defp write_shift_room(scope, shift_type_id, attrs) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope),
         {:ok, shift_type} <- fetch_shift_type(scope, shift_type_id) do
      shift_type
      |> ShiftRoom.changeset(attrs, scope.now)
      |> EmployerRepo.insert()
      |> loaded(shift_type)
    end
  end

  # The room comes back carrying the type it was built from, so a caller
  # rendering what it just created gets the same shape `list_shift_rooms/2`
  # hands it — a shift room has no display name of its own and every render of
  # one needs the type's.
  #
  # It is the struct already in hand rather than `EmployerRepo.preload/2`: the
  # row was read inside this transaction a statement ago, and re-reading it
  # would be a query issued to learn something the caller is holding.
  @spec loaded({:ok, ShiftRoom.t()} | {:error, Ecto.Changeset.t(ShiftRoom.t())}, ShiftType.t()) ::
          {:ok, ShiftRoom.t()} | {:error, Ecto.Changeset.t(ShiftRoom.t())}
  defp loaded({:ok, %ShiftRoom{} = room}, %ShiftType{} = shift_type) do
    {:ok, %{room | shift_type: shift_type}}
  end

  defp loaded({:error, %Ecto.Changeset{} = changeset}, _shift_type), do: {:error, changeset}

  @spec fetch_shift_type(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, ShiftType.t()} | {:error, :not_found}
  defp fetch_shift_type(scope, shift_type_id) do
    scope.venue_id
    |> ShiftType.of_venue()
    |> where([shift_type], shift_type.id == ^shift_type_id)
    |> EmployerRepo.one()
    |> found_shift_type()
  end

  @spec found_shift_type(ShiftType.t() | nil) :: {:ok, ShiftType.t()} | {:error, :not_found}
  defp found_shift_type(nil), do: {:error, :not_found}
  defp found_shift_type(%ShiftType{} = shift_type), do: {:ok, shift_type}

  @doc """
  The venue's most recent shift rooms, earliest first within the page.

  A page rather than a list, and the bound is `recent_shift_room_limit/0`. See
  `list_shift_rooms/2` for the extent a caller can ask for instead, and
  `HospitalityComs.Rooms.ShiftRoomPage` for why the *selection* runs from the
  other end of the order the page is displayed in.

  The shift type is preloaded, because a `ShiftRoom` has two instants and a
  `shift_type_id` and no display name at all — so every caller needs it, and
  `list_readable_shift_rooms/2` already loads it for the person side. One
  rendered shift room then serves both sides of this API.
  """
  @spec list_shift_rooms(EmployerScope.t()) :: {:ok, ShiftRoomPage.t()} | {:error, :no_grant}
  def list_shift_rooms(%EmployerScope{} = scope), do: list_shift_rooms(scope, :recent)

  @doc """
  The same, at the extent asked for.

  `:recent` is `recent_shift_room_limit/0` rooms and is what the one-arity form
  answers; `:all` is every shift room the venue has ever had, which is what this
  function used to do unconditionally.

  The unbounded read stays reachable — a manager auditing a venue's history has
  a real reason to want the lot — and what changed is that it is now reached
  **because somebody asked for it**. A caller cannot pass a number: a route
  passing `limit: 50` leaves the unbounded read one forgetful caller away from
  production, which is how this function came to be `EmployerRepo.all/1` over a
  venue's whole life.
  """
  @spec list_shift_rooms(EmployerScope.t(), MessagePage.extent()) ::
          {:ok, ShiftRoomPage.t()} | {:error, :no_grant}
  def list_shift_rooms(%EmployerScope{grant_id: grant_id} = scope, extent)
      when is_binary(grant_id) and extent in [:recent, :all] do
    EmployerRepo.scoped_transaction(scope, &read_shift_rooms(&1, extent))
  end

  @spec read_shift_rooms(EmployerScope.t(), MessagePage.extent()) ::
          {:ok, ShiftRoomPage.t()} | {:error, :no_grant}
  defp read_shift_rooms(scope, extent) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope) do
      {:ok, Records.rooms() |> Records.of_venue(scope.venue_id) |> shift_room_page(extent)}
    end
  end

  @spec shift_room_page(Ecto.Query.t(), MessagePage.extent()) :: ShiftRoomPage.t()
  defp shift_room_page(query, :all) do
    query |> Records.earliest_first() |> read_rooms() |> ShiftRoomPage.whole()
  end

  defp shift_room_page(query, :recent) do
    limit = recent_shift_room_limit()

    query |> Records.most_recent_rooms(limit + 1) |> read_rooms() |> ShiftRoomPage.bounded(limit)
  end

  # The preload is after the read and in the context function, which is where
  # `AGENTS.md` asks for one. It cannot be a `preload:` on the bounded query
  # either: that query's `from` is a subquery, and Ecto has no association to
  # follow off one.
  @spec read_rooms(Ecto.Query.t()) :: [ShiftRoom.t()]
  defp read_rooms(query), do: query |> EmployerRepo.all() |> EmployerRepo.preload(:shift_type)

  @doc """
  One of the venue's shift rooms, by id.
  """
  @spec fetch_shift_room(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, ShiftRoom.t()} | {:error, :no_grant | :not_found}
  def fetch_shift_room(%EmployerScope{grant_id: grant_id} = scope, shift_room_id)
      when is_binary(grant_id) and is_binary(shift_room_id) do
    EmployerRepo.scoped_transaction(scope, &read_shift_room(&1, shift_room_id))
  end

  @spec read_shift_room(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, ShiftRoom.t()} | {:error, :no_grant | :not_found}
  defp read_shift_room(scope, shift_room_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope) do
      scope.venue_id |> employer_room(shift_room_id) |> EmployerRepo.one() |> found_room()
    end
  end

  @doc """
  The engagements in a shift room at the scope's instant.

  Rostered now, in a room open now, holding an engagement active now. Answerable
  from the employer's side because all three are employer-zone reads — the
  employer wrote the roster, so nothing here discloses anything they did not.

  Suspension is absent, and not by omission: KTD18 confines it to the venue
  room, and a query that consulted it would be an employer-scoped read of a
  person-zone table, which `HospitalityComs.EmployerRepo` refuses.
  """
  @spec list_shift_room_members(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, [Engagement.t()]} | {:error, :no_grant | :not_found}
  def list_shift_room_members(%EmployerScope{grant_id: grant_id} = scope, shift_room_id)
      when is_binary(grant_id) and is_binary(shift_room_id) do
    EmployerRepo.scoped_transaction(scope, &read_members(&1, shift_room_id))
  end

  @spec read_members(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, [Engagement.t()]} | {:error, :no_grant | :not_found}
  defp read_members(scope, shift_room_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope),
         {:ok, room} <- read_room(scope, shift_room_id) do
      {:ok, room.id |> Records.shift_room_members(scope.now) |> EmployerRepo.all()}
    end
  end

  @doc """
  The engagements that may read a shift room at the scope's instant.

  The overlap set intersected with an active engagement — KTD14's snapshot
  scope, derived. Wider than the membership in one direction and narrower in
  another: somebody removed from the roster an hour ago is here, and somebody
  whose engagement has since ended is not.
  """
  @spec list_shift_room_readers(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, [Engagement.t()]} | {:error, :no_grant | :not_found}
  def list_shift_room_readers(%EmployerScope{grant_id: grant_id} = scope, shift_room_id)
      when is_binary(grant_id) and is_binary(shift_room_id) do
    EmployerRepo.scoped_transaction(scope, &read_readers(&1, shift_room_id))
  end

  @spec read_readers(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, [Engagement.t()]} | {:error, :no_grant | :not_found}
  defp read_readers(scope, shift_room_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope),
         {:ok, room} <- read_room(scope, shift_room_id) do
      {:ok, room.id |> Records.shift_room_readers(scope.now) |> EmployerRepo.all()}
    end
  end

  @spec read_room(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, ShiftRoom.t()} | {:error, :not_found}
  defp read_room(scope, shift_room_id) do
    scope.venue_id |> employer_room(shift_room_id) |> EmployerRepo.one() |> found_room()
  end

  @spec employer_room(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  defp employer_room(venue_id, shift_room_id) do
    Records.rooms() |> Records.of_venue(venue_id) |> Records.room(shift_room_id)
  end

  ## The venue room, from the person's side

  @doc """
  The venue rooms this person is in at their scope's instant.

  Active engagements minus suspensions, which is R9. Refuses an employer scope
  by function clause — an employer asking this question would be asking who has
  opted out — and an anonymous person scope too, because answering `[]` would
  make "nobody" and "somebody with nothing" the same answer.
  """
  @spec list_venue_rooms(PersonScope.t()) :: [VenueRoom.t()]
  def list_venue_rooms(%PersonScope{person: %Person{id: person_id}, now: now})
      when is_binary(person_id) do
    person_id
    |> Records.venues_of_person(now)
    |> Repo.all()
    |> Enum.map(&VenueRoom.of_venue/1)
  end

  @doc """
  This person's membership of a venue room at their scope's instant, as the
  engagement behind it.

  The same question `venue_room_member?/2` answers, returning the row rather
  than a boolean, because two callers need what the row carries.
  `HospitalityComsWeb.VenueRoomChannel` is one: a channel has to name the
  engagement to subscribe to its revocation (`HospitalityComs.Engagements
  .topic/1` is per engagement, by KTD7's reasoning) and to key its presence
  entry on something that is not a person id (KTD15b). The context's own
  message and history reads are the other, through the private
  `fetch_membership/2` this delegates to.

  `:not_a_member` covers an ended engagement, a suspension in force, and a
  venue that does not exist, identically — so a caller supplying an arbitrary
  venue id learns nothing from the refusal (AE1).
  """
  @spec fetch_venue_room_membership(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, Engagement.t()} | {:error, :not_a_member}
  def fetch_venue_room_membership(%PersonScope{} = scope, venue_id) when is_binary(venue_id) do
    fetch_membership(scope, venue_id)
  end

  @doc """
  Whether this person is in the venue's room at their scope's instant.
  """
  @spec venue_room_member?(PersonScope.t(), Ecto.UUID.t()) :: boolean()
  def venue_room_member?(%PersonScope{person: %Person{id: person_id}, now: now}, venue_id)
      when is_binary(person_id) and is_binary(venue_id) do
    person_id |> Records.venue_room_membership(venue_id, now) |> Repo.exists?()
  end

  @doc """
  The venue room's roll at the scope's instant: the venue's active engagements.

  Person-scoped, and only reachable by somebody who is in the room themselves —
  a room's roll is visible to the room. The set is engagements rather than
  people, because an engagement is what a message is attributed to and what
  carries the role label a client renders (KTD15b).

  Suspensions are **not** subtracted, so this is the same set
  `HospitalityComs.Engagements.list_engagements/1` returns to an employer
  session. That equality is KTD18: see the moduledoc and
  `HospitalityComs.Rooms.Records.venue_room_members/2`.

  A suspended *caller* still gets `{:error, :not_a_member}` — the refusal is
  about their own access, which is the one thing suspension governs.

  **Whole structs, and one of their fields is `person_id`.** This is the one
  list in the application that hands every member of a room the identity key of
  every other member, and U8/U9 will render it. They should project a field list
  rather than the struct, and attribute on the engagement's `id` — which is the
  `author_engagement_id` a message already carries (KTD15b), venue-local by
  construction — rather than on `person_id`. The same note sits on
  `HospitalityComs.Engagements.Records.outstanding_invitations/2`.
  """
  @spec list_venue_room_members(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, [Engagement.t()]} | {:error, :not_a_member}
  def list_venue_room_members(%PersonScope{} = scope, venue_id) when is_binary(venue_id) do
    with {:ok, engagement} <- fetch_membership(scope, venue_id) do
      {:ok, engagement.venue_id |> Records.venue_room_members(scope.now) |> Repo.all()}
    end
  end

  @doc """
  The venue room's messages: the most recent page by default, oldest first
  within it.

  **Full history is still what the room holds** (R14, KTD14), and the third
  arity is how a caller asks for it. There is no filter on when the reader's
  engagement began: a person engaged today reads what was said before they
  arrived, because a venue room is the venue's standing conversation rather than
  a record of one shift.

  What is bounded is one *read*, not the room. See `list_venue_room_messages/3`
  and `HospitalityComs.Rooms.MessagePage` for why the bound lives here and why
  the caller names an extent rather than a number.
  """
  @spec list_venue_room_messages(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, MessagePage.t()} | {:error, :not_a_member}
  def list_venue_room_messages(%PersonScope{} = scope, venue_id) when is_binary(venue_id) do
    list_venue_room_messages(scope, venue_id, :recent)
  end

  @doc """
  The same, at the extent asked for.

  `:recent` is `recent_message_limit/0` messages and is what the two-arity form
  answers; `:all` is every message the room holds, which is what this function
  used to do unconditionally.

  The unbounded read is deliberately still reachable — a venue room is a
  standing conversation and a worker returning from leave has a real reason to
  want the lot. What has changed is that it is now reached **because somebody
  asked for it**, which is the difference between a considered cost and an
  accidental one.
  """
  @spec list_venue_room_messages(PersonScope.t(), Ecto.UUID.t(), MessagePage.extent()) ::
          {:ok, MessagePage.t()} | {:error, :not_a_member}
  def list_venue_room_messages(%PersonScope{} = scope, venue_id, extent)
      when is_binary(venue_id) and extent in [:recent, :all] do
    with {:ok, engagement} <- fetch_membership(scope, venue_id) do
      {:ok, engagement.venue_id |> Records.venue_room_messages() |> page(extent)}
    end
  end

  @doc """
  Sends a message to a venue room.

  The author is the sender's own engagement at that venue, resolved against the
  database at the scope's instant — so an engagement that ended a second ago
  cannot send, with no job having run, and a suspended person cannot either.

  ## A closed venue has no room, and that is a retention rule

  `:room_closed` once `HospitalityComs.Lifecycle.close_venue/2` has run. Closure
  is the *only* trigger venue-room history has: it stamps `delete_after` on the
  rows whose deadline is still null, and a message written afterwards would
  carry a null deadline for ever, because `delete_after < instant` never matches
  a null and `close_venue/2` refuses to run twice. A closed venue that kept
  trading therefore accumulated messages nothing in the system could ever
  delete, and falsified the sentence closure exists to make true.

  The venue is resolved **under `FOR SHARE` inside the transaction that writes
  the message**, so the pure-race form is closed too: an unlocked read would let
  a send whose snapshot predates the closure commit a message the closure's
  stamping statement had already passed over. `FOR SHARE` conflicts with the
  `FOR NO KEY UPDATE` the closure's own `UPDATE venues` takes, so the send
  either commits first and is stamped, or parks and then finds the venue shut.
  Both take the venue row before touching `room_messages`, which is what keeps
  the two orderings from deadlocking. Reading a closed venue's room is
  untouched: the messages are there for thirty days and history is what closure
  puts a clock on.

  ## The author's own copy is written here

  In the same transaction, through `HospitalityComs.Lifecycle.retain_message/3`
  — KTD16's archive, taken with the message rather than when the term ends,
  because a term outlives its shifts by longer than a shift's history survives.
  See that function.
  """
  @spec send_venue_room_message(PersonScope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, RoomMessage.t()}
          | {:error, :not_a_member | :room_closed | Ecto.Changeset.t(RoomMessage.t())}
  def send_venue_room_message(%PersonScope{} = scope, venue_id, body)
      when is_binary(venue_id) and is_binary(body) do
    Multi.new()
    |> Multi.run(:venue, fn repo, _changes -> fetch_trading_venue(repo, venue_id) end)
    |> Multi.run(:engagement, fn _repo, _changes -> fetch_membership(scope, venue_id) end)
    |> Multi.insert(:message, fn %{engagement: engagement} ->
      RoomMessage.venue_room_changeset(engagement, body, scope.now)
    end)
    |> retaining()
    |> naming()
    |> Repo.transaction()
    |> sent()
  end

  # The venue row, locked against a closure that has not committed yet.
  @spec fetch_trading_venue(Ecto.Repo.t(), Ecto.UUID.t()) ::
          {:ok, Venue.t()} | {:error, :room_closed}
  defp fetch_trading_venue(repo, venue_id) do
    venue_id |> Records.trading_venue() |> repo.one() |> trading_or_refuse()
  end

  @spec trading_or_refuse(Venue.t() | nil) :: {:ok, Venue.t()} | {:error, :room_closed}
  defp trading_or_refuse(%Venue{} = venue), do: {:ok, venue}
  defp trading_or_refuse(nil), do: {:error, :room_closed}

  # The archive step both sends share. It is the last step rather than the
  # first, because it needs the message the insert minted.
  @spec retaining(Multi.t()) :: Multi.t()
  defp retaining(multi) do
    Multi.run(multi, :retained, fn repo, %{message: message, engagement: engagement} ->
      Lifecycle.retain_message(repo, message, engagement)
    end)
  end

  # The author's name and role label, read back through the **same** join every
  # history read uses (#66, #65), so a message cannot arrive with one shape on
  # the send reply and another on the read.
  #
  # For the **name** that is a correctness requirement and it was measured:
  # `HospitalityComsWeb.ChannelAuth.person_scope/1` builds `%Person{id:
  # person_id}` and nothing else — the socket deliberately caches the id and the
  # token digest and no `Person` struct — so a name taken off the scope is
  # correct over HTTP, `nil` on both channels, and there is no test position
  # from which the two look different. Caching it on the socket is the
  # alternative and is worse twice over: an identifying value on a struct a
  # crash report inspects, and a *mutable* one, so a rename would go on
  # broadcasting the old name to the whole room until the next join.
  #
  # For the **label** it is not. Both sends resolve a whole `Engagement` row out
  # of the database before they insert, in this same transaction, so
  # `engagement.role_label` is the string this query returns and taking it from
  # there would be correct on both transports. It is read back anyway because
  # the query is already being issued for the name and the `select_merge` fills
  # both fields in one row — one source behind one rendered shape, which is the
  # thing four separate defects in this tree came from not having.
  @spec naming(Multi.t()) :: Multi.t()
  defp naming(multi) do
    Multi.run(multi, :named, fn repo, %{message: message} ->
      {:ok, message.id |> Records.message() |> Records.with_author() |> repo.one!()}
    end)
  end

  # `:named` rather than `:message`, so the row a send answers with is the row a
  # history read would have produced. See `naming/1`.
  @spec sent({:ok, map()} | {:error, atom(), term(), map()}) ::
          {:ok, RoomMessage.t()}
          | {:error, refusal() | :not_rostered | Ecto.Changeset.t(RoomMessage.t())}
  defp sent({:ok, %{named: %RoomMessage{} = message}}), do: {:ok, message}
  defp sent({:error, _step, reason, _changes}), do: {:error, reason}

  # Membership rather than engagement: a suspended person is engaged and is not
  # in the room, and every venue-room operation is about the room.
  @spec fetch_membership(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, Engagement.t()} | {:error, :not_a_member}
  defp fetch_membership(%PersonScope{person: %Person{id: person_id}, now: now}, venue_id)
       when is_binary(person_id) do
    person_id
    |> Records.venue_room_membership(venue_id, now)
    |> Repo.one()
    |> member_or_refuse()
  end

  @spec member_or_refuse(Engagement.t() | nil) ::
          {:ok, Engagement.t()} | {:error, :not_a_member}
  defp member_or_refuse(nil), do: {:error, :not_a_member}
  defp member_or_refuse(%Engagement{} = engagement), do: {:ok, engagement}

  ## Suspension

  @doc """
  Takes this person out of a venue's room, from the scope's instant.

  Reversible at will and invisible to the employer (KTD18). The row lives in the
  person zone, so the invisibility is the grant tier rather than a `select` list
  — see `HospitalityComs.Rooms.VenueRoomSuspension`.

  Resolved against the engagement rather than the membership: a suspended person
  is still engaged, so asking for membership here would make suspending twice
  look like having no engagement. `:already_suspended` is the honest answer, and
  the exclusion constraint underneath is what makes it safe when two of the
  person's own sessions ask at once.

  ## The nudge, and why it is needed at all

  A suspension is derived like everything else here, so the *next* join is
  refused whether or not anything was announced. What that does not do is close
  a channel the person already has open — and until it does, the sentence above
  about not being able to read the room is false for as long as that channel
  lives, which can be hours. It matters most in the case the opt-out is for: the
  person taps it on their phone while their laptop is still in the room.

  So the write is followed by a broadcast on the engagement's own topic — U5's,
  through `HospitalityComs.Engagements.topic/1`, not a second mechanism — after
  the write and only if it happened, for the reason KTD8 gives. Per engagement
  rather than per person, so opting out of Venue B says nothing about Venue A.

  **Best effort, and logged rather than propagated**, exactly as
  `HospitalityComs.Engagements`' revocation announcement is: failing somebody's
  opt-out in order to report that a socket was not told would be the wrong
  trade, and the refused rejoin is the guarantee in any case.
  """
  @spec suspend_venue_room(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, VenueRoomSuspension.t()}
          | {:error,
             :no_engagement | :already_suspended | Ecto.Changeset.t(VenueRoomSuspension.t())}
  def suspend_venue_room(%PersonScope{} = scope, venue_id) when is_binary(venue_id) do
    with {:ok, engagement} <- fetch_engagement(scope, venue_id),
         :ok <- unsuspended(engagement, scope.now) do
      engagement.id
      |> VenueRoomSuspension.open_changeset(scope.now)
      |> Repo.insert()
      |> announce_suspension(engagement)
    end
  end

  # Only on `{:ok, _}`. A nudge for a write that did not happen would close a
  # channel whose access never ended (KTD8's ordering, from the person's side).
  @spec announce_suspension(
          {:ok, VenueRoomSuspension.t()} | {:error, Ecto.Changeset.t(VenueRoomSuspension.t())},
          Engagement.t()
        ) ::
          {:ok, VenueRoomSuspension.t()} | {:error, Ecto.Changeset.t(VenueRoomSuspension.t())}
  defp announce_suspension({:ok, %VenueRoomSuspension{} = suspension} = result, engagement) do
    broadcast_suspension(engagement, suspension.suspended_at)
    result
  end

  defp announce_suspension(result, _engagement), do: result

  # `{:error, :no_such_group}` is the one failure the `:pg` adapter can name,
  # and on OTP's `:pg` it is unreachable — `:pg.get_members/2` answers `[]` for
  # a group nobody has joined. The clause is here because the library's
  # contract allows it, and the log line is what makes it visible if the
  # adapter ever changes. No `person_id` in the line: KTD2's rule about naming
  # humans does not stop at the schemas the application owns.
  @spec broadcast_suspension(Engagement.t(), DateTime.t()) :: :ok
  defp broadcast_suspension(%Engagement{} = engagement, %DateTime{} = instant) do
    HospitalityComs.PubSub
    |> Phoenix.PubSub.broadcast(
      Engagements.topic(engagement.id),
      {:venue_room_suspended,
       %{engagement_id: engagement.id, venue_id: engagement.venue_id, at: instant}}
    )
    |> announced(engagement)
  end

  @spec announced(:ok | {:error, term()}, Engagement.t()) :: :ok
  defp announced(:ok, _engagement), do: :ok

  defp announced({:error, reason}, %Engagement{} = engagement) do
    Logger.warning(
      "venue room suspension was not announced " <>
        "engagement_id=#{engagement.id} venue_id=#{engagement.venue_id} " <>
        "reason_code=#{inspect(reason)}"
    )

    :ok
  end

  @spec unsuspended(Engagement.t(), DateTime.t()) :: :ok | {:error, :already_suspended}
  defp unsuspended(%Engagement{id: engagement_id}, now) do
    engagement_id
    |> Records.open_suspension(now)
    |> Repo.exists?()
    |> refuse_if_suspended()
  end

  @spec refuse_if_suspended(boolean()) :: :ok | {:error, :already_suspended}
  defp refuse_if_suspended(true), do: {:error, :already_suspended}
  defp refuse_if_suspended(false), do: :ok

  @doc """
  Puts this person back into a venue's room, from the scope's instant.

  The suspension row is kept and closed. On resuming, the room's full history is
  readable — including everything sent while the person was away, because
  history is not filtered by who was in the room when it was written.

  Closing is a conditional update on `resumed_at IS NULL`, the same manoeuvre
  `Rosters.remove_from_roster/3` uses on `left_at`. A plain `Repo.update/1`
  here would let two concurrent resumes both write: the later commit's
  `resumed_at` would win and the earlier caller would be handed a struct whose
  `resumed_at` no longer matched the row. Closing a period happens once, so
  losing the race is `{:error, :not_suspended}` — the same answer this function
  already gives for a suspension somebody closed a moment ago.
  """
  @spec resume_venue_room(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, VenueRoomSuspension.t()} | {:error, :no_engagement | :not_suspended}
  def resume_venue_room(%PersonScope{} = scope, venue_id) when is_binary(venue_id) do
    with {:ok, engagement} <- fetch_engagement(scope, venue_id),
         {:ok, suspension} <- fetch_open_suspension(engagement, scope.now) do
      close_open_suspension(suspension, scope.now)
    end
  end

  @spec close_open_suspension(VenueRoomSuspension.t(), DateTime.t()) ::
          {:ok, VenueRoomSuspension.t()} | {:error, :not_suspended}
  defp close_open_suspension(%VenueRoomSuspension{id: id}, %DateTime{} = now) do
    # Truncated for the same reason `close_changeset/2` truncates it: both
    # columns are `:utc_datetime`, so a sub-second instant would be rounded by
    # Postgres rather than floored, and a resume at 12:00:01.8 would land at
    # 12:00:02 — after the call that made it.
    stamped_at = DateTime.truncate(now, :second)

    query =
      from suspension in VenueRoomSuspension,
        where: suspension.id == ^id and is_nil(suspension.resumed_at),
        select: suspension

    case Repo.update_all(query, set: [resumed_at: stamped_at, updated_at: stamped_at]) do
      {1, [%VenueRoomSuspension{} = resumed]} -> {:ok, resumed}
      {0, _none} -> {:error, :not_suspended}
    end
  end

  @doc """
  Whether this person has suspended a venue's room at their scope's instant.

  Person-scoped, and there is no employer-scoped counterpart. That is KTD18: an
  employer able to ask would have a retaliation surface, which is what the
  opt-out exists to avoid being.
  """
  @spec venue_room_suspended?(PersonScope.t(), Ecto.UUID.t()) :: boolean()
  def venue_room_suspended?(%PersonScope{} = scope, venue_id) when is_binary(venue_id) do
    scope |> fetch_engagement(venue_id) |> suspension_in_force(scope.now)
  end

  @spec suspension_in_force({:ok, Engagement.t()} | {:error, :no_engagement}, DateTime.t()) ::
          boolean()
  defp suspension_in_force({:error, :no_engagement}, _now), do: false

  defp suspension_in_force({:ok, %Engagement{id: engagement_id}}, now) do
    engagement_id |> Records.open_suspension(now) |> Repo.exists?()
  end

  @spec fetch_engagement(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, Engagement.t()} | {:error, :no_engagement}
  defp fetch_engagement(%PersonScope{person: %Person{id: person_id}, now: now}, venue_id)
       when is_binary(person_id) do
    person_id
    |> Records.venue_engagement(venue_id, now)
    |> Repo.one()
    |> engaged_or_refuse()
  end

  @spec engaged_or_refuse(Engagement.t() | nil) ::
          {:ok, Engagement.t()} | {:error, :no_engagement}
  defp engaged_or_refuse(nil), do: {:error, :no_engagement}
  defp engaged_or_refuse(%Engagement{} = engagement), do: {:ok, engagement}

  @spec fetch_open_suspension(Engagement.t(), DateTime.t()) ::
          {:ok, VenueRoomSuspension.t()} | {:error, :not_suspended}
  defp fetch_open_suspension(%Engagement{id: engagement_id}, now) do
    engagement_id
    |> Records.open_suspension(now)
    |> Repo.one()
    |> suspended_or_refuse()
  end

  @spec suspended_or_refuse(VenueRoomSuspension.t() | nil) ::
          {:ok, VenueRoomSuspension.t()} | {:error, :not_suspended}
  defp suspended_or_refuse(nil), do: {:error, :not_suspended}
  defp suspended_or_refuse(%VenueRoomSuspension{} = suspension), do: {:ok, suspension}

  ## Shift rooms, from the person's side

  @doc """
  The shift rooms this person may read at their scope's instant, across every
  venue.

  Their roster periods that overlapped a room's open window, intersected with an
  engagement active now. A person engaged today sees no room from before their
  engagement, because they were on nobody's roster then — KTD14 refusing the
  day-one hire the venue's whole shift history.

  **This arity is unbounded in a way `list_readable_shift_rooms/2` is not**, and
  `HospitalityComsWeb.Endpoint` already says so: a person's readable shift-room
  set grows with every shift they are ever rostered on. It has no HTTP surface
  for that reason; the venue-filtered arity is the one a client asks.
  """
  @spec list_readable_shift_rooms(PersonScope.t()) :: [ShiftRoom.t()]
  def list_readable_shift_rooms(%PersonScope{person: %Person{id: person_id}, now: now})
      when is_binary(person_id) do
    read_person_shift_rooms(person_id, nil, now)
  end

  @doc """
  The same, at one venue.

  The filter is in the query rather than in whatever renders the answer. Not a
  disclosure either way — every row is one this person may read — but shipping
  more than was asked becomes a leak the first time the rule changes.

  **It does not consult suspension, and that is KTD18 rather than an omission.**
  A list of rooms "at a venue" reads like something a person out of that venue's
  room should not get; suspension is the venue room only, and a suspended person
  is still on their shift rosters and still reads and writes in their shift
  rooms. `HospitalityComs.Rooms.Records.readable_shift_rooms/3` carries the
  argument in full.

  A venue this person holds no engagement at answers `[]` rather than a refusal:
  the list's authorisation is the roster overlap, so an empty list for a venue
  with no rooms and for a venue that is not theirs are the same answer, which is
  AE1 satisfied by construction rather than by a clause.
  """
  @spec list_readable_shift_rooms(PersonScope.t(), Ecto.UUID.t()) :: [ShiftRoom.t()]
  def list_readable_shift_rooms(
        %PersonScope{person: %Person{id: person_id}, now: now},
        venue_id
      )
      when is_binary(person_id) and is_binary(venue_id) do
    read_person_shift_rooms(person_id, venue_id, now)
  end

  # The shift type carries the only display name either room kind has, so it is
  # loaded for every caller of this list rather than by whoever remembers.
  # `AGENTS.md` asks for preloads in the context function; it cannot be a
  # `preload:` in the query, because `Records.distinct_rooms/1` selects a joined
  # binding rather than the `from` source.
  @spec read_person_shift_rooms(Ecto.UUID.t(), Ecto.UUID.t() | nil, DateTime.t()) ::
          [ShiftRoom.t()]
  defp read_person_shift_rooms(person_id, venue_id, now) do
    person_id
    |> Records.readable_shift_rooms(venue_id, now)
    |> Repo.all()
    |> Repo.preload(:shift_type)
  end

  @doc """
  Whether this person is in a shift room right now — rostered, in an open room,
  on an active engagement.

  The predicate that decides whether they may send. `shift_room_readable?/2` is
  the wider one that decides whether they may read.
  """
  @spec shift_room_member?(PersonScope.t(), Ecto.UUID.t()) :: boolean()
  def shift_room_member?(%PersonScope{} = scope, shift_room_id)
      when is_binary(shift_room_id) do
    match?({:ok, _engagement}, fetch_shift_room_member(scope, shift_room_id))
  end

  @doc """
  The engagement this person may read a shift room under, at their scope's
  instant.

  `shift_room_readable?/2` with the row instead of the boolean, and for the
  reason `fetch_venue_room_membership/2` exists: a channel has to name the
  engagement to subscribe to its revocation and to key presence on it.

  Both compose the same `reader_engagement/3`, so "may read this room" is
  written once. At most one row can come back — the exclusion constraint
  `engagements_no_overlap` forbids one person holding two overlapping terms at
  one venue, so a person has at most one engagement active at any instant there.

  `:not_found` covers a room that does not exist and a room this person was
  never rostered on alike, exactly as `list_shift_room_messages/2` does.
  """
  @spec fetch_shift_room_reader(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, Engagement.t()} | {:error, :not_found}
  def fetch_shift_room_reader(
        %PersonScope{person: %Person{id: person_id}, now: now},
        shift_room_id
      )
      when is_binary(person_id) and is_binary(shift_room_id) do
    shift_room_id
    |> reader_engagement(person_id, now)
    |> Repo.one()
    |> reader_or_refuse()
  end

  @spec reader_or_refuse(Engagement.t() | nil) :: {:ok, Engagement.t()} | {:error, :not_found}
  defp reader_or_refuse(nil), do: {:error, :not_found}
  defp reader_or_refuse(%Engagement{} = engagement), do: {:ok, engagement}

  @doc """
  Whether this person may read a shift room at their scope's instant.
  """
  @spec shift_room_readable?(PersonScope.t(), Ecto.UUID.t()) :: boolean()
  def shift_room_readable?(%PersonScope{person: %Person{id: person_id}, now: now}, shift_room_id)
      when is_binary(person_id) and is_binary(shift_room_id) do
    shift_room_id |> reader_engagement(person_id, now) |> Repo.exists?()
  end

  @doc """
  A shift room's messages: the most recent page by default, oldest first within
  it, if this person may read it.

  `{:error, :not_found}` covers a room that does not exist and a room this
  person was never rostered on alike, so the refusal discloses nothing about
  which shifts a venue has run — which is what KTD14's scoping would otherwise
  leak one id at a time. The bound is a page of an answer the caller was already
  entitled to, so it turns no refusal into an empty page.
  """
  @spec list_shift_room_messages(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, MessagePage.t()} | {:error, :not_found}
  def list_shift_room_messages(%PersonScope{} = scope, shift_room_id)
      when is_binary(shift_room_id) do
    list_shift_room_messages(scope, shift_room_id, :recent)
  end

  @doc """
  The same, at the extent asked for. See `list_venue_room_messages/3`.

  A shift room's history is bounded by the shift rather than by the venue's
  whole life, so it is the less likely of the two to reach the limit. It has the
  same bound anyway: a bound applied to one of the two functions is a bound the
  other is one forgetful caller away from not having, which is the shape this
  unit exists to close.
  """
  @spec list_shift_room_messages(PersonScope.t(), Ecto.UUID.t(), MessagePage.extent()) ::
          {:ok, MessagePage.t()} | {:error, :not_found}
  def list_shift_room_messages(%PersonScope{} = scope, shift_room_id, extent)
      when is_binary(shift_room_id) and extent in [:recent, :all] do
    scope
    |> shift_room_readable?(shift_room_id)
    |> read_shift_room_messages(shift_room_id, extent)
  end

  @spec read_shift_room_messages(boolean(), Ecto.UUID.t(), MessagePage.extent()) ::
          {:ok, MessagePage.t()} | {:error, :not_found}
  defp read_shift_room_messages(false, _shift_room_id, _extent), do: {:error, :not_found}

  defp read_shift_room_messages(true, shift_room_id, extent) do
    {:ok, shift_room_id |> Records.shift_room_messages() |> page(extent)}
  end

  # The one place either extent becomes a query, so the two room kinds cannot
  # come to disagree about what `:recent` means — and, since #66 and #65, the
  # one place the author's name and role label are joined on, so they cannot
  # come to disagree about those either.
  #
  # `with_author/1` is applied **after** the ordering, outside `most_recent/2`'s
  # subquery, so neither the bound nor the page's own order is touched by it.
  @spec page(Ecto.Queryable.t(), MessagePage.extent()) :: MessagePage.t()
  defp page(queryable, :all) do
    queryable
    |> Records.oldest_first()
    |> Records.with_author()
    |> Repo.all()
    |> MessagePage.whole()
  end

  defp page(queryable, :recent) do
    limit = recent_message_limit()

    # One more than the page, which is how `MessagePage` answers "is this the
    # whole history" without a second statement.
    queryable
    |> Records.most_recent(limit + 1)
    |> Records.with_author()
    |> Repo.all()
    |> MessagePage.bounded(limit)
  end

  @doc """
  Sends a message to a shift room.

  Refused with `:room_closed` once the scope's instant reaches
  `ends_at + grace`, and before `starts_at` for the same reason — the open
  window is half-open and a room that has not opened is as closed as one that
  has shut. A shift type with a grace of zero closes writes at exactly `ends_at`.

  Refused with `:not_found` when the room does not exist **or belongs to a venue
  this person holds no active engagement at**, and with `:not_rostered` when it
  is one of their venue's rooms and they are not in it: rostered now, on an
  engagement active now. Somebody who was removed from the roster an hour ago
  can still *read* the room — that is `list_shift_room_messages/2` — and cannot
  add to it.

  The order of the three refusals is deliberate, and the first one is the
  interesting one. `:room_closed` and `:not_rostered` are both statements that
  the named room exists; answered about an arbitrary id they would enumerate
  every venue's shifts one probe at a time, which is the
  not-found-rather-than-forbidden rule (AE1) lost at the one place a caller
  supplies the id. So the lookup is confined to the person's own venues first,
  and inside that boundary the two remaining answers tell them only what their
  own venue's published shift times already do.

  The author's own copy is written in the same transaction, through
  `HospitalityComs.Lifecycle.retain_message/3`. This is the room kind that made
  the archive's old trigger lose data, and the one whose source rows die first.

  There is deliberately **no** venue-closure gate here, unlike
  `send_venue_room_message/3`. A shift message's deadline is stamped at insert,
  so a message written into a running shift at a venue that closed an hour ago
  is deleted on the shift's own clock like every other one; there are no
  undeletable rows to prevent, and the room shuts by itself at `ends_at + grace`.
  """
  @spec send_shift_room_message(PersonScope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, RoomMessage.t()}
          | {:error, refusal() | :not_rostered | Ecto.Changeset.t(RoomMessage.t())}
  def send_shift_room_message(%PersonScope{} = scope, shift_room_id, body)
      when is_binary(shift_room_id) and is_binary(body) do
    Multi.new()
    |> Multi.run(:room, fn _repo, _changes -> fetch_open_room(scope, shift_room_id) end)
    |> Multi.run(:engagement, fn _repo, _changes ->
      fetch_shift_room_member(scope, shift_room_id)
    end)
    |> Multi.insert(:message, fn %{room: room, engagement: engagement} ->
      RoomMessage.shift_room_changeset(room, engagement, body, scope.now)
    end)
    |> retaining()
    |> naming()
    |> Repo.transaction()
    |> sent()
  end

  # The open room, or why it is not available. Both queries are confined to the
  # person's own venues, and the second runs only on the failure path — so it
  # can never turn a refusal into a success, which is the same shape
  # `HospitalityComs.Engagements` uses to tell three claim refusals apart.
  @spec fetch_open_room(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, ShiftRoom.t()} | {:error, :not_found | :room_closed}
  defp fetch_open_room(%PersonScope{person: %Person{id: person_id}, now: now}, shift_room_id)
       when is_binary(person_id) do
    reachable = reachable_room(person_id, shift_room_id, now)

    reachable
    |> Records.open_at(now)
    |> Repo.one()
    |> open_or_diagnose(reachable)
  end

  @spec reachable_room(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  defp reachable_room(person_id, shift_room_id, now) do
    Records.rooms()
    |> Records.room(shift_room_id)
    |> Records.at_person_venues(person_id, now)
  end

  @spec open_or_diagnose(ShiftRoom.t() | nil, Ecto.Query.t()) ::
          {:ok, ShiftRoom.t()} | {:error, :not_found | :room_closed}
  defp open_or_diagnose(%ShiftRoom{} = room, _reachable), do: {:ok, room}

  defp open_or_diagnose(nil, reachable) do
    reachable |> Repo.exists?() |> closed_or_missing()
  end

  @spec closed_or_missing(boolean()) :: {:error, :not_found | :room_closed}
  defp closed_or_missing(true), do: {:error, :room_closed}
  defp closed_or_missing(false), do: {:error, :not_found}

  @spec fetch_shift_room_member(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, Engagement.t()} | {:error, :not_rostered}
  defp fetch_shift_room_member(
         %PersonScope{person: %Person{id: person_id}, now: now},
         shift_room_id
       )
       when is_binary(person_id) do
    shift_room_id
    |> Records.shift_room_members(now)
    |> where([engagement], engagement.person_id == ^person_id)
    |> Repo.one()
    |> rostered_or_refuse()
  end

  @spec rostered_or_refuse(Engagement.t() | nil) ::
          {:ok, Engagement.t()} | {:error, :not_rostered}
  defp rostered_or_refuse(nil), do: {:error, :not_rostered}
  defp rostered_or_refuse(%Engagement{} = engagement), do: {:ok, engagement}

  @spec reader_engagement(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  defp reader_engagement(shift_room_id, person_id, now) do
    shift_room_id
    |> Records.shift_room_readers(now)
    |> where([engagement], engagement.person_id == ^person_id)
  end

  ## The venue room itself

  @doc """
  The room of a venue this person is in.

  There is no `venue_rooms` table — see `HospitalityComs.Rooms.VenueRoom` — so
  this resolves the venue and derives the room from it. `:not_a_member` when
  they are not in it, suspension included.
  """
  @spec fetch_venue_room(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, VenueRoom.t()} | {:error, :not_a_member}
  def fetch_venue_room(%PersonScope{} = scope, venue_id) when is_binary(venue_id) do
    with {:ok, engagement} <- fetch_membership(scope, venue_id) do
      Venue |> Repo.get(engagement.venue_id) |> venue_room()
    end
  end

  @spec venue_room(Venue.t() | nil) :: {:ok, VenueRoom.t()} | {:error, :not_a_member}
  defp venue_room(nil), do: {:error, :not_a_member}
  defp venue_room(%Venue{} = venue), do: {:ok, VenueRoom.of_venue(venue)}

  @spec found_room(ShiftRoom.t() | nil) :: {:ok, ShiftRoom.t()} | {:error, :not_found}
  defp found_room(nil), do: {:error, :not_found}
  defp found_room(%ShiftRoom{} = room), do: {:ok, room}
end
