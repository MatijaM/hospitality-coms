defmodule HospitalityComs.RoomsTest do
  @moduledoc """
  Two room kinds, no stored membership, and no job.

  Four things are asserted here and they answer different questions.

  **That membership is derived.** Every test that changes who is in a room does
  it by moving the *instant* rather than by writing a membership row, because
  there is no membership row to write. The clock-advance tests assert the same
  call succeeding and then failing across a boundary, and look at the job table
  in between to confirm nothing ran.

  **That the overlap predicate is right.** It is the one piece of logic in this
  unit that U5 did not already prove, and the failure it can have is silent: an
  endpoint-only form reports an overlap for an empty roster period, so somebody
  rostered and un-rostered in the same instant would be able to read a room they
  were never in. `overlapping_open_interval/1 agrees with Postgres` is a matrix
  test comparing the Ecto spelling against `&&` on the generated `tstzrange`
  columns, case by case, with the empty and unbounded cases included.

  **That removal is not retroactive.** A person removed from a roster after the
  room opened keeps their access to what was already said — and to what is said
  afterwards, because the read scope is the overlap and the overlap has already
  happened. That is KTD6b's whole claim and it is asserted as a state rather
  than as a return value.

  **That the employer cannot see a suspension.** KTD18. Three ways: the
  privilege sweep says the role holds nothing on the table
  (`HospitalityComs.BoundaryTest`), the query backstop refuses the join, and
  there is no employer-side function that would answer the question.

  ## The controls

  Every assertion that could pass for the wrong reason ships with one that fails
  when it does:

    * the ended engagement is excluded *next to* the active one being included,
      so a membership query returning nothing would fail the pair;
    * the post-grace send is refused next to the within-grace send succeeding;
    * the person rostered and removed before the shift is absent next to the
      person added after it opened being present;
    * the day-one hire cannot read a past shift room next to being able to read
      the venue room's full history;
    * the suspended person is absent from the venue room next to remaining in
      their shift room;
    * the overlap matrix contains pairs that do overlap, so a predicate
      returning false everywhere fails it.

  ## Why this file is not sandboxed

  A shift room is written through `HospitalityComs.EmployerRepo` and read
  through `HospitalityComs.Repo`; under the sandbox those are two transactions
  that cannot see each other. See `HospitalityComs.EngagementsFixtures` — the
  rows are committed and purged by a name prefix before and after every test.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import HospitalityComs.DataCase, only: [errors_on: 1]
  import HospitalityComs.EngagementsFixtures
  import HospitalityComs.RoomsFixtures

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.EmployerRepo.ZoneViolationError
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Records, as: EngagementRecords
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.MessagePage
  alias HospitalityComs.Rooms.Records
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rooms.VenueRoom
  alias HospitalityComs.Rosters
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.ShiftType

  @now ~U[2026-03-01 12:00:00.000000Z]

  # A shift that opens an hour from `@now` and runs eight hours.
  @shift_starts DateTime.add(@now, 1, :hour)
  @shift_ends DateTime.add(@now, 9, :hour)
  @grace_minutes 30
  @grace_closes DateTime.add(@shift_ends, @grace_minutes, :minute)

  @a_second 1

  setup do
    real_connections()
  end

  ## The venue room

  describe "venue-room membership" do
    test "holds a person whose engagement is active, and not one whose engagement ended" do
      # R9, and its own control: the same query, the same person, two instants.
      # A membership query that returned nothing would satisfy the second
      # assertion and fail the first.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      assert Rooms.venue_room_member?(person, employer.venue_id)
      assert [%Engagement{id: id}] = members(person, employer.venue_id)
      assert id == engagement.id

      after_the_end = DateTime.add(engagement.ends_at, @a_second, :second)

      refute Rooms.venue_room_member?(person_at(person, after_the_end), employer.venue_id)
    end

    test "excludes the person at the instant their engagement ends, and includes them a second before" do
      # Half-open, asserted at the boundary rather than near it.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      a_second_before = DateTime.add(engagement.ends_at, -@a_second, :second)

      assert Rooms.venue_room_member?(person_at(person, a_second_before), employer.venue_id)
      refute Rooms.venue_room_member?(person_at(person, engagement.ends_at), employer.venue_id)
    end

    test "changes across the engagement's upper bound with no job having run" do
      # The unit's verification condition for the venue room. The job table is
      # inspected between the two reads: the only row is the expiry job U5
      # enqueues at claim time, still scheduled and never executed.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      assert Rooms.venue_room_member?(person, employer.venue_id)
      assert executed_jobs() == 0

      after_the_end = DateTime.add(engagement.ends_at, @a_second, :second)

      refute Rooms.venue_room_member?(person_at(person, after_the_end), employer.venue_id)
      assert executed_jobs() == 0
    end

    test "is not answerable from an employer scope, because no function has a head for one" do
      # KTD18 as an API absence rather than a runtime check. An employer able to
      # ask who is in the venue room could learn who has opted out by noticing
      # an absence, so there is no arity that takes an employer scope and no
      # clause that matches one.
      {employer, _creation} = scoped_venue_fixture(@now)

      refute function_exported?(Rooms, :list_venue_room_members, 1)
      refute function_exported?(Rooms, :venue_room_member?, 1)

      assert_raise FunctionClauseError, fn ->
        Rooms.list_venue_room_members(scope_of(:employer, employer), employer.venue_id)
      end
    end

    test "refuses an anonymous person scope by function clause too" do
      # Answering `[]` would make "nobody" and "somebody with nothing" the same
      # answer, which is the distinction R1 rests on.
      assert_raise FunctionClauseError, fn ->
        Rooms.list_venue_rooms(scope_of(:anonymous, anonymous_person_scope()))
      end
    end

    test "lists the venue rooms a person is in, derived from the venue and stored nowhere" do
      %{employer: employer, person: person} = engaged()

      assert [%VenueRoom{venue_id: venue_id}] = Rooms.list_venue_rooms(person)
      assert venue_id == employer.venue_id

      refute Enum.any?(database_tables(), &(&1 == "venue_rooms"))
    end
  end

  ## Suspension

  describe "suspension" do
    test "removes the person from the venue room and leaves them in their shift room" do
      # KTD18's scope, and its own control. A suspension that removed the person
      # from everything would satisfy the first assertion and fail the second.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      {:ok, _suspension} = Rooms.suspend_venue_room(person, employer.venue_id)

      during = person_at(person, @shift_starts)

      refute Rooms.venue_room_member?(during, employer.venue_id)
      assert Rooms.shift_room_member?(during, room.id)
      assert Rooms.shift_room_readable?(during, room.id)
    end

    test "hides the venue room's messages while it is in force" do
      %{employer: employer, person: person} = engaged()

      {:ok, _message} = Rooms.send_venue_room_message(person, employer.venue_id, "before")
      {:ok, _suspension} = Rooms.suspend_venue_room(person, employer.venue_id)

      assert {:error, :not_a_member} = Rooms.list_venue_room_messages(person, employer.venue_id)

      assert {:error, :not_a_member} =
               Rooms.send_venue_room_message(person, employer.venue_id, "while out")
    end

    test "is reversible, and the resumed person sees everything sent while they were out" do
      # The scenario in full. A colleague speaks into the room while the first
      # person is suspended; on resuming, that message is in their history.
      %{employer: employer, person: person} = engaged()
      %{person: colleague} = engaged_at(employer)

      later = DateTime.add(@now, 1, :hour)
      later_still = DateTime.add(@now, 2, :hour)

      {:ok, _before} = Rooms.send_venue_room_message(person, employer.venue_id, "before")
      {:ok, _suspension} = Rooms.suspend_venue_room(person_at(person, later), employer.venue_id)

      {:ok, _during} =
        Rooms.send_venue_room_message(
          person_at(colleague, later_still),
          employer.venue_id,
          "while out"
        )

      resumed = person_at(person, DateTime.add(@now, 3, :hour))
      {:ok, _closed} = Rooms.resume_venue_room(resumed, employer.venue_id)

      assert {:ok, %MessagePage{messages: messages}} =
               Rooms.list_venue_room_messages(resumed, employer.venue_id)

      assert Enum.map(messages, & &1.body) == ["before", "while out"]
    end

    test "leaves the room's roll identical to the engagements an employer can already list" do
      # KTD18 as a set difference rather than as a `select` list, which is the
      # form the guarantee actually has to survive. A manager is a worker too:
      # one caller holds an employer scope and a person scope at the same venue,
      # so they can read `Engagements.list_engagements/1` and
      # `Rooms.list_venue_room_members/2` in the same breath. If the second
      # subtracted suspensions, the difference between the two lists would be
      # exactly the set of people who had opted out — and the invisibility the
      # person zone buys would be recoverable by subtraction from inside the
      # room, which is the retaliation surface KTD18 exists to close.
      %{employer: employer, person: person} = engaged()
      %{person: colleague} = engaged_at(employer)
      %{person: opted_out} = engaged_at(employer)

      {:ok, _suspension} = Rooms.suspend_venue_room(opted_out, employer.venue_id)

      assert {:ok, engagements} = Engagements.list_engagements(employer)
      assert length(engagements) == 3

      assert ids(members(person, employer.venue_id)) == ids(engagements)
      assert ids(members(colleague, employer.venue_id)) == ids(engagements)
    end

    test "still governs what the suspended person themselves may reach" do
      # The control for the roll being unfiltered. Suspension is not a no-op
      # dressed up as one: it is the person's own access that closes, and the
      # room's roll is not where that is recorded.
      %{employer: employer, person: person} = engaged()

      {:ok, _suspension} = Rooms.suspend_venue_room(person, employer.venue_id)

      refute Rooms.venue_room_member?(person, employer.venue_id)
      assert Rooms.list_venue_rooms(person) == []
      assert {:error, :not_a_member} = Rooms.list_venue_room_members(person, employer.venue_id)
      assert {:error, :not_a_member} = Rooms.list_venue_room_messages(person, employer.venue_id)
      assert {:error, :not_a_member} = Rooms.fetch_venue_room(person, employer.venue_id)

      # The send too, and it carries more weight than the reads: U7 gives
      # suspension a broadcast that stops the person's open channels, and that
      # broadcast is best effort. This is the refusal that holds when it is
      # lost — derived at the instant of the send, with no job and no nudge.
      assert {:error, :not_a_member} =
               Rooms.send_venue_room_message(person, employer.venue_id, "still here?")
    end

    test "is invisible to an employer scope: the query is refused before Postgres is asked" do
      # The backstop names the table. The privilege sweep in
      # `HospitalityComs.BoundaryTest` is the tier underneath it.
      %{employer: employer, person: person} = engaged()
      {:ok, _suspension} = Rooms.suspend_venue_room(person, employer.venue_id)

      assert_raise ZoneViolationError, ~r/venue_room_suspensions/, fn ->
        EmployerRepo.scoped_transaction(employer, fn scope ->
          {:ok,
           Engagement
           |> where([engagement], engagement.venue_id == ^scope.venue_id)
           |> Records.unsuspended(scope.now)
           |> EmployerRepo.all()}
        end)
      end
    end

    test "leaves the employer's own view of the engagement unchanged" do
      # The absence, from the other side: everything an employer session can see
      # about this person is identical before and after.
      %{employer: employer, person: person} = engaged()

      {:ok, before} = Engagements.list_engagements(employer)
      {:ok, _suspension} = Rooms.suspend_venue_room(person, employer.venue_id)
      {:ok, afterwards} = Engagements.list_engagements(employer)

      assert afterwards == before
    end

    test "refuses a second suspension and a resume when there is nothing to resume" do
      %{employer: employer, person: person} = engaged()

      assert {:ok, _suspension} = Rooms.suspend_venue_room(person, employer.venue_id)
      assert {:error, :already_suspended} = Rooms.suspend_venue_room(person, employer.venue_id)

      assert {:ok, _resumed} = Rooms.resume_venue_room(person, employer.venue_id)
      assert {:error, :not_suspended} = Rooms.resume_venue_room(person, employer.venue_id)
    end

    test "refuses a person with no engagement at that venue" do
      %{person: person} = engaged()
      {other_employer, _creation} = scoped_venue_fixture(@now)

      assert {:error, :no_engagement} =
               Rooms.suspend_venue_room(person, other_employer.venue_id)

      refute Rooms.venue_room_suspended?(person, other_employer.venue_id)
    end

    test "is a period, so it resolves at its own boundary with nothing having run" do
      %{employer: employer, person: person} = engaged()

      {:ok, suspension} = Rooms.suspend_venue_room(person, employer.venue_id)
      before_it_began = DateTime.add(suspension.suspended_at, -@a_second, :second)

      refute Rooms.venue_room_suspended?(person_at(person, before_it_began), employer.venue_id)
      assert Rooms.venue_room_suspended?(person, employer.venue_id)
    end
  end

  ## Shift rooms

  describe "shift-room membership" do
    test "at open is the rostered set holding active engagements" do
      %{employer: employer, person: person, engagement: engagement} = engaged()
      %{person: colleague, engagement: unrostered} = engaged_at(employer)
      room = shift_room(employer)

      roster_entry_fixture(employer, room, engagement.id)

      at_open = employer_at(employer, @shift_starts)

      assert {:ok, [%Engagement{id: id}]} = Rooms.list_shift_room_members(at_open, room.id)
      assert id == engagement.id
      refute id == unrostered.id

      assert Rooms.shift_room_member?(person_at(person, @shift_starts), room.id)
      refute Rooms.shift_room_member?(person_at(colleague, @shift_starts), room.id)
    end

    test "excludes a rostered person whose engagement has since ended" do
      # The intersection with `active_at/2`, asserted as the difference it makes:
      # the roster entry is untouched and the person is gone.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      at_open = employer_at(employer, @shift_starts)
      assert {:ok, [_member]} = Rooms.list_shift_room_members(at_open, room.id)

      {:ok, _ended} = Engagements.end_engagement(employer_at(employer, @now), engagement.id)

      assert {:ok, []} = Rooms.list_shift_room_members(at_open, room.id)
      assert {:ok, [_entry]} = Rosters.list_roster(at_open, room.id)
      refute Rooms.shift_room_readable?(person_at(person, @shift_starts), room.id)
    end

    test "is empty before the room opens and after it closes, because the window is half-open" do
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      before_open = DateTime.add(@shift_starts, -@a_second, :second)
      last_open_second = DateTime.add(@grace_closes, -@a_second, :second)

      assert {:ok, []} =
               Rooms.list_shift_room_members(employer_at(employer, before_open), room.id)

      assert {:ok, [_member]} =
               Rooms.list_shift_room_members(employer_at(employer, @shift_starts), room.id)

      assert {:ok, [_still]} =
               Rooms.list_shift_room_members(employer_at(employer, last_open_second), room.id)

      assert {:ok, []} =
               Rooms.list_shift_room_members(employer_at(employer, @grace_closes), room.id)
    end
  end

  describe "shift-room readability" do
    test "adding somebody after the room opened puts them in it and keeps them readable after grace" do
      # The pair KTD6b exists for: derived membership adds them without a job,
      # and the overlap keeps them once the room has shut.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)

      mid_shift = DateTime.add(@shift_starts, 2, :hour)
      roster_entry_fixture(employer_at(employer, mid_shift), room, engagement.id)

      refute Rooms.shift_room_member?(person_at(person, @shift_starts), room.id)
      assert Rooms.shift_room_member?(person_at(person, mid_shift), room.id)

      long_after = DateTime.add(@grace_closes, 30, :day)

      assert Rooms.shift_room_readable?(person_at(person, long_after), room.id)

      assert {:ok, %MessagePage{}} =
               Rooms.list_shift_room_messages(person_at(person, long_after), room.id)
    end

    test "removing somebody after the room opened leaves their access to what was already sent" do
      # Non-retroactivity, asserted as a state. The removal happens after a
      # message exists, and the message is still readable afterwards.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      %{person: colleague, engagement: other} = engaged_at(employer)
      room = shift_room(employer)

      roster_entry_fixture(employer, room, engagement.id)
      roster_entry_fixture(employer, room, other.id)

      mid_shift = DateTime.add(@shift_starts, 2, :hour)
      {:ok, _sent} = Rooms.send_shift_room_message(person_at(person, mid_shift), room.id, "hello")

      later = DateTime.add(mid_shift, 1, :hour)

      {:ok, _removed} =
        Rosters.remove_from_roster(employer_at(employer, later), room.id, engagement.id)

      after_removal = person_at(person, DateTime.add(later, 1, :hour))

      refute Rooms.shift_room_member?(after_removal, room.id)
      assert Rooms.shift_room_readable?(after_removal, room.id)

      assert {:ok, %MessagePage{messages: [%RoomMessage{body: "hello"}]}} =
               Rooms.list_shift_room_messages(after_removal, room.id)

      # And what the colleague says afterwards is still readable too: the read
      # scope is the overlap, not a snapshot of the room's contents.
      {:ok, _second} =
        Rooms.send_shift_room_message(
          person_at(colleague, DateTime.add(later, 2, :hour)),
          room.id,
          "after"
        )

      assert {:ok, %MessagePage{messages: [_first, %RoomMessage{body: "after"}]}} =
               Rooms.list_shift_room_messages(after_removal, room.id)
    end

    test "somebody rostered before the shift and removed before it starts never appears" do
      # The case that distinguishes overlap from "was ever rostered", and its
      # control is the test above: an overlap predicate that matched nothing
      # would pass this and fail that.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)

      roster_entry_fixture(employer, room, engagement.id)

      removed_at = DateTime.add(@now, 10, :minute)

      {:ok, entry} =
        Rosters.remove_from_roster(employer_at(employer, removed_at), room.id, engagement.id)

      assert DateTime.compare(entry.left_at, @shift_starts) == :lt

      refute Rooms.shift_room_member?(person_at(person, @shift_starts), room.id)
      refute Rooms.shift_room_readable?(person_at(person, @shift_starts), room.id)

      refute Rooms.shift_room_readable?(
               person_at(person, DateTime.add(@grace_closes, 1, :day)),
               room.id
             )

      assert {:ok, []} =
               Rooms.list_shift_room_readers(employer_at(employer, @shift_starts), room.id)
    end

    test "an entry removed at the instant it was added overlaps nothing, even inside the window" do
      # The empty period. An endpoint-only overlap predicate reports this as an
      # overlap, which would give somebody access to a room they were never in.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)

      mid_shift = DateTime.add(@shift_starts, 2, :hour)
      at_mid_shift = employer_at(employer, mid_shift)

      roster_entry_fixture(at_mid_shift, room, engagement.id)
      {:ok, entry} = Rosters.remove_from_roster(at_mid_shift, room.id, engagement.id)

      assert DateTime.compare(entry.left_at, entry.joined_at) == :eq

      refute Rooms.shift_room_readable?(person_at(person, mid_shift), room.id)
      assert {:ok, []} = Rooms.list_shift_room_readers(at_mid_shift, room.id)
    end

    test "a roster period opened and closed inside one second is a period, not an empty range" do
      # The consequence of truncating a roster bound, stated where it is
      # observable. Rostered at 1.2s past the room's opening and removed at
      # 1.8s, this person was demonstrably in the room; truncating both bounds
      # made the period `[t, t)`, which overlaps nothing, so the six hundred
      # milliseconds they were in it were unmade by the removal that ended them.
      #
      # KTD6b's claim is that no write can shorten an overlap that has already
      # happened. A floored upper bound is a write that does.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)

      joined_at = DateTime.add(@shift_starts, 1_200, :millisecond)
      left_at = DateTime.add(@shift_starts, 1_800, :millisecond)

      roster_entry_fixture(employer_at(employer, joined_at), room, engagement.id)

      assert {:ok, entry} =
               Rosters.remove_from_roster(employer_at(employer, left_at), room.id, engagement.id)

      assert entry.joined_at == joined_at
      assert entry.left_at == left_at

      after_close = DateTime.add(@grace_closes, 1, :hour)

      assert Rooms.shift_room_readable?(person_at(person, after_close), room.id)

      assert {:ok, [_reader]} =
               Rooms.list_shift_room_readers(employer_at(employer, after_close), room.id)
    end

    test "a person outside the overlap set cannot read the closed room, active engagement or not" do
      # KTD14's snapshot scope. The colleague is engaged at the venue for the
      # whole period and was never rostered on this shift.
      %{employer: employer, engagement: engagement} = engaged()
      %{person: colleague} = engaged_at(employer)
      room = shift_room(employer)

      roster_entry_fixture(employer, room, engagement.id)

      after_close = DateTime.add(@grace_closes, 1, :hour)
      viewer = person_at(colleague, after_close)

      assert Rooms.venue_room_member?(viewer, employer.venue_id)
      refute Rooms.shift_room_readable?(viewer, room.id)
      assert {:error, :not_found} = Rooms.list_shift_room_messages(viewer, room.id)
    end

    test "rostering onto a room that shut yesterday grants nothing, because joined_at is now" do
      # The one write that could hand out retroactive read access, and the whole
      # reason `joined_at` is the instant of the *call* rather than the shift's
      # start. The raw-row matrix covers the interval shape; this is the context
      # path, where a manager really can roster somebody onto a room that has
      # already closed and the answer has to be that they were never in it.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      shift_type = shift_type_fixture(employer, @grace_minutes)
      closed_yesterday = DateTime.add(@now, -1, :day)

      room =
        shift_room_fixture(
          employer,
          shift_type,
          DateTime.add(closed_yesterday, -8, :hour),
          closed_yesterday
        )

      entry = roster_entry_fixture(employer, room, engagement.id)

      # The rostering happened, and it happened now.
      assert entry.joined_at == @now
      assert {:ok, [_live]} = Rosters.list_roster(employer, room.id)

      # And it overlaps nothing, so it confers nothing.
      refute Rooms.shift_room_member?(person, room.id)
      refute Rooms.shift_room_readable?(person, room.id)
      assert Rooms.list_readable_shift_rooms(person) == []
      assert {:error, :not_found} = Rooms.list_shift_room_messages(person, room.id)
      assert {:ok, []} = Rooms.list_shift_room_readers(employer, room.id)

      # The room is reachable — it is this person's own venue — and shut.
      assert {:error, :room_closed} = Rooms.send_shift_room_message(person, room.id, "too late")
    end

    test "refuses a room that does not exist with the same answer as one it may not read" do
      %{person: person} = engaged()

      assert {:error, :not_found} =
               Rooms.list_shift_room_messages(person, Ecto.UUID.generate())
    end
  end

  ## The grace window

  describe "sending into a shift room" do
    test "is accepted within grace and refused once it closes" do
      # The pair, and the unit's verification condition. The instant moves; the
      # job table does not.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      last_open_second = DateTime.add(@grace_closes, -@a_second, :second)

      assert {:ok, %RoomMessage{}} =
               Rooms.send_shift_room_message(person_at(person, @shift_ends), room.id, "handover")

      assert {:ok, %RoomMessage{}} =
               Rooms.send_shift_room_message(
                 person_at(person, last_open_second),
                 room.id,
                 "one more"
               )

      assert executed_jobs() == 0

      assert {:error, :room_closed} =
               Rooms.send_shift_room_message(
                 person_at(person, @grace_closes),
                 room.id,
                 "too late"
               )

      assert executed_jobs() == 0
    end

    test "is refused before the room opens" do
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      before_open = DateTime.add(@shift_starts, -@a_second, :second)

      assert {:error, :room_closed} =
               Rooms.send_shift_room_message(person_at(person, before_open), room.id, "early")
    end

    test "closes at the shift's end when the shift type's grace is zero" do
      %{employer: employer, person: person, engagement: engagement} = engaged()
      shift_type = shift_type_fixture(employer, 0)
      room = shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)
      roster_entry_fixture(employer, room, engagement.id)

      assert room.closes_at == DateTime.truncate(@shift_ends, :second)

      a_second_before = DateTime.add(@shift_ends, -@a_second, :second)

      assert {:ok, %RoomMessage{}} =
               Rooms.send_shift_room_message(
                 person_at(person, a_second_before),
                 room.id,
                 "last call"
               )

      assert {:error, :room_closed} =
               Rooms.send_shift_room_message(person_at(person, @shift_ends), room.id, "too late")
    end

    test "is refused for somebody who is not rostered, in a room that is open" do
      %{employer: employer} = engaged()
      %{person: colleague} = engaged_at(employer)
      room = shift_room(employer)

      assert {:error, :not_rostered} =
               Rooms.send_shift_room_message(person_at(colleague, @shift_starts), room.id, "hi")
    end

    test "is refused for somebody removed from the roster, who can still read" do
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      mid_shift = DateTime.add(@shift_starts, 2, :hour)
      {:ok, _sent} = Rooms.send_shift_room_message(person_at(person, mid_shift), room.id, "hello")

      {:ok, _removed} =
        Rosters.remove_from_roster(employer_at(employer, mid_shift), room.id, engagement.id)

      later = person_at(person, DateTime.add(mid_shift, 1, :hour))

      assert {:error, :not_rostered} = Rooms.send_shift_room_message(later, room.id, "again")

      assert {:ok, %MessagePage{messages: [%RoomMessage{body: "hello"}]}} =
               Rooms.list_shift_room_messages(later, room.id)
    end

    test "refuses a room that does not exist" do
      %{person: person} = engaged()

      assert {:error, :not_found} =
               Rooms.send_shift_room_message(person, Ecto.UUID.generate(), "hi")
    end

    test "answers not-found about another venue's room, whether it is open or shut" do
      # AE1's rule at the one place a caller supplies the id. `:room_closed` and
      # `:not_rostered` are both statements that the named room exists, so
      # answering either about an arbitrary id would enumerate every venue's
      # shifts one probe at a time. The control is the pair of tests above: the
      # same two answers *are* given about this person's own venue.
      %{person: person} = engaged()
      %{employer: other} = engaged()
      elsewhere = shift_room(other)

      open = person_at(person, @shift_starts)
      shut = person_at(person, DateTime.add(@grace_closes, 1, :hour))

      assert {:error, :not_found} = Rooms.send_shift_room_message(open, elsewhere.id, "hi")
      assert {:error, :not_found} = Rooms.send_shift_room_message(shut, elsewhere.id, "hi")

      # Same instants, this person's own venue: the answers are the informative
      # ones, so the assertion above is about the venue and not about the clock.
      %{employer: employer, engagement: engagement} = engaged()
      mine = shift_room(employer)
      roster_entry_fixture(employer, mine, engagement.id)
      %{person: colleague} = engaged_at(employer)

      assert {:error, :not_rostered} =
               Rooms.send_shift_room_message(person_at(colleague, @shift_starts), mine.id, "hi")

      assert {:error, :room_closed} =
               Rooms.send_shift_room_message(
                 person_at(colleague, DateTime.add(@grace_closes, 1, :hour)),
                 mine.id,
                 "hi"
               )
    end
  end

  ## History

  describe "history" do
    test "a newly engaged person reads the venue room's history from before their engagement" do
      # R14, in the room KTD14 grants it to.
      %{employer: employer, person: person} = engaged()

      {:ok, _early} = Rooms.send_venue_room_message(person, employer.venue_id, "old news")

      later = DateTime.add(@now, 10, :day)
      %{person: newcomer} = engaged_at(employer, later)

      assert {:ok, %MessagePage{messages: [%RoomMessage{body: "old news"}]}} =
               Rooms.list_venue_room_messages(person_at(newcomer, later), employer.venue_id)
    end

    test "a newly engaged person cannot read a shift room from before their engagement" do
      # KTD14's other half, and the control is the test above: taking R14
      # literally would let a day-one hire read every shift the venue has run.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      {:ok, _sent} =
        Rooms.send_shift_room_message(person_at(person, @shift_starts), room.id, "on shift")

      later = DateTime.add(@now, 10, :day)
      %{person: newcomer} = engaged_at(employer, later)
      viewer = person_at(newcomer, later)

      assert Rooms.venue_room_member?(viewer, employer.venue_id)
      refute Rooms.shift_room_readable?(viewer, room.id)
      assert {:error, :not_found} = Rooms.list_shift_room_messages(viewer, room.id)
      assert Rooms.list_readable_shift_rooms(viewer) == []
    end

    test "lists the shift rooms a person may read, each once" do
      # `DISTINCT`, because rostered-removed-rostered is three overlapping
      # periods on one room.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)

      roster_entry_fixture(employer, room, engagement.id)

      {:ok, _out} =
        Rosters.remove_from_roster(employer_at(employer, @shift_starts), room.id, engagement.id)

      mid_shift = DateTime.add(@shift_starts, 2, :hour)
      roster_entry_fixture(employer_at(employer, mid_shift), room, engagement.id)

      after_close = person_at(person, DateTime.add(@grace_closes, 1, :hour))

      assert [%ShiftRoom{id: id}] = Rooms.list_readable_shift_rooms(after_close)
      assert id == room.id
    end
  end

  ## The bound on history

  describe "the message bound" do
    test "answers the most recent page, and the page is not the oldest rows" do
      # The unit's central claim, and its own control in one body.
      #
      # The count assertion alone certifies nothing: a bound that took the
      # **oldest** fifty returns fifty rows and satisfies it. So the bodies are
      # named — the first written must be absent and the last written present —
      # and the fixture holds `limit + 1` rows, because a bound asserted against
      # a room of twelve is a bound asserted against nothing.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      limit = Rooms.recent_message_limit()
      bodies = venue_room_messages_fixture(engagement, limit + 1, @now)

      assert {:ok, %MessagePage{messages: page, complete: false}} =
               Rooms.list_venue_room_messages(person, employer.venue_id)

      assert length(page) == limit

      read = Enum.map(page, & &1.body)

      refute List.first(bodies) in read
      assert List.last(bodies) in read
    end

    test "orders the page oldest first, like the stream it precedes" do
      # Getting the newest fifty means ordering descending somewhere. If that
      # ordering is the one the caller sees, the room renders backwards — and
      # every assertion in the test above passes.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      bodies = venue_room_messages_fixture(engagement, Rooms.recent_message_limit() + 1, @now)

      assert {:ok, %MessagePage{messages: page}} =
               Rooms.list_venue_room_messages(person, employer.venue_id)

      assert Enum.map(page, & &1.body) == Enum.take(bodies, -Rooms.recent_message_limit())
    end

    test "lifts the bound for :all, which is the control for the bound existing at all" do
      # A limit applied to `:all` too would satisfy every assertion above and
      # make "load the whole history" a lie.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      count = Rooms.recent_message_limit() + 1
      bodies = venue_room_messages_fixture(engagement, count, @now)

      assert {:ok, %MessagePage{messages: whole, complete: true}} =
               Rooms.list_venue_room_messages(person, employer.venue_id, :all)

      assert Enum.map(whole, & &1.body) == bodies
    end

    test "calls the history complete at exactly the limit" do
      # The `limit + 1` probe's own boundary, and the control for `complete`
      # being derived rather than hardcoded false.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      limit = Rooms.recent_message_limit()
      venue_room_messages_fixture(engagement, limit, @now)

      assert {:ok, %MessagePage{messages: page, complete: true}} =
               Rooms.list_venue_room_messages(person, employer.venue_id)

      assert length(page) == limit
    end

    test "answers an empty room with an empty page that is complete" do
      # The other end of `complete`. A flag derived from a non-empty list gets
      # this one wrong.
      %{employer: employer, person: person} = engaged()

      assert {:ok, %MessagePage{messages: [], complete: true}} =
               Rooms.list_venue_room_messages(person, employer.venue_id)
    end

    test "bounds a shift room's history the same way, and lifts it the same way" do
      # The second function. A bound applied to one of the two is a bound the
      # other is one forgetful caller away from not having.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      limit = Rooms.recent_message_limit()
      bodies = shift_room_messages_fixture(engagement, room, limit + 1, @shift_starts)

      reader = person_at(person, DateTime.add(@grace_closes, 1, :hour))

      assert {:ok, %MessagePage{messages: page, complete: false}} =
               Rooms.list_shift_room_messages(reader, room.id)

      assert length(page) == limit
      refute List.first(bodies) in Enum.map(page, & &1.body)
      assert List.last(bodies) in Enum.map(page, & &1.body)

      assert {:ok, %MessagePage{messages: whole, complete: true}} =
               Rooms.list_shift_room_messages(reader, room.id, :all)

      assert Enum.map(whole, & &1.body) == bodies
    end

    test "keeps the refusals it had, so the bound is not reached without authority" do
      # The bound is a page of an answer the caller was already entitled to.
      # Nothing about paging may turn a refusal into an empty page.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      venue_room_messages_fixture(engagement, 3, @now)
      {:ok, _suspension} = Rooms.suspend_venue_room(person, employer.venue_id)

      assert {:error, :not_a_member} = Rooms.list_venue_room_messages(person, employer.venue_id)

      assert {:error, :not_a_member} =
               Rooms.list_venue_room_messages(person, employer.venue_id, :all)

      assert {:error, :not_found} =
               Rooms.list_shift_room_messages(person, Ecto.UUID.generate(), :all)
    end
  end

  ## The venue-filtered shift room list

  describe "list_readable_shift_rooms/2" do
    test "answers one venue's rooms while the unfiltered arity answers both" do
      # The filter, and its control. A filtered arity that returned `[]` for
      # every venue satisfies the first assertion on its own; the unfiltered
      # arity is what proves the fixture had two venues' rooms in it.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      here = shift_room(employer)
      roster_entry_fixture(employer, here, engagement.id)

      {elsewhere_employer, _creation} = scoped_venue_fixture(@now)

      elsewhere_engagement =
        engagement_fixture(elsewhere_employer, person, %{
          starts_at: @now,
          ends_at: DateTime.add(@now, 90, :day),
          code_expires_at: DateTime.add(@now, 7, :day)
        })

      there = shift_room(elsewhere_employer)
      roster_entry_fixture(elsewhere_employer, there, elsewhere_engagement.id)

      during = person_at(person, @shift_starts)

      assert Enum.map(Rooms.list_readable_shift_rooms(during, employer.venue_id), & &1.id) ==
               [here.id]

      assert Enum.map(
               Rooms.list_readable_shift_rooms(during, elsewhere_employer.venue_id),
               & &1.id
             ) == [there.id]

      both = during |> Rooms.list_readable_shift_rooms() |> Enum.map(& &1.id) |> Enum.sort()

      assert both == Enum.sort([here.id, there.id])
    end

    test "still answers a suspended person, who is out of the venue room and on their rosters" do
      # KTD18, on the arity this unit adds. The filtered list must not grow a
      # venue-room membership gate: suspension is the venue room only, and a
      # suspended person is still on their shift rosters.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      {:ok, _suspension} = Rooms.suspend_venue_room(person, employer.venue_id)

      during = person_at(person, @shift_starts)

      # The control: the suspension is real, and it took the venue room away.
      assert Rooms.list_venue_rooms(during) == []

      assert Enum.map(Rooms.list_readable_shift_rooms(during, employer.venue_id), & &1.id) ==
               [room.id]
    end

    test "answers an empty list for a venue this person holds no engagement at" do
      # AE1 by construction rather than by a refusal: an empty list for a venue
      # with no rooms and for a venue that is not yours are the same answer.
      %{person: person} = engaged()
      {stranger, _creation} = scoped_venue_fixture(@now)
      _room = shift_room(stranger)

      assert Rooms.list_readable_shift_rooms(person, stranger.venue_id) == []
    end

    test "carries the shift type's name, so a client renders a label rather than a uuid" do
      # `ShiftRoom` has no display name of its own — only two instants and a
      # `shift_type_id`. Without the association loaded, every room list in the
      # client is uuid prefixes.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      shift_type = shift_type_fixture(employer, @grace_minutes)
      room = shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)
      roster_entry_fixture(employer, room, engagement.id)

      during = person_at(person, @shift_starts)

      assert [%ShiftRoom{shift_type: %ShiftType{name: name}}] =
               Rooms.list_readable_shift_rooms(during, employer.venue_id)

      assert name == shift_type.name

      assert [%ShiftRoom{shift_type: %ShiftType{}}] = Rooms.list_readable_shift_rooms(during)
    end
  end

  ## Shift rooms, from the employer's side

  describe "create_shift_room/3" do
    test "stamps the shift type's grace on the room rather than joining to it" do
      # The room's boundary is fixed at creation. Editing the shift type
      # afterwards must not reopen a closed room.
      {employer, _creation} = scoped_venue_fixture(@now)
      shift_type = shift_type_fixture(employer, 45)

      room = shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)

      assert room.grace_period_minutes == 45
      assert room.closes_at == DateTime.truncate(DateTime.add(@shift_ends, 45, :minute), :second)

      {:ok, widened} =
        Venues.create_shift_type(
          employer,
          employer.venue_id,
          %{name: "Wider #{System.unique_integer([:positive])}", grace_period_minutes: 120}
        )

      assert %ShiftType{grace_period_minutes: 120} = widened
      assert {:ok, reloaded} = Rooms.fetch_shift_room(employer, room.id)
      assert reloaded.grace_period_minutes == 45
      assert reloaded.closes_at == room.closes_at
    end

    test "accepts a grace of zero, which is a value rather than an omission" do
      {employer, _creation} = scoped_venue_fixture(@now)
      shift_type = shift_type_fixture(employer, 0)

      room = shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)

      assert room.grace_period_minutes == 0
      assert room.closes_at == DateTime.truncate(@shift_ends, :second)
    end

    test "refuses a term that does not move forward" do
      {employer, _creation} = scoped_venue_fixture(@now)
      shift_type = shift_type_fixture(employer)

      assert {:error, changeset} =
               Rooms.create_shift_room(employer, shift_type.id, %{
                 starts_at: @shift_ends,
                 ends_at: @shift_starts
               })

      assert "must be after the shift starts" in errors_on(changeset).ends_at
    end

    test "refuses a shift type belonging to another venue" do
      {employer, _creation} = scoped_venue_fixture(@now)
      {other, _other_creation} = scoped_venue_fixture(@now)
      elsewhere = shift_type_fixture(other)

      assert {:error, :not_found} =
               Rooms.create_shift_room(employer, elsewhere.id, %{
                 starts_at: @shift_starts,
                 ends_at: @shift_ends
               })
    end

    test "refuses a scope with no grant by function clause" do
      grantless = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert_raise FunctionClauseError, fn ->
        Rooms.create_shift_room(scope_of(:grantless, grantless), Ecto.UUID.generate(), %{})
      end
    end

    test "lists the venue's rooms earliest first and refuses another venue's" do
      {employer, _creation} = scoped_venue_fixture(@now)
      {other, _other_creation} = scoped_venue_fixture(@now)
      shift_type = shift_type_fixture(employer)

      late =
        shift_room_fixture(employer, shift_type, @shift_ends, DateTime.add(@shift_ends, 8, :hour))

      early = shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)

      assert {:ok, rooms} = Rooms.list_shift_rooms(employer)
      assert Enum.map(rooms, & &1.id) == [early.id, late.id]

      assert {:ok, []} = Rooms.list_shift_rooms(other)
      assert {:error, :not_found} = Rooms.fetch_shift_room(other, early.id)
    end
  end

  ## What holds a message row to one venue

  describe "a message's venue" do
    test "is held to its shift room's by the composite key, not by a policy" do
      # `room_messages` carries a row-level security policy that binds nobody:
      # `employer_role` holds no privilege on the table, and the only role that
      # reaches it — the application's own, through `HospitalityComs.Repo` —
      # owns the table and is not bound by a policy that is not `FORCE`d, which
      # it cannot be. See `*_enable_room_row_level_security.exs`.
      #
      # This is the tier that is actually there, asserted by writing the row
      # Postgres has to refuse. It is also what makes
      # `Records.shift_room_messages/1` safe without a venue filter.
      %{employer: employer, engagement: engagement} = engaged()
      %{employer: other} = engaged()
      elsewhere = shift_room(other)

      assert_raise Postgrex.Error, ~r/room_messages_shift_room_fkey/, fn ->
        write_raw_message(employer.venue_id, elsewhere.id, engagement.id)
      end
    end

    test "is held to its author's engagement by the composite key too" do
      # KTD15b's other half. A message at venue A cannot be attributed to an
      # engagement at venue B, and `MATCH FULL` is what says so — the two
      # columns are checked together or the row is refused.
      %{employer: employer} = engaged()
      %{engagement: elsewhere} = engaged()
      room = shift_room(employer)

      assert_raise Postgrex.Error, ~r/room_messages_author_fkey/, fn ->
        write_raw_message(employer.venue_id, room.id, elsewhere.id)
      end
    end

    test "accepts the row both keys agree about, which is the control" do
      # Without this the two refusals above would pass against a table that
      # refused every insert.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      assert %Postgrex.Result{num_rows: 1} =
               write_raw_message(employer.venue_id, room.id, engagement.id)
    end
  end

  ## The predicate itself

  describe "the overlap predicate" do
    @matrix [
      # {label, entry_offsets, expected}. Offsets are minutes from the shift's
      # start; `nil` upper means the entry is still open.
      {"contained in the window", {60, 120}, true},
      {"starting before the window and ending inside it", {-60, 60}, true},
      {"starting inside the window and open", {60, nil}, true},
      {"open from before the window", {-60, nil}, true},
      {"ending exactly at the window's start", {-120, 0}, false},
      {"starting exactly at the window's close", {510, nil}, false},
      {"ending one second into the window", {-120, 1}, true},
      {"starting one second before the window closes", {509, nil}, true},
      {"entirely before the window", {-180, -60}, false},
      {"entirely after the window", {600, 660}, false},
      {"empty, inside the window", {60, 60}, false},
      {"empty, at the window's start", {0, 0}, false},
      {"empty, at the window's close", {510, 510}, false},
      {"spanning the whole window", {-60, 600}, true}
    ]

    test "agrees with Postgres's range overlap, case by case" do
      # The highest-risk logic in the unit, checked against the database's own
      # spelling of the same rule rather than against a comment claiming they
      # agree. The generated `tstzrange` columns are what the exclusion
      # constraint reads, so this is also what says the constraint and the
      # membership query mean the same thing.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      Enum.each(@matrix, fn {label, offsets, expected} ->
        entry_id = write_raw_entry(room, engagement, offsets)

        assert overlap_via_ecto(room, entry_id) == expected, "ecto disagreed: #{label}"
        assert overlap_via_postgres(entry_id) == expected, "postgres disagreed: #{label}"

        Repo.query!("DELETE FROM roster_entries WHERE id = $1", [uuid(entry_id)])
      end)
    end

    test "contains at least one overlapping and one non-overlapping case" do
      # The matrix's own control: a predicate answering `false` everywhere, or
      # `true` everywhere, would pass a matrix that was all one way.
      answers = Enum.map(@matrix, fn {_label, _offsets, expected} -> expected end)

      assert true in answers
      assert false in answers
    end

    test "agrees with active_at/2 on containment at both boundaries" do
      # Containment is overlap against a point interval, which is why one
      # convention has to hold across all four intervals in this schema.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)
      entry = roster_entry_fixture(employer, room, engagement.id)

      assert rostered_at?(entry, entry.joined_at)
      refute rostered_at?(entry, DateTime.add(entry.joined_at, -@a_second, :second))

      assert active_at?(engagement, engagement.starts_at)
      refute active_at?(engagement, engagement.ends_at)

      assert open_at?(room, room.starts_at)
      refute open_at?(room, room.closes_at)
    end
  end

  ## Helpers

  defp engaged do
    {employer, _creation} = scoped_venue_fixture(@now)
    engaged_at(employer) |> Map.put(:employer, employer)
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
    shift_type = shift_type_fixture(employer, @grace_minutes)
    shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)
  end

  defp members(person, venue_id) do
    {:ok, members} = Rooms.list_venue_room_members(person, venue_id)
    members
  end

  defp ids(engagements), do: Enum.map(engagements, & &1.id)

  defp anonymous_person_scope, do: PersonScope.for_person(nil, @now)

  # Scopes handed out of a map so that their type at the call site is the union
  # of every kind rather than the one kind the compiler can prove has no
  # matching clause. Written inline, Elixir 1.20 proves the refusal at compile
  # time and warns at the call site — a good warning and a bad test, because a
  # scope built at run time from a session carries no such proof and it is the
  # run-time refusal the boundary rests on. `HospitalityComs.EngagementsTest`
  # and `HospitalityComs.VenuesTest` do the same thing for the same reason.
  defp scope_of(kind, scope) do
    Map.fetch!(%{anonymous: scope, grantless: scope, employer: scope}, kind)
  end

  defp executed_jobs do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM oban_jobs WHERE state NOT IN ('scheduled', 'available')")

    count
  end

  defp database_tables do
    %{rows: rows} =
      Repo.query!(
        "SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE n.nspname = 'public' AND c.relkind = 'r'"
      )

    Enum.map(rows, &hd/1)
  end

  # A roster entry written straight through SQL, so the matrix can place a
  # period anywhere — including the empty and already-closed shapes the context
  # would refuse to write on purpose.
  defp write_raw_entry(room, engagement, {lower, upper}) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO roster_entries
        (id, venue_id, shift_room_id, engagement_id, joined_at, left_at,
         delete_after, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $8, $7, $7)
      """,
      [
        uuid(id),
        uuid(room.venue_id),
        uuid(room.id),
        uuid(engagement.id),
        offset_instant(lower),
        offset_instant(upper),
        DateTime.truncate(@now, :second),
        # U10's stamped retention deadline. The column is `NOT NULL`, so a raw
        # insert has to carry what `RosterEntry.join_changeset/3` would have
        # stamped from the room.
        Lifecycle.history_deadline(room.closes_at)
      ]
    )

    id
  end

  # A message written straight through SQL, so a test can aim `venue_id`,
  # `shift_room_id` and `author_engagement_id` at three different venues and
  # find out which tier answers. No context call can build these rows.
  defp write_raw_message(venue_id, shift_room_id, author_engagement_id) do
    Repo.query!(
      """
      INSERT INTO room_messages
        (id, venue_id, shift_room_id, author_engagement_id, body, sent_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'raw', $5, $5, $5)
      """,
      [
        uuid(Ecto.UUID.generate()),
        uuid(venue_id),
        uuid(shift_room_id),
        uuid(author_engagement_id),
        DateTime.truncate(@now, :second)
      ]
    )
  end

  defp offset_instant(nil), do: nil

  defp offset_instant(minutes),
    do: DateTime.truncate(DateTime.add(@shift_starts, minutes, :minute), :second)

  defp uuid(id), do: Ecto.UUID.dump!(id)

  defp overlap_via_ecto(room, entry_id) do
    Records.roster()
    |> Records.of_room(room.id)
    |> Records.overlapping_open_interval()
    |> where([entry: entry], entry.id == ^entry_id)
    |> Repo.exists?()
  end

  defp overlap_via_postgres(entry_id) do
    %{rows: [[overlaps?]]} =
      Repo.query!(
        """
        SELECT entry.period && room.open_period
        FROM roster_entries entry
        JOIN shift_rooms room ON room.id = entry.shift_room_id
        WHERE entry.id = $1
        """,
        [uuid(entry_id)]
      )

    overlaps?
  end

  defp rostered_at?(entry, instant) do
    Records.roster()
    |> Records.rostered_at(instant)
    |> where([entry: candidate], candidate.id == ^entry.id)
    |> Repo.exists?()
  end

  defp active_at?(engagement, instant) do
    Engagement
    |> EngagementRecords.active_at(instant)
    |> where([candidate], candidate.id == ^engagement.id)
    |> Repo.exists?()
  end

  defp open_at?(room, instant) do
    Records.rooms() |> Records.room(room.id) |> Records.open_at(instant) |> Repo.exists?()
  end
end
