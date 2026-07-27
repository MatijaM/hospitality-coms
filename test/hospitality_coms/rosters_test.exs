defmodule HospitalityComs.RostersTest do
  @moduledoc """
  The only writes a shift room's membership has, and the two rules underneath
  them.

  **Removal closes a period.** Every removal test asserts the row is still there
  afterwards, with `left_at` set, because that is what makes non-retroactivity
  structural rather than defended (KTD6b). A test that only asserted the person
  was gone from the current roster would pass against a `DELETE`, and a `DELETE`
  is precisely what must not happen.

  **Two overlapping periods on one shift are a database error.** The exclusion
  constraint is asserted through the tuple it produces, next to the adjacent
  case that is accepted — a constraint rejecting everything would satisfy the
  first assertion alone.

  `HospitalityComs.RoomsTest` holds the consequences: who is in the room, who
  may read it, and what a closed period leaves behind.

  ## Why this file is not sandboxed

  Rosters are written through `HospitalityComs.EmployerRepo` and the engagements
  they name are claimed through `HospitalityComs.Repo`; under the sandbox those
  are two transactions that cannot see each other. See
  `HospitalityComs.EngagementsFixtures`.
  """

  use ExUnit.Case, async: false

  import HospitalityComs.EngagementsFixtures
  import HospitalityComs.RoomsFixtures

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Engagements
  alias HospitalityComs.Repo
  alias HospitalityComs.Rosters
  alias HospitalityComs.Rosters.RosterEntry

  @now ~U[2026-03-01 12:00:00.000000Z]

  @shift_starts DateTime.add(@now, 1, :hour)
  @shift_ends DateTime.add(@now, 9, :hour)

  @an_hour_on DateTime.add(@now, 1, :hour)
  @two_hours_on DateTime.add(@now, 2, :hour)

  # Two instants inside one second. Every other instant in this unit's tests is
  # a whole second, where truncation is the identity — which is exactly why a
  # bound that truncated went unnoticed.
  @joined_mid_second DateTime.add(@now, 1_200, :millisecond)
  @left_mid_second DateTime.add(@now, 1_800, :millisecond)

  setup do
    real_connections()
  end

  describe "add_to_roster/3" do
    test "opens a period with no upper bound, from the instant of the call" do
      # `joined_at` is when the rostering happened, not when the shift starts.
      # That is what makes a rostering undone before the shift a period that
      # never overlaps the room.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      assert {:ok, %RosterEntry{} = entry} =
               Rosters.add_to_roster(employer, room.id, engagement.id)

      assert entry.joined_at == @now
      assert is_nil(entry.left_at)
      assert entry.venue_id == employer.venue_id
      assert entry.shift_room_id == room.id
      assert entry.engagement_id == engagement.id
    end

    test "names the engagement and carries no person key" do
      # KTD2. An employer-zone table may not name a human, so the association is
      # made from the person's side through the bridge.
      fields = RosterEntry.__schema__(:fields)

      refute :person_id in fields
      refute Enum.any?(fields, &(&1 |> Atom.to_string() |> String.contains?("person")))
      assert :engagement_id in fields
      assert :venue_id in fields
    end

    test "refuses a second open period for the same person on the same shift" do
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      assert {:ok, _first} = Rosters.add_to_roster(employer, room.id, engagement.id)

      assert {:error, :already_rostered} =
               Rosters.add_to_roster(employer, room.id, engagement.id)
    end

    test "refuses an overlapping period at the database tier, as a tuple rather than a raise" do
      # The exclusion constraint on its own, reached past the friendly check by
      # writing a closed period and then an earlier one that overlaps it.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      roster_entry_fixture(employer_at(employer, @an_hour_on), room, engagement.id)

      {:ok, _closed} =
        Rosters.remove_from_roster(employer_at(employer, @two_hours_on), room.id, engagement.id)

      # An open period beginning *before* the closed one overlaps it, and there
      # is no open period for the friendly check to find.
      assert {:error, changeset} = Rosters.add_to_roster(employer, room.id, engagement.id)

      assert "overlaps a period this person already holds on this shift" in errors_on(changeset).period
    end

    test "accepts a fresh period beginning exactly where the last one closed" do
      # The control for the test above. Half-open bounds mean `[a, t)` and
      # `[t, ∞)` do not overlap, so a constraint that rejected everything would
      # fail here.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      roster_entry_fixture(employer, room, engagement.id)

      {:ok, closed} =
        Rosters.remove_from_roster(employer_at(employer, @an_hour_on), room.id, engagement.id)

      assert {:ok, %RosterEntry{} = reopened} =
               Rosters.add_to_roster(employer_at(employer, @an_hour_on), room.id, engagement.id)

      assert reopened.joined_at == closed.left_at
      refute reopened.id == closed.id
    end

    test "stamps both bounds at the instant they happened, microseconds included" do
      # `DateTime.truncate(now, :second)` floored `joined_at` and `left_at`, and
      # `timestamp(0)` underneath *rounded* them, so the two tiers did not even
      # agree on which second a bound belonged to. Flooring `left_at` closes a
      # period before the removal happened and erases up to a second of elapsed
      # membership; flooring `joined_at` backdates the rostering by as much.
      #
      # Both bounds are the instant the call carried, exactly.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      entry = roster_entry_fixture(employer_at(employer, @joined_mid_second), room, engagement.id)

      assert entry.joined_at == @joined_mid_second

      assert {:ok, closed} =
               Rosters.remove_from_roster(
                 employer_at(employer, @left_mid_second),
                 room.id,
                 engagement.id
               )

      assert closed.left_at == @left_mid_second
      assert Repo.get(RosterEntry, entry.id).left_at == @left_mid_second

      # Six hundred milliseconds is a period. Truncated, it was `[t, t)` — the
      # empty range, which overlaps nothing.
      assert DateTime.compare(closed.left_at, closed.joined_at) == :gt
    end

    test "refuses an engagement at another venue" do
      %{employer: employer} = engaged()
      %{engagement: elsewhere} = engaged()
      room = shift_room(employer)

      assert {:error, :not_found} = Rosters.add_to_roster(employer, room.id, elsewhere.id)
    end

    test "refuses an engagement whose term has closed" do
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      {:ok, _ended} = Engagements.end_engagement(employer, engagement.id)

      assert {:error, :not_found} =
               Rosters.add_to_roster(employer_at(employer, @an_hour_on), room.id, engagement.id)
    end

    test "refuses a shift room at another venue with the same answer as one that does not exist" do
      %{employer: employer, engagement: engagement} = engaged()
      %{employer: other} = engaged()
      elsewhere = shift_room(other)

      assert {:error, :not_found} = Rosters.add_to_roster(employer, elsewhere.id, engagement.id)

      assert {:error, :not_found} =
               Rosters.add_to_roster(employer, Ecto.UUID.generate(), engagement.id)
    end

    test "refuses a scope with no grant by function clause" do
      grantless = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert_raise FunctionClauseError, fn ->
        Rosters.add_to_roster(
          scope_of(:grantless, grantless),
          Ecto.UUID.generate(),
          Ecto.UUID.generate()
        )
      end
    end
  end

  describe "remove_from_roster/3" do
    test "closes the period and keeps the row" do
      # The whole of KTD6b in one assertion: the row survives, so the overlap it
      # already had cannot be unmade.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)
      entry = roster_entry_fixture(employer, room, engagement.id)

      assert {:ok, %RosterEntry{} = closed} =
               Rosters.remove_from_roster(
                 employer_at(employer, @an_hour_on),
                 room.id,
                 engagement.id
               )

      assert closed.id == entry.id
      assert closed.left_at == @an_hour_on
      assert closed.joined_at == entry.joined_at
      assert Repo.get(RosterEntry, entry.id).left_at == closed.left_at
    end

    test "closes an entry that has not begun at its own opening, which is the empty period" do
      # A rostering made in error must be undoable without leaving a period
      # nobody can free. The same widening `end_engagement/2` makes.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)
      entry = roster_entry_fixture(employer_at(employer, @two_hours_on), room, engagement.id)

      assert {:ok, closed} =
               Rosters.remove_from_roster(employer, room.id, engagement.id)

      assert closed.left_at == entry.joined_at

      # The period is empty, so the slot is free again.
      assert {:ok, _again} =
               Rosters.add_to_roster(employer_at(employer, @two_hours_on), room.id, engagement.id)
    end

    test "refuses when there is no open period, including one closed a moment ago" do
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      assert {:error, :not_rostered} =
               Rosters.remove_from_roster(employer, room.id, engagement.id)

      roster_entry_fixture(employer, room, engagement.id)

      assert {:ok, _closed} =
               Rosters.remove_from_roster(
                 employer_at(employer, @an_hour_on),
                 room.id,
                 engagement.id
               )

      assert {:error, :not_rostered} =
               Rosters.remove_from_roster(
                 employer_at(employer, @two_hours_on),
                 room.id,
                 engagement.id
               )
    end

    test "leaves another venue's roster alone" do
      %{employer: employer, engagement: engagement} = engaged()
      %{employer: other, engagement: theirs} = engaged()

      room = shift_room(employer)
      their_room = shift_room(other)

      roster_entry_fixture(employer, room, engagement.id)
      roster_entry_fixture(other, their_room, theirs.id)

      {:ok, _closed} =
        Rosters.remove_from_roster(employer_at(employer, @an_hour_on), room.id, engagement.id)

      assert {:ok, [%RosterEntry{left_at: nil}]} =
               Rosters.list_roster(employer_at(other, @an_hour_on), their_room.id)
    end
  end

  describe "list_roster/2" do
    test "answers with the entries live at the scope's instant, earliest joined first" do
      %{employer: employer, engagement: first} = engaged()
      %{engagement: second} = engaged_at(employer)
      room = shift_room(employer)

      roster_entry_fixture(employer, room, first.id)
      roster_entry_fixture(employer_at(employer, @an_hour_on), room, second.id)

      assert {:ok, [one]} = Rosters.list_roster(employer, room.id)
      assert one.engagement_id == first.id

      assert {:ok, [one, two]} = Rosters.list_roster(employer_at(employer, @an_hour_on), room.id)
      assert Enum.map([one, two], & &1.engagement_id) == [first.id, second.id]
    end

    test "drops an entry once its period has closed, and list_engagement_periods/3 keeps it" do
      # The record a closed period is, from both sides.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      {:ok, _closed} =
        Rosters.remove_from_roster(employer_at(employer, @an_hour_on), room.id, engagement.id)

      later = employer_at(employer, @two_hours_on)

      assert {:ok, []} = Rosters.list_roster(later, room.id)

      assert {:ok, [%RosterEntry{left_at: %DateTime{}}]} =
               Rosters.list_engagement_periods(later, room.id, engagement.id)
    end

    test "refuses a shift room at another venue" do
      %{employer: employer} = engaged()
      %{employer: other} = engaged()
      elsewhere = shift_room(other)

      assert {:error, :not_found} = Rosters.list_roster(employer, elsewhere.id)
    end
  end

  ## Helpers

  defp engaged do
    {employer, _creation} = scoped_venue_fixture(@now)
    engaged_at(employer)
  end

  defp engaged_at(employer, now \\ @now) do
    person = person_scope_fixture(now)

    engagement =
      engagement_fixture(employer_at(employer, now), person, %{
        starts_at: now,
        ends_at: DateTime.add(now, 90, :day),
        code_expires_at: DateTime.add(now, 7, :day)
      })

    %{employer: employer, person: person, engagement: engagement}
  end

  defp shift_room(employer) do
    shift_type = shift_type_fixture(employer, 30)
    shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)
  end

  defp errors_on(changeset), do: HospitalityComs.DataCase.errors_on(changeset)

  # See `HospitalityComs.EngagementsTest` for why a refused scope is handed out
  # of a map rather than written inline.
  defp scope_of(kind, scope) do
    Map.fetch!(%{anonymous: scope, grantless: scope, employer: scope}, kind)
  end
end
