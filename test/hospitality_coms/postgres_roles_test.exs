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

  alias HospitalityComs.Repo.Migrations.CreatePostgresRoles
  alias HospitalityComs.Repo.Migrations.GrantEmployerZone
  alias HospitalityComs.Repo.Migrations.GrantEngagementZone

  @roles_migration "create_postgres_roles"
  @employer_grants_migration "grant_employer_zone"
  @engagement_grants_migration "grant_engagement_zone"

  # In the order Ecto applies them, which is the reverse of the order
  # `rolled_back_grants/0` unwinds them in.
  @grant_migrations [
    {@employer_grants_migration, GrantEmployerZone},
    {@engagement_grants_migration, GrantEngagementZone}
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

  defp table_grant_count do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM information_schema.role_table_grants
        WHERE grantee IN ('employer_role', 'person_role')
        """,
        []
      )

    count
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
