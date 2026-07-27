defmodule HospitalityComs.Repo.Migrations.EnableRoomRowLevelSecurity do
  @moduledoc """
  Venue tenancy on the three employer-zone tables U6 adds.

  U4 measured the exploit this closes and closed it for its own three tables;
  U5 did the same for its three. On a table `employer_role` can reach,
  everything holding one venue out of another's rows above this tier is a
  `where venue_id = ^scope.venue_id` written by hand, so a single statement that
  omitted it reached every row in the database. The same statement aimed at
  `roster_entries` would remove every worker from every shift at every venue,
  which is the same accident with a bigger blast radius — so the same policy
  goes on, on the same predicate, keyed on the same transaction-local setting.

  That argument covers `shift_rooms` and `roster_entries`. It does **not** cover
  `room_messages`, and the paragraph below is the honest version.

  ## `room_messages` carries a policy that binds nobody

  Two facts, each asserted in `HospitalityComs.BoundaryTest` and each fine on
  its own, meet here: `employer_role` holds no privilege at all on this table
  (`*_grant_room_zone.exs` says why), and the policies here are not `FORCE`d.
  So the only role that reaches `room_messages` is the application's own login
  role through `HospitalityComs.Repo` — which **owns** the table and is
  therefore not bound by the policy. The policy is inert. It is not belt and
  braces; it is braces, worn next to a door that a different key opens.

  This is not the shape `attested_entries` has, and calling it that was the
  mistake. That table is read by an employer session through U9's
  owner-privileged view, so the policy underneath a view is the tier the view
  rests on. `room_messages` is read by the person's side of the application,
  which owns the table outright.

  So say what does hold a message row to its venue, because something must:

    * **Writes have a database tier, and it is the composite keys.**
      `room_messages_author_fkey` is `MATCH FULL` into
      `engagements (id, venue_id)` and `room_messages_shift_room_fkey` is
      `MATCH SIMPLE` into `shift_rooms (id, venue_id)`. A message cannot be
      attributed to an engagement at another venue, and cannot be filed in
      another venue's room. `HospitalityComs.RoomsTest` asserts both by writing
      the row Postgres has to refuse.
    * **Reads of a shift room inherit it.** `Records.shift_room_messages/1`
      filters on `shift_room_id` alone, and every row that names a room carries
      that room's venue by the key above — so its tenancy is the key's, not the
      filter's.
    * **Reads of a venue room do not.** `Records.venue_room_messages/1` filters
      on `venue_id`, and nothing underneath it would refuse a statement that
      omitted the filter. What the caller cannot do is *choose* that venue: it
      comes off the engagement `HospitalityComs.Rooms.fetch_membership/2`
      resolved for this person at this instant, not off the request.

  ## FORCE was considered and is worse than useless here

  Measured, twice. A `FORCE`d policy is evaluated for the owner too, and the
  predicate calls `app_current_employer_id()`, which raises
  `app.employer_id is not set on this connection` wherever the setting is
  absent — which is every person-side read of a room, every migration and every
  seed. A person's own reads span venues besides, so there is no one value the
  wrapper could set for them.

  And in this project it would not even fail loudly: `HospitalityComs.Repo`
  connects as `postgres`, a superuser, and superusers bypass row-level security
  whether or not it is `FORCE`d. `FORCE` would therefore read as a tier while
  providing none, and start raising the day the application ran as the
  non-superuser owner it should. A policy that binds nobody and says so is
  better than one that binds nobody and does not.

  The policy stays on because the employer zone's rule in
  `HospitalityComs.BoundaryTest` is that *every* employer-zone table carries
  one, a rule with an exception is a rule somebody argues with, and the day
  `employer_role` is granted anything here — which would need its own argument —
  the tenancy is already written.

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
