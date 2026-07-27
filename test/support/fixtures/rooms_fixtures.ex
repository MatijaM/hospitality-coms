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
  alias HospitalityComs.EngagementsFixtures
  alias HospitalityComs.Rooms
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
  A roster entry putting `engagement_id` on `room` from the scope's instant.
  """
  @spec roster_entry_fixture(EmployerScope.t(), ShiftRoom.t(), Ecto.UUID.t()) :: RosterEntry.t()
  def roster_entry_fixture(%EmployerScope{} = scope, %ShiftRoom{} = room, engagement_id) do
    {:ok, entry} = Rosters.add_to_roster(scope, room.id, engagement_id)
    entry
  end
end
