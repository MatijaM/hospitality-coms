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
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rosters
  alias HospitalityComs.Rosters.RosterEntry

  @now ~U[2026-03-01 12:00:00.000000Z]

  @shift_starts DateTime.add(@now, 1, :hour)
  @shift_ends DateTime.add(@now, 9, :hour)

  @an_hour_on DateTime.add(@now, 1, :hour)
  @two_hours_on DateTime.add(@now, 2, :hour)

  # Next week's hire and next week's shift. The term opens after the rostering
  # and the room opens after that, which is the ordinary shape of a rota built
  # in advance and the shape `add_to_roster/3` used to refuse.
  @next_monday DateTime.add(@now, 7, :day)
  @next_month DateTime.add(@now, 37, :day)

  @future_shift_starts DateTime.add(@next_monday, 8, :hour)
  @future_shift_ends DateTime.add(@next_monday, 16, :hour)

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

    test "accepts an engagement whose term has not opened yet" do
      # **Issue #24.** The check was "active at the scope's instant", which
      # excluded the not-yet-open state as a side effect of excluding the closed
      # one — so a hire whose term opens next Monday could not go on next
      # Tuesday's shift today, and the operator got `:not_found`, which is what
      # a bad id gets. The set is now "the term has not closed", which is
      # `end_engagement/2`'s own target set and was widened for this same state.
      %{employer: employer} = engaged()
      room = future_shift_room(employer)
      unstarted = engaged_from(employer, @next_monday, @next_month)

      assert {:ok, %RosterEntry{} = entry} =
               Rosters.add_to_roster(employer, room.id, unstarted.id)

      assert entry.engagement_id == unstarted.id

      # `joined_at` is the instant of the call, not the term's opening: the
      # entry is `[today, ∞)` and the engagement opens on Monday, and membership
      # is the intersection of the two.
      assert entry.joined_at == @now
      assert is_nil(entry.left_at)
    end

    test "puts a person on a rota whose entry confers nothing until their term opens" do
      # **The property the widening rests on, asserted rather than argued.**
      # `shift_room_members/2`, `shift_room_readers/2` and
      # `readable_shift_rooms/2` all intersect the roster with an engagement
      # active *at the instant asked about*, so the write-time check delivered
      # no property the read path was not already delivering — it only cost the
      # operator a rota they could not build.
      #
      # **The room is open at both instants, and that is what makes this
      # isolating.** Written first against next week's room, every "before"
      # assertion passed because the room was shut — measured: deleting
      # `active_at/2` from `shift_room_members/2` altogether left that version
      # green. Here the room opens an hour from now and the term opens two, so
      # the only difference between the two reads is whether the engagement is
      # active, and one write happens before either of them.
      %{employer: employer} = engaged()
      room = shift_room(employer)

      %{engagement: unstarted, person: person} =
        engaged_pair_from(employer, @two_hours_on, @next_month)

      {:ok, _entry} = Rosters.add_to_roster(employer, room.id, unstarted.id)

      shut_out = employer_at(employer, @an_hour_on)
      waiting = person_at(person, @an_hour_on)

      assert {:ok, []} = Rooms.list_shift_room_members(shut_out, room.id)
      assert {:ok, []} = Rooms.list_shift_room_readers(shut_out, room.id)
      assert Rooms.list_readable_shift_rooms(waiting) == []

      refute Rooms.shift_room_member?(waiting, room.id)
      refute Rooms.shift_room_readable?(waiting, room.id)

      # The control: the same five reads an hour later, when the term has opened
      # and nothing else has changed.
      open = employer_at(employer, @two_hours_on)
      working = person_at(person, @two_hours_on)

      assert {:ok, [member]} = Rooms.list_shift_room_members(open, room.id)
      assert member.id == unstarted.id
      assert {:ok, [_reader]} = Rooms.list_shift_room_readers(open, room.id)
      assert [readable] = Rooms.list_readable_shift_rooms(working)
      assert readable.id == room.id

      assert Rooms.shift_room_member?(working, room.id)
      assert Rooms.shift_room_readable?(working, room.id)
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

    test "closes an entry whose engagement has already ended" do
      # The state the expiry worker leaves behind. `end_engagement/2` closes no
      # roster entries, so an ended engagement can still hold an open period —
      # and `add_to_roster/3` refuses to create one, so this call is the only
      # way such a row can ever be closed. Refusing it here would leave the
      # entry open for ever, with no operation anywhere able to reach it.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)
      entry = roster_entry_fixture(employer, room, engagement.id)

      {:ok, _ended} = Engagements.end_engagement(employer, engagement.id)

      assert {:ok, closed} =
               Rosters.remove_from_roster(
                 employer_at(employer, @an_hour_on),
                 room.id,
                 engagement.id
               )

      assert closed.id == entry.id
      assert closed.left_at == @an_hour_on

      # And it stays closed: the engagement is gone, so nothing reopens it.
      assert {:error, :not_found} =
               Rosters.add_to_roster(employer_at(employer, @two_hours_on), room.id, engagement.id)
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

    test "carries the engagement each entry names, so a caller has a role label" do
      # R13. A `RosterEntry` has an id and no label; the label is the
      # engagement's, and this is where it is loaded.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      assert {:ok, [entry]} = Rosters.list_roster(employer, room.id)
      assert %Engagement{} = entry.engagement
      assert entry.engagement.id == engagement.id
      assert entry.engagement.role_label == engagement.role_label
    end

    test "labels an entry whose engagement has not opened, which no client-side join could" do
      # **KTD-E10's whole argument, and the second assertion is the control.**
      #
      # `add_to_roster/3` accepts an engagement whose term has not opened —
      # next Monday's starter on next Tuesday's rota, built today — while
      # `Engagements.list_engagements/1` answers only with engagements active at
      # the instant. So a caller joining the roster against the venue's people
      # list has no label for this row and renders a bare id.
      #
      # Without the second assertion, "the label came from the preload" and
      # "the label could have come from the people list" are the same green.
      %{employer: employer} = engaged()
      starter = engaged_from(employer, @next_monday, @next_month)
      room = future_shift_room(employer)

      roster_entry_fixture(employer, room, starter.id)

      assert {:ok, [entry]} = Rosters.list_roster(employer, room.id)
      assert entry.engagement_id == starter.id
      assert entry.engagement.role_label == starter.role_label

      assert {:ok, active} = Engagements.list_engagements(employer)
      refute starter.id in Enum.map(active, & &1.id)
    end

    test "hands the written entry back carrying its engagement too" do
      # The create response renders the same shape the list does, and a render
      # reaching an unloaded association raises rather than rendering nil.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      assert {:ok, %RosterEntry{engagement: %Engagement{} = loaded}} =
               Rosters.add_to_roster(employer, room.id, engagement.id)

      assert loaded.id == engagement.id
      assert loaded.role_label == engagement.role_label
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

  # An engagement of this venue whose term opens later than the scope's instant,
  # which is the state issue #24 is about: claimed, confirmed, and not yet open
  # (KTD13).
  defp engaged_from(employer, starts_at, ends_at) do
    %{engagement: engagement} = engaged_pair_from(employer, starts_at, ends_at)
    engagement
  end

  defp engaged_pair_from(employer, starts_at, ends_at) do
    person = person_scope_fixture(@now)

    engagement =
      engagement_fixture(employer, person, %{
        starts_at: starts_at,
        ends_at: ends_at,
        code_expires_at: DateTime.add(@now, 7, :day)
      })

    %{person: person, engagement: engagement}
  end

  defp shift_room(employer) do
    shift_type = shift_type_fixture(employer, 30)
    shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)
  end

  defp future_shift_room(employer) do
    shift_type = shift_type_fixture(employer, 30)
    shift_room_fixture(employer, shift_type, @future_shift_starts, @future_shift_ends)
  end

  defp errors_on(changeset), do: HospitalityComs.DataCase.errors_on(changeset)

  # See `HospitalityComs.EngagementsTest` for why a refused scope is handed out
  # of a map rather than written inline.
  defp scope_of(kind, scope) do
    Map.fetch!(%{anonymous: scope, grantless: scope, employer: scope}, kind)
  end
end
