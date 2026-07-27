defmodule HospitalityComs.Repo.Migrations.EnableRoomRowLevelSecurity do
  @moduledoc """
  Venue tenancy on the three employer-zone tables U6 adds.

  U4 measured the exploit this closes and closed it for its own three tables;
  U5 did the same for its three. Everything holding one venue out of another's
  rows above this tier is a `where venue_id = ^scope.venue_id` written by hand,
  so a single statement that omitted it reached every row in the database. The
  same statement aimed at `roster_entries` would remove every worker from every
  shift at every venue, which is the same accident with a bigger blast radius —
  so the same policy goes on, on the same predicate, keyed on the same
  transaction-local setting.

  `room_messages` carries a policy and no privileges, which is the shape
  `attested_entries` already has. Belt and braces, deliberately: `employer_role`
  holds nothing on the table, so the policy protects a door that is already
  locked. It goes on anyway because the employer zone's rule in
  `HospitalityComs.BoundaryTest` is that *every* employer-zone table carries
  one, and a rule with an exception is a rule somebody argues with.

  ## `venue_room_suspensions` gets none, and that is not an omission

  It is a person-zone table. It carries no `venue_id`, so the predicate has
  nothing to compare, and `employer_role` holds no privilege on it, so there is
  nothing for a policy to filter. Row-level security answers "which rows may
  this role see"; the person zone's answer is "none, and not by filtering".
  `people` and `people_tokens` have no policy for the same reason.

  ## Not FORCEd, and granted to PUBLIC

  For the reasons U4 and U5 gave. The tables are owned by the application's
  login role, so `HospitalityComs.Repo`, the migrator and the seeds bypass the
  policies while `employer_role` — which owns nothing and holds no `BYPASSRLS` —
  is bound by them. `FORCE` would bind the owner too, and the predicate raises
  wherever `app.employer_id` is unset: every migration, every seed, and the
  whole of the person's own reading of these rooms, which is the side they
  exist to serve.

  Policies are granted to `PUBLIC` rather than `TO employer_role` so they write
  no `pg_shdepend` row. The owner bypasses them regardless and no other role can
  reach these tables.

  ## Rollback order

  The policies depend on `app_current_employer_id()`, which `grant_zones` drops
  with `RESTRICT` on purpose. Rolling `grant_zones` back without rolling this
  migration back first fails loudly with `dependent_objects_still_exist`, which
  is that `RESTRICT` working. `HospitalityComs.BoundaryTest` both rolls in the
  right order and pins the wrong one.
  """

  use Ecto.Migration

  # Table, and the column that has to equal the transaction's venue.
  @tenancy [
    {"shift_rooms", "venue_id"},
    {"room_messages", "venue_id"},
    {"roster_entries", "venue_id"}
  ]

  def up do
    Enum.each(@tenancy, &enable/1)
  end

  def down do
    Enum.each(@tenancy, &disable/1)
  end

  defp enable({table, key}) do
    execute("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY #{policy(table)} ON #{table}
      USING (#{key} = app_current_employer_id())
      WITH CHECK (#{key} = app_current_employer_id())
    """)
  end

  defp disable({table, _key}) do
    execute("DROP POLICY #{policy(table)} ON #{table}")
    execute("ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY")
  end

  defp policy(table), do: "#{table}_tenancy"
end
