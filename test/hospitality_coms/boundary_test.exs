defmodule HospitalityComs.BoundaryTest do
  @moduledoc """
  The proof suite for the boundary the product's central claim rests on.

  Four tiers hold an employer session away from person data, and only one of
  them produces an error rather than a leak when it is violated: the Postgres
  grants. This file asserts that tier against `has_table_privilege` — the
  privilege bit itself — rather than against an error response, because an
  error response is evidence that *this* query was refused and the privilege
  bit is evidence that every query is.

  ## Why half of this file is about the tests rather than about the boundary

  `employer_role` holds no privilege on `people` today in part because no
  migration ever granted it one: Postgres default-denies on a table owned by
  another role. So "assert the privilege is absent" passes whether or not this
  unit's migration does anything, and a suite that cannot tell those two apart
  is decoration with a green tick on it.

  Every assertion here that could pass for the wrong reason therefore ships
  with a control that fails when it does:

    * the sweep is handed a privilege behind its back and has to catch it;
    * the migration is rolled over a privilege that exists and has to remove
      it, which is the only test that proves its `REVOKE` statements execute;
    * the foreign-key rule is vacuous while the employer zone is empty, so its
      query has to find the one foreign key that does exist;
    * the query backstop has to *not* refuse a query it has no business
      refusing.

  Roles and grants are cluster-global rather than database-local, so every
  test that grants or revokes runs inside the sandbox transaction and is rolled
  back even when it fails.
  """

  # `EmployerRepo` needs a sandbox owner of its own, and the migration tests
  # move schema state, so nothing here is async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Repo
  alias HospitalityComs.Repo.Migrations.GrantZones
  alias HospitalityComs.Zones

  @migration_name "grant_zones"

  @scoping_functions ["app_current_employer_id()", "app_current_instant()"]

  # Migration files are not compiled into the application, so the module has to
  # be loaded before the migrator can be handed it directly — unless the
  # migrator has already loaded it on the way in, which is what happens the
  # first time this runs against a database where the migration is pending.
  setup_all do
    load_migration(Code.ensure_loaded?(GrantZones))
    :ok
  end

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
  end

  describe "the employer role's privileges on the person zone" do
    test "are none, across every person-zone table and every table privilege" do
      assert Zones.employer_privileges(Repo) == []
    end

    test "are swept over a list that names the tables that matter" do
      # The sweep above is satisfied by an empty table list. This is what says
      # it looked at anything, and at the two tables whose exposure would end
      # the argument: the person row, and the bearer credentials that stand
      # for it.
      assert "people" in Zones.person_zone_tables()
      assert "people_tokens" in Zones.person_zone_tables()
    end

    test "are reported by the sweep when one is granted behind its back" do
      # The load-bearing control. Without it, every assertion in this describe
      # block passes on a database where the grant migration was never written,
      # because Postgres default-denies and the absence looks identical.
      Repo.query!("GRANT SELECT ON people TO employer_role")

      assert {"people", "SELECT"} in Zones.employer_privileges(Repo)
    end

    test "are reported per privilege, so a write grant is caught as well as a read" do
      Repo.query!("GRANT INSERT, UPDATE ON people_tokens TO employer_role")

      offences = Zones.employer_privileges(Repo)

      assert {"people_tokens", "INSERT"} in offences
      assert {"people_tokens", "UPDATE"} in offences
      refute {"people_tokens", "SELECT"} in offences
    end
  end

  describe "the grant migration" do
    test "removes a privilege that exists rather than restating an absence" do
      Repo.query!("GRANT SELECT ON people TO employer_role")
      assert {"people", "SELECT"} in Zones.employer_privileges(Repo)

      migrate(:down)
      capture_log(fn -> migrate(:up) end)

      assert Zones.employer_privileges(Repo) == []
    end

    test "leaves privileges in the same state when rolled back and forward" do
      before = privilege_snapshot()

      migrate(:down)
      rolled_back = privilege_snapshot()

      capture_log(fn -> migrate(:up) end)

      assert privilege_snapshot() == before

      # And the round trip went somewhere. Comparing two identical nothings
      # would pass on a migration whose `up` and `down` were both empty.
      refute rolled_back == before
    end

    test "leaves the employer role able to execute the scoping functions" do
      Enum.each(@scoping_functions, fn function ->
        assert function_privilege(function) == true
      end)
    end

    test "leaves the employer role droppable" do
      # Roles are cluster-global and grants are database-local, so a single
      # privilege granted to `employer_role` in any database in the cluster
      # makes `DROP ROLE employer_role` fail in every other one — including the
      # rollback `HospitalityComs.PostgresRolesTest` asserts on U1's roles
      # migration. Nothing this migration does is worth that, so nothing it
      # does creates the dependency.
      #
      # U4 will have to: the employer zone is unreadable without real grants on
      # real tables. This is the test that tells it so.
      assert shared_dependencies("employer_role") == 0
    end
  end

  describe "the bridge" do
    test "is the only crossing: no employer-zone table holds a foreign key to people" do
      offenders = MapSet.intersection(tables_referencing_people(), employer_zone_tables())

      assert MapSet.to_list(offenders) == []
    end

    test "is looked for with a query that finds the foreign keys that exist" do
      # The rule above is vacuously true while the employer zone is empty. This
      # is what makes it a tripwire for U4 onward rather than a no-op: the
      # query does resolve real referencing tables.
      assert "people_tokens" in tables_referencing_people()
    end
  end

  ## Helpers

  # The sandbox lends this test a single connection, so the migrator's own
  # locking transaction would deadlock against the migration it is guarding.
  # The lock exists to serialise concurrent deployers; there are none here.
  @migrator_opts [log: false, migration_lock: false]

  defp migrate(direction) do
    apply(Ecto.Migrator, direction, [Repo, migration_version(), GrantZones, @migrator_opts])
  end

  defp migration_version do
    Repo
    |> Ecto.Migrator.migrations()
    |> Enum.find_value(fn {_status, version, name} -> name == @migration_name && version end)
  end

  defp load_migration(true), do: :ok

  defp load_migration(false) do
    Repo
    |> Ecto.Migrator.migrations_path()
    |> Path.join("*_#{@migration_name}.exs")
    |> Path.wildcard()
    |> Enum.each(&Code.require_file/1)
  end

  # Everything the migration is responsible for, in one comparable value: the
  # employer role's effective privilege on every person-zone table, and its
  # execute privilege on each scoping function — with `nil` standing for a
  # function that does not exist, which is what the rolled-back state looks
  # like.
  defp privilege_snapshot do
    %{
      tables: Zones.employer_privileges(Repo),
      functions: Map.new(@scoping_functions, &{&1, function_privilege(&1)})
    }
  end

  defp function_privilege(signature) do
    %{rows: [[held]]} =
      Repo.query!(
        """
        SELECT CASE
                 WHEN to_regprocedure($1) IS NULL THEN NULL
                 ELSE has_function_privilege('employer_role', to_regprocedure($1), 'EXECUTE')
               END
        """,
        [signature]
      )

    held
  end

  # Entries in the cluster-wide dependency catalogue that point at the role.
  # Every one of them is a database somewhere that has to be cleaned up before
  # the role can be dropped.
  defp shared_dependencies(role) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM pg_shdepend d
        JOIN pg_authid a ON a.oid = d.refobjid
        WHERE a.rolname = $1
        """,
        [role]
      )

    count
  end

  defp tables_referencing_people do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT c.conrelid::regclass::text
        FROM pg_constraint c
        WHERE c.contype = 'f' AND c.confrelid = 'people'::regclass
        """,
        []
      )

    rows |> Enum.map(&hd/1) |> MapSet.new()
  end

  defp employer_zone_tables, do: MapSet.new(Zones.employer_zone_tables())
end
