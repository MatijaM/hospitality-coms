defmodule HospitalityComs.Repo.Migrations.GrantEngagementZone do
  @moduledoc """
  What `employer_role` may do with an invitation and with the bridge, and the
  two tables it may not touch at all.

  U4's `grant_employer_zone` wrote out its list rather than reading `Zones`, and
  that was right: a migration is a record of what was done to a database on a
  given day, and wiring it to a module later units edit would make its behaviour
  change retroactively. This migration follows the same rule, and adds only what
  U5's own code exercises.

  ## The inventory

    * `invitations` — SELECT and INSERT. A manager issues an invitation and
      lists the venue's outstanding ones. **No UPDATE**: redeeming an invitation
      is the claim's first `Ecto.Multi` step, and the claim runs as the
      application's own role, so there is no employer session anywhere that can
      mark a code claimed.

      The SELECT is table-level and therefore **includes `claim_code_digest`**.
      That is a deliberate choice rather than an omission: the claim looks an
      invitation up *by* that column, and a column list here would be a second
      place to keep the schema's columns in step. The digest is SHA-256 of 32
      random bytes, so a leak of it is not a leak of a working code — but it
      does reach any employer session that reads a whole row, and
      `HospitalityComs.Engagements.Records.outstanding_invitations/2` returns
      whole rows. **U6 must render a field list rather than the struct.**
    * `engagements` — SELECT, plus UPDATE on `ends_at`, `lock_version` and
      `updated_at` alone. Renewal and ending write those three columns and
      nothing else. A table-level UPDATE would also let a session move an
      engagement to another person or another venue, or rewrite the grant it
      holds, which are exactly the cross-boundary writes the single-crossing
      rule exists to make unrepresentable.

      **No INSERT.** An engagement is created only by the person claiming a
      code, and that path runs as the application's own role. An employer
      session that could insert one could manufacture a worker.

  ## And two tables it holds nothing on

  `attested_entries` gets no grant here, and that is KTD3 rather than an
  oversight. Hidden entries are a per-row disclosure rule, which grants cannot
  express, so the employer reads U9's owner-privileged view and never the base
  table. The absence is asserted in `HospitalityComs.BoundaryTest`, because an
  absence nobody checks is an absence somebody adds a grant to.

  `people` is the other one, and it always was.

  ## What this costs

  The same cluster-wide `pg_shdepend` dependency U4's grants cost, on two more
  tables. Roles are cluster-global while grants are database-local, so a row in
  any database on the cluster makes `DROP ROLE employer_role` fail in every
  other — which is why `HospitalityComs.PostgresRolesTest` rolls the grant
  migrations back before it rolls the roles migration back, and why `down`
  exists and is exercised.

  `down` revokes everything, restoring the state this migration found:
  `employer_role` holding nothing on either table.
  """

  use Ecto.Migration

  # Table, then the privileges granted on it. Column-scoped grants are written
  # as `{privilege, columns}` and expand to `GRANT priv (col, ...)`.
  @grants [
    {"invitations", ["SELECT", "INSERT"]},
    {"engagements", ["SELECT", {"UPDATE", ["ends_at", "lock_version", "updated_at"]}]}
  ]

  @role "employer_role"

  @doc """
  The tables this migration granted on, as it was written.

  A historical record rather than a live list, exposed so the proof suite can
  compare it against the classification instead of transcribing it a third time.
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
