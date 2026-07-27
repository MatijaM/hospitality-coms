defmodule HospitalityComs.Repo.Migrations.GrantEmployerZone do
  @moduledoc """
  The first privileges `employer_role` has ever held, and the cluster-wide
  consequence of holding them.

  Everything before this migration was a `REVOKE`: `employer_role` could reach
  nothing, because Postgres default-denies on a table owned by another role and
  nothing had ever granted it anything. The employer zone cannot be read that
  way, so this is where the asymmetry stops being one-sided.

  ## Explicit, per table, per privilege

  Nothing here is `GRANT ALL`, `... ON ALL TABLES IN SCHEMA public`, or
  `ALTER DEFAULT PRIVILEGES`. The last is the one worth naming: U3 measured
  that a default-privilege grant survives `REVOKE ALL ON TABLE` and is
  inherited by every table created afterwards, and the sweep in
  `HospitalityComs.Zones.employer_privileges/1` reports effective privilege on
  the person-zone tables it knows about — so a default privilege would hand
  `employer_role` every person-zone table a later unit adds, retroactively in
  appearance and invisibly in fact. A convenience that grows privileges as the
  schema grows is exactly the mechanism the zone partition exists to refuse.

  So the list is written out. Four statements, each naming a table and the
  privileges the employer zone's code actually exercises:

    * `venues` — SELECT and INSERT. A venue is created by a person who has one
      yet to exist, so the insert is the bootstrap; nothing updates a venue in
      this unit.
    * `employer_grants` — SELECT and INSERT, plus UPDATE on `revoked_at`,
      `revoked_by_grant_id` and `updated_at` alone. Revocation writes those
      three columns and nothing else, and a table-level UPDATE would also let a
      session move a grant to another venue or rewrite its lineage, which are
      cross-tenant writes dressed as administrative ones.
    * `shift_types` — SELECT and INSERT.

  No DELETE anywhere. Deletion is confined to the lifecycle context (KTD21),
  which runs as the application's own role.

  ## What this costs, and it is not nothing

  A `GRANT` to a role writes a row in `pg_shdepend`. Roles are cluster-global
  while grants are database-local, so one such row in **any** database on the
  cluster makes `DROP ROLE employer_role` fail in **every** other one —
  including the rollback `HospitalityComs.PostgresRolesTest` asserts on U1's
  roles migration. U3 declined to spend that on a privilege that protected
  nothing and left a canary saying so; this migration is what spends it.

  Two consequences, both of them real:

    * `HospitalityComs.PostgresRolesTest` rolls **this** migration down before
      it rolls the roles migration down. That is the true ordering — Ecto rolls
      migrations back in reverse — and it is what keeps U1 reversible.
    * A second database on the same cluster that has run this migration will
      make that rollback fail anyway, and no connection to the first database
      can revoke it. Rolling the other database back, or dropping it, is the
      only fix. This is a property of Postgres roles, not of this migration,
      and it is the reason `down` exists and is exercised.

  `down` revokes exactly what `up` granted, restoring the state this migration
  found: `employer_role` holding nothing, anywhere.
  """

  use Ecto.Migration

  # Table, then the privileges granted on it. Column-scoped grants are written
  # as `{privilege, columns}` and expand to `GRANT priv (col, ...)`.
  @grants [
    {"venues", ["SELECT", "INSERT"]},
    {"employer_grants",
     ["SELECT", "INSERT", {"UPDATE", ["revoked_at", "revoked_by_grant_id", "updated_at"]}]},
    {"shift_types", ["SELECT", "INSERT"]}
  ]

  @role "employer_role"

  @doc """
  The tables this migration granted on, as it was written.

  A historical record rather than a live list, exposed so the proof suite can
  compare it against `HospitalityComs.Zones.employer_zone_tables/0` instead of
  transcribing it a third time.
  """
  @spec granted_tables() :: [String.t()]
  def granted_tables, do: Enum.map(@grants, fn {table, _privileges} -> table end)

  def up do
    Enum.each(@grants, &grant/1)
  end

  def down do
    # `REVOKE ALL PRIVILEGES` rather than the mirror image of each grant: the
    # state to restore is "holds nothing", and spelling out the same list twice
    # is a way for the two spellings to drift.
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
