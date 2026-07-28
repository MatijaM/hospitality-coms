defmodule HospitalityComs.PostgresRolesTest do
  @moduledoc """
  The two Postgres roles are the only tier of the boundary whose violation
  produces an error rather than a leak, so the migration that creates them has
  to be reversible in fact and not just in intent.

  Roles are cluster-global rather than database-local. Every assertion here
  therefore runs inside the sandbox transaction, which rolls the roles back to
  their pre-test state even when an assertion fails.

  ## Why the grants migrations are rolled back first

  U4 gave `employer_role` real privileges on the employer zone and U5 gave it
  more, and a `GRANT` writes a row in `pg_shdepend`. `DROP ROLE` refuses while
  any of those rows exists, so from U4 onward the roles migration cannot be
  rolled back on its own — which is not a defect in it. Ecto rolls migrations
  back in reverse order, so the real sequence is U5's `down`, then U4's, then
  U1's, and that is the sequence asserted here.

  This list grows with every unit that grants something, and that is the point
  of asserting it rather than describing it: a unit that adds a grant migration
  and forgets to add it here finds out from this file rather than from a
  `dependent_objects_still_exist` in the middle of a production rollback.

  U8's `grant_peer_zone` is in the list and grants nothing — it only revokes, on
  three person-zone tables — so it writes no `pg_shdepend` row and rolling it
  back changes nothing here. It is listed anyway, because the rule is "every
  grant migration" and a list with a judgement call in it is a list somebody
  gets wrong later.

  U9's `grant_profile_zone` does grant, on three objects — and two of them are
  **views**, which is the first time the employer role has depended on anything
  that is not a table. `pg_shdepend` does not care about the distinction and
  neither does `DROP ROLE`, so the entry below is the whole of what this file
  needs; `HospitalityComs.BoundaryTest` is where the difference shows, because
  `pg_describe_object` says `view x` rather than `table x`.

  Rolling U1 back *without* rolling the grants back is not a scenario that has
  to work. What has to work is that U1's `down` removes the roles once nothing
  depends on them, and `rolled_back_grants/0` is what puts the database in that
  state.

  ## The cluster-wide caveat, made legible

  Because the dependency rows are cluster-global in effect, a *second* database
  on the same cluster that has run U4's grant migration makes `DROP ROLE` fail
  here too, and no connection to this database can revoke a privilege granted
  in that one. `assert_no_foreign_dependencies/0` checks for exactly that and
  names the databases, so the failure says "roll back or drop
  hospitality_coms_dev" rather than raising a `dependent_objects_still_exist`
  out of the middle of a migrator.
  """

  use HospitalityComs.DataCase, async: false

  import ExUnit.CaptureLog

  alias HospitalityComs.Repo.Migrations.CreateEmployerLoginRole
  alias HospitalityComs.Repo.Migrations.CreatePostgresRoles
  alias HospitalityComs.Repo.Migrations.GrantEmployerZone
  alias HospitalityComs.Repo.Migrations.GrantEngagementZone
  alias HospitalityComs.Repo.Migrations.GrantPeerZone
  alias HospitalityComs.Repo.Migrations.GrantProfileZone
  alias HospitalityComs.Repo.Migrations.GrantRetentionZone
  alias HospitalityComs.Repo.Migrations.GrantRoomZone

  @roles_migration "create_postgres_roles"
  @login_role "employer_login"
  @employer_grants_migration "grant_employer_zone"
  @engagement_grants_migration "grant_engagement_zone"
  @room_grants_migration "grant_room_zone"
  @peer_grants_migration "grant_peer_zone"
  @profile_grants_migration "grant_profile_zone"
  @retention_grants_migration "grant_retention_zone"
  @login_role_migration "create_employer_login_role"

  # In the order Ecto applies them, which is the reverse of the order
  # `rolled_back_grants/0` unwinds them in. Every unit that grants adds an
  # entry: a grant is a `pg_shdepend` row, roles are cluster-global while
  # grants are database-local, and one row anywhere makes `DROP ROLE` fail
  # everywhere.
  #
  # #17's `create_employer_login_role` is the last entry and it is here for a
  # different reason from the rest, measured rather than inferred. It grants a
  # *membership*, and a membership writes no `pg_shdepend` row — so it is not
  # what makes `DROP ROLE employer_role` fail, and the drop succeeds with it
  # applied. What it does instead is worse for being silent:
  #
  #   `DROP ROLE employer_role` removes `employer_login`'s membership without
  #   complaint, and re-applying the roles migration's `up` does not restore
  #   it. The re-created role is a fresh role with no members.
  #
  # So a roles migration rolled back underneath a live login role leaves a
  # credential that can no longer assume anything and an `EmployerRepo` that
  # cannot start. Listing it here is what keeps the unwind in an order where
  # that cannot happen; `"loses the login role's membership ..."` below pins the
  # property itself.
  @grant_migrations [
    {@employer_grants_migration, GrantEmployerZone},
    {@engagement_grants_migration, GrantEngagementZone},
    {@room_grants_migration, GrantRoomZone},
    {@peer_grants_migration, GrantPeerZone},
    {@profile_grants_migration, GrantProfileZone},
    {@retention_grants_migration, GrantRetentionZone},
    {@login_role_migration, CreateEmployerLoginRole}
  ]

  @migrations [{@roles_migration, CreatePostgresRoles} | @grant_migrations]

  # Migration files are not compiled into the application, so the modules have
  # to be loaded before the migrator can be handed them directly.
  setup_all do
    Enum.each(@migrations, fn {name, _module} ->
      Enum.each(migration_files(name), &Code.require_file/1)
    end)

    :ok
  end

  describe "the roles migration" do
    test "creates both roles when migrated up" do
      assert role_exists?("employer_role")
      assert role_exists?("person_role")
    end

    test "leaves no employer_role in pg_roles when migrated down" do
      rolled_back_grants()

      migrate(@roles_migration, :down)

      refute role_exists?("employer_role")
      refute role_exists?("person_role")

      # #17's login role comes off with the rest. It is dropped by its own
      # migration's `down`, which `rolled_back_grants/0` ran first — so the
      # property U1 tests for is unchanged by a third role having joined the
      # model: migrating up and then down leaves none of them behind.
      refute role_exists?(@login_role)
    end

    test "restores both roles when migrated down and up again" do
      rolled_back_grants()

      migrate(@roles_migration, :down)

      # Re-running a migration that later ones were stacked on top of makes the
      # migrator warn about out-of-order deployment. It is warning about a
      # rollback in production, not about this test, which puts the version
      # straight back where it found it.
      capture_log(fn -> migrate(@roles_migration, :up) end)

      assert role_exists?("employer_role")
      assert role_exists?("person_role")
    end

    test "loses the login role's membership when rolled back underneath it, and does not restore it" do
      # Issue #20's question, answered with the measurement that decides it.
      #
      # `DROP ROLE` refuses while a `pg_shdepend` row exists and says so. It
      # does **not** refuse on account of a membership: memberships are removed
      # silently, and the role that comes back from a re-applied `up` is a fresh
      # role with no members. So rolling the roles migration back underneath a
      # live `employer_login` is not a loud failure that gets fixed — it is a
      # quiet one that leaves a credential able to authenticate and unable to
      # assume anything, and `EmployerRepo` cannot open a connection again until
      # somebody re-runs the login migration.
      #
      # Every *grant* migration is rolled back here except the login one, which
      # is deliberately left applied: that is the state this test is about, and
      # it is the state `@grant_migrations` exists to make unreachable in the
      # real unwind order.
      @grant_migrations
      |> Enum.reject(fn {name, _module} -> name == @login_role_migration end)
      |> Enum.reverse()
      |> Enum.each(fn {name, _module} -> migrate(name, :down) end)

      assert_no_foreign_dependencies()
      assert memberships_of(@login_role) == ["employer_role"]

      migrate(@roles_migration, :down)

      assert role_exists?(@login_role)
      assert memberships_of(@login_role) == []

      capture_log(fn -> migrate(@roles_migration, :up) end)

      assert role_exists?("employer_role")
      assert memberships_of(@login_role) == []
    end

    test "bounds how long the employer role can hold a connection" do
      settings = role_settings("employer_role")

      assert Enum.any?(settings, &String.starts_with?(&1, "statement_timeout="))
      assert Enum.any?(settings, &String.starts_with?(&1, "idle_in_transaction_session_timeout="))
    end

    test "grants no table privileges of its own" do
      # This assertion used to read `count == 0` with no rollback in front of
      # it, and its name said the zone grants were a later unit's job. U4 is
      # that unit, so the bare count now says something about U4 rather than
      # about the migration under test. Rolling U4's grants back first restores
      # the original question: does *this* migration grant anything.
      rolled_back_grants()

      assert table_grant_count() == 0
    end

    test "is what the assertion above would notice, once the zone grants are back" do
      # The control, and the reason the rollback above is not just ceremony. If
      # `rolled_back_grants/0` silently did nothing, the assertion would be
      # measuring an empty database instead of a rolled-back one.
      assert table_grant_count() > 0
    end
  end

  # The sandbox lends this test a single connection, so the migrator's own
  # locking transaction would deadlock against the migration it is guarding.
  # The lock exists to serialise concurrent deployers; there are none here.
  @migrator_opts [log: false, migration_lock: false]

  defp rolled_back_grants do
    @grant_migrations
    |> Enum.reverse()
    |> Enum.each(fn {name, _module} -> migrate(name, :down) end)

    assert_no_foreign_dependencies()
    :ok
  end

  defp migrate(name, direction) do
    {^name, module} = List.keyfind(@migrations, name, 0)
    apply(Ecto.Migrator, direction, [Repo, migration_version(name), module, @migrator_opts])
  end

  defp migration_version(name) do
    Repo
    |> Ecto.Migrator.migrations()
    |> Enum.find_value(fn {_status, version, migration} -> migration == name && version end)
  end

  defp migration_files(name) do
    Repo
    |> Ecto.Migrator.migrations_path()
    |> Path.join("*_#{name}.exs")
    |> Path.wildcard()
  end

  # Every other database on this cluster that still grants something to one of
  # the roles. Each one makes `DROP ROLE` fail here, and none of them can be
  # fixed from this connection.
  defp assert_no_foreign_dependencies do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT coalesce(datname, '<shared catalog>')
        FROM pg_shdepend d
        JOIN pg_authid a ON a.oid = d.refobjid
        LEFT JOIN pg_database db ON db.oid = d.dbid
        WHERE a.rolname IN ('employer_role', 'person_role')
          AND d.dbid <> (SELECT oid FROM pg_database WHERE datname = current_database())
        """,
        []
      )

    databases = Enum.map(rows, &hd/1)

    assert databases == [],
           """
           Other databases on this cluster still grant privileges to \
           employer_role or person_role: #{inspect(databases)}

           Roles are cluster-global and grants are database-local, so \
           `DROP ROLE employer_role` fails here for a privilege granted there, \
           and no connection to this database can revoke it. Roll \
           `grant_employer_zone` back in those databases, or drop them.
           """
  end

  # #17's login role is in this list because the answer for it is not "few" but
  # "none, ever". It is granted membership of `employer_role` and no privilege
  # on any object, so that `DROP ROLE employer_login` cannot be blocked from
  # another database on the cluster. `HospitalityComs.BoundaryTest` sweeps that
  # claim across every relation with a control; here it only has to not spoil
  # the count.
  defp table_grant_count do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM information_schema.role_table_grants
        WHERE grantee IN ('employer_role', 'person_role', 'employer_login')
        """,
        []
      )

    count
  end

  defp memberships_of(role) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT g.rolname
        FROM pg_auth_members m
        JOIN pg_roles g ON g.oid = m.roleid
        JOIN pg_roles member ON member.oid = m.member
        WHERE member.rolname = $1
        ORDER BY 1
        """,
        [role]
      )

    Enum.map(rows, &hd/1)
  end

  defp role_exists?(name) do
    %{rows: rows} = Repo.query!("SELECT 1 FROM pg_roles WHERE rolname = $1", [name])
    rows != []
  end

  defp role_settings(name) do
    %{rows: rows} = Repo.query!("SELECT rolconfig FROM pg_roles WHERE rolname = $1", [name])
    settings_from_rows(rows)
  end

  defp settings_from_rows([[settings]]) when is_list(settings), do: settings
  defp settings_from_rows(_rows), do: []
end
