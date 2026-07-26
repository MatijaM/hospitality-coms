defmodule HospitalityComs.Repo.Migrations.GrantZones do
  @moduledoc """
  The zone grants: the one tier of the boundary whose violation is an error
  rather than a leak.

  ## What the REVOKE is and is not

  `employer_role` holds no privilege on `people` or `people_tokens` before this
  migration runs, because Postgres default-denies on a table owned by another
  role and nothing has ever granted it one. The statements below are therefore
  a declaration of intent rather than the thing currently holding the door
  shut, and it is worth saying so plainly: a test asserting the privilege is
  absent passes on a database this migration has never touched.

  It is still worth executing. `REVOKE` is the statement a later `GRANT ALL ON
  ALL TABLES IN SCHEMA public` has to be reconciled against, it is where a
  reader looks to find out what the employer role may not do, and it makes the
  intent survive somebody adding a convenience grant three units from now.
  `HospitalityComs.BoundaryTest` rolls this migration over a privilege that
  does exist, which is what proves these statements reach the objects they
  name.

  The table list is written out rather than read from `HospitalityComs.Zones`.
  A migration is a historical record of what was done to a database on a given
  day; wiring it to a module that later units will edit would make its
  behaviour change retroactively. Later units revoke their own tables, and the
  sweep in the proof suite — which *is* driven by `Zones` — is what catches a
  table nobody covered.

  ## The scoping functions

  `attested_entries` sits in the employer zone and is read by the employer only
  through an owner-privileged view, because the hidden-entry rule is per row
  and grants cannot express it (KTD3). That view filters on the employer and
  the instant of the current unit of work, both of which arrive as
  transaction-local settings written by
  `HospitalityComs.EmployerRepo.scoped_transaction/2`.

  These two functions are how the view will read them, and they exist in this
  migration rather than in U9's because the guarantee is this unit's: a read
  that escapes the wrapper must **raise** rather than resolve to NULL. A NULL
  would make the view return zero rows, which is indistinguishable from a
  worker who has disclosed nothing — the failure would look like an answer.

  Both cases raise, and they are genuinely two cases. On a connection that has
  never run a scoped transaction, `current_setting/1` raises
  `undefined_object`. On a *pooled* connection that has run one and committed,
  the setting still exists and reads as the empty string, because `SET LOCAL`
  reverts a parameter to its prior value rather than undefining it. The second
  is the dangerous one — it is the state every connection in the pool is in
  after the first employer request — so the two are collapsed into one
  exception with one message.

  One limit on that, measured rather than assumed, and U9 inherits it. Postgres
  evaluates a `STABLE` function in a qualifier per row, so a scan that yields no
  rows never calls it and the statement succeeds with an empty result. An
  escaped read of a *populated* relation raises; an escaped read of an empty one
  returns nothing, which is what a correctly scoped read of the same nothing
  would also return. The failure this prevents — a NULL silently filtering a
  populated table down to zero rows — is prevented.

  They are left with the `EXECUTE` that Postgres grants every new function to
  `PUBLIC`, and that is deliberate. Revoking it and granting `EXECUTE` to
  `employer_role` reads better and buys nothing: both functions do no more than
  return a setting the caller's own transaction wrote, and any role may already
  call `current_setting` on it directly. What the grant *would* buy is a row in
  `pg_shdepend` — and because roles are cluster-global while grants are
  database-local, one such row in any database in the cluster makes
  `DROP ROLE employer_role` fail in every other, which is exactly the
  reversibility `HospitalityComs.PostgresRolesTest` pins on U1's roles
  migration. A privilege that protects nothing is not worth spending that on.

  The tables are a different matter and U4 will have to spend it: the employer
  zone cannot be read without real grants on real tables. When it does, U1's
  down-migration test has to be reckoned with rather than discovered.
  """

  use Ecto.Migration

  # Written out deliberately; see the moduledoc.
  @person_zone_tables ~w(people people_tokens)

  @scoping_functions ["app_current_employer_id()", "app_current_instant()"]

  def up do
    Enum.each(@person_zone_tables, &revoke_all/1)

    execute(create_employer_id_function())
    execute(create_instant_function())
  end

  def down do
    Enum.each(@scoping_functions, &execute("DROP FUNCTION IF EXISTS #{&1}"))

    # The tables are deliberately not re-granted. The state this migration
    # found was no privilege at all, and restoring it means leaving it alone.
  end

  defp revoke_all(table) do
    execute("REVOKE ALL PRIVILEGES ON TABLE #{table} FROM employer_role")
  end

  defp create_employer_id_function do
    """
    CREATE OR REPLACE FUNCTION app_current_employer_id() RETURNS uuid
    LANGUAGE plpgsql
    STABLE
    AS $fn$
    DECLARE
      raw text;
    BEGIN
      BEGIN
        raw := current_setting('app.employer_id');
      EXCEPTION WHEN undefined_object THEN
        raw := '';
      END;

      IF raw = '' THEN
        RAISE EXCEPTION 'app.employer_id is not set on this connection'
          USING HINT = 'employer reads run inside EmployerRepo.scoped_transaction/2';
      END IF;

      RETURN raw::uuid;
    END
    $fn$
    """
  end

  defp create_instant_function do
    """
    CREATE OR REPLACE FUNCTION app_current_instant() RETURNS timestamptz
    LANGUAGE plpgsql
    STABLE
    AS $fn$
    DECLARE
      raw text;
    BEGIN
      BEGIN
        raw := current_setting('app.now');
      EXCEPTION WHEN undefined_object THEN
        raw := '';
      END;

      IF raw = '' THEN
        RAISE EXCEPTION 'app.now is not set on this connection'
          USING HINT = 'employer reads run inside EmployerRepo.scoped_transaction/2';
      END IF;

      RETURN raw::timestamptz;
    END
    $fn$
    """
  end
end
