defmodule HospitalityComs.Repo.Migrations.GrantProfileZone do
  @moduledoc """
  What `employer_role` may do with the profile: read two views, and answer the
  corrections a worker addressed to it.

  ## The inventory

    * `correction_requests` — `SELECT`, plus `UPDATE` on `resolved_at`,
      `resolution`, `resolved_by_grant_id` and `updated_at` alone. Answering is
      the only mutation a correction request has, and a table-level `UPDATE`
      would let a session rewrite the worker's own words, move a request to
      another engagement, or backdate one.

      **No `INSERT`.** A correction request is *written by the worker*, through
      `HospitalityComs.Repo` under a `PersonScope`, which is the manoeuvre the
      claim already makes when it writes an attested entry. An employer session
      that could insert one could manufacture a complaint and then resolve it.

      The `SELECT` is what an `UPDATE ... WHERE` needs — Postgres requires
      `SELECT` on every column a statement reads — and it is confined to one
      venue by the row-level security policy
      `enable_profile_row_level_security` writes.

    * `employer_visible_attested_entries` and
      `employer_visible_correction_requests` — `SELECT`, and nothing else. A
      view can be updatable in Postgres when it is simple enough; these two are
      multi-way joins and are not, but the grant says `SELECT` rather than
      relying on that, because "not auto-updatable" is a property of the view's
      shape and the shape is a thing a later unit edits.

  ## And the tables it holds nothing on

  `attested_entries` still, which is KTD3 and is why the views exist.
  `declared_entries` and `attested_entry_disclosures`, which are person zone.

  The disclosure ledger is the one worth spelling out. `attested_entry_disclosures`
  carries `audience_venue_id`, so unlike every other person-zone table in this
  tree an employer-scoped query over it *would* mean something —
  `WHERE audience_venue_id = <me> AND disclosed = false` is the list of workers
  concealing something from this venue. That is a strictly worse disclosure than
  the entries themselves and it is the oracle the standing incompleteness notice
  exists not to be. The `REVOKE` below is the declaration; the classification in
  `HospitalityComs.Zones`, `HospitalityComs.EmployerRepo`'s backstop and
  Postgres default-denying are what enforce it.

  ## Why a `REVOKE` on a table nobody was granted is worth writing

  U8's `grant_peer_zone` gives the argument in full and it is unchanged here. In
  short: it is the declaration of intent a later convenience grant has to be
  reconciled against, and `HospitalityComs.BoundaryTest` asserts that the union
  of every migration's revoked list equals
  `HospitalityComs.Zones.person_zone_tables/0`, so a person-zone table covered by
  no migration fails there the day it is added.

  ## What this costs, and where it is accounted for

  A `pg_shdepend` row per granted object — three of them, one of which is a table
  and two of which are **views**. Roles are cluster-global while grants are
  database-local, so a row in any database on the cluster makes
  `DROP ROLE employer_role` fail in every other; `HospitalityComs.PostgresRolesTest`
  therefore rolls this migration back before it rolls the roles migration back,
  and this unit adds an entry to that list.

  `pg_describe_object` names a view `view x` rather than `table x`, which is why
  the granted views are exposed separately from the granted tables below —
  `HospitalityComs.BoundaryTest` compares the two against what the catalogue
  actually says.

  `down` revokes everything, restoring the state this migration found:
  `employer_role` holding nothing anywhere in the profile.
  """

  use Ecto.Migration

  # Table, then the privileges granted on it. Column-scoped grants are written
  # as `{privilege, columns}` and expand to `GRANT priv (col, ...)`.
  @grants [
    {"correction_requests",
     [
       "SELECT",
       {"UPDATE", ["resolved_at", "resolution", "resolved_by_grant_id", "updated_at"]}
     ]}
  ]

  @granted_views ["employer_visible_attested_entries", "employer_visible_correction_requests"]

  # The two person-zone tables U9 adds. Written out rather than read from
  # `HospitalityComs.Zones`, like every grant migration before it: a migration is
  # a record of what was done to a database on a given day, and wiring it to a
  # module later units edit would make its behaviour change retroactively.
  @person_zone_tables ~w(declared_entries attested_entry_disclosures)

  @role "employer_role"

  @doc """
  The tables this migration granted on, as it was written.
  """
  @spec granted_tables() :: [String.t()]
  def granted_tables, do: Enum.map(@grants, fn {table, _privileges} -> table end)

  @doc """
  The views this migration granted on, as it was written.

  Separate from `granted_tables/0` because `pg_describe_object` names them
  differently, and the proof suite compares against what the catalogue says.
  """
  @spec granted_views() :: [String.t()]
  def granted_views, do: @granted_views

  @doc """
  The tables this migration revoked, as it was written.

  U3's `grant_zones`, U6's `grant_room_zone` and U8's `grant_peer_zone` expose
  the same thing. The proof suite asserts the union of the four equals
  `HospitalityComs.Zones.person_zone_tables/0`.
  """
  @spec person_zone_tables() :: [String.t()]
  def person_zone_tables, do: @person_zone_tables

  def up do
    Enum.each(@person_zone_tables, &revoke_all/1)
    Enum.each(@grants, &grant/1)
    Enum.each(@granted_views, &grant_select/1)
  end

  def down do
    # `REVOKE ALL PRIVILEGES` rather than the mirror image of each grant: the
    # state to restore is "holds nothing", and spelling out the same list twice
    # is a way for the two spellings to drift.
    Enum.each(granted_tables() ++ @granted_views, &revoke_all/1)

    # The person-zone tables are deliberately not re-granted. The state this
    # migration found was no privilege at all, and restoring it means leaving it
    # alone — the same reverse `grant_zones` and `grant_peer_zone` give.
  end

  defp grant({table, privileges}) do
    execute(
      "GRANT #{Enum.map_join(privileges, ", ", &privilege/1)} ON TABLE #{table} TO #{@role}"
    )
  end

  defp grant_select(view) do
    execute("GRANT SELECT ON TABLE #{view} TO #{@role}")
  end

  defp privilege({name, columns}), do: "#{name} (#{Enum.join(columns, ", ")})"
  defp privilege(name), do: name

  defp revoke_all(relation) do
    execute("REVOKE ALL PRIVILEGES ON TABLE #{relation} FROM #{@role}")
  end
end
