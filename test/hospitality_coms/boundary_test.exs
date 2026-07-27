defmodule HospitalityComs.BoundaryTest do
  @moduledoc """
  The proof suite for the boundary the product's central claim rests on.

  Several things hold an employer session away from person data, and only one
  of them produces an error rather than a leak when it is violated: the
  Postgres grants. This file asserts that tier against `has_table_privilege`
  and `has_any_column_privilege` — the privilege bits themselves — rather than
  against an error response, because an error response is evidence that *this*
  query was refused and the privilege bit is evidence that every query is.

  ## What this suite does not claim

  It does not claim the grants are a tier *below* the BEAM guards, reachable
  only by somebody with a psql prompt. `EmployerRepo` logs in as the
  application's own role and assumes `employer_role` on connect, so one
  `RESET ROLE` over a raw `query/3` — which no guard sees — puts every
  privilege back. "the escapes neither guard closes" pins all three, so they
  are a decision on the record rather than a discovery somebody makes later.

  What the whole boundary is strong against is *accident*: a join added three
  units from now, a context function called from the wrong zone, a forgotten
  filter. It is not strong against a caller who means to get out, and no test
  here pretends otherwise.

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

  # Association shapes that do not exist in the application yet, declared at the
  # bottom of this file. See the comment there for why they are not in
  # `test/support`.
  alias __MODULE__.Venue

  @migration_name "grant_zones"

  @now ~U[2026-03-01 12:00:00.000000Z]

  @scoping_functions ["app_current_employer_id()", "app_current_instant()"]

  # The predicate U9's view will carry, written the way a view carries it.
  @employer_filter "app_current_employer_id()::text"

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

    test "are reported when the grant is on one column rather than on the table" do
      # The blind spot every other control in this block shares. Measured:
      #
      #   GRANT SELECT (email) ON people TO employer_role;
      #   has_table_privilege('employer_role','people','SELECT')      -> f
      #   has_any_column_privilege('employer_role','people','SELECT') -> t
      #
      # A sweep asking only the first question reported nothing while the
      # employer role could read every worker's address — and no control above
      # could fail on it, because they all grant at table level.
      Repo.query!("GRANT SELECT (email) ON people TO employer_role")

      assert {"people", "SELECT"} in Zones.employer_privileges(Repo)
    end

    test "are reported for a column grant on a write privilege too" do
      Repo.query!("GRANT UPDATE (email) ON people TO employer_role")

      offences = Zones.employer_privileges(Repo)

      assert {"people", "UPDATE"} in offences
      refute {"people", "SELECT"} in offences
    end

    test "cover MAINTAIN, which the sweep asks about and PostgreSQL 17 answers" do
      # The list the sweep asks about is the whole of what Postgres can grant on
      # a table, and MAINTAIN is part of that on 17. This is also where a
      # PostgreSQL older than 17 fails: `has_table_privilege` answers
      # `unrecognized privilege type` there rather than false.
      Repo.query!("GRANT MAINTAIN ON people TO employer_role")

      assert {"people", "MAINTAIN"} in Zones.employer_privileges(Repo)
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

    test "revoked the tables the classification calls the person zone today" do
      # The migration writes its table list out rather than reading `Zones`,
      # and that is right: a migration is a record of what was done to a
      # database on a given day, and wiring it to a module later units will
      # edit would make its behaviour change retroactively.
      #
      # Nothing said the two agreed, though, so a person-zone table added to
      # `Zones` without a REVOKE of its own would be caught only by the sweep,
      # and only once somebody granted something. This says it now.
      # Through `apply/3` because migration files are not compiled into the
      # application; `setup_all` is what puts this module in memory.
      revoked = apply(GrantZones, :person_zone_tables, [])

      assert Enum.sort(revoked) == Enum.sort(Zones.person_zone_tables())
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
      assert shared_dependencies(Zones.employer_role()) == 0
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

    test "refuses to open a second employer's scope inside the first" do
      # There is no savepoint between the two. Before this refusal existed the
      # inner `set_config` overwrote `app.employer_id` for the rest of the
      # shared transaction and nothing put it back, so the outer work carried on
      # reading as the inner employer.
      outer = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      inner = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert_raise EmployerRepo.NestedScopeError, ~r/already in force/, fn ->
        EmployerRepo.scoped_transaction(outer, fn _scope ->
          EmployerRepo.scoped_transaction(inner, fn _scope -> {:ok, :leaked} end)
        end)
      end
    end

    test "refuses before the second employer's scope reaches the connection" do
      # The refusal is only worth anything if it arrives first. This is the
      # assertion that would have caught the leak: after the nested call, the
      # connection still answers with the outer employer.
      outer = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      inner = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, resolved} =
               EmployerRepo.scoped_transaction(outer, fn _scope ->
                 assert_raise EmployerRepo.NestedScopeError, fn ->
                   EmployerRepo.scoped_transaction(inner, fn _scope -> {:ok, :leaked} end)
                 end

                 {:ok, current_employer_id()}
               end)

      assert resolved == outer.employer_id
      refute resolved == inner.employer_id
    end

    test "allows an identical scope to be entered again, writing nothing" do
      # The control for the refusal above: it must refuse a *conflict*, not
      # nesting. An identical scope would write the two settings that are
      # already there, so there is nothing to leak and nothing to refuse.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, {inner, after_inner}} =
               EmployerRepo.scoped_transaction(scope, fn _scope ->
                 {:ok, inner} =
                   EmployerRepo.scoped_transaction(scope, fn _scope ->
                     {:ok, current_employer_id()}
                   end)

                 {:ok, {inner, current_employer_id()}}
               end)

      assert inner == scope.employer_id
      assert after_inner == scope.employer_id
    end

    test "leaves nothing behind for the next caller after the refusal" do
      # The refusal must not strand the process dictionary in a state where the
      # unscoped guard waves the next operation through.
      outer = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      inner = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert_raise EmployerRepo.NestedScopeError, fn ->
        EmployerRepo.scoped_transaction(outer, fn _scope ->
          EmployerRepo.scoped_transaction(inner, fn _scope -> {:ok, :leaked} end)
        end)
      end

      assert_raise EmployerRepo.UnscopedError, fn ->
        EmployerRepo.all(from(c in "pg_class", select: c.relname, limit: 1))
      end
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

  describe "the shape the employer-visible view is built on" do
    # U9 owns the view itself. What it will filter on exists now, because the
    # guarantee is this unit's: an escaped read must raise rather than resolve
    # to NULL and return no rows, which is indistinguishable from a worker who
    # has disclosed nothing.
    test "a read outside the wrapper raises where there is anything to return" do
      unscoped = "SELECT c.relname FROM pg_class c WHERE c.oid::text = #{@employer_filter}"

      assert_raise Postgrex.Error, ~r/app\.employer_id is not set/, fn ->
        EmployerRepo.query!(unscoped, [])
      end
    end

    test "a read outside the wrapper that scans nothing returns nothing" do
      # The honest edge of the guarantee, pinned so U9 inherits it as a known
      # fact rather than as a surprise. Postgres evaluates the scoping function
      # per row, so a scan that yields none never calls it and the statement
      # succeeds — with an empty result, which is what a correctly scoped read
      # of the same nothing would also return. The failure mode the one-argument
      # `current_setting` exists to prevent is a *populated* relation filtered
      # down to nothing by a NULL, and that is the test above.
      empty = """
      SELECT t.x FROM (SELECT 1 AS x WHERE false) t WHERE t.x::text = #{@employer_filter}
      """

      assert %{rows: []} = EmployerRepo.query!(empty, [])
    end

    test "a read inside the wrapper resolves the scope's employer" do
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, [[resolved]]} =
               EmployerRepo.scoped_transaction(scope, fn _scope ->
                 %{rows: rows} =
                   EmployerRepo.query!("SELECT app_current_employer_id()::text", [])

                 {:ok, rows}
               end)

      assert resolved == scope.employer_id
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

    test "refuses one reached through a subquery in a where" do
      # Ecto does not put an expression subquery in the binding list. It parks
      # it on a `:subqueries` field of the `where` clause, which a walker
      # reading bindings alone never opens — measured: of eight shapes, only
      # from-position, CTE, union and association joins were refused.
      query =
        from(c in "pg_class",
          where: c.relname in subquery(from(p in Person, select: p.email)),
          select: c.relname
        )

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a subquery in a select" do
      query =
        from(c in "pg_class", select: %{n: subquery(from(p in Person, select: count(p.id)))})

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a subquery in a having" do
      query =
        from(c in "pg_class",
          group_by: c.relname,
          having: count(c.oid) > subquery(from(p in Person, select: count(p.id))),
          select: c.relname
        )

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a subquery in an order_by or a group_by" do
      ordered =
        from(c in "pg_class",
          order_by: [asc: subquery(from(p in Person, select: count(p.id)))],
          select: c.relname
        )

      grouped =
        from(c in "pg_class",
          group_by: subquery(from(p in Person, select: count(p.id))),
          select: c.relname
        )

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn -> employer_query(ordered) end
      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn -> employer_query(grouped) end
    end

    test "does not refuse an expression subquery that reaches nothing forbidden" do
      # The control for the four above. A walker that refused every query
      # carrying a `:subqueries` field would pass all of them.
      query =
        from(c in "pg_class",
          where: c.oid in subquery(from(n in "pg_namespace", select: n.oid)),
          select: c.relname,
          limit: 1
        )

      assert {:ok, _rows} = employer_query(query)
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

    test "does not see a write, which Postgres refuses instead" do
      # The documented hole, asserted rather than described. Ecto has no
      # insert-path hook that sees a table, so this statement is sent — and
      # refused by the grant tier, with a message about the connection's role
      # rather than about the zone. This is what it looks like when the only
      # tier that is a guarantee is the one doing the work.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      stamped_at = DateTime.truncate(@now, :second)

      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.scoped_transaction(scope, fn _scope ->
          {:ok,
           EmployerRepo.insert!(%Person{
             email: "smuggled@example.com",
             inserted_at: stamped_at,
             updated_at: stamped_at
           })}
        end)
      end
    end

    test "refuses one reached through a has_many :through" do
      # `Ecto.Association.HasThrough` carries no `:related` key at all, only a
      # chain of association names, so reading `.related` off it raised
      # `KeyError` from inside the backstop — closed, but saying nothing, and
      # closed for a legitimate join as much as for this one. The chain is
      # walked now, and every table it passes through is checked.
      query = from(v in Venue, join: p in assoc(v, :people), select: p.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "does not refuse a has_many :through that stays inside the employer zone" do
      # The control, and the regression the clause above would otherwise be:
      # before it, *every* `:through` join raised, whatever it reached.
      query = from(v in Venue, join: s in assoc(v, :shifts_through), select: s.id)

      assert {_query, _opts} = EmployerRepo.prepare_query(:all, query, [])
    end

    test "refuses one whose many_to_many join table is in the person zone" do
      # The related schema is innocent here. `join_through` is the table the
      # query actually reaches, and the backstop never looked at it.
      query = from(v in Venue, join: s in assoc(v, :smuggled_shifts), select: s.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people_tokens/, fn ->
        employer_query(query)
      end
    end

    test "does not refuse a many_to_many whose join table is not" do
      query = from(v in Venue, join: s in assoc(v, :shifts), select: s.id)

      assert {_query, _opts} = EmployerRepo.prepare_query(:all, query, [])
    end

    test "refuses an association join it cannot resolve rather than crashing on it" do
      # An unresolvable association is an association that cannot be placed in
      # a zone. The refusal names the field instead of raising `KeyError` from
      # somewhere in the walker.
      query = from(v in Venue, join: x in assoc(v, :nonexistent), select: x.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/is not an association/, fn ->
        employer_query(query)
      end
    end

    test "does not refuse the same query issued through the person zone's own repo" do
      # Which is what says the query is well formed and the refusal above is the
      # boundary rather than a typo.
      assert Repo.all(from(p in Person, select: p.id)) == []
    end
  end

  describe "the escapes neither guard closes" do
    # Pinned rather than described. A hole nobody asserts is a hole somebody
    # closes by accident and reopens by accident, and two of these are load
    # bearing: the wrapper is built on the first, and the third is the honest
    # limit of what the whole boundary claims.

    test "raw SQL outside the wrapper is not refused, and must not be" do
      # Ecto dispatches `query/3`, `query!/3`, `query_many/3` and `to_sql/3`
      # straight to `Ecto.Adapters.SQL` without consulting
      # `default_options/1`, so the unscoped guard never sees them.
      #
      # This is the exemption the wrapper comes in through: `write_settings/1`
      # is a raw query issued before the scope is registered, so a `query/3`
      # that went through the guard could never satisfy it. Closing this would
      # close the door.
      assert %{rows: [[1]]} = EmployerRepo.query!("SELECT 1", [])
    end

    test "raw SQL inside the wrapper skips the zone guard and is left to Postgres" do
      # `prepare_query/3` sees an `Ecto.Query`. A string is not one, so the
      # only thing between this statement and `people` is the grant.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.scoped_transaction(scope, fn _scope ->
          {:ok, EmployerRepo.query!("SELECT id FROM people", [])}
        end)
      end
    end

    test "RESET ROLE gives back every privilege the grants were withholding" do
      # The grant tier is one `SET ROLE` deep. Connections log in as the
      # application's own role and assume `employer_role` on connect, and
      # `GRANT employer_role TO CURRENT_USER` from U1 is what lets them — so
      # the login role is still there to go back to, and raw SQL is how you get
      # at it.
      #
      # This is not a tier below the BEAM guards. It is the same tier: code
      # that means to get out, gets out. What the boundary is strong against is
      # accident. Closing it needs `EmployerRepo` to log in as a role of its
      # own, which is infrastructure rather than code and is filed separately.
      #
      # The role is restored by the sandbox: `SET ROLE` is transactional, and
      # every connection here is inside a transaction that is rolled back.
      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.query!("SELECT count(*) FROM people", [])
      end

      EmployerRepo.query!("RESET ROLE", [])

      assert %{rows: [[_count]]} = EmployerRepo.query!("SELECT count(*) FROM people", [])

      EmployerRepo.query!("SET ROLE #{Zones.employer_role()}", [])

      # And back, on this connection, before it can be lent to anything else.
      # Without this the test above would leave an open door behind it and
      # every refusal in this file could start passing for the wrong reason.
      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.query!("SELECT count(*) FROM people", [])
      end
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

  # The employer the *connection* is scoped to, as the view will read it, which
  # is the only side of the wrapper that can leak.
  defp current_employer_id do
    %{rows: [[id]]} = EmployerRepo.query!("SELECT app_current_employer_id()::text", [])
    id
  end

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
                 ELSE has_function_privilege($2, to_regprocedure($1), 'EXECUTE')
               END
        """,
        [signature, Zones.employer_role()]
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

  ## The association shapes the backstop has to resolve

  # Ecto reflects `has_many :through` and `many_to_many` differently from
  # everything else, and neither shape exists in the application yet — U4's
  # roster and U5's bridge are where they arrive. They are declared here rather
  # than in `test/support` because `test/support` is compiled into the
  # application, which would put these in `Zones.all_schemas/0` and fail the
  # totality test with tables nobody ever migrated.
  #
  # None of these tables exists. Nothing here is queried; every assertion stops
  # inside `prepare_query/3`, which runs before Postgres is asked anything.

  defmodule Shift do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "shifts" do
    end
  end

  defmodule VenueShift do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "venue_shifts" do
      field(:venue_id, :binary_id)
      field(:shift_id, :binary_id)
    end
  end

  defmodule Engagement do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "engagements" do
      belongs_to(:venue, Venue, type: :binary_id)
      belongs_to(:person, Person, type: :binary_id)
      many_to_many(:shifts, Shift, join_through: VenueShift)
    end
  end

  defmodule Venue do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "venues" do
      has_many(:engagements, Engagement)

      # Reaches `people` through the bridge, which is the crossing the zone
      # rule exists to refuse.
      has_many(:people, through: [:engagements, :person])

      # Reaches nothing forbidden, and used to raise anyway.
      has_many(:shifts_through, through: [:engagements, :shifts])

      many_to_many(:shifts, Shift, join_through: VenueShift)

      # Innocent related schema, person-zone join table.
      many_to_many(:smuggled_shifts, Shift, join_through: "people_tokens")
    end
  end
end
