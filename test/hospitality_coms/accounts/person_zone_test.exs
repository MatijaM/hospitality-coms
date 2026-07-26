defmodule HospitalityComs.Accounts.PersonZoneTest do
  @moduledoc """
  No employer-side code path can create a person record (R1).

  There are two ways to be wrong about that and they need separate answers.

  The first is Postgres. `employer_role` holds no privilege on `people`, so a
  statement issued through `EmployerRepo` is refused by the database rather
  than by an application check somebody can forget. That is asserted here
  against the privilege itself and against an actual attempted write. U3 adds
  the explicit `REVOKE` migration and the systematic sweep over every
  person-zone table; what this file pins is that the guarantee is already true
  for the table this unit creates, so U3's migration is a statement of intent
  rather than the thing holding the door shut.

  The second is us. A privilege only helps if person data goes through the repo
  the privilege applies to, so the Accounts context is checked — from compiled
  code, not from a grep — for any call into `EmployerRepo`.
  """

  # `EmployerRepo` needs its own sandbox owner and the compiled-code check reads
  # BEAM files, so neither half of this belongs in an async test.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Repo

  @accounts_modules [
    HospitalityComs.Accounts,
    HospitalityComs.Accounts.Person,
    HospitalityComs.Accounts.PersonToken,
    HospitalityComs.Accounts.PersonNotifier,
    HospitalityComs.Accounts.Scope
  ]

  setup do
    repo_owner = Sandbox.start_owner!(Repo, shared: true)
    employer_owner = Sandbox.start_owner!(EmployerRepo, shared: true)

    on_exit(fn ->
      Sandbox.stop_owner(employer_owner)
      Sandbox.stop_owner(repo_owner)
    end)
  end

  describe "the employer role against people" do
    test "holds no INSERT privilege" do
      assert %{rows: [[false]]} =
               Repo.query!("SELECT has_table_privilege('employer_role', 'people', 'INSERT')", [])
    end

    test "holds no SELECT privilege" do
      assert %{rows: [[false]]} =
               Repo.query!("SELECT has_table_privilege('employer_role', 'people', 'SELECT')", [])
    end

    test "is refused by Postgres when it tries to create a person" do
      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.query!(
          "INSERT INTO people (id, email, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, now(), now())",
          ["smuggled@example.com"]
        )
      end
    end

    test "is refused by Postgres when it tries to read people" do
      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.query!("SELECT id FROM people", [])
      end
    end
  end

  describe "the accounts context" do
    test "calls no repo but the person zone's own" do
      offenders =
        Enum.filter(@accounts_modules, fn module ->
          module |> called_modules() |> Enum.member?(EmployerRepo)
        end)

      assert offenders == []
    end

    test "actually reaches the repo it claims to" do
      # Guards the test above from passing because the module list drifted out
      # of date or the imports chunk stopped being readable.
      assert Repo in called_modules(Accounts)
    end
  end

  defp called_modules(module) do
    {:ok, {^module, [imports: imports]}} =
      module |> :code.which() |> :beam_lib.chunks([:imports])

    imports |> Enum.map(fn {called, _fun, _arity} -> called end) |> Enum.uniq()
  end
end
