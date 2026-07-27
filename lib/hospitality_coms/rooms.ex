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
  and writes `room_messages` in the employer zone — and no session on either
  side holds the privileges for all three. `employer_role` deliberately holds
  nothing at all on `room_messages`, so the send could not run as the employer
  even if a caller wanted it to.

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

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms.Records
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rooms.ShiftRoom
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
    end
  end

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
  The venue's shift rooms, earliest first.
  """
  @spec list_shift_rooms(EmployerScope.t()) :: {:ok, [ShiftRoom.t()]} | {:error, :no_grant}
  def list_shift_rooms(%EmployerScope{grant_id: grant_id} = scope) when is_binary(grant_id) do
    EmployerRepo.scoped_transaction(scope, &read_shift_rooms/1)
  end

  @spec read_shift_rooms(EmployerScope.t()) :: {:ok, [ShiftRoom.t()]} | {:error, :no_grant}
  defp read_shift_rooms(scope) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope) do
      {:ok,
       Records.rooms()
       |> Records.of_venue(scope.venue_id)
       |> Records.earliest_first()
       |> EmployerRepo.all()}
    end
  end

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
  """
  @spec list_venue_room_members(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, [Engagement.t()]} | {:error, :not_a_member}
  def list_venue_room_members(%PersonScope{} = scope, venue_id) when is_binary(venue_id) do
    with {:ok, engagement} <- fetch_membership(scope, venue_id) do
      {:ok, engagement.venue_id |> Records.venue_room_members(scope.now) |> Repo.all()}
    end
  end

  @doc """
  The venue room's messages, oldest first.

  **Full history**, with no filter on when the reader's engagement began (R14,
  KTD14). A person engaged today reads what was said before they arrived,
  because a venue room is the venue's standing conversation rather than a record
  of one shift.
  """
  @spec list_venue_room_messages(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, [RoomMessage.t()]} | {:error, :not_a_member}
  def list_venue_room_messages(%PersonScope{} = scope, venue_id) when is_binary(venue_id) do
    with {:ok, engagement} <- fetch_membership(scope, venue_id) do
      {:ok, engagement.venue_id |> Records.venue_room_messages() |> Repo.all()}
    end
  end

  @doc """
  Sends a message to a venue room.

  The author is the sender's own engagement at that venue, resolved against the
  database at the scope's instant — so an engagement that ended a second ago
  cannot send, with no job having run, and a suspended person cannot either.
  """
  @spec send_venue_room_message(PersonScope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, RoomMessage.t()}
          | {:error, :not_a_member | Ecto.Changeset.t(RoomMessage.t())}
  def send_venue_room_message(%PersonScope{} = scope, venue_id, body)
      when is_binary(venue_id) and is_binary(body) do
    with {:ok, engagement} <- fetch_membership(scope, venue_id) do
      engagement
      |> RoomMessage.venue_room_changeset(body, scope.now)
      |> Repo.insert()
    end
  end

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
    end
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
  """
  @spec resume_venue_room(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, VenueRoomSuspension.t()}
          | {:error, :no_engagement | :not_suspended | Ecto.Changeset.t(VenueRoomSuspension.t())}
  def resume_venue_room(%PersonScope{} = scope, venue_id) when is_binary(venue_id) do
    with {:ok, engagement} <- fetch_engagement(scope, venue_id),
         {:ok, suspension} <- fetch_open_suspension(engagement, scope.now) do
      suspension
      |> VenueRoomSuspension.close_changeset(scope.now)
      |> Repo.update()
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
  The shift rooms this person may read at their scope's instant.

  Their roster periods that overlapped a room's open window, intersected with an
  engagement active now. A person engaged today sees no room from before their
  engagement, because they were on nobody's roster then — KTD14 refusing the
  day-one hire the venue's whole shift history.
  """
  @spec list_readable_shift_rooms(PersonScope.t()) :: [ShiftRoom.t()]
  def list_readable_shift_rooms(%PersonScope{person: %Person{id: person_id}, now: now})
      when is_binary(person_id) do
    person_id |> Records.readable_shift_rooms(now) |> Repo.all()
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
  Whether this person may read a shift room at their scope's instant.
  """
  @spec shift_room_readable?(PersonScope.t(), Ecto.UUID.t()) :: boolean()
  def shift_room_readable?(%PersonScope{person: %Person{id: person_id}, now: now}, shift_room_id)
      when is_binary(person_id) and is_binary(shift_room_id) do
    shift_room_id |> reader_engagement(person_id, now) |> Repo.exists?()
  end

  @doc """
  A shift room's messages, oldest first, if this person may read it.

  `{:error, :not_found}` covers a room that does not exist and a room this
  person was never rostered on alike, so the refusal discloses nothing about
  which shifts a venue has run — which is what KTD14's scoping would otherwise
  leak one id at a time.
  """
  @spec list_shift_room_messages(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, [RoomMessage.t()]} | {:error, :not_found}
  def list_shift_room_messages(%PersonScope{} = scope, shift_room_id)
      when is_binary(shift_room_id) do
    scope
    |> shift_room_readable?(shift_room_id)
    |> read_shift_room_messages(shift_room_id)
  end

  @spec read_shift_room_messages(boolean(), Ecto.UUID.t()) ::
          {:ok, [RoomMessage.t()]} | {:error, :not_found}
  defp read_shift_room_messages(false, _shift_room_id), do: {:error, :not_found}

  defp read_shift_room_messages(true, shift_room_id) do
    {:ok, shift_room_id |> Records.shift_room_messages() |> Repo.all()}
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
  """
  @spec send_shift_room_message(PersonScope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, RoomMessage.t()}
          | {:error, refusal() | :not_rostered | Ecto.Changeset.t(RoomMessage.t())}
  def send_shift_room_message(%PersonScope{} = scope, shift_room_id, body)
      when is_binary(shift_room_id) and is_binary(body) do
    with {:ok, room} <- fetch_open_room(scope, shift_room_id),
         {:ok, engagement} <- fetch_shift_room_member(scope, shift_room_id) do
      room
      |> RoomMessage.shift_room_changeset(engagement, body, scope.now)
      |> Repo.insert()
    end
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
