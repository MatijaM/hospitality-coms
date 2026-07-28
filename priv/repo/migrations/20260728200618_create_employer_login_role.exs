defmodule HospitalityComs.Repo.Migrations.CreateEmployerLoginRole do
  @moduledoc """
  Gives `HospitalityComs.EmployerRepo` a login identity of its own, so the
  grant tier stops being one `RESET ROLE` deep.

  Issue #17. U1 created `employer_role` and granted it `TO CURRENT_USER`,
  because the application assumed the role with `SET ROLE` rather than logging
  in as it — which meant the connection's *session user* was still the
  application's own role: a superuser that owns every table and view in this
  database. `SET ROLE` is undone by `RESET ROLE`, and raw
  `EmployerRepo.query!/3` reaches Postgres without passing either of the two
  BEAM guards, so:

      EmployerRepo.query!("RESET ROLE", [])
      EmployerRepo.query!("SELECT email FROM people", [])

  worked. A tier that application code can switch off from the same position as
  the tiers above it is not a tier below them; it is the same one. The docs said
  so plainly and `HospitalityComs.BoundaryTest` pinned it as a known property
  rather than pretending otherwise. This migration is the fix, and that test is
  now inverted.

  ## The role

  `employer_login`: `LOGIN`, `NOINHERIT`, a member of `employer_role` and of no
  other role, holding no privilege on any object.

  **`NOINHERIT` is the load-bearing word.** Both spellings close the escape;
  they do not close it equally. Measured on PostgreSQL 17, with a person-zone
  table the role must not read and an employer-zone table it must:

      login role  | after SET ROLE employer_role | after RESET ROLE
      ------------|------------------------------|-----------------------------
      INHERIT     | venues ok, people denied     | venues **ok**, people denied
      NOINHERIT   | venues ok, people denied     | venues **denied**, people denied

  Under `INHERIT` the login role *is* `employer_role` at all times, the
  `after_connect` `SET ROLE` is decoration, and a privilege granted to the login
  role by some later migration would widen the employer zone with nothing in the
  sweep to notice — because the sweep asks about `employer_role`. Under
  `NOINHERIT` the login role carries the right to *become* `employer_role` and
  nothing else, so escaping costs the caller the employer zone as well. That is
  what makes "after `RESET ROLE`, `venues` is denied" an assertion with a
  mechanism behind it.

  ## What is deliberately not granted

  Nothing. Not `CONNECT` on the database, not `USAGE` on the schema — both come
  from `PUBLIC`, and a grant of its own would write a `pg_shdepend` row.
  Grants are database-local while roles are cluster-global, so one such row
  would make `DROP ROLE employer_login` fail in every *other* database on this
  cluster, which is the hazard issue #20 is about. Measured:
  `GRANT employer_role TO employer_login` writes no `pg_shdepend` row at all,
  because role membership lives in `pg_auth_members`. This migration therefore
  adds nothing to that surface, and `HospitalityComs.BoundaryTest` asserts it
  with a control.

  ## A migration may create a role. It may not mint a secret.

  The password is read from `HospitalityComs.EmployerRepo.config/0` — the one
  place that cannot disagree with what the application actually connects with,
  whether the environment spells its credentials as `username:`/`password:` or
  as a `url:` — and it is written **only when the role does not already exist**.

    * In dev, test and CI the role is absent, so it is created with the literal
      from `config/dev.exs` and `config/test.exs`. That literal sits beside the
      `postgres`/`postgres` already in those files; it is not a secret and never
      was, and one `mix ecto.setup` bootstraps a working database.

    * In production the operator provisions `employer_login` with a real
      password out of band first. This migration finds it, skips the create,
      and issues only the `GRANT`. **The secret never reaches a migration and
      therefore never reaches the Postgres statement log**, which
      `log_statement = 'ddl'` would otherwise capture verbatim.

  If production does *not* pre-provision, the role is created from
  `EMPLOYER_DATABASE_URL` — still the operator's own secret, now logged. Hence
  the documented path.

  What is *not* a secret is re-asserted on every `up`: `LOGIN` and `NOINHERIT`
  are applied with `ALTER ROLE` whether the role was found or created, so a
  pre-provisioned role that got them wrong is corrected rather than trusted.

  ## `down`, and why it is listed in `HospitalityComs.PostgresRolesTest`

  `down` revokes the membership and drops the role, restoring the state this
  migration found. It joins that test's rollback list for a reason unlike every
  other entry's, and the reason is measured rather than inferred: a membership
  writes no `pg_shdepend` row, so `DROP ROLE employer_role` does **not** fail
  while `employer_login` is a member of it — it removes the membership silently,
  and re-applying U1's `up` does not restore it, because the role that comes
  back is a fresh one with no members.

  So rolling U1 back underneath a live login role is not a loud failure that
  gets fixed. It leaves a credential that can still authenticate and can no
  longer assume anything, and `EmployerRepo` cannot open a connection until
  somebody re-runs this migration. Listing it keeps the unwind in an order where
  that cannot happen, and the property itself is pinned as a test.

  ## What this migration does not touch

  U1 set `statement_timeout` and `idle_in_transaction_session_timeout` on
  `employer_role` and called them part of the time model. **They have never
  taken effect**, measured: role-level settings from `pg_db_role_setting` are
  applied at login for the *session user*, and `SET ROLE` does not re-apply
  them. Logging in as the application's role and assuming `employer_role`
  reports `statement_timeout = 0`.

  Putting them on `employer_login` is what would make them effective, and that
  is a behaviour change #17 did not ask for with real risk attached — a
  ten-second idle-in-transaction cap on a sandbox connection that holds a
  transaction open for the length of a test is a flake generator, and four test
  files park real connections on real locks deliberately. The finding is
  recorded in `CLAUDE.md`; acting on it is its own ticket. This migration sets
  no role-level setting, and `HospitalityComs.BoundaryTest` asserted that, so it
  could not be enabled as a side effect.

  **That ticket is issue #45 and it has landed**, in
  `*_bound_employer_login_connections.exs`, which is the migration that puts
  both caps on this role. The flake risk was measured rather than reasoned about
  — twenty consecutive runs of the four parking files with the caps live, and no
  statement cancelled — and the assertion named above is inverted there, against
  a live connection rather than against `pg_roles`. This migration still sets no
  role-level setting, and still should not: a credential's attributes and a
  connection's budget are two changes with two reasons, and #45's `down` has to
  be able to lift the budget without dropping the credential.
  """

  use Ecto.Migration

  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Zones

  def up do
    execute(&create_login_role/0, &noop/0)
    execute("GRANT #{Zones.employer_role()} TO #{Zones.employer_login_role()}")
  end

  def down do
    execute("REVOKE #{Zones.employer_role()} FROM #{Zones.employer_login_role()}")
    execute("DROP ROLE IF EXISTS #{Zones.employer_login_role()}")
  end

  # The existence check is in Elixir rather than in a `DO $$` block because a
  # `DO` block takes no parameters, and the password must not be pasted into a
  # statement by hand. Postgres escapes it instead: `quote_literal` is the same
  # function `format('%L', ...)` calls, so a password containing a quote is
  # handled by the server that will parse it rather than by string surgery here.
  defp create_login_role do
    role = Zones.employer_login_role()

    role
    |> existing()
    |> create_unless_present(role)

    # Whether found or created. These are the security-relevant attributes and
    # they are not secrets, so a pre-provisioned role is corrected rather than
    # trusted to have got them right.
    repo().query!("ALTER ROLE #{role} WITH LOGIN NOINHERIT", [])
  end

  defp existing(role) do
    %{rows: rows} = repo().query!("SELECT 1 FROM pg_roles WHERE rolname = $1", [role])
    rows
  end

  defp create_unless_present([_row], _role), do: :ok

  defp create_unless_present([], role) do
    repo().query!("CREATE ROLE #{role} LOGIN NOINHERIT#{password_clause()}", [])
  end

  # `EmployerRepo.config/0` re-resolves from the application environment and
  # does not require the repo to be started — which it is not during
  # `mix ecto.migrate`, since `:ecto_repos` names the primary repo alone.
  defp password_clause do
    EmployerRepo.config() |> Keyword.get(:password) |> literal_clause()
  end

  # No password configured is the pre-provisioned case: create the role without
  # a `PASSWORD` clause rather than with an empty one, which would be a
  # different thing entirely.
  defp literal_clause(nil), do: ""

  defp literal_clause(password) do
    %{rows: [[literal]]} = repo().query!("SELECT quote_literal($1)", [password])
    " PASSWORD #{literal}"
  end

  # `execute/2` needs both directions, and the role's removal is `down`'s second
  # statement, so this half has nothing to undo.
  defp noop, do: :ok
end
