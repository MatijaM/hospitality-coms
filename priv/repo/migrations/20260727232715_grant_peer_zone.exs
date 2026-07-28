defmodule HospitalityComs.Repo.Migrations.GrantPeerZone do
  @moduledoc """
  What `employer_role` may do with the peer graph, which is nothing at all.

  This migration grants no privilege on any table, and that is its content
  rather than an omission. U3's `grant_zones` has the same shape for `people`
  and `people_tokens`, and the person-zone half of U6's `grant_room_zone` has it
  for `venue_room_suspensions`. The name follows those two so that "the grant
  migrations" stays one list; what it does is revoke.

  ## Why a `REVOKE` on a table nobody was granted is worth writing

  Postgres default-denies on a table owned by another role, so at the instant
  this runs it changes nothing measurable. Three things make it worth having
  anyway.

  It is the **declaration of intent** a later convenience grant has to be
  reconciled against. Somebody adding `GRANT SELECT ON peer_messages TO
  employer_role` in a future migration is contradicting a statement in the tree
  rather than filling a gap in it.

  It is what `HospitalityComs.BoundaryTest` compares the classification against.
  That suite asserts the union of every migration's revoked list equals
  `HospitalityComs.Zones.person_zone_tables/0`, so a person-zone table added
  with no migration covering it fails there — the day it is added, rather than
  at the first query that comes back with rows it should not have.

  And it costs nothing cluster-wide. A `REVOKE` on a table nobody was granted
  writes no `pg_shdepend` row, so unlike U4's, U5's and U6's grants this one
  leaves `DROP ROLE employer_role` exactly as reachable as it found it. It is in
  `HospitalityComs.PostgresRolesTest`'s unwind list all the same, because that
  list is "every grant migration" and a list with a judgement call in it is a
  list somebody gets wrong later.

  ## Why the peer graph gets nothing, spelled out

  R6 is the requirement the whole product exists for: an employer-scoped session
  cannot resolve a peer conversation through any transport, query, or
  subscription path. Four tiers hold it, and only this one produces an error
  rather than a leak (KTD1):

    * the grants below, which are absent, so Postgres refuses;
    * `HospitalityComs.EmployerRepo`'s query backstop, which raises
      `ZoneViolationError` naming the table before Postgres is asked;
    * `HospitalityComsWeb.EmployerSocket`, which routes no `"peer"` topic, so a
      join is refused in Phoenix's dispatch with no application code running;
    * `HospitalityComs.Peers`, every function of which heads on a
      `HospitalityComs.Accounts.PersonScope`.

  There is no reading under which an employer session wants any of this. A peer
  connection is between two people and records no venue, so there is not even a
  filter that would make such a query mean something.

  ## `down` restores what this found, which is nothing

  The state before this migration is "holds no privilege", and restoring it
  means leaving it alone — the same reverse `grant_zones` and the person-zone
  half of `grant_room_zone` give, and for the same reason.
  """

  use Ecto.Migration

  # The three person-zone tables U8 adds. Written out rather than read from
  # `HospitalityComs.Zones`, like every grant migration before it: a migration
  # is a record of what was done to a database on a given day, and wiring it to
  # a module later units edit would make its behaviour change retroactively.
  @person_zone_tables ~w(connection_requests peer_connections peer_messages)

  @role "employer_role"

  @doc """
  The tables this migration revoked, as it was written.

  U3's `grant_zones` and U6's `grant_room_zone` expose the same thing. The proof
  suite asserts the union of the three equals
  `HospitalityComs.Zones.person_zone_tables/0`.
  """
  @spec person_zone_tables() :: [String.t()]
  def person_zone_tables, do: @person_zone_tables

  @doc """
  The tables this migration granted on, which is none.

  Exposed so the proof suite's "grant on every table the classification places
  outside the person zone" can quantify over every grant migration without one
  of them being a special case somebody has to remember.
  """
  @spec granted_tables() :: [String.t()]
  def granted_tables, do: []

  def up do
    Enum.each(@person_zone_tables, &revoke_all/1)
  end

  def down do
    # Deliberately empty. See the moduledoc.
    :ok
  end

  defp revoke_all(table) do
    execute("REVOKE ALL PRIVILEGES ON TABLE #{table} FROM #{@role}")
  end
end
