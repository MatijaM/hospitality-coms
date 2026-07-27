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
  never run a scoped transaction the setting is undefined; on a *pooled*
  connection that has run one and committed, it exists and reads as the empty
  string, because `SET LOCAL` reverts a parameter to its prior value rather
  than undefining it. The second is the dangerous one — it is the state every
  connection in the pool is in after the first employer request — so the two
  are collapsed into one exception with one message.

  They are told apart by the two-argument `current_setting(name, true)`, which
  answers NULL for an undefined setting, and not by catching
  `undefined_object`. A PL/pgSQL block with an `EXCEPTION` clause allocates an
  implicit subtransaction on every entry, fired or not, and these functions are
  written for U9's per-row view qualifier: one subtransaction per row of every
  employer read, to handle a case that arises once per connection. Measured
  over 200,000 rows on this database, 320ms with the exception block against
  244ms without. Same behaviour, none of the cost.

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

  ## What the REVOKE does not reach, for U4

  `ALTER DEFAULT PRIVILEGES` is a separate mechanism and `REVOKE ALL ON TABLE`
  does not touch it. Measured: a default-privilege grant to `employer_role`
  survives the statements below and is inherited by every table created
  afterwards, so a single `ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT
  SELECT ON TABLES TO employer_role` would hand the employer role every
  person-zone table U10 adds, silently and retroactively-looking.

  Nothing sets one today, and this migration does not attempt to revoke a
  mechanism nobody used. The control is the sweep in
  `HospitalityComs.Zones.employer_privileges/1`, which asks about effective
  privilege and therefore catches a grant however it arrived. U4 is where this
  stops being theoretical.

  ## Why `down` does not CASCADE

  `DROP FUNCTION IF EXISTS` without `CASCADE` fails once U9's view depends on
  `app_current_employer_id()`. That is the intended behaviour rather than an
  oversight. `CASCADE` would drop somebody else's object as a side effect of
  rolling this one back, and the object in question is the employer-visible
  view — the thing the hidden-entry rule is enforced by. A rollback that
  quietly removes it is worse than a rollback that stops.

  Ecto rolls migrations back in reverse order, so U9's `down` drops its own
  view before this one runs and the ordinary path never meets the dependency.
  The path that does is somebody rolling back out of order, and that is exactly
  when a loud failure is worth having.
  """

  use Ecto.Migration

  # Written out deliberately; see the moduledoc. `HospitalityComs.BoundaryTest`
  # pins it against `HospitalityComs.Zones.person_zone_tables/0` as of today, so
  # that the day the two diverge is the day somebody is told, rather than the
  # day somebody notices.
  @person_zone_tables ~w(people people_tokens)

  @scoping_functions ["app_current_employer_id()", "app_current_instant()"]

  @doc """
  The tables this migration revoked, as it was written.

  A historical record rather than a live list, exposed so the proof suite can
  compare it with the classification instead of transcribing it a third time.
  """
  @spec person_zone_tables() :: [String.t()]
  def person_zone_tables, do: @person_zone_tables

  def up do
    Enum.each(@person_zone_tables, &revoke_all/1)

    execute(create_employer_id_function())
    execute(create_instant_function())
  end

  def down do
    # No CASCADE, deliberately; see the moduledoc.
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
      -- Two arguments: missing_ok. NULL for a setting that was never defined,
      -- rather than `undefined_object` and the per-row subtransaction an
      -- EXCEPTION block would cost to catch it.
      raw := current_setting('app.employer_id', true);

      IF raw IS NULL OR raw = '' THEN
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
      raw := current_setting('app.now', true);

      IF raw IS NULL OR raw = '' THEN
        RAISE EXCEPTION 'app.now is not set on this connection'
          USING HINT = 'employer reads run inside EmployerRepo.scoped_transaction/2';
      END IF;

      RETURN raw::timestamptz;
    END
    $fn$
    """
  end
end
