defmodule HospitalityComs.EngagementsConcurrencyTest do
  @moduledoc """
  The two races the exclusion constraint cannot see.

  R3's constraint is the obvious guard and it answers neither of the failures
  here, which is the reason this file exists rather than being folded into
  `HospitalityComs.EngagementsTest`.

  ## Two people redeem one claim code

  Their engagements would carry *different* `person_id`s, so the two rows do not
  conflict, the exclusion constraint stays silent, and both claims succeed —
  giving one invitation two members and the venue somebody it never invited.
  What answers it is the conditional consume as the **first** step of the
  claim's `Ecto.Multi`: one `UPDATE ... WHERE claimed_at IS NULL` that both
  racers aim at, where Postgres serialises them and the second matches nothing.

  ## Two managers renew one engagement

  A row does not conflict with itself, so the constraint is silent again. Both
  read the same `ends_at`, both write their own, and the later write wins with
  nothing raised anywhere — a lost update on the authorization root for
  everything that person can reach at the venue. `optimistic_lock/2` is what
  turns the loser into `{:error, :stale}` instead, and this file is what says
  the lock is load bearing rather than decorative.

  ## Why this file does not use the sandbox

  A race needs two connections in two transactions that can see each other's
  commits. The sandbox gives every process one shared connection inside one
  rolled-back transaction, which serialises exactly the thing under test. So
  every process here checks out a real connection and the rows are committed for
  real, then purged before and after each test on a name prefix no other test
  uses.

  ## Why the race is deterministic

  Postgres supplies the barrier, exactly as it does in
  `HospitalityComs.VenuesConcurrencyTest`. A third connection holds a row lock
  until both racers are parked on it, so neither can write until both have
  started — and each racer reports the Postgres backend it checked out before it
  begins, so the test waits on *those* backends rather than on any blocked
  backend. Waiting on a count instead is satisfied by an unrelated waiter, and
  the race then degrades into a sequential run that passes on an implementation
  with no guard at all.

  The barrier is released in an `after`. `await_blocked/1` flunks on a hard
  wall-clock budget, and a barrier that is never released leaves the holder
  inside an open transaction for as long as the VM lives: ExUnit catches the
  assertion error in the test process, so it exits `:normal`, nothing kills the
  linked tasks, and the purge that follows blocks on the rows they are still
  holding.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import HospitalityComs.EngagementsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Invitation
  alias HospitalityComs.Repo

  @now ~U[2026-03-01 12:00:00.000000Z]
  @in_a_month DateTime.add(@now, 30, :day)
  @in_two_months DateTime.add(@now, 60, :day)
  @in_three_months DateTime.add(@now, 90, :day)

  @barrier_timeout 5_000

  setup do
    real_connections()
  end

  describe "two people redeeming one claim code" do
    test "produce exactly one engagement" do
      {employer, %{venue: venue}} = scoped_venue_fixture(@now)
      %{invitation: invitation, claim_code: code} = invitation_fixture(employer)

      results = race_claims(invitation.id, code)

      assert Enum.count(results, &match?({:ok, %{engagement: %Engagement{}}}, &1)) == 1
      assert engagement_count(venue.id) == 1
    end

    test "leave the loser naming the step that refused it" do
      # Not a bare `{:error, _}`. The plan's requirement is that the loser fails
      # *cleanly with a step name*, because a race resolved three statements
      # later — at the unique index on `invitation_id` — would be a
      # `Postgrex.Error` about an index rather than an answer about a code.
      {employer, _creation} = scoped_venue_fixture(@now)
      %{invitation: invitation, claim_code: code} = invitation_fixture(employer)

      results = race_claims(invitation.id, code)

      assert Enum.count(results, &match?({:error, :consume, :already_claimed, _changes}, &1)) ==
               1
    end

    test "attach the one engagement to exactly one of the two claimants" do
      # The other half of "exactly one": the winner is a real person and the
      # loser holds nothing. A guard that wrote one engagement with a null or a
      # shared person would satisfy the count above.
      {employer, %{venue: venue}} = scoped_venue_fixture(@now)
      %{invitation: invitation, claim_code: code} = invitation_fixture(employer)

      first = person_scope_fixture(@now)
      second = person_scope_fixture(@now)

      race_claims(invitation.id, code, [first, second])

      holders = engagement_person_ids(venue.id)

      assert length(holders) == 1
      assert hd(holders) in [first.person.id, second.person.id]
    end

    test "are a real race, not two calls that happened to be sequential" do
      # The control both `HospitalityComs.VenuesConcurrencyTest` and this file
      # carry. Without a barrier the two claims can finish one after the other,
      # and every test above passes on an implementation that reads the
      # invitation and then writes it. This flunks unless both racers are
      # demonstrably parked on the same lock with neither having written.
      {employer, %{venue: venue}} = scoped_venue_fixture(@now)
      %{invitation: invitation, claim_code: code} = invitation_fixture(employer)

      holder = hold_row("invitations", invitation.id)

      tasks =
        Enum.map([person_scope_fixture(@now), person_scope_fixture(@now)], &claimer(&1, code))

      try do
        await_blocked(backend_pids(2))

        # Both are inside the consume and neither has written anything.
        assert engagement_count(venue.id) == 0
        assert Repo.get!(Invitation, invitation.id).claimed_at == nil
      after
        release(holder)
      end

      results = Task.await_many(tasks, @barrier_timeout)

      assert Enum.count(results, &match?({:error, :consume, :already_claimed, _changes}, &1)) ==
               1
    end
  end

  describe "two concurrent renewals" do
    test "do not silently discard one extension" do
      {employer, _creation} = scoped_venue_fixture(@now)
      engagement = engagement_fixture(employer, person_scope_fixture(@now), term())

      results = race_renewals(employer, engagement.id)

      assert Enum.count(results, &match?({:ok, %Engagement{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :stale})) == 1
    end

    test "leave the engagement carrying the extension that won, and only that one" do
      # The property, rather than the error tuple. Before `optimistic_lock/2`
      # both updates succeeded and the row ended up with whichever `ends_at`
      # committed last — which is not "the extension that won", it is "the
      # extension that was slower", and nothing anywhere said so.
      {employer, _creation} = scoped_venue_fixture(@now)
      engagement = engagement_fixture(employer, person_scope_fixture(@now), term())

      results = race_renewals(employer, engagement.id)

      [{:ok, winner}] = Enum.filter(results, &match?({:ok, %Engagement{}}, &1))
      reloaded = Repo.get!(Engagement, engagement.id)

      assert DateTime.compare(reloaded.ends_at, winner.ends_at) == :eq
      assert reloaded.lock_version == engagement.lock_version + 1
    end

    test "are a real race, not two calls that happened to be sequential" do
      # The control. Two sequential renewals both succeed and are both correct,
      # so without the barrier the assertions above pass on an implementation
      # with no optimistic lock at all.
      {employer, _creation} = scoped_venue_fixture(@now)
      engagement = engagement_fixture(employer, person_scope_fixture(@now), term())

      holder = hold_row("engagements", engagement.id)

      tasks = [
        renewer(employer, engagement.id, @in_two_months),
        renewer(employer, engagement.id, @in_three_months)
      ]

      try do
        await_blocked(backend_pids(2))

        # Both have read the same version and neither has written.
        assert Repo.get!(Engagement, engagement.id).lock_version == engagement.lock_version
      after
        release(holder)
      end

      results = Task.await_many(tasks, @barrier_timeout)

      assert Enum.count(results, &(&1 == {:error, :stale})) == 1
    end
  end

  ## Racing

  defp race_claims(invitation_id, code, scopes \\ nil) do
    race(invitation_id, "invitations", fn ->
      scopes = scopes || [person_scope_fixture(@now), person_scope_fixture(@now)]
      Enum.map(scopes, &claimer(&1, code))
    end)
  end

  defp race_renewals(employer, engagement_id) do
    race(engagement_id, "engagements", fn ->
      [
        renewer(employer, engagement_id, @in_two_months),
        renewer(employer, engagement_id, @in_three_months)
      ]
    end)
  end

  # `build` is a function rather than a list, and that is the whole of the
  # barrier's correctness. `Task.async/1` starts a process the moment it is
  # called, so a list of tasks built at the call site is a set of racers already
  # running while `hold_row/2` is still acquiring the lock they are supposed to
  # park on — a race between the racers and the barrier, which one of them wins
  # a few runs in ten. Measured: with the tasks built eagerly this file failed
  # roughly one run in three, always in `await_blocked/1` and always with one
  # backend idle having already committed.
  #
  # Deferring the build means nothing starts until the lock is held.
  # `HospitalityComs.VenuesConcurrencyTest` gets the same property from its
  # ordering rather than from a closure.
  defp race(row_id, table, build) when is_function(build, 0) do
    holder = hold_row(table, row_id)
    tasks = build.()

    try do
      await_blocked(backend_pids(length(tasks)))
    after
      release(holder)
    end

    Task.await_many(tasks, @barrier_timeout)
  end

  # The claim runs as the application's own role, so the backend to watch is
  # `Repo`'s.
  defp claimer(%PersonScope{} = scope, code) do
    detached(Repo, fn -> Engagements.claim_invitation(scope, code) end)
  end

  # Renewal runs as `employer_role`, so the backend to watch is
  # `EmployerRepo`'s. Watching the wrong one is how this file would silently
  # stop being a race: `await_blocked/1` would time out rather than pass, which
  # is the failure mode worth having.
  defp renewer(employer, engagement_id, ends_at) do
    detached(EmployerRepo, fn ->
      Engagements.renew_engagement(employer, engagement_id, ends_at)
    end)
  end

  # A task on its own real connections. It is not `allow`ed onto the test's,
  # because sharing one is the opposite of what this file needs. It reports the
  # Postgres backend it checked out before it starts work, so the barrier can
  # wait on this backend rather than on any backend that happens to be blocked.
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

  # `Sandbox.checkout/2` pins one connection to the calling process, so the
  # backend this names is the one that process's work will block on.
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

  # Holds an exclusive lock on one row until released, from a connection of its
  # own, so that both racers have reached the statement that needs it before
  # either can take it.
  defp hold_row(table, row_id) do
    test = self()

    holder =
      Task.async(fn -> with_connections(fn -> lock_until_released(table, row_id, test) end) end)

    assert_receive {:holding, _pid}, @barrier_timeout
    holder
  end

  defp lock_until_released(table, row_id, test) do
    Repo.transaction(fn ->
      Repo.query!("SELECT id FROM #{table} WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(row_id)])
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

  # Backend pids are small integers, which `inspect/1` renders as a charlist.
  defp list(pids), do: Enum.map_join(pids, ", ", &to_string/1)

  ## Reading, outside the context

  # A term long enough that both renewals are extensions of it.
  defp term, do: %{starts_at: @now, ends_at: @in_a_month}

  defp engagement_count(venue_id) do
    Repo.aggregate(from(e in Engagement, where: e.venue_id == ^venue_id), :count)
  end

  defp engagement_person_ids(venue_id) do
    Repo.all(from(e in Engagement, where: e.venue_id == ^venue_id, select: e.person_id))
  end
end
