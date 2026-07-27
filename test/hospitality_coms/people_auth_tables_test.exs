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

  ## `people` now has a dependent, and it is the bridge

  U5 created `engagements.person_id`, the single crossing between the two zones
  (KTD2), as a foreign key with `ON DELETE RESTRICT`. `DROP TABLE people`
  therefore fails while `engagements` exists — which is that `RESTRICT` doing
  its job, and it is the same growth U4 forced on U3's rollback ordering.

  Every test here that migrates down now unwinds U5 first, in the order Ecto
  would: the engagement zone's row-level security, its grants, then the tables.
  Rolling `create_people_auth_tables` back *without* that is an out-of-order
  rollback, and the loud failure it produces is the point of the `RESTRICT`.
  """

  use HospitalityComs.DataCase, async: false

  import ExUnit.CaptureLog

  alias HospitalityComs.Repo.Migrations.CreateEngagements
  alias HospitalityComs.Repo.Migrations.CreatePeopleAuthTables
  alias HospitalityComs.Repo.Migrations.EnableEngagementRowLevelSecurity
  alias HospitalityComs.Repo.Migrations.GrantEngagementZone

  @migration_name "create_people_auth_tables"

  # The migrations standing between this one and a droppable `people`, in the
  # order they were applied. Unwound in reverse and reapplied in order.
  @dependents [
    {"create_engagements", CreateEngagements},
    {"grant_engagement_zone", GrantEngagementZone},
    {"enable_engagement_row_level_security", EnableEngagementRowLevelSecurity}
  ]

  # Migration files are not compiled into the application, so the modules have
  # to be loaded before the migrator can be handed them directly.
  setup_all do
    Enum.each(["#{@migration_name}" | Enum.map(@dependents, &elem(&1, 0))], fn name ->
      Enum.each(migration_files(name), &Code.require_file/1)
    end)

    :ok
  end

  describe "the people auth tables migration" do
    test "creates both tables when migrated up" do
      assert table_exists?("people")
      assert table_exists?("people_tokens")
    end

    test "cannot be rolled back under the bridge, and says which key holds it" do
      # The `RESTRICT` on `engagements.person_id` meeting the only table it can
      # ever hold up. Ecto rolls migrations back in reverse, so the ordinary
      # path never reaches this; the path that does is an out-of-order
      # rollback, which is exactly when a loud failure is worth having.
      assert_raise Postgrex.Error, ~r/dependent_objects_still_exist/, fn -> migrate(:down) end
    end

    test "leaves neither table behind when migrated down" do
      rolled_back(fn ->
        refute table_exists?("people")
        refute table_exists?("people_tokens")
      end)
    end

    test "restores the tables when migrated down and up again" do
      rolled_back(fn -> :nothing_in_between end)

      assert table_exists?("people")
      assert table_exists?("people_tokens")
    end

    test "restores the erasure shape, not just the tables" do
      rolled_back(fn -> :nothing_in_between end)

      # A `down` that dropped the constraints and an `up` that forgot to put
      # them back would leave a database that looks fine and silently admits
      # the two rows U10 depends on being impossible.
      assert index_exists?("people_email_index")
      assert constraint_exists?("people_erased_email_removed")
      assert constraint_exists?("people_present_email_required")
      assert index_exists?("people_tokens_context_token_index")
      assert citext_installed?()
    end

    test "restores the bridge that was rolled back with it" do
      # The other half of the round trip, and the reason it unwinds three
      # migrations rather than one: a `people` restored without `engagements`
      # is a person zone with no way across the boundary, and the suite would
      # not notice until the next file that claimed an invitation.
      rolled_back(fn -> refute table_exists?("engagements") end)

      assert table_exists?("engagements")
      assert constraint_exists?("engagements_no_overlap")
      assert constraint_exists?("engagements_person_id_fkey")
    end

    test "restores a schema that still accepts a person and their token" do
      rolled_back(fn -> :nothing_in_between end)

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

  # Everything U5 stacked on top of `people`, unwound in reverse, then this
  # migration down and up again, then U5 put back in order. `between` runs at
  # the bottom of that, which is the only place the rolled-back state is
  # observable.
  defp rolled_back(between) do
    @dependents |> Enum.reverse() |> Enum.each(&migrate(&1, :down))
    migrate(:down)

    result = between.()

    capture_log(fn ->
      migrate(:up)
      Enum.each(@dependents, &migrate(&1, :up))
    end)

    result
  end

  defp migrate(direction) do
    migrate({@migration_name, CreatePeopleAuthTables}, direction)
  end

  defp migrate({name, module}, direction) do
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
