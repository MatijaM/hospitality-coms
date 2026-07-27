defmodule HospitalityComs.BoundaryLifetimeTest do
  @moduledoc """
  How long the employer scope lives on a connection, asserted where the answer
  is the production one.

  `HospitalityComs.EmployerRepo.scoped_transaction/2` writes `app.employer_id`
  and `app.now` with `set_config(..., true)` — transaction-locally. The third
  argument is the whole of the guarantee. Written session-locally instead, the
  settings would outlive the transaction, outlive the request, and still be
  there when the pool hands the connection to the next employer's read. Nothing
  would error; the second employer would simply be reading as the first.

  ## Why this file is not sandboxed

  Inside the sandbox, `EmployerRepo`'s transaction is a savepoint within the
  test's own open transaction. A `SET LOCAL` reverts at the end of the
  transaction that contains it, and that is the sandbox's, not the wrapper's —
  so the setting survives a successful inner commit and the production lifetime
  is not reproduced. Asserting it there would either fail or be weakened until
  it passed, and the weakened version proves nothing.

  So every process here takes a real connection with `sandbox: false`. Nothing
  is written to a table; the only state touched is the connection's own
  settings, which are put back before the connection returns to the pool.

  ## Why the assertions are not vacuous

  "The setting is gone after the transaction" is also what a *different*
  connection looks like, and a pool hands out whichever one is free. Two
  controls close that off: the backend pid is asserted to be the same across
  the whole test, and a deliberately session-scoped setting written the same way
  is asserted to survive. If the second statement were landing somewhere else,
  the control would fail alongside the assertion instead of leaving it looking
  green.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.EmployerRepo

  @now ~U[2026-03-01 12:00:00.000000Z]
  @probe "app.lifetime_probe"

  setup do
    Sandbox.checkout(EmployerRepo, sandbox: false)
    :ok
  end

  test "the connection under test is one connection, which is what makes the rest meaningful" do
    assert backend_pid() == backend_pid()
  end

  test "a setting written session-locally survives the transaction that wrote it" do
    # The control. This is the failure mode `scoped_transaction/2` avoids, shown
    # working, so that the assertion below cannot pass by talking to a fresh
    # connection.
    #
    # Nothing here is sandboxed, so the probe is a real session setting on a
    # real pooled connection. Clearing it on the last line of the test would
    # clear it only when the test passes; on a failure the connection would go
    # back to the pool still carrying it, and the next thing to be handed that
    # connection would inherit a leaked setting from a test about leaked
    # settings.
    #
    # `after` rather than `on_exit`: the connection is checked out to this
    # process and `on_exit` runs in another one, which the ownership pool
    # refuses.
    pid_before = backend_pid()

    try do
      {:ok, :written} =
        EmployerRepo.transact(fn ->
          set_session(@probe, "leaked")
          {:ok, :written}
        end)

      assert backend_pid() == pid_before
      assert setting(@probe) == "leaked"
    after
      set_session(@probe, "")
    end
  end

  test "the employer scope does not survive the transaction that wrote it" do
    pid_before = backend_pid()
    scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

    {:ok, inside} =
      EmployerRepo.scoped_transaction(scope, fn _scope ->
        {:ok, setting("app.employer_id")}
      end)

    assert inside == scope.venue_id
    assert backend_pid() == pid_before

    # Not the previous employer's id. On a pooled connection that is the whole
    # difference between a boundary and a coin toss.
    refute setting("app.employer_id") == scope.venue_id
  end

  test "the scoping function raises on a connection that has already served an employer" do
    # `SET LOCAL` reverts a parameter to its prior value rather than undefining
    # it, so after one scoped transaction `app.employer_id` is defined and
    # empty — and `current_setting/1` no longer raises. This is the state every
    # pooled connection is in from the first employer request onward, and it is
    # the one where a scoping function written the obvious way would start
    # returning NULL and quietly filtering everything out.
    scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
    {:ok, :done} = EmployerRepo.scoped_transaction(scope, fn _scope -> {:ok, :done} end)

    assert setting("app.employer_id") == ""

    assert_raise Postgrex.Error, ~r/app\.employer_id is not set/, fn ->
      EmployerRepo.query!("SELECT app_current_employer_id()", [])
    end

    assert_raise Postgrex.Error, ~r/app\.now is not set/, fn ->
      EmployerRepo.query!("SELECT app_current_instant()", [])
    end
  end

  test "a second employer on the same connection reads its own scope, not the first's" do
    first = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
    second = EmployerScope.for_employer(Ecto.UUID.generate(), DateTime.add(@now, 1, :hour))

    {:ok, _} = EmployerRepo.scoped_transaction(first, fn _scope -> {:ok, :done} end)

    {:ok, {employer_id, instant}} =
      EmployerRepo.scoped_transaction(second, fn _scope ->
        {:ok, {setting("app.employer_id"), setting("app.now")}}
      end)

    assert employer_id == second.venue_id
    refute employer_id == first.venue_id
    assert {:ok, parsed, 0} = DateTime.from_iso8601(instant)
    assert DateTime.compare(parsed, second.now) == :eq
  end

  ## Helpers

  defp backend_pid do
    %{rows: [[pid]]} = EmployerRepo.query!("SELECT pg_backend_pid()", [])
    pid
  end

  defp setting(name) do
    %{rows: [[value]]} = EmployerRepo.query!("SELECT current_setting($1, true)", [name])
    value
  end

  defp set_session(name, value) do
    EmployerRepo.query!("SELECT set_config($1, $2, false)", [name, value])
    :ok
  end
end
