defmodule HospitalityComs.Repo.Migrations.EnableEmployerZoneRowLevelSecurity do
  @moduledoc """
  A database tier for venue-to-venue tenancy, which the employer zone had none
  of.

  U4 shipped three tables, one shared `employer_role`, and no row-level
  security. Everything that kept one venue out of another's rows was a
  `where venue_id = ^scope.venue_id` written by hand in
  `HospitalityComs.Venues` — which means a single statement that omits it
  reaches every row in the database. Measured:
  `EmployerRepo.update_all(EmployerGrant, set: [revoked_at: t, ...])` passes
  the unscoped guard, passes the zone guard, passes Postgres, and revokes every
  grant at every venue.

  The zone boundary is a privilege question rather than a filter question
  (KTD1), and the person zone gets that for free — the forbidden tables carry
  no employer key, so there is no filter to forget. Inside the employer zone
  there *is* one, on every table, and this is what stops it being the kind of
  guarantee that depends on nobody forgetting.

  ## One policy per table, on the predicate that was already there

  `USING` and `WITH CHECK` are the same expression, and it is the expression
  every query in the context already carries: the row's venue equals the venue
  the transaction is scoped to. `app_current_employer_id()` is U3's function
  reading the transaction-local `app.employer_id` that
  `HospitalityComs.EmployerRepo.scoped_transaction/2` writes — the same setting
  U9's employer-visible view will filter on, so there is one place a
  transaction says which venue it is for.

  `WITH CHECK` matters as much as `USING`: without it a row could be inserted
  at another venue and then be invisible to the session that wrote it, which is
  worse than a refusal. Every insert the context performs takes `venue_id` from
  the scope, so it costs nothing.

  ## Not FORCEd, and that is the decision

  The tables are owned by the application's login role, so `Repo`, the migrator
  and the seeds bypass the policies while `employer_role` — which owns nothing
  and holds no `BYPASSRLS` — is bound by them. That is the same asymmetry the
  grants already have, and it is what makes this safe to add to tables three
  migrations have already touched.

  `FORCE ROW LEVEL SECURITY` would bind the owner too, and the predicate raises
  wherever `app.employer_id` is unset — which is every migration, every seed
  and every read the lifecycle context (KTD21) will make as the application's
  own role.

  ## This is not KTD3 reversed

  KTD3 chose an owner-privileged view over RLS for the *hidden attested entry*
  rule, on the grounds that a view has no `FORCE` to forget. That decision
  stands and this does not touch it. Hidden entries are a per-row disclosure
  rule over a table the employer role holds no privilege on at all; this is
  table-wide tenancy over tables it holds `SELECT` on, where the predicate is
  one column comparison already written into every query. They are different
  problems, and RLS is the right tool for the second.

  ## The policies are granted to PUBLIC

  Deliberately, and for the reason U3 gave for leaving the scoping functions'
  `EXECUTE` with `PUBLIC`. A `TO employer_role` clause would write a row in
  `pg_shdepend`, and roles are cluster-global while those rows are
  database-local, so it would be one more thing `DROP ROLE employer_role` fails
  on in every other database on the cluster. `PUBLIC` costs nothing here: the
  owner bypasses the policy regardless, and no other role can reach these
  tables at all.
  """

  use Ecto.Migration

  # Table, and the column that has to equal the transaction's venue. `venues`
  # is keyed on its own id, because a venue's id *is* the venue key — which is
  # also why it is the one employer-zone table with no `venue_id` column.
  @tenancy [
    {"venues", "id"},
    {"employer_grants", "venue_id"},
    {"shift_types", "venue_id"}
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
