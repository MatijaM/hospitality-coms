defmodule HospitalityComs.Repo.Migrations.BoundEmployerLoginConnections do
  @moduledoc """
  Puts U1's two caps where Postgres will actually read them: on the role
  `HospitalityComs.EmployerRepo` **logs in as**.

  Issue #45. U1's `create_postgres_roles` wrote

      ALTER ROLE employer_role SET statement_timeout = '5s'
      ALTER ROLE employer_role SET idle_in_transaction_session_timeout = '10s'

  and its moduledoc called them part of the time model rather than
  housekeeping. **Neither has ever taken effect.** Role-level settings live in
  `pg_db_role_setting` and are applied at connection start for the *session
  user*; `SET ROLE` changes the current user and re-reads nothing. `EmployerRepo`
  reaches `employer_role` by assumption and never by login, so both caps sat in
  the catalogue and bounded nothing. Measured on a live connection before this
  migration:

      current_user  | session_user   | statement_timeout | idle_in_transaction…
      --------------|----------------|-------------------|---------------------
      employer_role | employer_login | 0                 | 0

  That is the same shape as KTD3's finding about row-level security: a control
  that is real in the catalogue and absent at runtime, which is worse than no
  control at all, because the catalogue is where somebody checks.

  #17 is what makes the fix a one-liner. Before it there was no login role to
  put a setting on — the employer connection authenticated as the application's
  own superuser, and a cap there would have bounded the migrator and the seeds
  too. `employer_login` exists now, it authenticates for `EmployerRepo` and for
  nothing else, so a setting on it reaches exactly the connections the caps were
  written for and no others.

  ## Why the numbers did not move

  They were chosen against an imagined workload and this is the first time they
  have run, so they were re-measured rather than re-asserted. Across a full
  suite on a clean cluster with `log_min_duration_statement = 0`:

    * the longest statement on an `employer_login` connection is **39.7 ms** — a
      `SELECT … FOR UPDATE` that `venues_concurrency_test.exs` parks on a lock
      deliberately, so it is the longest by construction rather than by
      accident;
    * the longest stretch one of those connections spends idle inside a
      transaction is **0.324 s**, sampled from `pg_stat_activity`.

  Roughly 125x headroom on the statement cap and 30x on the idle cap. Issue #45
  asks specifically about the retention sweep and the demo's `run_due_work/0`,
  both of which do bounded-but-large deletes; neither is bounded by anything
  here, because **neither touches `EmployerRepo`**. `HospitalityComs.Lifecycle`
  runs as the application's own role by design — an erasure crosses venues,
  which is what no employer session may do — and `employer_role` holds no
  `DELETE` anywhere. Its largest single statement, the 500-row `insert_all`
  chunk `retention_sweeper_test.exs` drives 6600 messages through, takes 10 ms,
  on `Repo`.

  ## Cluster-wide rather than `IN DATABASE`

  `employer_login` serves this application and nothing else, so a
  database-scoped setting would buy a distinction with no second case. Neither
  spelling writes a `pg_shdepend` row — settings live in `pg_db_role_setting`
  and are removed with the role — so this migration adds nothing to the
  cluster-wide dependency surface issue #20 is about, exactly as U1's own
  `ALTER ROLE` did not.

  ## U1's settings on `employer_role` are left where they are

  They are inert and they cost nothing, and removing them would be a change to
  a committed migration's meaning made for tidiness. They also stop being inert
  the day somebody gives `employer_role` `LOGIN`, which is a thing an operator
  might do before reading this file. What changes is the claim made about them:
  `HospitalityComs.PostgresRolesTest` asserts them as a catalogue entry and now
  says that is all they are, and the *behavioural* claim is asserted against a
  live connection by `HospitalityComs.BoundaryTest`.

  ## `down`, and why this is in `HospitalityComs.PostgresRolesTest`'s list

  `down` resets both settings, restoring the state this migration found.

  It joins that test's rollback list for #17's reason rather than for a
  `pg_shdepend` one. `DROP ROLE employer_login` takes its settings with it
  silently, and re-applying `create_employer_login_role`'s `up` does not restore
  them — the role that comes back is a fresh one carrying nothing. So a login
  role dropped underneath this migration leaves a credential that authenticates,
  assumes nothing, and is unbounded, with no error anywhere to say so. Listing
  it keeps the unwind in an order where that cannot happen.
  """

  use Ecto.Migration

  alias HospitalityComs.Zones

  # The pair U1 chose, re-measured rather than re-asserted. See the moduledoc.
  @statement_timeout "5s"
  @idle_in_transaction_timeout "10s"

  def up do
    role = Zones.employer_login_role()

    execute("ALTER ROLE #{role} SET statement_timeout = '#{@statement_timeout}'")

    execute(
      "ALTER ROLE #{role} SET idle_in_transaction_session_timeout = '#{@idle_in_transaction_timeout}'"
    )
  end

  def down do
    role = Zones.employer_login_role()

    execute("ALTER ROLE #{role} RESET idle_in_transaction_session_timeout")
    execute("ALTER ROLE #{role} RESET statement_timeout")
  end
end
