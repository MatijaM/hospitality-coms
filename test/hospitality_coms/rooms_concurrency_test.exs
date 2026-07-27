defmodule HospitalityComs.RoomsConcurrencyTest do
  @moduledoc """
  The three races U6 adds, and the claims two moduledocs made about them.

  ## Two check-then-write pairs whose safe half is a constraint

  `HospitalityComs.Rosters.add_to_roster/3` asks `unrostered/3` and then
  inserts; `HospitalityComs.Rooms.suspend_venue_room/2` asks `unsuspended/2` and
  then inserts. Both checks are the *friendly* half — they exist so the ordinary
  caller gets `:already_rostered` or `:already_suspended` rather than a
  constraint message — and both moduledocs say the *safe* half is the exclusion
  constraint underneath, which arrives as a changeset error because the schema
  declares it by name.

  Nothing tested that. Run sequentially the friendly check answers every time
  and the constraint is never reached from these paths, so the claim was a
  sentence rather than a behaviour.

  ## Two concurrent removals

  `remove_from_roster/3` read an open entry and then wrote `left_at`. Two
  managers removing the same person at two instants both read the same open row,
  both wrote, and the later *commit* won — which is neither the earlier removal
  nor the later one, it is whichever transaction the scheduler finished second.
  A roster period's upper bound moved backwards and both callers were told
  `{:ok, …}`.

  ## Why this file does not use the sandbox

  A race needs two connections in two transactions that can see each other's
  commits, and the sandbox gives every process one shared connection inside one
  rolled-back transaction — which serialises exactly the thing under test. See
  `HospitalityComs.EngagementsFixtures`: every process here checks out real
  connections and the rows are purged on a name prefix before and after each
  test.

  ## Why the races are deterministic, and why two of them have one racer

  Postgres supplies the barrier, as it does in
  `HospitalityComs.EngagementsConcurrencyTest`, and it supplies a different one
  for each shape.

  The removal racers both issue an `UPDATE`, so a third connection holding the
  row under `FOR UPDATE` parks them both. Two real callers, released together,
  and the one that loses the row lock waits for the other rather than deadlocking
  with it.

  The two insert paths cannot be tested that way, and the reason is worth
  writing down because it is a property of `EXCLUDE` rather than of this code.
  They take no lock on any row that exists — their reads are plain `SELECT`s,
  which no row lock blocks — so the only thing that parks them is the exclusion
  constraint itself, and an `EXCLUDE` conflict between two *uncommitted*
  inserts is a deadlock rather than a violation: each backend inserts its index
  tuple, then finds the other's and waits on that transaction. Measured, with
  two real racers released together onto one constraint: `40P01
  deadlock_detected`, one backend aborted, no changeset anywhere. That is
  inherent — `engagements_no_overlap` has had the same property since U5 — and
  it is not the race the moduledocs describe.

  The race they describe is two managers who both saw no open entry and then
  wrote, which does not require the two writes to be simultaneous to the
  microsecond. So the barrier holds `LOCK TABLE … IN SHARE MODE`: it is
  compatible with the racer's reads and conflicts with its `INSERT`, so the
  caller under test passes its friendly check against an empty table and parks
  before writing. The test then asserts, while it is parked, that nothing is
  rostered — which is what says the check *did* pass — commits the other
  manager's row from the barrier's own connection, and lets the parked caller
  meet a committed conflict. What comes back is the changeset error the
  moduledoc promises, deterministically, on every run.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import HospitalityComs.EngagementsFixtures
  import HospitalityComs.RoomsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.VenueRoomSuspension
  alias HospitalityComs.Rosters
  alias HospitalityComs.Rosters.RosterEntry

  @now ~U[2026-03-01 12:00:00.000000Z]

  @shift_starts DateTime.add(@now, 1, :hour)
  @shift_ends DateTime.add(@now, 9, :hour)

  @an_hour_on DateTime.add(@now, 1, :hour)
  @two_hours_on DateTime.add(@now, 2, :hour)

  @barrier_timeout 5_000

  setup do
    real_connections()
  end

  describe "a rostering whose check ran before another manager's write" do
    test "is refused by the constraint, as a changeset error rather than a raise" do
      # The claim `HospitalityComs.Rosters` makes and nothing tested. Not a bare
      # `{:error, _}` and not `:already_rostered`: the friendly check is
      # demonstrably not what refused this one, because the assertion inside the
      # barrier says the table was empty when the check ran.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      barrier = hold_share_lock("roster_entries")
      task = rosterer(employer, room, engagement)

      try do
        await_blocked(backend_pids(1))

        # It passed `unrostered/3` against an empty table and is parked on its
        # insert. Whatever refuses it now is not the check.
        assert entry_count(room.id, engagement.id) == 0
      after
        # The other manager's rostering, committed while this one is parked.
        commit_and_release(barrier, fn -> insert_entry(room, engagement) end)
      end

      assert {:error, changeset} = Task.await(task, @barrier_timeout)

      assert "overlaps a period this person already holds on this shift" in errors_on(changeset).period

      assert entry_count(room.id, engagement.id) == 1
    end

    test "is told apart from the sequential case, which the check answers" do
      # The control. Sequentially the second call never reaches the constraint,
      # so the assertion above would pass against an implementation whose only
      # guard is the friendly check — which is the guard that does not hold when
      # two managers ask at once.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)

      assert {:ok, %RosterEntry{}} = Rosters.add_to_roster(employer, room.id, engagement.id)

      assert {:error, :already_rostered} =
               Rosters.add_to_roster(employer, room.id, engagement.id)
    end
  end

  describe "a suspension whose check ran before another session's write" do
    test "is refused by the constraint, as a changeset error rather than a raise" do
      # The same shape on the person's side of the boundary, and the reason
      # `HospitalityComs.Rooms.suspend_venue_room/2` says the exclusion
      # constraint is what makes `unsuspended/2` safe. Two open rows would leave
      # resuming closing one of them, so the person stays out of the room with
      # nothing to show why.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      barrier = hold_share_lock("venue_room_suspensions")
      task = suspender(person, employer.venue_id)

      try do
        await_blocked(backend_pids(1))

        assert suspension_count(engagement.id) == 0
      after
        commit_and_release(barrier, fn -> insert_suspension(engagement) end)
      end

      assert {:error, changeset} = Task.await(task, @barrier_timeout)

      assert "overlaps a suspension this engagement already holds" in errors_on(changeset).period

      assert suspension_count(engagement.id) == 1
    end

    test "is told apart from the sequential case, which the check answers" do
      %{employer: employer, person: person} = engaged()

      assert {:ok, %VenueRoomSuspension{}} = Rooms.suspend_venue_room(person, employer.venue_id)
      assert {:error, :already_suspended} = Rooms.suspend_venue_room(person, employer.venue_id)
    end
  end

  describe "two concurrent removals from one roster" do
    test "close the period once and refuse the second" do
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      results = race_removals(employer, room, engagement)

      assert Enum.count(results, &match?({:ok, %RosterEntry{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :not_rostered})) == 1
    end

    test "leave the upper bound the winner wrote, and nothing earlier" do
      # The property rather than the error tuple, and the failure it names: both
      # removals used to succeed and the row ended up carrying whichever
      # `left_at` committed last. That is not the earlier removal and not the
      # later one — it is the slower transaction — so a period's upper bound
      # moved backwards while both callers were told the removal had happened.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)
      entry = roster_entry_fixture(employer, room, engagement.id)

      results = race_removals(employer, room, engagement)

      assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, %RosterEntry{}}, &1))
      assert Repo.get!(RosterEntry, entry.id).left_at == winner.left_at
      assert winner.left_at in [@an_hour_on, @two_hours_on]
    end

    test "are a real race, not two calls that happened to be sequential" do
      # The control. Run one after the other the second correctly finds no open
      # period and refuses, so every assertion above passes against an
      # implementation that reads the entry and then writes it.
      %{employer: employer, engagement: engagement} = engaged()
      room = shift_room(employer)
      entry = roster_entry_fixture(employer, room, engagement.id)

      barrier = hold_row("roster_entries", entry.id)

      tasks = [
        remover(employer, @an_hour_on, room, engagement),
        remover(employer, @two_hours_on, room, engagement)
      ]

      try do
        await_blocked(backend_pids(2))

        # Both have read the same open entry and neither has closed it.
        assert Repo.get!(RosterEntry, entry.id).left_at == nil
      after
        release(barrier)
      end

      results = Task.await_many(tasks, @barrier_timeout)

      assert Enum.count(results, &(&1 == {:error, :not_rostered})) == 1
    end
  end

  ## Racing

  # `build` is a function rather than a list for the reason
  # `HospitalityComs.EngagementsConcurrencyTest` measured: `Task.async/1` starts
  # the process the moment it is called, so racers built at the call site are
  # already running while the barrier is still being acquired.
  defp race(barrier, build) when is_function(build, 0) do
    tasks = build.()

    try do
      await_blocked(backend_pids(length(tasks)))
    after
      release(barrier)
    end

    Task.await_many(tasks, @barrier_timeout)
  end

  defp race_removals(employer, room, engagement) do
    barrier = hold_row("roster_entries", open_entry_id(room, engagement))

    race(barrier, fn ->
      [
        remover(employer, @an_hour_on, room, engagement),
        remover(employer, @two_hours_on, room, engagement)
      ]
    end)
  end

  # Rostering runs as `employer_role`, so the backend to watch is
  # `EmployerRepo`'s. Watching the wrong one makes `await_blocked/1` time out
  # rather than pass, which is the failure mode worth having.
  defp rosterer(employer, room, engagement) do
    detached(EmployerRepo, fn -> Rosters.add_to_roster(employer, room.id, engagement.id) end)
  end

  defp remover(employer, instant, room, engagement) do
    scope = employer_at(employer, instant)

    detached(EmployerRepo, fn -> Rosters.remove_from_roster(scope, room.id, engagement.id) end)
  end

  # Suspending runs as the application's own role — it writes a person-zone
  # table — so the backend to watch is `Repo`'s.
  defp suspender(person, venue_id) do
    detached(Repo, fn -> Rooms.suspend_venue_room(person, venue_id) end)
  end

  defp detached(repo, fun) do
    test = self()

    Task.async(fn ->
      Sandbox.checkout(Repo, sandbox: false)
      Sandbox.checkout(EmployerRepo, sandbox: false)

      try do
        send(test, {:backend, backend_pid(repo)})
        fun.()
      after
        Sandbox.checkin(EmployerRepo)
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp backend_pid(repo) do
    %{rows: [[pid]]} = repo.query!("SELECT pg_backend_pid()", [])
    pid
  end

  defp backend_pids(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:backend, pid}, @barrier_timeout
      pid
    end)
  end

  ## The two barriers

  # An exclusive lock on one committed row, held until released. What parks two
  # callers that both issue an `UPDATE` against it.
  defp hold_row(table, row_id) do
    hold(fn test ->
      Repo.transaction(fn ->
        Repo.query!("SELECT id FROM #{table} WHERE id = $1 FOR UPDATE", [uuid(row_id)])
        wait_for_release(test)
      end)
    end)
  end

  # A table lock that is compatible with `SELECT` and conflicts with `INSERT`,
  # so a caller under test passes its friendly check against the table as it
  # stands and then parks before writing. See the moduledoc for why the two
  # insert paths need this rather than a row lock.
  #
  # Its own connection may still write — a transaction never conflicts with
  # itself — which is what lets `commit_and_release/2` land the other
  # manager's row while the caller is parked on it.
  defp hold_share_lock(table) do
    hold(fn test ->
      Repo.transaction(fn ->
        Repo.query!("LOCK TABLE #{table} IN SHARE MODE")
        wait_for_release(test)
      end)
    end)
  end

  defp hold(fun) when is_function(fun, 1) do
    test = self()
    holder = Task.async(fn -> with_connections(fn -> fun.(test) end) end)

    assert_receive {:holding, _pid}, @barrier_timeout
    holder
  end

  defp wait_for_release(test) do
    send(test, {:holding, self()})
    receive do: ({:release, work} -> work.())
  end

  # Always in an `after`. A barrier that is never released leaves its holder
  # inside an open transaction for as long as the VM lives — ExUnit catches the
  # assertion error in the test process, so it exits `:normal`, nothing kills
  # the linked tasks, and the purge that follows blocks on the rows they hold.
  defp release(holder), do: commit_and_release(holder, fn -> :ok end)

  defp commit_and_release(%Task{pid: pid} = holder, work) when is_function(work, 0) do
    send(pid, {:release, work})
    Task.await(holder, @barrier_timeout)
  end

  # Named backends rather than a count: a count of blocked backends anywhere in
  # the database is satisfied by an unrelated waiter, and the callers then finish
  # one after another with the test still green — the same green tick an
  # implementation with no guard at all would produce.
  defp await_blocked(pids), do: await_blocked(pids, @barrier_timeout)

  defp await_blocked(pids, remaining) when remaining <= 0 do
    flunk("expected backends #{list(pids)} to be blocked, saw #{list(blocked(pids))}")
  end

  defp await_blocked(pids, remaining) do
    pids |> blocked() |> all_of?(pids) |> blocked_or_wait(pids, remaining)
  end

  defp all_of?(blocked, pids), do: MapSet.new(blocked) == MapSet.new(pids)

  defp blocked_or_wait(true, _pids, _remaining), do: :ok

  defp blocked_or_wait(false, pids, remaining) do
    Process.sleep(25)
    await_blocked(pids, remaining - 25)
  end

  defp blocked(pids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pid FROM pg_stat_activity
        WHERE datname = current_database()
          AND wait_event_type = 'Lock'
          AND pid = ANY($1::int[])
        """,
        [pids]
      )

    Enum.map(rows, &hd/1)
  end

  defp list(pids), do: Enum.map_join(pids, ", ", &to_string/1)

  ## The other party's write, raw

  # The winning manager's rostering, written straight through SQL from the
  # barrier's own connection. It is the row a second `add_to_roster/3` would
  # have committed, and writing it this way is what makes the outcome the same
  # on every run — see the moduledoc.
  defp insert_entry(room, engagement) do
    Repo.query!(
      """
      INSERT INTO roster_entries
        (id, venue_id, shift_room_id, engagement_id, joined_at, left_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, NULL, $5, $5)
      """,
      [
        uuid(Ecto.UUID.generate()),
        uuid(room.venue_id),
        uuid(room.id),
        uuid(engagement.id),
        DateTime.truncate(@now, :second)
      ]
    )
  end

  defp insert_suspension(engagement) do
    Repo.query!(
      """
      INSERT INTO venue_room_suspensions
        (id, engagement_id, suspended_at, resumed_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, NULL, $3, $3)
      """,
      [uuid(Ecto.UUID.generate()), uuid(engagement.id), DateTime.truncate(@now, :second)]
    )
  end

  ## Fixtures and reading, outside the contexts

  defp engaged do
    {employer, _creation} = scoped_venue_fixture(@now)
    person = person_scope_fixture(@now)

    engagement =
      engagement_fixture(employer, person, %{
        starts_at: @now,
        ends_at: DateTime.add(@now, 90, :day),
        code_expires_at: DateTime.add(@now, 7, :day)
      })

    %{employer: employer, person: person, engagement: engagement}
  end

  defp shift_room(employer) do
    shift_type = shift_type_fixture(employer, 30)
    shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)
  end

  defp open_entry_id(room, engagement) do
    Repo.one!(
      from entry in RosterEntry,
        where: entry.shift_room_id == ^room.id,
        where: entry.engagement_id == ^engagement.id,
        where: is_nil(entry.left_at),
        select: entry.id
    )
  end

  defp entry_count(room_id, engagement_id) do
    Repo.aggregate(
      from(entry in RosterEntry,
        where: entry.shift_room_id == ^room_id,
        where: entry.engagement_id == ^engagement_id
      ),
      :count
    )
  end

  defp suspension_count(engagement_id) do
    Repo.aggregate(
      from(suspension in VenueRoomSuspension, where: suspension.engagement_id == ^engagement_id),
      :count
    )
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  defp errors_on(changeset), do: HospitalityComs.DataCase.errors_on(changeset)
end
