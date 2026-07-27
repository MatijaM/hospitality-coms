defmodule HospitalityComs.VenuesConcurrencyTest do
  @moduledoc """
  Two managers each standing down at the same moment, which is the one way an
  invariant enforced by "count, then decide, then write" produces a venue
  nobody can administer.

  Neither revocation is wrong on its own. Each reads two live grants, each
  correctly concludes it is not removing the last one, and together they remove
  both — and the failure is silent, because the last state anybody asserted was
  the correct one. `HospitalityComs.Venues.revoke_grant/2` takes the venue's
  live grants under `FOR UPDATE` before counting so that the count and the
  write are one decision; this file is what says that lock is load-bearing
  rather than decorative.

  ## Why each session revokes its own grant

  Because that is the shape that makes the loser's refusal the same whichever
  order Postgres picks. The acting grant is resolved from the locked set, so a
  session whose *own* grant a rival revoked first is refused `:no_grant` rather
  than `:last_grant_holder` — correctly, since its authority did not survive
  the wait. Two sessions each closing their own grant can never take each
  other's authority away, so the loser is always the one left holding the
  venue's last live grant, and the assertion can name the error rather than
  accepting either.

  ## Why this file does not use the sandbox

  A race needs two connections in two transactions that can see each other's
  commits. The sandbox gives every process one shared connection inside one
  rolled-back transaction, which serialises exactly the thing under test. So
  every process here checks out a real connection with `sandbox: false` and the
  rows are committed for real, then deleted before and after each test — matched
  on a venue-name prefix no other test uses, so a failure mid-test cannot leave
  rows behind for the rest of the suite to trip over.

  ## Why the race is deterministic

  Postgres supplies the barrier. A third connection holds a row lock on the
  venue's grants until both racers are parked on it, so neither can write until
  both have started. Each racer reports the Postgres backend it checked out
  before it starts, and the test waits until it can see *those* backends parked
  in `pg_stat_activity` before releasing — not until it can see some number of
  blocked backends, which any unrelated waiter satisfies while the race
  degrades into a sequential run that passes on an implementation with no lock
  at all.

  The barrier is released in an `after`. `await_blocked/1` flunks on a hard
  wall-clock budget, and a barrier that is never released leaves the holder
  inside an open transaction holding `FOR UPDATE` for as long as the VM lives:
  ExUnit catches the assertion error in the test process, so it exits `:normal`
  and nothing kills the linked tasks, and the purge that follows blocks on the
  rows they are still holding. The purge carries a `statement_timeout` for the
  same reason — the application's own role has none, so cleanup that cannot
  proceed has to fail rather than wait.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Repo
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Venues.Venue

  @now ~U[2026-03-01 12:00:00.000000Z]
  @name_prefix "race-venue"
  @barrier_timeout 5_000

  setup do
    Sandbox.checkout(Repo, sandbox: false)
    Sandbox.checkout(EmployerRepo, sandbox: false)
    purge()
    on_exit(fn -> with_connections(&purge/0) end)
    :ok
  end

  describe "two concurrent revocations of a venue's only two grants" do
    test "leave the venue with exactly one live grant" do
      {venue_id, sessions} = venue_with_two_grants()

      results = race(sessions, venue_id)

      assert Enum.count(results, &match?({:ok, %EmployerGrant{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :last_grant_holder})) == 1

      assert length(live_grants(venue_id)) == 1
    end

    test "leave a venue that is still administrable" do
      # The invariant stated as the thing it protects rather than as an error
      # tuple: whatever the interleaving, the surviving grant still authorises
      # a session.
      {venue_id, sessions} = venue_with_two_grants()

      race(sessions, venue_id)

      [survivor] = live_grants(venue_id)
      surviving_scope = EmployerScope.for_grant(venue_id, survivor.id, @now)

      assert {:ok, %Venue{}} = Venues.fetch_venue(surviving_scope)
    end

    test "are a real race, not two calls that happened to be sequential" do
      # The control. Without a barrier the two revocations can finish one after
      # the other, and the test above passes on an implementation with no lock
      # at all. `race/2` flunks if it cannot see both backends parked on the
      # lock, so this asserts that the barrier machinery is doing its job on
      # this database rather than silently degrading to a sequential run.
      {venue_id, sessions} = venue_with_two_grants()
      holder = hold_grants(venue_id)
      tasks = Enum.map(sessions, &revoker/1)

      try do
        await_blocked(backend_pids(2))

        # Both are inside `revoke_grant/2` and neither has written anything.
        assert length(live_grants(venue_id)) == 2
      after
        release(holder)
      end

      results = Task.await_many(tasks, @barrier_timeout)

      assert Enum.count(results, &(&1 == {:error, :last_grant_holder})) == 1
    end
  end

  ## Racing

  defp race(sessions, venue_id) do
    holder = hold_grants(venue_id)
    tasks = Enum.map(sessions, &revoker/1)

    try do
      await_blocked(backend_pids(length(tasks)))
    after
      release(holder)
    end

    Task.await_many(tasks, @barrier_timeout)
  end

  # One session standing down: the scope acts under the very grant it closes.
  defp revoker({scope, grant_id}) do
    detached(fn -> Venues.revoke_grant(scope, grant_id) end)
  end

  # A task on its own real connections. It is not `allow`ed onto the test's,
  # because sharing one is the opposite of what this file needs. It reports
  # the Postgres backend it checked out before it starts work, so the barrier
  # can wait on this backend rather than on any backend that happens to be
  # blocked.
  defp detached(fun) do
    test = self()

    Task.async(fn ->
      Sandbox.checkout(EmployerRepo, sandbox: false)

      try do
        send(test, {:backend, backend_pid()})
        fun.()
      after
        Sandbox.checkin(EmployerRepo)
      end
    end)
  end

  # `Sandbox.checkout/2` pins one connection to the calling process, so the
  # backend this names is the one that process's work will block on. Raw SQL
  # because `query/3` skips the unscoped guard, and there is no scope yet.
  defp backend_pid do
    %{rows: [[pid]]} = EmployerRepo.query!("SELECT pg_backend_pid()", [])
    pid
  end

  defp backend_pids(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:backend, pid}, @barrier_timeout
      pid
    end)
  end

  # Holds an exclusive lock on every grant of the venue until released, from a
  # connection of its own, so that both racers have entered `revoke_grant/2`
  # before either can take the lock it needs.
  defp hold_grants(venue_id) do
    test = self()
    holder = Task.async(fn -> with_connections(fn -> lock_until_released(venue_id, test) end) end)

    assert_receive {:holding, _pid}, @barrier_timeout
    holder
  end

  defp lock_until_released(venue_id, test) do
    Repo.transaction(fn ->
      Repo.all(
        from grant in EmployerGrant, where: grant.venue_id == ^venue_id, lock: "FOR UPDATE"
      )

      hold(test)
    end)
  end

  defp hold(test) do
    send(test, {:holding, self()})
    receive do: (:release -> :ok)
  end

  defp release(%Task{pid: pid} = holder) do
    send(pid, :release)
    Task.await(holder, @barrier_timeout)
  end

  # Waits until every one of `pids` is parked on a lock. Named backends rather
  # than a count: a count of blocked backends anywhere in the database is
  # satisfied by an unrelated waiter, and the racers then finish one after
  # another with the test still green — which is the same green tick an
  # implementation with no lock at all would produce.
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

  # Backend pids are small integers, which `inspect/1` renders as a charlist.
  defp list(pids), do: Enum.map_join(pids, ", ", &to_string/1)

  ## Fixtures, committed for real

  defp venue_with_two_grants do
    person = %Person{id: Ecto.UUID.generate(), email: "racer@example.com"}
    attrs = %{name: "#{@name_prefix}-#{System.unique_integer([:positive])}", timezone: "Etc/UTC"}

    {:ok, %{venue: venue, grant: founding}} =
      Venues.create_venue(PersonScope.for_person(person, @now), attrs)

    founding_scope = EmployerScope.for_grant(venue.id, founding.id, @now)
    {:ok, second} = Venues.issue_grant(founding_scope)
    second_scope = EmployerScope.for_grant(venue.id, second.id, @now)

    {venue.id, [{founding_scope, founding.id}, {second_scope, second.id}]}
  end

  # Read outside the context, because either grant may be the one the race
  # revoked and `Venues.list_grants/1` refuses a scope whose own grant is gone
  # — which is correct of it and useless here.
  defp live_grants(venue_id) do
    scope = EmployerScope.for_employer(venue_id, @now)

    {:ok, grants} =
      EmployerRepo.scoped_transaction(scope, fn _scope ->
        {:ok, EmployerRepo.all(EmployerGrant.live_at(venue_id, @now))}
      end)

    grants
  end

  ## Cleanup

  # Bounded rather than open-ended. `purge/0` runs through the application's
  # own role, which carries no `statement_timeout` of its own, so a row still
  # held by a task that outlived its test would make cleanup wait for the VM to
  # die rather than fail.
  @purge_timeout "10s"

  defp purge do
    {:ok, :purged} = Repo.transaction(&purge_committed/0)
    :ok
  end

  # Issued grants first: the lineage foreign key is `ON DELETE RESTRICT`, so a
  # single statement removing a founding grant alongside its descendants is
  # refused row by row rather than reconciled at the end of the statement.
  defp purge_committed do
    Repo.query!("SET LOCAL statement_timeout = '#{@purge_timeout}'")

    venue_ids =
      Repo.all(
        from venue in Venue, where: like(venue.name, ^"#{@name_prefix}%"), select: venue.id
      )

    Repo.delete_all(
      from grant in EmployerGrant,
        where: grant.venue_id in ^venue_ids and not is_nil(grant.granted_by_grant_id)
    )

    Repo.delete_all(from grant in EmployerGrant, where: grant.venue_id in ^venue_ids)
    Repo.delete_all(from venue in Venue, where: venue.id in ^venue_ids)

    :purged
  end

  defp with_connections(fun) do
    Sandbox.checkout(Repo, sandbox: false)
    Sandbox.checkout(EmployerRepo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(EmployerRepo)
      Sandbox.checkin(Repo)
    end
  end
end
