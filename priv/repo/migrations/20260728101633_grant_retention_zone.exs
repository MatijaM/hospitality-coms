defmodule HospitalityComs.Repo.Migrations.GrantRetentionZone do
  @moduledoc """
  U10's two tables, and the privileges `employer_role` does not hold on either.

  It grants nothing. `retained_message_copies` is the worker's own archive of
  their own words, reached only through `HospitalityComs.Repo` under a
  `PersonScope`; `retention_runs` is the deleter's log across every venue in the
  installation, which is precisely the kind of question no employer session may
  ask. Both are person zone.

  ## Why a `REVOKE` on a table nobody was granted is worth writing

  The same argument `grant_peer_zone` makes. The statement costs nothing — a
  `REVOKE` on a table with no grant writes no `pg_shdepend` row, so it creates
  none of the cluster-wide dependency that makes `DROP ROLE employer_role` fail
  in every other database on the cluster — and what it buys is a declaration in
  the schema that a later `GRANT` has to be reconciled against.

  `HospitalityComs.BoundaryTest` asserts that the union of every grant
  migration's `person_zone_tables/0` equals
  `HospitalityComs.Zones.person_zone_tables/0`, so the day a person-zone table
  is added without a migration covering it is the day somebody is told. A unit
  that granted nothing and therefore wrote no migration would be a hole in that
  union.

  It is also an entry in `HospitalityComs.PostgresRolesTest`'s unwind list, for
  the reason that file gives: the rule is "every grant migration", and a list
  with a judgement call in it is a list somebody gets wrong later.

  ## The retention deleter runs as the application's own role

  Nothing here grants `DELETE` to anybody, on any table, and that is the point
  rather than an omission. `HospitalityComs.Lifecycle` reads and writes through
  `HospitalityComs.Repo` — the application acting for itself — and never through
  `HospitalityComs.EmployerRepo`. `boundary_test.exs` asserts that the employer
  zone's privilege inventory contains no `DELETE`, `TRUNCATE` or `MAINTAIN`, and
  this migration is where that stays true in the one unit whose whole subject is
  deletion.
  """

  use Ecto.Migration

  # U10's two, written out rather than derived, because this file's job is to be
  # a second opinion the proof suite can disagree with.
  @person_zone_tables ~w(retained_message_copies retention_runs)

  @role "employer_role"

  @doc """
  The tables this migration granted on, as it was written.

  Empty, and exported anyway: `HospitalityComs.BoundaryTest` builds the
  grant-coverage union out of every grant migration's list, and a migration left
  out because it happened to grant nothing is a migration nobody notices the day
  it starts granting something.
  """
  @spec granted_tables() :: [String.t()]
  def granted_tables, do: []

  @doc """
  The tables this migration revoked, as it was written.
  """
  @spec person_zone_tables() :: [String.t()]
  def person_zone_tables, do: @person_zone_tables

  def up do
    Enum.each(@person_zone_tables, &revoke_all/1)
  end

  # The person-zone tables are deliberately not re-granted: the state to restore
  # is "holds nothing", which is what rolling this migration back leaves.
  def down, do: :ok

  defp revoke_all(table) do
    execute("REVOKE ALL PRIVILEGES ON TABLE #{table} FROM #{@role}")
  end
end
