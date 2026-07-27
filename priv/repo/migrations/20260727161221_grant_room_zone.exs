defmodule HospitalityComs.Repo.Migrations.GrantRoomZone do
  @moduledoc """
  What `employer_role` may do with a shift room and a roster, the room table it
  may not touch at all, and the first person-zone table added since U3.

  Like U4's and U5's grant migrations, the lists here are written out rather
  than read from `HospitalityComs.Zones`: a migration is a record of what was
  done to a database on a given day, and wiring it to a module later units edit
  would make its behaviour change retroactively.

  ## The inventory

    * `shift_rooms` — SELECT and INSERT. A manager schedules a shift and lists
      the venue's own. **No UPDATE**: a room's term and its stamped grace are
      what every membership answer is derived from, and a session that could
      move them could close a room somebody is standing in or reopen one that
      shut yesterday. Rescheduling is out of scope for this unit; when it
      arrives it needs a decision about already-sent messages, not a grant.
    * `roster_entries` — SELECT, INSERT, and UPDATE on `left_at` and
      `updated_at` alone. Those two columns are removal, which is the only
      mutation a roster entry has.

      A table-level UPDATE would also let a session move `joined_at` backwards,
      which is the retroactive grant KTD6b's structure exists to make
      impossible, or move an entry to another engagement or another shift. The
      column list is what keeps "removal closes a period" from being a
      convention.

  ## And two tables it holds nothing on

  `room_messages` gets no grant, and that is a decision rather than an
  oversight. Room conversation is worker-facing: R11's "readable to everyone
  whose roster period overlapped" is a statement about the people who worked the
  shift. A manager is one of them — they hold an engagement like anybody else —
  and they read the room through it, from the person's side, under a
  `HospitalityComs.Accounts.PersonScope`. What has no reason to exist is an
  *employer session* that can read a venue's conversation in bulk without being
  in it, so no grant creates one. The sends run through
  `HospitalityComs.Repo` as the application's own role, exactly as U5's claim
  does and for the same reason: they span both zones and no session on either
  side holds the privileges for all of it.

  `venue_room_suspensions` is the other one, and it is the point of KTD18.
  Origin R11 lets a person leave the venue room reversibly and says the employer
  must not see that they have; employer visibility of the flag would make it a
  retaliation surface rather than an opt-out. The `REVOKE` below is the same
  declaration of intent U3's `grant_zones` makes over `people` — Postgres
  default-denies, so it is not what is currently holding the door shut, but it
  is the statement a later convenience grant has to be reconciled against, and
  `HospitalityComs.BoundaryTest` runs the sweep that would catch one however it
  arrived.

  A `REVOKE` on a table nobody was granted writes no `pg_shdepend` row, so the
  person-zone half of this migration costs nothing cluster-wide. The two grants
  do, on two more tables.

  ## What this costs, and what `down` restores

  The same cluster-wide `pg_shdepend` dependency U4 and U5 paid, on
  `shift_rooms` and `roster_entries`. Roles are cluster-global while grants are
  database-local, so a row in any database on the cluster makes
  `DROP ROLE employer_role` fail in every other — which is why
  `HospitalityComs.PostgresRolesTest` rolls the grant migrations back before it
  rolls the roles migration back, and why this one is in its list.

  `down` revokes everything, restoring the state this migration found:
  `employer_role` holding nothing on either table. The person-zone `REVOKE` has
  no reverse, for the reason `grant_zones` gives — the state it found was no
  privilege at all, and restoring that means leaving it alone.
  """

  use Ecto.Migration

  # Table, then the privileges granted on it. Column-scoped grants are written
  # as `{privilege, columns}` and expand to `GRANT priv (col, ...)`.
  @grants [
    {"shift_rooms", ["SELECT", "INSERT"]},
    {"roster_entries", ["SELECT", "INSERT", {"UPDATE", ["left_at", "updated_at"]}]}
  ]

  # The person-zone table U6 adds. Written out for the same reason the grants
  # are, and pinned against the classification by
  # `HospitalityComs.BoundaryTest` alongside U3's list.
  @person_zone_tables ~w(venue_room_suspensions)

  @role "employer_role"

  @doc """
  The tables this migration granted on, as it was written.

  A historical record rather than a live list, exposed so the proof suite can
  compare it against the classification instead of transcribing it a third time.
  """
  @spec granted_tables() :: [String.t()]
  def granted_tables, do: Enum.map(@grants, fn {table, _privileges} -> table end)

  @doc """
  The tables this migration revoked, as it was written.

  U3's `grant_zones` exposes the same thing for `people` and `people_tokens`.
  The proof suite asserts the union of the two equals
  `HospitalityComs.Zones.person_zone_tables/0`, so the day a person-zone table
  is added without a migration covering it is the day somebody is told.
  """
  @spec person_zone_tables() :: [String.t()]
  def person_zone_tables, do: @person_zone_tables

  def up do
    Enum.each(@grants, &grant/1)
    Enum.each(@person_zone_tables, &revoke_all/1)
  end

  def down do
    # `REVOKE ALL PRIVILEGES` rather than the mirror image of each grant: the
    # state to restore is "holds nothing", and spelling out the same list twice
    # is a way for the two spellings to drift.
    #
    # The person-zone tables are deliberately not re-granted; see the moduledoc.
    Enum.each(granted_tables(), &revoke_all/1)
  end

  defp grant({table, privileges}) do
    execute(
      "GRANT #{Enum.map_join(privileges, ", ", &privilege/1)} ON TABLE #{table} TO #{@role}"
    )
  end

  defp privilege({name, columns}), do: "#{name} (#{Enum.join(columns, ", ")})"
  defp privilege(name), do: name

  defp revoke_all(table) do
    execute("REVOKE ALL PRIVILEGES ON TABLE #{table} FROM #{@role}")
  end
end
