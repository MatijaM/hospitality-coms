defmodule HospitalityComs.Accounts.PersonZoneTest do
  @moduledoc """
  No employer-side code path can create a person record (R1).

  There are two ways to be wrong about that and they need separate answers.

  The first is Postgres. `employer_role` holds no privilege on `people` or on
  `people_tokens`, so a statement issued through `EmployerRepo` is refused by
  the database rather than by an application check somebody can forget. That is
  asserted here against the privilege itself and against an actual attempted
  write. U3 adds the explicit `REVOKE` migration and the systematic sweep over
  every person-zone table; what this file pins is that the guarantee is already
  true for the tables this unit creates, so U3's migration is a statement of
  intent rather than the thing holding the door shut.

  Both tables are named, not just `people`. `people_tokens` holds the bearer
  credentials, so a role that could read it would not need to read `people` to
  become a worker — and U3 builds its sweep from the list this file
  establishes, so a table missing here is a table missing there.

  The second is us. A privilege only helps if person data goes through the repo
  the privilege applies to, so the Accounts context is checked — from compiled
  code, not from a grep — for any call into `EmployerRepo`. The modules that
  get checked are read out of the application's own module list, so U3 and U10
  are covered by this file without editing it.
  """

  # `EmployerRepo` needs its own sandbox owner and the compiled-code check reads
  # BEAM files, so neither half of this belongs in an async test.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Repo

  # The context's modules are read out of the application rather than listed,
  # so a module added by a later unit is covered the day it is compiled instead
  # of the day somebody remembers this file. `HospitalityComs.AccountsFixtures`
  # is a sibling, not a child, and the dotted prefix keeps it out.
  @accounts_prefix "Elixir.HospitalityComs.Accounts"
  @accounts_namespace @accounts_prefix <> "."

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

  describe "the employer role against people_tokens" do
    test "holds no INSERT privilege" do
      assert %{rows: [[false]]} =
               Repo.query!(
                 "SELECT has_table_privilege('employer_role', 'people_tokens', 'INSERT')",
                 []
               )
    end

    test "holds no SELECT privilege" do
      assert %{rows: [[false]]} =
               Repo.query!(
                 "SELECT has_table_privilege('employer_role', 'people_tokens', 'SELECT')",
                 []
               )
    end

    test "is refused by Postgres when it tries to mint a credential" do
      assert_raise Postgrex.Error, ~r/permission denied for table people_tokens/, fn ->
        EmployerRepo.query!(
          """
          INSERT INTO people_tokens (id, person_id, token, context, inserted_at)
          VALUES (gen_random_uuid(), gen_random_uuid(), $1, 'session', now())
          """,
          [:crypto.strong_rand_bytes(32)]
        )
      end
    end

    test "is refused by Postgres when it tries to read credentials" do
      assert_raise Postgrex.Error, ~r/permission denied for table people_tokens/, fn ->
        EmployerRepo.query!("SELECT token FROM people_tokens", [])
      end
    end
  end

  describe "the accounts context" do
    test "calls no repo but the person zone's own" do
      offenders =
        Enum.filter(accounts_modules(), fn module ->
          module |> called_modules() |> Enum.member?(EmployerRepo)
        end)

      assert offenders == []
    end

    test "actually reaches the repo it claims to" do
      # Guards the test above from passing because the module list came back
      # empty or the imports chunk stopped being readable.
      assert Repo in called_modules(Accounts)
    end

    test "sweeps the whole namespace rather than a list somebody maintains" do
      modules = accounts_modules()

      assert Accounts in modules
      assert Accounts.Person in modules
      assert Accounts.PersonToken in modules
      refute HospitalityComs.AccountsFixtures in modules
    end
  end

  defp accounts_modules do
    {:ok, modules} = :application.get_key(:hospitality_coms, :modules)
    Enum.filter(modules, &accounts_module?(Atom.to_string(&1)))
  end

  defp accounts_module?(@accounts_prefix), do: true
  defp accounts_module?(@accounts_namespace <> _rest), do: true
  defp accounts_module?(_name), do: false

  defp called_modules(module) do
    {:ok, {^module, [imports: imports]}} =
      module |> :code.which() |> :beam_lib.chunks([:imports])

    imports |> Enum.map(fn {called, _fun, _arity} -> called end) |> Enum.uniq()
  end
end
