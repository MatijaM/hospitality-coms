defmodule HospitalityComs.PeersConcurrencyTest do
  @moduledoc """
  The three races U8 adds, and the issue scenario that is only a race.

  ## "Simultaneous crossed requests resolve to one connection, not two"

  Run sequentially it is not a scenario at all: the second caller's friendly
  check sees the first caller's row and answers `:already_requested`. What the
  sentence is about is two people tapping at the same moment, both passing that
  check against a pair with no current row, and both writing — and the only
  thing that can refuse the second one then is the partial unique index
  `connection_requests_one_current_per_pair`.

  Every claim below is of that shape. The friendly check is what makes the
  ordinary caller's refusal legible; the constraint is what makes it true.

  ## Why this file does not use the sandbox

  A race needs two connections in two transactions that can see each other's
  commits, and the sandbox gives every process one shared connection inside one
  rolled-back transaction — which serialises exactly the thing under test. See
  `HospitalityComs.EngagementsFixtures`: every process here checks out real
  connections and the rows are purged on a name prefix before and after each
  test.

  ## Why the races are deterministic, and why they use two different barriers

  Postgres supplies the barrier, as it does in
  `HospitalityComs.EngagementsConcurrencyTest` and
  `HospitalityComs.RoomsConcurrencyTest`, and which one depends on what the
  racers do.

  The accept and disconnect races both issue a conditional `UPDATE` against a
  row that exists, so a third connection holding that row under `FOR UPDATE`
  parks them both. Released together, the one that loses the row lock waits for
  the other rather than deadlocking with it, and then matches zero rows.

  The crossed-request race has no row to lock — the pair has no current request,
  which is the whole point — so the barrier is `LOCK TABLE … IN SHARE MODE`,
  which is compatible with the racers' `SELECT`s and conflicts with their
  `INSERT`s. Both callers therefore pass their friendly check against a pair
  with nothing current and park before writing. The test asserts *while they are
  parked* that no request exists, which is what says the checks did pass, and
  then releases them onto one unique index.

  Unlike U6's insert races, this one can carry two real racers: a unique index
  makes the second inserter wait on the first transaction and then raises
  `unique_violation`, where an `EXCLUDE` constraint between two uncommitted
  inserts deadlocks instead. That difference is a property of the two index
  kinds rather than of this code, and it is why the barrier here does not have
  to commit the conflicting row itself.

  **Racers are built inside the barrier's closure**, for the reason
  `HospitalityComs.EngagementsConcurrencyTest` measured: `Task.async/1` starts
  the process the moment it is called, so a list built at the call site is
  already running while the barrier is still being acquired.
  """

  use ExUnit.Case, async: false

  import HospitalityComs.EngagementsFixtures
  import HospitalityComs.PeersFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Peers
  alias HospitalityComs.Peers.Connection
  alias HospitalityComs.Peers.ConnectionRequest
  alias HospitalityComs.Peers.Records
  alias HospitalityComs.Repo

  @now ~U[2026-03-01 12:00:00.000000Z]

  @barrier_timeout 5_000

  setup do
    real_connections()
  end

  describe "two crossed requests, sent at the same moment" do
    test "produce exactly one request row, and the loser is told a constraint refused it" do
      %{first: first, second: second} = co_rostered(@now)

      barrier = hold_share_lock("connection_requests")

      results =
        race(
          barrier,
          fn -> [requester(first, second), requester(second, first)] end,
          # Both callers are parked on their insert, and the pair has nothing
          # current — so whatever refuses one of them below is not the check.
          fn -> assert current_requests(first, second) == 0 end
        )

      assert Enum.count(results, &match?({:ok, %ConnectionRequest{}}, &1)) == 1

      assert [{:error, :request, changeset, _changes}] =
               Enum.reject(results, &match?({:ok, _request}, &1))

      assert "a request between these two is already outstanding" in errors_on(changeset).pair_low_id

      assert current_requests(first, second) == 1
    end

    test "resolve to one connection, not two" do
      # The issue's scenario in full. One request survived the race, so there is
      # exactly one thing to accept and exactly one connection it can make — and
      # the partial unique index on `peer_connections` is underneath that in any
      # case.
      %{first: first, second: second} = co_rostered(@now)

      barrier = hold_share_lock("connection_requests")

      race(
        barrier,
        fn -> [requester(first, second), requester(second, first)] end,
        fn -> assert current_requests(first, second) == 0 end
      )

      [request] = Repo.all(Records.current_request(first.person.id, second.person.id))
      acceptor = acceptor_of(request, first, second)

      assert {:ok, %Connection{}} = Peers.accept_request(acceptor, request.id)
      assert connection_count(first, second) == 1
    end

    test "are told apart from the sequential case, which the friendly check answers" do
      # The control. Run one after the other the second caller never reaches the
      # constraint, so the assertions above would pass against an implementation
      # whose only guard is the check — which is the guard that does not hold
      # when two people ask at once.
      %{first: first, second: second} = co_rostered(@now)

      assert {:ok, %ConnectionRequest{}} = Peers.request_connection(first, second.person.id)

      assert {:error, :permitted, :already_requested, _changes} =
               Peers.request_connection(second, first.person.id)

      assert current_requests(first, second) == 1
    end
  end

  describe "two concurrent accepts of one request" do
    test "make one connection and refuse the second with :not_found" do
      %{first: first, second: second} = co_rostered(@now)
      request = request_fixture(first, second)

      barrier = hold_row("connection_requests", request.id)

      results =
        race(
          barrier,
          fn -> [acceptor(second, request), acceptor(second, request)] end,
          fn -> assert connection_count(first, second) == 0 end
        )

      assert Enum.count(results, &match?({:ok, %Connection{}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :answer, :not_found, _changes}, &1)) == 1
      assert connection_count(first, second) == 1
    end

    test "are told apart from the sequential case (control)" do
      %{first: first, second: second} = co_rostered(@now)
      request = request_fixture(first, second)

      assert {:ok, %Connection{}} = Peers.accept_request(second, request.id)
      assert {:error, :answer, :not_found, _changes} = Peers.accept_request(second, request.id)
    end
  end

  describe "two concurrent disconnects of one conversation" do
    test "close it once and refuse the second with :already_disconnected" do
      # Before the conditional close, both parties read the same open row, both
      # wrote, and whichever transaction committed second decided when the
      # conversation ended — and both callers were told `{:ok, …}`.
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      barrier = hold_row("peer_connections", connection.id)

      results =
        race(
          barrier,
          fn -> [disconnector(first, connection), disconnector(second, connection)] end,
          fn -> assert live_connections(first, second) == 1 end
        )

      assert Enum.count(results, &match?({:ok, %Connection{}}, &1)) == 1

      assert Enum.count(
               results,
               &match?({:error, :close, :already_disconnected, _changes}, &1)
             ) == 1
    end

    test "hand back a struct the row agrees with, and block exactly one person" do
      # The failure this names: the winner's `disconnected_by_id` decides which
      # of the two may approach again (KTD19), so a losing caller handed an
      # `{:ok, …}` would be told they kept the initiative when they did not.
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      barrier = hold_row("peer_connections", connection.id)

      results =
        race(
          barrier,
          fn -> [disconnector(first, connection), disconnector(second, connection)] end,
          fn -> assert live_connections(first, second) == 1 end
        )

      assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, %Connection{}}, &1))

      stored = Repo.get!(Connection, connection.id)
      assert stored.disconnected_by_id == winner.disconnected_by_id
      assert stored.disconnected_at == winner.disconnected_at

      blocked = Repo.get!(ConnectionRequest, connection.request_id).blocked_initiator_id
      assert blocked == Connection.counterpart(stored, stored.disconnected_by_id)
    end

    test "are told apart from the sequential case (control)" do
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      assert {:ok, %Connection{}} = Peers.disconnect(first, connection.id)

      assert {:error, :close, :already_disconnected, _changes} =
               Peers.disconnect(second, connection.id)
    end
  end

  ## Racing

  # `build` is a function rather than a list for the reason
  # `HospitalityComs.EngagementsConcurrencyTest` measured: `Task.async/1` starts
  # the process the moment it is called, so racers built at the call site are
  # already running while the barrier is still being acquired.
  #
  # The assertion inside the `try` is what says the racers got past their
  # friendly checks: with the barrier held, neither has written anything.
  defp race(barrier, build, while_parked)
       when is_function(build, 0) and is_function(while_parked, 0) do
    tasks = build.()

    try do
      await_blocked(backend_pids(length(tasks)))
      while_parked.()
    after
      release(barrier)
    end

    Task.await_many(tasks, @barrier_timeout)
  end

  # Every racer here writes a person-zone table through `HospitalityComs.Repo`,
  # so that is the backend to watch. Watching the wrong one makes
  # `await_blocked/1` time out rather than pass, which is the failure mode worth
  # having.
  defp requester(requester, addressee) do
    detached(fn -> Peers.request_connection(requester, addressee.person.id) end)
  end

  defp acceptor(addressee, request) do
    detached(fn -> Peers.accept_request(addressee, request.id) end)
  end

  defp disconnector(person, connection) do
    detached(fn -> Peers.disconnect(person, connection.id) end)
  end

  defp detached(fun) do
    test = self()

    Task.async(fn ->
      Sandbox.checkout(Repo, sandbox: false)
      Sandbox.checkout(EmployerRepo, sandbox: false)

      try do
        send(test, {:backend, backend_pid()})
        fun.()
      after
        Sandbox.checkin(EmployerRepo)
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
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
  # callers that both issue a conditional `UPDATE` against it.
  defp hold_row(table, row_id) do
    hold(fn test ->
      Repo.transaction(fn ->
        Repo.query!("SELECT id FROM #{table} WHERE id = $1 FOR UPDATE", [uuid(row_id)])
        wait_for_release(test)
      end)
    end)
  end

  # A table lock compatible with `SELECT` and conflicting with `INSERT`, so a
  # caller under test passes its friendly check against the table as it stands
  # and then parks before writing. The crossed-request race needs this rather
  # than a row lock, because the row it would lock is the one neither caller has
  # written yet.
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
  defp release(%Task{pid: pid} = holder) do
    send(pid, {:release, fn -> :ok end})
    Task.await(holder, @barrier_timeout)
  end

  # Named backends rather than a count: a count of blocked backends anywhere in
  # the database is satisfied by an unrelated waiter, and the callers then
  # finish one after another with the test still green — the same green tick an
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

  ## Reading, outside the context

  defp current_requests(first, second) do
    first.person.id
    |> Records.current_request(second.person.id)
    |> Repo.aggregate(:count)
  end

  defp connection_count(first, second) do
    first.person.id
    |> Records.connection_between(second.person.id)
    |> Repo.aggregate(:count)
  end

  defp live_connections(first, second) do
    first.person.id
    |> Records.live_connection(second.person.id)
    |> Repo.aggregate(:count)
  end

  defp acceptor_of(%ConnectionRequest{addressee_id: id}, first, second) do
    Enum.find([first, second], &(&1.person.id == id))
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  defp errors_on(changeset), do: HospitalityComs.DataCase.errors_on(changeset)
end
