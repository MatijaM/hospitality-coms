defmodule HospitalityComs.Repo.Migrations.EnableProfileRowLevelSecurity do
  @moduledoc """
  Venue tenancy on `correction_requests`, the one employer-zone table U9 adds.

  The same policy U4's `enable_employer_zone_row_level_security` and U5's
  `enable_engagement_row_level_security` write, on the same predicate, keyed on
  the same transaction-local setting: `USING` and `WITH CHECK`, both on the
  row's venue equalling `app_current_employer_id()`. `HospitalityComs.BoundaryTest`
  asserts that *every* employer-zone table carries one, and a rule with an
  exception is a rule somebody argues with.

  It is load-bearing here rather than belt-and-braces. `employer_role` holds
  `SELECT` and a column-scoped `UPDATE` on this table, so a resolve issued with
  a filter somebody forgot would otherwise answer, or write, across every venue
  in the database — which is the exploit U4 measured on `employer_grants`.

  Not `FORCE`d, for the reason every other policy in this tree is not: the table
  is owned by the application's login role, so `HospitalityComs.Repo` — which is
  how the *worker* writes the request — bypasses it, while `employer_role`, which
  owns nothing, is bound. FORCE would bind the owner too, and the predicate
  raises wherever `app.employer_id` is unset, which is every person-side write
  there is.

  ## The two person-zone tables get no policy, and could not use one

  `declared_entries` and `attested_entry_disclosures` are person zone.
  `employer_role` holds nothing on either, the only accessor is
  `HospitalityComs.Repo` — which owns them and is therefore unbound by a policy
  that is not FORCEd — and the predicate would have to read `app.employer_id`,
  which is unset on every read they ever get. That is the reasoning
  `create_peer_graph` gives for its three, unchanged.

  ## The views get no policy either, and that is the whole of KTD3

  A view has no row-level security of its own; it has a `WHERE`. That is the
  point. `HospitalityComs.Repo` connects as a **superuser** on this deployment,
  and a superuser bypasses row-level security whether or not a policy is FORCEd
  — so an RLS-based hidden-entry rule would read as a tier in a migration and
  provide none in the database. `create_employer_visible_view` says the rest.

  Policies are granted to `PUBLIC` rather than `TO employer_role`, for U4's
  reason: `TO employer_role` writes a `pg_shdepend` row, those are cluster-global
  in effect, and the owner bypasses the policy regardless.
  """

  use Ecto.Migration

  # Table, and the column that has to equal the transaction's venue.
  @tenancy [{"correction_requests", "venue_id"}]

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
