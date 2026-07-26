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

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Repo
  alias HospitalityComs.Repo.Migrations.GrantZones
  alias HospitalityComs.Zones

  @migration_name "grant_zones"

  @now ~U[2026-03-01 12:00:00.000000Z]

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
    repo_owner = Sandbox.start_owner!(Repo, shared: true)
    employer_owner = Sandbox.start_owner!(EmployerRepo, shared: true)

    on_exit(fn ->
      Sandbox.stop_owner(employer_owner)
      Sandbox.stop_owner(repo_owner)
    end)
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

  describe "the transaction wrapper" do
    test "writes the employer and the instant where the view will read them" do
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, {employer_id, instant}} =
               EmployerRepo.scoped_transaction(scope, fn _scope ->
                 %{rows: [[employer_id, instant]]} =
                   EmployerRepo.query!(
                     "SELECT app_current_employer_id()::text, app_current_instant()",
                     []
                   )

                 {:ok, {employer_id, instant}}
               end)

      assert employer_id == scope.employer_id
      assert DateTime.compare(instant, @now) == :eq
    end

    test "hands the scope to the work, so the instant travels rather than being read again" do
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, ^scope} = EmployerRepo.scoped_transaction(scope, &{:ok, &1})
    end

    test "lets a query the employer is entitled to run through" do
      # The control for everything below: a backstop that refused everything
      # would pass every refusal test in this file and ship a repo nobody can
      # use.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, [_relname | _rest]} =
               EmployerRepo.scoped_transaction(scope, fn _scope ->
                 {:ok, EmployerRepo.all(from(c in "pg_class", select: c.relname, limit: 3))}
               end)
    end
  end

  describe "an employer read outside the wrapper" do
    test "raises rather than running unscoped" do
      assert_raise EmployerRepo.UnscopedError, ~r/scoped_transaction/, fn ->
        EmployerRepo.all(from(c in "pg_class", select: c.relname, limit: 1))
      end
    end

    test "raises for a write too, not only for a read" do
      assert_raise EmployerRepo.UnscopedError, ~r/scoped_transaction/, fn ->
        EmployerRepo.insert_all("pg_class", [%{relname: "nope"}])
      end
    end

    test "raises even inside a bare transaction that set no scope" do
      assert_raise EmployerRepo.UnscopedError, ~r/scoped_transaction/, fn ->
        EmployerRepo.transaction(fn ->
          EmployerRepo.all(from(c in "pg_class", select: c.relname, limit: 1))
        end)
      end
    end

    test "leaves the scoping functions raising rather than resolving to NULL" do
      # A NULL here is the failure mode the one-argument `current_setting`
      # exists to prevent: the view would return no rows, and no rows is
      # indistinguishable from a worker who has disclosed nothing.
      assert_raise Postgrex.Error, ~r/app\.employer_id is not set/, fn ->
        EmployerRepo.query!("SELECT app_current_employer_id()", [])
      end

      assert_raise Postgrex.Error, ~r/app\.now is not set/, fn ->
        EmployerRepo.query!("SELECT app_current_instant()", [])
      end
    end
  end

  describe "the query backstop" do
    test "refuses a person-zone table named as the query's source" do
      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(from(p in Person, select: p.id))
      end
    end

    test "refuses one named as a string rather than as a schema" do
      assert_raise EmployerRepo.ZoneViolationError, ~r/people_tokens/, fn ->
        employer_query(from(t in "people_tokens", select: t.id))
      end
    end

    test "refuses one reached through an explicit join" do
      query = from(c in "pg_class", join: p in Person, on: true, select: p.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through an association join" do
      # The join's source is nil until the planner resolves it, so a backstop
      # reading `source` alone would wave this through.
      query = from(t in PersonToken, join: p in assoc(t, :person), select: p.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a subquery" do
      query = from(p in subquery(from(p in Person, select: %{id: p.id})), select: p.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a common table expression" do
      query =
        "pg_class"
        |> with_cte("hidden", as: ^from(p in Person, select: %{id: p.id}))
        |> select([c], c.relname)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a union" do
      query =
        from(p in Person, select: %{id: p.id})
        |> union(^from(t in PersonToken, select: %{id: t.id}))

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(from(c in "pg_class", select: %{id: c.oid}) |> union(^query))
      end
    end

    test "raises inside the BEAM rather than letting Postgres produce the error" do
      # The distinction the plan asks for. A `Postgrex.Error` would mean the
      # statement was sent and refused; this exception means it was never sent,
      # and the message names the table rather than the connection's role.
      error =
        assert_raise EmployerRepo.ZoneViolationError, fn ->
          employer_query(from(p in Person, select: p.id))
        end

      refute is_struct(error, Postgrex.Error)
      assert error.message =~ "person zone"
    end

    test "does not refuse the same query issued through the person zone's own repo" do
      # Which is what says the query is well formed and the refusal above is the
      # boundary rather than a typo.
      assert Repo.all(from(p in Person, select: p.id)) == []
    end
  end

  describe "a person-zone context function" do
    test "refuses an employer scope by function clause" do
      # Not a runtime check inside the body. The refusal is the absence of a
      # matching head, so it happens before the function runs and it happens
      # whether or not whoever wrote the function remembered to guard it.
      assert_raise FunctionClauseError, fn -> Accounts.sudo_mode?(scope(:employer)) end
    end

    test "accepts a person scope, including an anonymous one" do
      # Without this the test above passes on a function that refuses
      # everything, which is not the same guarantee at all.
      refute Accounts.sudo_mode?(scope(:person))
    end
  end

  ## Helpers

  # Runs a query the way the application will: inside the wrapper, so that what
  # refuses it is the zone rule and not the absence of a scope.
  defp employer_query(query) do
    scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
    EmployerRepo.scoped_transaction(scope, fn _scope -> {:ok, EmployerRepo.all(query)} end)
  end

  # Handed out of a map so the value's type is the union of both scopes rather
  # than one of them. Written inline, Elixir 1.20 proves at compile time that
  # `sudo_mode?/1` has no clause matching an employer scope and warns at the
  # call site — the guarantee holding a step earlier than this file can assert
  # it. That is a good warning and a bad test: a scope built at run time from a
  # session carries no such proof, and it is the run-time refusal that the
  # boundary rests on.
  defp scope(kind) do
    Map.fetch!(
      %{
        person: PersonScope.for_person(nil, @now),
        employer: EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      },
      kind
    )
  end

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
