defmodule HospitalityComs.PeopleAuthTablesTest do
  @moduledoc """
  The person zone's schema migration, exercised in both directions.

  This migration hand-writes `up` and `down` rather than using `change`,
  because three of the things it creates — a partial unique index and two check
  constraints — are what makes U10's erasure possible at all. A hand-written
  `down` is a claim nobody has checked until it is needed, and the moment it is
  needed is a rollback in production.

  So it is checked here, the way `HospitalityComs.PostgresRolesTest` checks the
  roles migration: down, then up, then everything that matters asserted back in
  place. It all happens inside the sandbox transaction, so dropping `people`
  rolls back even when an assertion fails.
  """

  use HospitalityComs.DataCase, async: false

  import ExUnit.CaptureLog

  alias HospitalityComs.Repo.Migrations.CreatePeopleAuthTables

  @migration_name "create_people_auth_tables"

  # Migration files are not compiled into the application, so the module has to
  # be loaded before the migrator can be handed it directly.
  setup_all do
    Enum.each(migration_files(), &Code.require_file/1)
    :ok
  end

  describe "the people auth tables migration" do
    test "creates both tables when migrated up" do
      assert table_exists?("people")
      assert table_exists?("people_tokens")
    end

    test "leaves neither table behind when migrated down" do
      migrate(:down)

      refute table_exists?("people")
      refute table_exists?("people_tokens")
    end

    test "restores the tables when migrated down and up again" do
      migrate(:down)
      capture_log(fn -> migrate(:up) end)

      assert table_exists?("people")
      assert table_exists?("people_tokens")
    end

    test "restores the erasure shape, not just the tables" do
      migrate(:down)
      capture_log(fn -> migrate(:up) end)

      # A `down` that dropped the constraints and an `up` that forgot to put
      # them back would leave a database that looks fine and silently admits
      # the two rows U10 depends on being impossible.
      assert index_exists?("people_email_index")
      assert constraint_exists?("people_erased_email_removed")
      assert constraint_exists?("people_present_email_required")
      assert index_exists?("people_tokens_context_token_index")
      assert citext_installed?()
    end

    test "restores a schema that still accepts a person and their token" do
      migrate(:down)
      capture_log(fn -> migrate(:up) end)

      %{rows: [[person_id]]} =
        Repo.query!(
          "INSERT INTO people (id, email, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, now(), now()) RETURNING id",
          ["rolled-back@example.com"]
        )

      assert %{num_rows: 1} =
               Repo.query!(
                 """
                 INSERT INTO people_tokens (id, person_id, token, context, inserted_at)
                 VALUES (gen_random_uuid(), $1, $2, 'session', now())
                 """,
                 [person_id, :crypto.strong_rand_bytes(32)]
               )
    end
  end

  # The sandbox lends this test a single connection, so the migrator's own
  # locking transaction would deadlock against the migration it is guarding.
  @migrator_opts [log: false, migration_lock: false]

  defp migrate(direction) do
    args = [Repo, migration_version(), CreatePeopleAuthTables, @migrator_opts]
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

  defp table_exists?(name) do
    exists?(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
      [
        name
      ]
    )
  end

  defp index_exists?(name) do
    exists?("SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1", [name])
  end

  defp constraint_exists?(name) do
    exists?("SELECT 1 FROM pg_constraint WHERE conname = $1", [name])
  end

  defp citext_installed?, do: exists?("SELECT 1 FROM pg_extension WHERE extname = 'citext'", [])

  defp exists?(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)
    rows != []
  end
end
