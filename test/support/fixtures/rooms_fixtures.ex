defmodule HospitalityComs.RoomsFixtures do
  @moduledoc """
  Test helpers for shift rooms, rosters and room messages.

  Built on `HospitalityComs.EngagementsFixtures` rather than on
  `HospitalityComs.VenuesFixtures`, and for the same reason U5 stopped using the
  latter: this unit spans both repos in one test. A manager creates a shift room
  and rosters somebody through `HospitalityComs.EmployerRepo`; the person then
  reads and writes through `HospitalityComs.Repo`, as the application's own role,
  because sending a message touches the person zone, the bridge and the employer
  zone at once and no session on either side holds the privileges for all three.

  Under the sandbox those are two transactions that cannot see each other's rows,
  so everything here commits for real and `EngagementsFixtures.purge/0` — which
  U6 extended with these tables, ahead of the bridge they all reference — removes
  it before and after each test.

  Every fixture takes the instant explicitly. A test asserting on a grace
  boundary has to be able to place a write on either side of it, and moving
  global state to say so is exactly what the injected clock exists to avoid.
  """

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.EngagementsFixtures
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rosters
  alias HospitalityComs.Rosters.RosterEntry
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.ShiftType

  @doc """
  The instant these fixtures hang off, shared with every other zone's fixtures.
  """
  @spec fixed_instant() :: DateTime.t()
  def fixed_instant, do: EngagementsFixtures.fixed_instant()

  @doc """
  An employer scope for the same venue and grant, at another instant.

  What makes "advance the clock and ask again" one line rather than four, and
  what keeps every such advance explicit in the test that makes it.
  """
  @spec employer_at(EmployerScope.t(), DateTime.t()) :: EmployerScope.t()
  def employer_at(%EmployerScope{venue_id: venue_id, grant_id: grant_id}, %DateTime{} = instant)
      when is_binary(grant_id) do
    EmployerScope.for_grant(venue_id, grant_id, instant)
  end

  @doc """
  A person scope for the same person, at another instant.
  """
  @spec person_at(PersonScope.t(), DateTime.t()) :: PersonScope.t()
  def person_at(%PersonScope{person: %Person{} = person}, %DateTime{} = instant) do
    PersonScope.for_person(person, instant)
  end

  @doc """
  A shift type at the scope's venue, with `grace_period_minutes` minutes of
  grace.
  """
  @spec shift_type_fixture(EmployerScope.t(), non_neg_integer()) :: ShiftType.t()
  def shift_type_fixture(%EmployerScope{} = scope, grace_period_minutes \\ 30) do
    attrs = %{
      name: "Shift type #{System.unique_integer([:positive])}",
      grace_period_minutes: grace_period_minutes
    }

    {:ok, shift_type} = Venues.create_shift_type(scope, scope.venue_id, attrs)
    shift_type
  end

  @doc """
  A shift room over `[starts_at, ends_at)`, with the shift type's grace stamped
  on it.
  """
  @spec shift_room_fixture(EmployerScope.t(), ShiftType.t(), DateTime.t(), DateTime.t()) ::
          ShiftRoom.t()
  def shift_room_fixture(
        %EmployerScope{} = scope,
        %ShiftType{} = shift_type,
        %DateTime{} = starts_at,
        %DateTime{} = ends_at
      ) do
    {:ok, room} =
      Rooms.create_shift_room(scope, shift_type.id, %{starts_at: starts_at, ends_at: ends_at})

    room
  end

  @doc """
  `count` shift rooms of `shift_type`, one day apart from `first_starts_at` and
  eight hours long, returning their ids **earliest first**.

  ## Why this is `insert_all` rather than thirty-one creations

  `HospitalityComs.Rooms.recent_shift_room_limit/0` can only be demonstrated by
  a venue holding **more rooms than the bound**, and a test asserting "thirty
  came back" against a fixture of twelve passes for the wrong reason — the shape
  `docs/solutions/test-failures/tests-that-certify-nothing.md` catalogues. So
  every such test needs `limit + 1` rooms, four of them do, and
  `Rooms.create_shift_room/3` is a transaction with a grant resolution and a
  type resolution in it.

  `closes_at` is a generated column and is left to the database, exactly as it
  is on the real write.

  **The ids are returned earliest first**, because the assertion that matters is
  not how many rooms came back but *which*: a bound that took the venue's oldest
  rooms satisfies every count. A caller names `List.first/1` and `List.last/1`.
  """
  @spec shift_rooms_fixture(EmployerScope.t(), ShiftType.t(), pos_integer(), DateTime.t()) ::
          [Ecto.UUID.t()]
  def shift_rooms_fixture(
        %EmployerScope{} = scope,
        %ShiftType{} = shift_type,
        count,
        %DateTime{} = first_starts_at
      )
      when is_integer(count) and count > 0 do
    stamped_at = DateTime.truncate(scope.now, :second)

    rows =
      Enum.map(1..count//1, fn n ->
        starts_at = DateTime.truncate(DateTime.add(first_starts_at, n - 1, :day), :second)

        %{
          id: Ecto.UUID.generate(),
          venue_id: shift_type.venue_id,
          shift_type_id: shift_type.id,
          starts_at: starts_at,
          ends_at: DateTime.add(starts_at, 8, :hour),
          grace_period_minutes: shift_type.grace_period_minutes,
          inserted_at: stamped_at,
          updated_at: stamped_at
        }
      end)

    {^count, nil} = Repo.insert_all(ShiftRoom, rows)

    Enum.map(rows, & &1.id)
  end

  @doc """
  A roster entry putting `engagement_id` on `room` from the scope's instant.
  """
  @spec roster_entry_fixture(EmployerScope.t(), ShiftRoom.t(), Ecto.UUID.t()) :: RosterEntry.t()
  def roster_entry_fixture(%EmployerScope{} = scope, %ShiftRoom{} = room, engagement_id) do
    {:ok, entry} = Rosters.add_to_roster(scope, room.id, engagement_id)
    entry
  end

  @doc """
  `count` messages in `engagement`'s venue room, one second apart from
  `first_sent_at`, returning their bodies oldest first.

  ## Why this is `insert_all` rather than fifty-one sends

  The bound on `HospitalityComs.Rooms.list_venue_room_messages/2` can only be
  demonstrated by a room holding **more messages than the bound**. A test that
  asserts "fifty came back" against a fixture of twelve passes for the wrong
  reason and certifies nothing — the shape
  `docs/solutions/test-failures/tests-that-certify-nothing.md` catalogues. So
  every such test needs fifty-one rows, several of them do, and
  `send_venue_room_message/3` is an `Ecto.Multi` with an archive step per row.

  One statement writes the same rows. What it deliberately does *not* write is
  `HospitalityComs.Lifecycle`'s archive copy, and nothing here reads one; a test
  about retention uses the context's own send, as `lifecycle_test.exs` does.

  **The bodies are numbered and returned**, because the assertion that matters
  is not how many rows came back but *which*: a bound that took the oldest fifty
  satisfies every count. A caller names `List.first/1` and `List.last/1`.
  """
  @spec venue_room_messages_fixture(Engagement.t(), pos_integer(), DateTime.t()) :: [String.t()]
  def venue_room_messages_fixture(%Engagement{} = engagement, count, %DateTime{} = first_sent_at)
      when is_integer(count) and count > 0 do
    write_messages(engagement, nil, nil, count, first_sent_at)
  end

  @doc """
  The same, in a shift room, carrying the deadline `RoomMessage`'s own changeset
  would have stamped from the room.
  """
  @spec shift_room_messages_fixture(
          Engagement.t(),
          ShiftRoom.t(),
          pos_integer(),
          DateTime.t()
        ) :: [String.t()]
  def shift_room_messages_fixture(
        %Engagement{} = engagement,
        %ShiftRoom{} = room,
        count,
        %DateTime{} = first_sent_at
      )
      when is_integer(count) and count > 0 do
    write_messages(
      engagement,
      room.id,
      Lifecycle.history_deadline(room.closes_at),
      count,
      first_sent_at
    )
  end

  @spec write_messages(
          Engagement.t(),
          Ecto.UUID.t() | nil,
          DateTime.t() | nil,
          pos_integer(),
          DateTime.t()
        ) :: [String.t()]
  defp write_messages(engagement, shift_room_id, delete_after, count, first_sent_at) do
    rows =
      Enum.map(1..count//1, fn n ->
        sent_at = DateTime.truncate(DateTime.add(first_sent_at, n - 1, :second), :second)

        %{
          id: Ecto.UUID.generate(),
          venue_id: engagement.venue_id,
          shift_room_id: shift_room_id,
          author_engagement_id: engagement.id,
          body: "message #{n}",
          sent_at: sent_at,
          delete_after: delete_after,
          inserted_at: sent_at,
          updated_at: sent_at
        }
      end)

    {^count, nil} = Repo.insert_all(RoomMessage, rows)

    Enum.map(rows, & &1.body)
  end
end
