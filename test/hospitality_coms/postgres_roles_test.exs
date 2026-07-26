defmodule HospitalityComs.PostgresRolesTest do
  @moduledoc """
  The two Postgres roles are the only tier of the boundary whose violation
  produces an error rather than a leak, so the migration that creates them has
  to be reversible in fact and not just in intent.

  Roles are cluster-global rather than database-local. Every assertion here
  therefore runs inside the sandbox transaction, which rolls the roles back to
  their pre-test state even when an assertion fails.
  """

  use HospitalityComs.DataCase, async: false

  import ExUnit.CaptureLog

  alias HospitalityComs.Repo.Migrations.CreatePostgresRoles

  @migration_name "create_postgres_roles"

  # Migration files are not compiled into the application, so the module has to
  # be loaded before the migrator can be handed it directly.
  setup_all do
    Enum.each(migration_files(), &Code.require_file/1)
    :ok
  end

  describe "the roles migration" do
    test "creates both roles when migrated up" do
      assert role_exists?("employer_role")
      assert role_exists?("person_role")
    end

    test "leaves no employer_role in pg_roles when migrated down" do
      migrate(:down)

      refute role_exists?("employer_role")
      refute role_exists?("person_role")
    end

    test "restores both roles when migrated down and up again" do
      migrate(:down)

      # Re-running a migration that later ones were stacked on top of makes the
      # migrator warn about out-of-order deployment. It is warning about a
      # rollback in production, not about this test, which puts the version
      # straight back where it found it.
      capture_log(fn -> migrate(:up) end)

      assert role_exists?("employer_role")
      assert role_exists?("person_role")
    end

    test "bounds how long the employer role can hold a connection" do
      settings = role_settings("employer_role")

      assert Enum.any?(settings, &String.starts_with?(&1, "statement_timeout="))
      assert Enum.any?(settings, &String.starts_with?(&1, "idle_in_transaction_session_timeout="))
    end

    test "grants no table privileges — zone grants are a later unit's job" do
      %{rows: [[count]]} =
        Repo.query!(
          """
          SELECT count(*)
          FROM information_schema.role_table_grants
          WHERE grantee IN ('employer_role', 'person_role')
          """,
          []
        )

      assert count == 0
    end
  end

  # The sandbox lends this test a single connection, so the migrator's own
  # locking transaction would deadlock against the migration it is guarding.
  # The lock exists to serialise concurrent deployers; there are none here.
  @migrator_opts [log: false, migration_lock: false]

  defp migrate(direction) do
    args = [Repo, migration_version(), CreatePostgresRoles, @migrator_opts]
    apply(Ecto.Migrator, direction, args)
  end

  defp migration_version do
    Repo
    |> Ecto.Migrator.migrations()
    |> Enum.find_value(fn {_status, version, name} -> name == @migration_name && version end)
  end

  defp migration_files do
    Repo
    |> Ecto.Migrator.migrations_path()
    |> Path.join("*_#{@migration_name}.exs")
    |> Path.wildcard()
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
