defmodule HospitalityComs.Repo.Migrations.EnableEngagementRowLevelSecurity do
  @moduledoc """
  Venue tenancy on the three tables U5 adds, including the bridge.

  U4 measured the exploit this closes and closed it for its own three tables:
  everything holding one venue out of another's rows was a
  `where venue_id = ^scope.venue_id` written by hand, so a single statement that
  omitted it reached every row in the database. The same statement aimed at
  `engagements` would end every engagement at every venue, which is a worse
  version of the same accident — so the same policy goes on, on the same
  predicate, keyed on the same transaction-local setting.

  ## Why the bridge gets a venue policy, when it is not an employer-zone table

  Because the *employer's* view of it is per venue, and that is the only side
  the policy binds. `engagements` is classified `:shared` because it names a
  human and a venue in one row; what the classification decides is which
  privileges the employer role may hold, not which rows it may see once it holds
  them. Those are different questions and this is the answer to the second.

  The person's side is unaffected, and structurally so. `HospitalityComs.Repo`
  connects as the application's own login role, which owns these tables, and the
  policies are not `FORCE`d — so every person-zone read of the bridge, the claim
  that writes it, and U10's lifecycle context all bypass the policy, while
  `employer_role` (which owns nothing and holds no `BYPASSRLS`) is bound by it.
  One table, readable from both sides, with one predicate that only one of them
  meets. That asymmetry is the same one the grants already have.

  `FORCE ROW LEVEL SECURITY` would bind the owner too, and the predicate raises
  wherever `app.employer_id` is unset — which is every migration, every seed,
  every job attempt and the whole of the person's own zone. It would not make
  the boundary stronger; it would make the bridge unreadable from the side it
  exists to serve.

  ## `attested_entries` has a policy and no privileges

  Belt and braces, deliberately. `employer_role` holds nothing on that table
  (KTD3 — the employer reads U9's owner-privileged view), so the policy protects
  a door that is already locked. It goes on anyway for two reasons: the employer
  zone's rule in `HospitalityComs.BoundaryTest` is that *every* employer-zone
  table carries one, and a rule with an exception is a rule somebody argues
  with; and U9 has to decide what the view's own privileges are, which is easier
  to get right when the base table underneath it is already scoped.

  ## The policies are granted to PUBLIC

  For the reason U4 gave: `TO employer_role` would write a `pg_shdepend` row,
  and those are cluster-global in effect. `PUBLIC` costs nothing — the owner
  bypasses the policy regardless, and no other role can reach these tables.
  """

  use Ecto.Migration

  # Table, and the column that has to equal the transaction's venue.
  @tenancy [
    {"invitations", "venue_id"},
    {"engagements", "venue_id"},
    {"attested_entries", "venue_id"}
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
