defmodule HospitalityComs.AccountsConcurrencyTest do
  @moduledoc """
  Two requests arriving at once, which is what a double-clicked link and a
  mail client's link prefetcher both look like from the server.

  Neither race here is exotic. Both were reachable from the public API with no
  more than a second tab, and both produced the wrong answer: a magic link
  redeemed twice raised `Ecto.StaleEntryError` into a 500 instead of the
  promised 401, or — on the unconfirmed path — issued two sessions from one
  link; and a first-ever log-in that lost the insert race got a 422 saying the
  address "has already been taken", which is precisely the existence disclosure
  that merging register and log-in into one endpoint exists to prevent.

  ## Why this file does not use the sandbox

  A race needs two connections in two transactions that can see each other's
  commits. The sandbox gives every process one shared connection inside one
  rolled-back transaction, which serialises exactly the thing under test. So
  every process here checks out a real connection with `sandbox: false` and the
  rows are committed for real. They are deleted before and after each test,
  matched on a domain no other test uses, so a failure mid-test cannot leave a
  row behind for the rest of the suite to trip over.

  ## Why the races are deterministic

  Postgres supplies the barrier. A row lock held by a third connection makes
  both racers finish reading before either can write, and an uncommitted insert
  makes the second inserter of a unique key block rather than fail. Each racer
  reports the Postgres backend it checked out before it starts, and the test
  waits until it can see *those* backends parked in `pg_stat_activity` before
  releasing the barrier — not until it can see some number of blocked backends,
  which any unrelated waiter satisfies while the race quietly degrades into a
  sequential run that passes on code with no lock at all.

  The barrier is released in an `after`. `await_blocked/1` flunks on a hard
  wall-clock budget, and a barrier that is never released leaves the holder
  inside an open transaction holding its lock for as long as the VM lives:
  ExUnit catches the assertion error in the test process, so it exits `:normal`
  and nothing kills the linked tasks, and the purge that follows blocks on the
  rows they are still holding. The purge carries a `statement_timeout` for the
  same reason — the application's own role has none, so cleanup that cannot
  proceed has to fail rather than wait.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Repo

  @now ~U[2026-03-01 12:00:00.000000Z]
  @domain "concurrency.test"
  @barrier_timeout 5_000

  setup do
    Sandbox.checkout(Repo, sandbox: false)
    purge()
    on_exit(fn -> with_connection(&purge/0) end)
    :ok
  end

  describe "two redemptions of one magic link" do
    test "issue exactly one session to a person who has already confirmed" do
      person = confirmed_person()
      {encoded_token, token_id} = login_token(person)

      results =
        race(
          2,
          fn ->
            Accounts.login_person_by_magic_link(PersonScope.for_person(nil, @now), encoded_token)
          end,
          token_id
        )

      assert_one_winner(results)
    end

    test "issue exactly one session to a person confirming for the first time" do
      person = unconfirmed_person()
      {encoded_token, token_id} = login_token(person)

      results =
        race(
          2,
          fn ->
            Accounts.login_person_by_magic_link(PersonScope.for_person(nil, @now), encoded_token)
          end,
          token_id
        )

      assert_one_winner(results)
      assert %Person{confirmed_at: %DateTime{}} = Repo.get!(Person, person.id)
    end

    test "leave no live token behind either way" do
      person = confirmed_person()
      {encoded_token, token_id} = login_token(person)

      race(
        2,
        fn ->
          Accounts.login_person_by_magic_link(PersonScope.for_person(nil, @now), encoded_token)
        end,
        token_id
      )

      refute Accounts.get_person_by_magic_link_token(
               PersonScope.for_person(nil, @now),
               encoded_token
             )
    end
  end

  describe "a first-ever log-in that loses the insert race" do
    test "returns the person the winner created rather than a 422" do
      email = unique_email()
      winner = start_uncommitted_registration(email)

      task =
        detached(fn ->
          Accounts.request_login_instructions(
            PersonScope.for_person(nil, @now),
            email,
            url_builder()
          )
        end)

      try do
        await_blocked(backend_pids(1))
      after
        release(winner)
      end

      # A 422 here would say "has already been taken" to somebody who has never
      # used this application, which is the enumeration oracle the single
      # log-in door exists to close.
      assert {:ok, %Person{email: ^email}} = Task.await(task)
      assert Repo.aggregate(from(p in Person, where: p.email == ^email), :count) == 1
    end

    test "still refuses an address that is not an address" do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.request_login_instructions(
                 PersonScope.for_person(nil, @now),
                 "not an address",
                 url_builder()
               )
    end

    test "still refuses an address nobody could hold" do
      too_long = String.duplicate("a", 160) <> "@" <> @domain

      assert {:error, changeset} =
               Accounts.request_login_instructions(
                 PersonScope.for_person(nil, @now),
                 too_long,
                 url_builder()
               )

      assert [_message | _rest] = Keyword.get_values(changeset.errors, :email)
      assert Repo.aggregate(from(p in Person, where: p.email == ^too_long), :count) == 0
    end
  end

  ## Racing

  # Runs `fun` in `count` detached processes whose writes are all forced to
  # queue behind a lock on `token_id`, so every one of them has read the row
  # before any of them can claim it.
  defp race(count, fun, token_id) do
    holder = hold_row(token_id)
    tasks = Enum.map(1..count, fn _index -> detached(fun) end)

    try do
      await_blocked(backend_pids(count))
    after
      release(holder)
    end

    Task.await_many(tasks, @barrier_timeout)
  end

  defp assert_one_winner(results) do
    assert Enum.count(results, &match?({:ok, {%Person{}, _expired}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_found})) == 1
  end

  # A task on its own real connection. It is not `allow`ed onto the test's
  # connection, because sharing one is the opposite of what this file needs. It
  # reports the Postgres backend it checked out before it starts work, so the
  # barrier can wait on this backend rather than on any backend that happens to
  # be blocked.
  defp detached(fun) do
    test = self()

    Task.async(fn ->
      Sandbox.checkout(Repo, sandbox: false)

      try do
        send(test, {:backend, backend_pid()})
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  # `Sandbox.checkout/2` pins one connection to the calling process, so the
  # backend this names is the one that process's work will block on.
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

  # Holds an exclusive lock on the token row until released, from a connection
  # of its own.
  defp hold_row(token_id) do
    test = self()
    holder = Task.async(fn -> with_connection(fn -> lock_until_released(token_id, test) end) end)

    assert_receive {:holding, _pid}, @barrier_timeout
    holder
  end

  defp lock_until_released(token_id, test) do
    Repo.transaction(fn ->
      Repo.one!(from(t in PersonToken, where: t.id == ^token_id, lock: "FOR UPDATE"))
      hold(test)
    end)
  end

  # Opens a transaction that inserts `email` and does not commit, so the next
  # process to insert the same address blocks on the unique index.
  defp start_uncommitted_registration(email) do
    test = self()
    winner = Task.async(fn -> with_connection(fn -> insert_until_released(email, test) end) end)

    assert_receive {:holding, _pid}, @barrier_timeout
    winner
  end

  defp insert_until_released(email, test) do
    Repo.transaction(fn ->
      Repo.insert!(Ecto.Changeset.change(%Person{}, person_attrs(email)))
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
  # another with the test still green — which is the same green tick code with
  # no lock at all would produce.
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

  defp unique_email, do: "race#{System.unique_integer([:positive])}@#{@domain}"

  defp url_builder, do: &"http://localhost/log-in/#{&1}"

  # `display_name` is `NOT NULL` since #66 and these rows are written by a raw
  # changeset rather than by `Accounts.register_person/2`, which is where the
  # generator lives — so the fixture supplies one. Nothing in this file asserts
  # on it.
  defp person_attrs(email) do
    stamped_at = DateTime.truncate(@now, :second)

    %{
      email: email,
      display_name: "Captain Nemo",
      inserted_at: stamped_at,
      updated_at: stamped_at
    }
  end

  defp unconfirmed_person do
    Repo.insert!(Ecto.Changeset.change(%Person{}, person_attrs(unique_email())))
  end

  defp confirmed_person do
    unconfirmed_person()
    |> Ecto.Changeset.change(confirmed_at: DateTime.truncate(@now, :second))
    |> Repo.update!()
  end

  defp login_token(person) do
    {encoded_token, person_token} = PersonToken.build_email_token(person, "login", @now)
    %PersonToken{id: id} = Repo.insert!(person_token)
    {encoded_token, id}
  end

  ## Cleanup

  # Bounded rather than open-ended. `purge/0` runs through the application's own
  # role, which carries no `statement_timeout` of its own, so a row still held
  # by a task that outlived its test would make cleanup wait for the VM to die
  # rather than fail.
  @purge_timeout "10s"

  defp purge do
    {:ok, _deleted} = Repo.transaction(&purge_committed/0)
    :ok
  end

  defp purge_committed do
    Repo.query!("SET LOCAL statement_timeout = '#{@purge_timeout}'")
    Repo.delete_all(from(p in Person, where: like(p.email, ^"%@#{@domain}")))
  end

  defp with_connection(fun) do
    Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end
end
