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
  makes the second inserter of a unique key block rather than fail. The test
  waits until it can see the racers blocked in `pg_stat_activity` before
  releasing the barrier, so the interleaving is forced rather than hoped for.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
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
        race(2, fn -> Accounts.login_person_by_magic_link(encoded_token, @now) end, token_id)

      assert_one_winner(results)
    end

    test "issue exactly one session to a person confirming for the first time" do
      person = unconfirmed_person()
      {encoded_token, token_id} = login_token(person)

      results =
        race(2, fn -> Accounts.login_person_by_magic_link(encoded_token, @now) end, token_id)

      assert_one_winner(results)
      assert %Person{confirmed_at: %DateTime{}} = Repo.get!(Person, person.id)
    end

    test "leave no live token behind either way" do
      person = confirmed_person()
      {encoded_token, token_id} = login_token(person)

      race(2, fn -> Accounts.login_person_by_magic_link(encoded_token, @now) end, token_id)

      refute Accounts.get_person_by_magic_link_token(encoded_token, @now)
    end
  end

  describe "a first-ever log-in that loses the insert race" do
    test "returns the person the winner created rather than a 422" do
      email = unique_email()
      winner = start_uncommitted_registration(email)

      task = detached(fn -> Accounts.request_login_instructions(email, url_builder(), @now) end)
      await_blocked(1)
      release(winner)

      # A 422 here would say "has already been taken" to somebody who has never
      # used this application, which is the enumeration oracle the single
      # log-in door exists to close.
      assert {:ok, %Person{email: ^email}} = Task.await(task)
      assert Repo.aggregate(from(p in Person, where: p.email == ^email), :count) == 1
    end

    test "still refuses an address that is not an address" do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.request_login_instructions("not an address", url_builder(), @now)
    end

    test "still refuses an address nobody could hold" do
      too_long = String.duplicate("a", 160) <> "@" <> @domain

      assert {:error, changeset} =
               Accounts.request_login_instructions(too_long, url_builder(), @now)

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

    await_blocked(count)
    release(holder)

    Task.await_many(tasks, @barrier_timeout)
  end

  defp assert_one_winner(results) do
    assert Enum.count(results, &match?({:ok, {%Person{}, _expired}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_found})) == 1
  end

  # A task on its own real connection. It is not `allow`ed onto the test's
  # connection, because sharing one is the opposite of what this file needs.
  defp detached(fun) do
    Task.async(fn ->
      Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  # Holds an exclusive lock on the token row until released, from a connection
  # of its own.
  defp hold_row(token_id) do
    test = self()

    holder =
      Task.async(fn ->
        with_connection(fn ->
          Repo.transaction(fn ->
            Repo.one!(from(t in PersonToken, where: t.id == ^token_id, lock: "FOR UPDATE"))
            send(test, {:holding, self()})
            receive do: (:release -> :ok)
          end)
        end)
      end)

    assert_receive {:holding, _pid}, @barrier_timeout
    holder
  end

  # Opens a transaction that inserts `email` and does not commit, so the next
  # process to insert the same address blocks on the unique index.
  defp start_uncommitted_registration(email) do
    test = self()

    Task.async(fn ->
      with_connection(fn ->
        Repo.transaction(fn ->
          Repo.insert!(Ecto.Changeset.change(%Person{}, person_attrs(email)))
          send(test, {:holding, self()})
          receive do: (:release -> :ok)
        end)
      end)
    end)
    |> tap(fn _task -> assert_receive {:holding, _pid}, @barrier_timeout end)
  end

  defp release(%Task{pid: pid} = holder) do
    send(pid, :release)
    Task.await(holder, @barrier_timeout)
  end

  # Waits until `count` backends are parked on a lock. Without this the racers
  # could finish one after another and the test would pass without ever having
  # raced.
  defp await_blocked(count), do: await_blocked(count, @barrier_timeout)

  defp await_blocked(count, remaining) when remaining <= 0 do
    flunk("expected #{count} blocked backends, saw #{blocked_backends()}")
  end

  defp await_blocked(count, remaining) do
    blocked_or_wait(blocked_backends() >= count, count, remaining)
  end

  defp blocked_or_wait(true, _count, _remaining), do: :ok

  defp blocked_or_wait(false, count, remaining) do
    Process.sleep(25)
    await_blocked(count, remaining - 25)
  end

  defp blocked_backends do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database()
          AND wait_event_type = 'Lock'
          AND pid <> pg_backend_pid()
        """,
        []
      )

    count
  end

  ## Fixtures, committed for real

  defp unique_email, do: "race#{System.unique_integer([:positive])}@#{@domain}"

  defp url_builder, do: &"http://localhost/log-in/#{&1}"

  defp person_attrs(email) do
    stamped_at = DateTime.truncate(@now, :second)
    %{email: email, inserted_at: stamped_at, updated_at: stamped_at}
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

  defp purge do
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
