defmodule HospitalityComs.BoundaryTest do
  @moduledoc """
  The proof suite for the boundary the product's central claim rests on.

  Several things hold an employer session away from person data, and only one
  of them produces an error rather than a leak when it is violated: the
  Postgres grants. This file asserts that tier against `has_table_privilege`
  and `has_any_column_privilege` — the privilege bits themselves — rather than
  against an error response, because an error response is evidence that *this*
  query was refused and the privilege bit is evidence that every query is.

  ## What this suite does not claim

  It does not claim the grants are a tier *below* the BEAM guards, reachable
  only by somebody with a psql prompt. `EmployerRepo` logs in as the
  application's own role and assumes `employer_role` on connect, so one
  `RESET ROLE` over a raw `query/3` — which no guard sees — puts every
  privilege back. "the escapes neither guard closes" pins all three, so they
  are a decision on the record rather than a discovery somebody makes later.

  What the whole boundary is strong against is *accident*: a join added three
  units from now, a context function called from the wrong zone, a forgotten
  filter. It is not strong against a caller who means to get out, and no test
  here pretends otherwise.

  ## Why half of this file is about the tests rather than about the boundary

  `employer_role` holds no privilege on `people` today in part because no
  migration ever granted it one: Postgres default-denies on a table owned by
  another role. So "assert the privilege is absent" passes whether or not this
  unit's migration does anything, and a suite that cannot tell those two apart
  is decoration with a green tick on it.

  Every assertion here that could pass for the wrong reason therefore ships
  with a control that fails when it does:

    * the sweep is handed a privilege behind its back and has to catch it;
    * the migration is rolled over a privilege that exists and has to remove
      it, which is the only test that proves its `REVOKE` statements execute;
    * the foreign-key rule is vacuous while the employer zone is empty, so its
      query has to find the one foreign key that does exist;
    * the query backstop has to *not* refuse a query it has no business
      refusing.

  Roles and grants are cluster-global rather than database-local, so every
  test that grants or revokes runs inside the sandbox transaction and is rolled
  back even when it fails.
  """

  # `EmployerRepo` needs a sandbox owner of its own, and the migration tests
  # move schema state, so nothing here is async.
  use ExUnit.Case, async: false

  # Migration files are not compiled into the application, so the compiler
  # cannot see them. `setup_all` is what puts them in memory.
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.GrantZones}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.GrantEmployerZone}
  @compile {:no_warn_undefined,
            HospitalityComs.Repo.Migrations.EnableEmployerZoneRowLevelSecurity}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.CreateVenues}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.CreateEngagements}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.GrantEngagementZone}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.EnableEngagementRowLevelSecurity}

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Repo
  alias HospitalityComs.Repo.Migrations.CreateEngagements
  alias HospitalityComs.Repo.Migrations.CreateVenues
  alias HospitalityComs.Repo.Migrations.EnableEmployerZoneRowLevelSecurity
  alias HospitalityComs.Repo.Migrations.EnableEngagementRowLevelSecurity
  alias HospitalityComs.Repo.Migrations.GrantEmployerZone
  alias HospitalityComs.Repo.Migrations.GrantEngagementZone
  alias HospitalityComs.Repo.Migrations.GrantZones
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Zones

  # Association shapes that do not exist in the application yet, declared at the
  # bottom of this file. See the comment there for why they are not in
  # `test/support`.
  alias __MODULE__.Venue

  @migration_name "grant_zones"
  @employer_zone_migration "grant_employer_zone"
  @row_security_migration "enable_employer_zone_row_level_security"
  @employer_tables_migration "create_venues"
  @engagement_tables_migration "create_engagements"
  @engagement_zone_migration "grant_engagement_zone"
  @engagement_row_security_migration "enable_engagement_row_level_security"

  # The employer-zone table U5 added that `employer_role` deliberately holds no
  # privilege on. KTD3: hidden attested entries are a per-row rule, which grants
  # cannot express, so the employer reads U9's owner-privileged view and never
  # the base table.
  @ungranted_tables ["attested_entries"]

  # The queue's own tables. They belong to `oban` rather than to this
  # application, there is no Ecto schema for them in `:hospitality_coms`, and
  # `employer_role` holds nothing on either — which "are none at all on the
  # queue's tables either" asserts with the same sweep that audits the person
  # zone, so the exclusion below is a decision with a test behind it rather than
  # a hole.
  #
  # No job this application enqueues carries a `person_id` in its args, which
  # `HospitalityComs.EngagementsTest` and
  # `HospitalityComs.Workers.EngagementSweeperTest` both assert. KTD2's rule
  # about where a human may be named does not stop at the schemas this
  # application owns.
  @queue_tables ~w(oban_jobs oban_peers)

  @now ~U[2026-03-01 12:00:00.000000Z]

  @scoping_functions ["app_current_employer_id()", "app_current_instant()"]

  # The predicate U9's view will carry, written the way a view carries it.
  @employer_filter "app_current_employer_id()::text"

  # Migration files are not compiled into the application, so the module has to
  # be loaded before the migrator can be handed it directly — unless the
  # migrator has already loaded it on the way in, which is what happens the
  # first time this runs against a database where the migration is pending.
  setup_all do
    load_migration(@migration_name, Code.ensure_loaded?(GrantZones))
    load_migration(@employer_zone_migration, Code.ensure_loaded?(GrantEmployerZone))

    load_migration(
      @row_security_migration,
      Code.ensure_loaded?(EnableEmployerZoneRowLevelSecurity)
    )

    load_migration(@employer_tables_migration, Code.ensure_loaded?(CreateVenues))
    load_migration(@engagement_tables_migration, Code.ensure_loaded?(CreateEngagements))
    load_migration(@engagement_zone_migration, Code.ensure_loaded?(GrantEngagementZone))

    load_migration(
      @engagement_row_security_migration,
      Code.ensure_loaded?(EnableEngagementRowLevelSecurity)
    )

    :ok
  end

  setup do
    repo_owner = Sandbox.start_owner!(Repo, shared: true)
    employer_owner = Sandbox.start_owner!(EmployerRepo, shared: true)

    on_exit(fn ->
      Sandbox.stop_owner(employer_owner)
      Sandbox.stop_owner(repo_owner)
    end)
  end

  describe "the employer role's privileges on the person zone" do
    test "are none, across every person-zone table and every table privilege" do
      assert Zones.employer_privileges(Repo) == []
    end

    test "are swept over a list that names the tables that matter" do
      # The sweep above is satisfied by an empty table list. This is what says
      # it looked at anything, and at the two tables whose exposure would end
      # the argument: the person row, and the bearer credentials that stand
      # for it.
      assert "people" in Zones.person_zone_tables()
      assert "people_tokens" in Zones.person_zone_tables()
    end

    test "are reported by the sweep when one is granted behind its back" do
      # The load-bearing control. Without it, every assertion in this describe
      # block passes on a database where the grant migration was never written,
      # because Postgres default-denies and the absence looks identical.
      Repo.query!("GRANT SELECT ON people TO employer_role")

      assert {"people", "SELECT"} in Zones.employer_privileges(Repo)
    end

    test "are reported per privilege, so a write grant is caught as well as a read" do
      Repo.query!("GRANT INSERT, UPDATE ON people_tokens TO employer_role")

      offences = Zones.employer_privileges(Repo)

      assert {"people_tokens", "INSERT"} in offences
      assert {"people_tokens", "UPDATE"} in offences
      refute {"people_tokens", "SELECT"} in offences
    end

    test "are reported when the grant is on one column rather than on the table" do
      # The blind spot every other control in this block shares. Measured:
      #
      #   GRANT SELECT (email) ON people TO employer_role;
      #   has_table_privilege('employer_role','people','SELECT')      -> f
      #   has_any_column_privilege('employer_role','people','SELECT') -> t
      #
      # A sweep asking only the first question reported nothing while the
      # employer role could read every worker's address — and no control above
      # could fail on it, because they all grant at table level.
      Repo.query!("GRANT SELECT (email) ON people TO employer_role")

      assert {"people", "SELECT"} in Zones.employer_privileges(Repo)
    end

    test "are reported for a column grant on a write privilege too" do
      Repo.query!("GRANT UPDATE (email) ON people TO employer_role")

      offences = Zones.employer_privileges(Repo)

      assert {"people", "UPDATE"} in offences
      refute {"people", "SELECT"} in offences
    end

    test "cover MAINTAIN, which the sweep asks about and PostgreSQL 17 answers" do
      # The list the sweep asks about is the whole of what Postgres can grant on
      # a table, and MAINTAIN is part of that on 17. This is also where a
      # PostgreSQL older than 17 fails: `has_table_privilege` answers
      # `unrecognized privilege type` there rather than false.
      Repo.query!("GRANT MAINTAIN ON people TO employer_role")

      assert {"people", "MAINTAIN"} in Zones.employer_privileges(Repo)
    end
  end

  describe "the grant migration" do
    test "removes a privilege that exists rather than restating an absence" do
      Repo.query!("GRANT SELECT ON people TO employer_role")
      assert {"people", "SELECT"} in Zones.employer_privileges(Repo)

      round_trip_grant_zones(fn -> :nothing_in_between end)

      assert Zones.employer_privileges(Repo) == []
    end

    test "cannot be rolled back under a live row-level security policy, and says which" do
      # The RESTRICT `grant_zones` chose deliberately, meeting its first
      # dependent object. The employer zone's tenancy policies are written on
      # `app_current_employer_id()`, so rolling the function out from under
      # them stops rather than dropping them silently with CASCADE — and a
      # policy that disappears during a rollback is a tenancy boundary that
      # disappears with it.
      #
      # Ecto rolls migrations back in reverse, so the ordinary path never
      # reaches this. The path that does is an out-of-order rollback, which is
      # exactly when a loud failure is worth having.
      assert_raise Postgrex.Error, ~r/dependent_objects_still_exist/, fn -> migrate(:down) end
    end

    test "leaves privileges in the same state when rolled back and forward" do
      before = privilege_snapshot()

      rolled_back =
        round_trip_grant_zones(fn ->
          # The snapshot's `tables` component is `[]` before and `[]` after
          # unless something puts a privilege in the way of the round trip, so
          # without this the table half of the comparison was `[] == []` and
          # only the function half carried any weight — a REVOKE round trip
          # that never exercised a REVOKE.
          Repo.query!("GRANT SELECT, INSERT ON people TO employer_role")
          privilege_snapshot()
        end)

      assert {"people", "SELECT"} in rolled_back.tables
      assert privilege_snapshot() == before

      # And the round trip went somewhere. Comparing two identical nothings
      # would pass on a migration whose `up` and `down` were both empty.
      refute rolled_back == before
    end

    test "creates both scoping functions, callable by the employer role" do
      Enum.each(@scoping_functions, fn function ->
        assert function_privilege(function) == true
      end)
    end

    test "is not what makes them callable, and the predicate can say so" do
      # The control the test above needs, and the correction to what its name
      # used to claim. `has_function_privilege` is true because Postgres grants
      # EXECUTE on every new function to PUBLIC — not because this migration
      # granted anything, which it deliberately does not: a grant would put a
      # row in `pg_shdepend` and make `DROP ROLE employer_role` fail across the
      # cluster. So the assertion above proves the functions exist. This is
      # what says the predicate behind it can answer false at all.
      [function | _rest] = @scoping_functions

      Repo.query!("REVOKE EXECUTE ON FUNCTION #{function} FROM PUBLIC")

      assert function_privilege(function) == false
    end

    test "revoked the tables the classification calls the person zone today" do
      # The migration writes its table list out rather than reading `Zones`,
      # and that is right: a migration is a record of what was done to a
      # database on a given day, and wiring it to a module later units will
      # edit would make its behaviour change retroactively.
      #
      # Nothing said the two agreed, though, so a person-zone table added to
      # `Zones` without a REVOKE of its own would be caught only by the sweep,
      # and only once somebody granted something. This says it now.
      assert Enum.sort(GrantZones.person_zone_tables()) ==
               Enum.sort(Zones.person_zone_tables())
    end

    test "spends no cluster-wide dependency of its own" do
      # This is U3's canary, adapted rather than retired. Its claim was that
      # *this* migration creates no `pg_shdepend` row, because roles are
      # cluster-global while grants are database-local and one such row in any
      # database makes `DROP ROLE employer_role` fail in every other. It said
      # so as `== 0` over the whole cluster, which was the right spelling while
      # nothing anywhere had been granted.
      #
      # U4 grants for real and U5 grants more, so the bare count now measures
      # them rather than this migration. Rolling their grants back restores the
      # original question, and the claim survives intact: `grant_zones` leaves
      # the employer role with nothing depending on it. What the later units
      # spend, and what it buys, is asserted in "the employer-zone grants"
      # below.
      revoke_zone_grants()

      assert dependent_objects() == [],
             """
             `grant_zones` now leaves cluster-wide dependencies behind: \
             #{inspect(dependent_objects())}

             It is not supposed to grant anything. Its scoping functions are \
             left with the EXECUTE that Postgres gives PUBLIC precisely so \
             that no `pg_shdepend` row is written for them.
             """
    end
  end

  describe "the employer-zone grants" do
    # The other half of the boundary, and the half that had no tests before U4
    # because the employer zone had no tables. The person-zone assertions are
    # about an absence; these are about an inventory, and an inventory is worth
    # pinning exactly: these grants are what makes `DROP ROLE employer_role`
    # fail across the cluster, so a privilege nobody exercises is a cost
    # nobody chose.

    test "are exactly the privileges the employer zone's code exercises" do
      # In the order the sweep walks the zone, which is the order the
      # classification lists it in. `attested_entries` is in that list and
      # contributes nothing, which is KTD3 rather than an omission.
      assert employer_zone_privileges() == [
               {"venues", "SELECT"},
               {"venues", "INSERT"},
               {"employer_grants", "SELECT"},
               {"employer_grants", "INSERT"},
               {"employer_grants", "UPDATE"},
               {"shift_types", "SELECT"},
               {"shift_types", "INSERT"},
               {"invitations", "SELECT"},
               {"invitations", "INSERT"}
             ]
    end

    test "are exactly the privileges the bridge's code exercises" do
      # `engagements` is the shared zone, so the sweep above does not reach it,
      # and it is the one table where the employer role's exact privileges
      # matter most: it names a human.
      #
      # **No INSERT.** An engagement is created only by the person claiming a
      # code, running as the application's own role, so no employer session
      # anywhere can manufacture a worker.
      assert Zones.privileges(Repo, Zones.shared_tables()) == [
               {"engagements", "SELECT"},
               {"engagements", "UPDATE"}
             ]
    end

    test "give UPDATE on three columns of engagements rather than on the table" do
      # Renewal and ending write `ends_at`, `lock_version` and `updated_at`. A
      # table-level UPDATE would also let a session move an engagement to
      # another person or another venue, or rewrite the grant it holds — which
      # are exactly the cross-boundary writes the single-crossing rule exists
      # to make unrepresentable.
      refute table_privilege?("engagements", "UPDATE")

      assert updatable_columns("engagements") == ["ends_at", "lock_version", "updated_at"]
    end

    test "are none at all on the attested entries base table" do
      # KTD3, asserted rather than described. The hidden-entry rule is per row
      # and grants cannot express it, so the employer reads U9's
      # owner-privileged view; a grant here would be the view's whole purpose
      # walked around, and nothing else in this file would notice.
      assert Zones.privileges(Repo, @ungranted_tables) == []
    end

    test "are none at all on the queue's tables either" do
      # `oban_jobs` and `oban_peers` belong to the library rather than to the
      # application, so they are in no zone and
      # `HospitalityComs.ZonesTest` never sees them — they are named in this
      # file's infrastructure exclusion list instead. This is what makes that
      # exclusion honest: the same sweep that audits the person zone, pointed
      # at the two tables the exclusion covers.
      assert Zones.privileges(Repo, @queue_tables) == []
    end

    test "include no DELETE, and deletion is a different context's business" do
      # Named separately from the inventory above because it is a rule rather
      # than a list: deletion is confined to the lifecycle context (KTD21),
      # which runs as the application's own role. A DELETE here would make an
      # employer session able to destroy rows the retention design commits to
      # keeping.
      privileges = Enum.map(employer_zone_privileges(), fn {_table, privilege} -> privilege end)

      refute "DELETE" in privileges
      refute "TRUNCATE" in privileges
      refute "MAINTAIN" in privileges
    end

    test "give UPDATE on three columns of employer_grants rather than on the table" do
      # Revocation writes `revoked_at`, `revoked_by_grant_id` and
      # `updated_at`. A table-level UPDATE would also let a session move a
      # grant to another venue or rewrite its lineage, which are cross-tenant
      # writes wearing an administrative hat — so the grant is column-scoped,
      # and this is what says so rather than the migration's own comment.
      refute table_privilege?("employer_grants", "UPDATE")

      assert updatable_columns("employer_grants") == [
               "revoked_at",
               "revoked_by_grant_id",
               "updated_at"
             ]
    end

    test "are the only thing the employer role depends on in this database" do
      # The number `HospitalityComs.PostgresRolesTest` has to roll back before
      # it can drop the role, expressed as the objects rather than as a count:
      # a count of five is satisfied by five grants on `people`.
      assert dependent_objects() == dependent_zone_tables()
    end

    test "are what the check above would notice growing" do
      # The control. Without it the assertion passes on a query that cannot see
      # a dependency at all, which is the same green tick as a boundary that
      # holds.
      Repo.query!("GRANT SELECT ON people TO employer_role")

      assert "table people" in dependent_objects()
    end

    test "are what it would notice growing on something that is not a table, too" do
      # The blind spot the control above shares with every other one in this
      # file: they all grant on a table. This query used to carry
      # `classid = 'pg_class'::regclass`, which drops every dependency on a
      # function, a sequence or a type — and a GRANT on a function writes a
      # `pg_shdepend` row exactly like a GRANT on a table does, and makes
      # `DROP ROLE employer_role` fail exactly as hard. Measured: the grant
      # below was invisible to the filtered query while the role could not be
      # dropped.
      #
      # U4 narrowed U3's canary in two ways. The `current_database()` scoping
      # was forced — `objid` only resolves in the database that owns it — and
      # this filter was not. Names come from `pg_describe_object/3` now, which
      # resolves every class rather than one.
      Repo.query!("GRANT EXECUTE ON FUNCTION app_current_employer_id() TO employer_role")

      assert "function app_current_employer_id()" in dependent_objects()
    end

    test "are removed by the migrations' own downs, leaving the role clean" do
      # Which is what makes U1's rollback reachable again, and the only test
      # that proves the REVOKE statements execute and reach the objects they
      # name.
      revoke_zone_grants()

      assert employer_zone_privileges() == []
      assert Zones.privileges(Repo, Zones.shared_tables()) == []
      assert dependent_objects() == []
    end

    test "are restored by rolling the migrations back and forward" do
      before = employer_zone_privileges() ++ Zones.privileges(Repo, Zones.shared_tables())

      revoke_zone_grants()
      rolled_back = employer_zone_privileges() ++ Zones.privileges(Repo, Zones.shared_tables())
      capture_log(&restore_zone_grants/0)

      assert employer_zone_privileges() ++ Zones.privileges(Repo, Zones.shared_tables()) ==
               before

      refute rolled_back == before
    end

    test "grant on every table the classification places outside the person zone" do
      # Two migrations now, and one table deliberately left out of both. The
      # union has to be the whole of the employer and shared zones: a table
      # added to `Zones` with no grant of its own and no entry in
      # `@ungranted_tables` is a table somebody forgot to decide about, and this
      # is where they find out rather than at the first query that returns
      # `permission denied`.
      granted = GrantEmployerZone.granted_tables() ++ GrantEngagementZone.granted_tables()

      assert Enum.sort(granted ++ @ungranted_tables) ==
               Enum.sort(Zones.employer_zone_tables() ++ Zones.shared_tables())
    end

    test "do not arrive through ALTER DEFAULT PRIVILEGES, which nothing sweeps" do
      # The hole U3 measured and left for this unit. A default-privilege grant
      # survives `REVOKE ALL ON TABLE` and is inherited by every table created
      # afterwards, so one of these would hand `employer_role` every
      # person-zone table U10 adds — silently, and looking retroactive. The
      # column-aware sweep catches the *effect* on tables it knows about; this
      # catches the mechanism, including for tables nobody has written yet.
      assert default_privilege_grantees() == []
    end

    test "are what the check above would notice, since nothing else sweeps it" do
      # The control, rolled back with the sandbox transaction like every other
      # DDL in this file.
      Repo.query!(
        "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO employer_role"
      )

      assert Zones.employer_role() in default_privilege_grantees()
    end
  end

  describe "the employer zone's tables" do
    test "are removed by their own migration's down and restored by its up" do
      # `grant_employer_zone` has had a rollback test since it was written and
      # the migration that creates the tables has not, which is the half of
      # "reversible" only a rollback proves: a `down` nobody runs is a `down`
      # nobody has read carefully, and this one drops two self-referential
      # foreign keys by hand before it can drop the table they are on.
      assert MapSet.subset?(employer_zone_tables(), database_tables())
      assert "employer_grants_granted_by_fkey" in foreign_keys("employer_grants")
      assert "employer_grants_revoked_by_fkey" in foreign_keys("employer_grants")
      assert "employer_grants" in tables_with_composite_key()

      rolled_back =
        round_trip_employer_zone(fn ->
          %{
            tables: MapSet.intersection(employer_zone_tables(), database_tables()),
            foreign_keys: foreign_keys("employer_grants"),
            composite_key?: "employer_grants" in tables_with_composite_key()
          }
        end)

      assert MapSet.to_list(rolled_back.tables) == []
      assert rolled_back.foreign_keys == []
      refute rolled_back.composite_key?

      assert MapSet.subset?(employer_zone_tables(), database_tables())
      assert "employer_grants_granted_by_fkey" in foreign_keys("employer_grants")
      assert "employer_grants_revoked_by_fkey" in foreign_keys("employer_grants")
      assert "employer_grants" in tables_with_composite_key()
    end

    test "come back with the privileges and the policies written on them" do
      # The other half of the round trip, and the reason it rolls all three
      # migrations rather than one: a table restored without its grants is a
      # table `employer_role` cannot read, and one restored without its policy
      # is a table every venue can read.
      #
      # The rolled-back state is not asked about here: `Zones.privileges/2`
      # raises on a table that does not exist, deliberately, so that a zone
      # naming a table nobody migrated fails loudly instead of sweeping
      # nothing. The absence is asserted in the test above.
      before = employer_zone_privileges()
      refute before == []

      round_trip_employer_zone(fn -> :nothing_in_between end)

      assert employer_zone_privileges() == before
      assert Enum.reject(row_security_flags(), fn {_table, %{enabled: on}} -> on end) == []
    end
  end

  describe "the employer zone's row-level security" do
    # The tier the employer zone had none of. Venue-to-venue isolation rested
    # entirely on `HospitalityComs.Venues` pinning `venue_id` on every query,
    # so a single `EmployerRepo.update_all(EmployerGrant, ...)` with no filter
    # passed the unscoped guard, passed the zone guard, passed Postgres, and
    # revoked every grant in the database.
    #
    # KTD3 chose a view over RLS for the per-row hidden-entry rule, and that
    # decision stands: a view has no `FORCE` to forget. This is table-wide
    # tenancy, which is the case RLS is actually for — one predicate, the same
    # one already written into every query, moved somewhere a forgotten filter
    # cannot get past it.

    test "hides another venue's grants from a query with no filter at all" do
      first = venue_with_grant()
      second = venue_with_grant()

      assert unfiltered_grant_ids(first) == [first.grant.id]
      assert unfiltered_grant_ids(second) == [second.grant.id]
    end

    test "hides another venue's own row, and its shift types" do
      first = venue_with_grant()
      second = venue_with_grant()

      assert unfiltered_venue_ids(first) == [first.venue.id]
      assert unfiltered_venue_ids(second) == [second.venue.id]

      shift_type = shift_type_at(second)

      assert unfiltered_shift_type_ids(first) == []
      assert unfiltered_shift_type_ids(second) == [shift_type.id]
    end

    test "bounds an unfiltered update to the venue the transaction is scoped to" do
      # The exploit stated as itself. Before the policy this call revoked
      # every grant at every venue in one statement and orphaned all of them.
      first = venue_with_grant()
      second = venue_with_grant()

      assert {count, _returned} = revoke_everything(first)

      assert count == 1
      assert unfiltered_grant_ids(second) == [second.grant.id]
      assert [%EmployerGrant{revoked_at: nil}] = live_grants_of(second)
    end

    test "refuses an insert aimed at a venue the transaction is not scoped to" do
      # `WITH CHECK` rather than `USING`: the row would be invisible after it
      # landed, which is worse than a refusal. Every insert the context
      # performs takes `venue_id` from the scope, so this costs it nothing.
      first = venue_with_grant()
      second = venue_with_grant()

      assert_raise Postgrex.Error, ~r/row-level security policy/, fn ->
        EmployerRepo.scoped_transaction(scope_of_venue(first), fn scope ->
          {:ok,
           EmployerRepo.insert!(
             EmployerGrant.issued_changeset(
               second.venue.id,
               second.grant.id,
               scope.now
             )
           )}
        end)
      end
    end

    test "is enabled on every employer-zone table, with one tenancy policy each" do
      flags = row_security_flags()

      assert Enum.sort(Map.keys(flags)) == Enum.sort(Zones.employer_zone_tables())
      assert Enum.reject(flags, fn {_table, %{enabled: on}} -> on end) == []

      Enum.each(Zones.employer_zone_tables(), fn table ->
        assert [[_name, qual, with_check]] = policies_on(table)
        assert qual =~ "app_current_employer_id()"
        assert with_check =~ "app_current_employer_id()"
      end)
    end

    test "covers the bridge too, which the classification alone would not require" do
      # `engagements` is `:shared`, so the rule asserted above — every
      # *employer-zone* table carries a policy — says nothing about it. It
      # carries one anyway, and it has to: `employer_role` holds SELECT and a
      # column-scoped UPDATE on it, so a single `update_all` with no filter
      # would end every engagement at every venue. That is the exploit U4
      # measured, aimed at the one table that names a human.
      #
      # Structural only, here. Populating the bridge needs a person and a venue
      # visible to the *same* connection, and this file holds two sandbox
      # transactions that cannot see each other's rows —
      # `HospitalityComs.EngagementsTest` runs unsandboxed and asserts the
      # policy's behaviour there.
      flags = row_security_flags(Zones.shared_tables())

      assert Map.keys(flags) == ["engagements"]
      assert Enum.reject(flags, fn {_table, %{enabled: on}} -> on end) == []

      assert [[_name, qual, with_check]] = policies_on("engagements")
      assert qual =~ "app_current_employer_id()"
      assert with_check =~ "app_current_employer_id()"
    end

    test "is not FORCEd, because the owner is the migrator and the application's own repo" do
      # Deliberate, and the reason this is safe to add to tables three
      # migrations already touch. The tables belong to the application's login
      # role, so `Repo`, every migration and every seed bypass the policies
      # while `employer_role` — a non-owner — is bound by them. FORCE would
      # bind the owner too, and a policy keyed on `app_current_employer_id()`
      # raises wherever that setting is unset, which is all of them.
      assert Enum.reject(row_security_flags(), fn {_table, %{forced: on}} -> not on end) == []
    end
  end

  describe "the classification against the database it describes" do
    test "every table in the database is in a zone" do
      # `Zones.all_schemas/0` finds Ecto schemas, and totality in
      # `HospitalityComs.ZonesTest` is total over those. A migration can create
      # a table with no schema module — a `many_to_many` join table, an audit
      # log, a backing table for a view — and that table is invisible from
      # there while being just as much person data. Postgres is asked here
      # instead of the module list.
      unclassified = unclassified_tables()

      assert MapSet.to_list(unclassified) == [],
             """
             These tables exist in the database and are in no zone: \
             #{inspect(MapSet.to_list(unclassified))}

             A table with no Ecto schema is invisible to the totality check in \
             HospitalityComs.ZonesTest. Classify it in HospitalityComs.Zones, \
             behind a schema if it has rows the application reads and behind \
             an entry in this test's exclusion list if it is infrastructure.
             """
    end

    test "an unclassified table is what the check above would report" do
      # The control. Rolled back with the sandbox transaction, like every other
      # DDL in this file.
      Repo.query!("CREATE TABLE stowaway (id uuid PRIMARY KEY)")

      assert "stowaway" in unclassified_tables()
    end

    test "the classification names tables the database actually has" do
      # And the other direction: a zone naming a table nobody migrated would
      # make the sweep raise, but nothing said so out loud.
      assert MapSet.subset?(MapSet.new(Zones.classified_tables()), database_tables())
    end
  end

  describe "the bridge" do
    test "is the only crossing: no employer-zone table holds a foreign key to people" do
      offenders = MapSet.intersection(tables_referencing_people(), employer_zone_tables())

      assert MapSet.to_list(offenders) == [],
             """
             These employer-zone tables hold a foreign key to `people`: \
             #{inspect(MapSet.to_list(offenders))}

             KTD2 permits exactly one crossing, `engagements.person_id`, and \
             the employer zone is on the far side of it. An employer-zone row \
             that names a person is a second crossing, and it puts a worker's \
             identity in rows the employer role can read in bulk. Reference \
             `engagements (id, venue_id)` instead, or record the association \
             from the bridge's side.
             """
    end

    test "is engagements, and it is the only crossing that exists" do
      # The positive form, which only became assertable when U5 built the
      # bridge. "No employer-zone table references `people`" is satisfied by a
      # schema with no crossings at all; what KTD2 actually claims is that there
      # is exactly one, and that it is this one.
      crossings =
        MapSet.difference(tables_referencing_people(), MapSet.new(Zones.person_zone_tables()))

      assert MapSet.to_list(crossings) == ["engagements"],
             """
             The tables outside the person zone that hold a foreign key to \
             `people` are #{inspect(MapSet.to_list(crossings))}.

             KTD2 permits exactly one, `engagements.person_id`. A second makes \
             the single-bridge claim false, puts the erasure blast radius \
             across the boundary in more than one place, and gives an employer \
             a way to reach a human without an engagement. Reference \
             `engagements (id, venue_id)` instead.
             """
    end

    test "holds its person key non-null and refuses to cascade a delete through it" do
      # KTD15. Erasure pseudonymises the person row in place rather than
      # deleting it, and both halves of that decision are written here:
      # `NOT NULL` so the exclusion constraint keeps working on an erased
      # person, and `ON DELETE RESTRICT` so an accidental delete raises instead
      # of taking a worker's whole employment record across the boundary with
      # it. `SET NULL` would drop the engagement out of overlap enforcement
      # entirely; `CASCADE` would destroy the record the design commits to
      # keeping.
      assert bridge_key() == %{nullable: false, on_delete: "r"}
    end

    test "enforces the overlap rule with the exclusion constraint the changeset names" do
      # R3, and the reason the constraint is named rather than left to
      # Postgres. `HospitalityComs.Engagements.Engagement` declares an
      # `exclusion_constraint/3` against this exact atom; without the match the
      # violation raises through the transaction and the repository's
      # enumerated errors stop being true at the one place it is load bearing.
      assert to_string(Engagement.overlap_constraint()) in exclusion_constraints("engagements")
    end

    test "is looked for with a query that finds the foreign keys that exist" do
      # The rule above was vacuously true while the employer zone was empty.
      # This is what makes it a tripwire rather than a no-op: the query does
      # resolve real referencing tables.
      assert "people_tokens" in tables_referencing_people()
    end

    test "is checked against an employer zone that is not empty" do
      # The other half of the same vacuity. An intersection with the empty set
      # is empty whatever the query returns, so the rule above says nothing at
      # all until there are employer-zone tables to say it about.
      refute Enum.empty?(Zones.employer_zone_tables())
    end

    test "leaves every employer-zone table carrying a venue key" do
      # The positive form of the rule. "No person key" is satisfied by a table
      # with no keys at all; what KTD2 asks for is that every employer-zone row
      # is reachable *only* by way of a venue. `venues` is exempt because its
      # own id is that key.
      assert without_venue_key() == []
    end

    test "gives every referenceable employer-zone table a unique (id, venue_id)" do
      # The composite-key discipline, asserted rather than remembered. It looks
      # redundant next to a primary key on `id` and it is what makes a
      # composite foreign key possible: without it, a later table can only say
      # `REFERENCES employer_grants (id)`, and a row at venue A can point at a
      # grant belonging to venue B.
      assert without_composite_key() == []
    end

    test "finds those indexes by a query that resolves the ones that exist" do
      # The control for both structural checks: a query that matched nothing
      # would report every table as compliant.
      assert "employer_grants" in tables_with_composite_key()
      assert "shift_types" in tables_with_composite_key()
    end
  end

  describe "the transaction wrapper" do
    test "writes the employer and the instant where the view will read them" do
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, {employer_id, instant}} =
               EmployerRepo.scoped_transaction(scope, fn _scope ->
                 %{rows: [[employer_id, instant]]} =
                   EmployerRepo.query!(
                     "SELECT app_current_employer_id()::text, app_current_instant()",
                     []
                   )

                 {:ok, {employer_id, instant}}
               end)

      assert employer_id == scope.venue_id
      assert DateTime.compare(instant, @now) == :eq
    end

    test "hands the scope to the work, so the instant travels rather than being read again" do
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, ^scope} = EmployerRepo.scoped_transaction(scope, &{:ok, &1})
    end

    test "refuses to open a second employer's scope inside the first" do
      # There is no savepoint between the two. Before this refusal existed the
      # inner `set_config` overwrote `app.employer_id` for the rest of the
      # shared transaction and nothing put it back, so the outer work carried on
      # reading as the inner employer.
      outer = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      inner = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert_raise EmployerRepo.NestedScopeError, ~r/already in force/, fn ->
        EmployerRepo.scoped_transaction(outer, fn _scope ->
          EmployerRepo.scoped_transaction(inner, fn _scope -> {:ok, :leaked} end)
        end)
      end
    end

    test "refuses before the second employer's scope reaches the connection" do
      # The refusal is only worth anything if it arrives first. This is the
      # assertion that would have caught the leak: after the nested call, the
      # connection still answers with the outer employer.
      outer = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      inner = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, resolved} =
               EmployerRepo.scoped_transaction(outer, fn _scope ->
                 assert_raise EmployerRepo.NestedScopeError, fn ->
                   EmployerRepo.scoped_transaction(inner, fn _scope -> {:ok, :leaked} end)
                 end

                 {:ok, current_employer_id()}
               end)

      assert resolved == outer.venue_id
      refute resolved == inner.venue_id
    end

    test "allows an identical scope to be entered again, writing nothing" do
      # The control for the refusal above: it must refuse a *conflict*, not
      # nesting. An identical scope would write the two settings that are
      # already there, so there is nothing to leak and nothing to refuse.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, {inner, after_inner}} =
               EmployerRepo.scoped_transaction(scope, fn _scope ->
                 {:ok, inner} =
                   EmployerRepo.scoped_transaction(scope, fn _scope ->
                     {:ok, current_employer_id()}
                   end)

                 {:ok, {inner, current_employer_id()}}
               end)

      assert inner == scope.venue_id
      assert after_inner == scope.venue_id
    end

    test "leaves nothing behind for the next caller after the refusal" do
      # The refusal must not strand the process dictionary in a state where the
      # unscoped guard waves the next operation through.
      outer = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      inner = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert_raise EmployerRepo.NestedScopeError, fn ->
        EmployerRepo.scoped_transaction(outer, fn _scope ->
          EmployerRepo.scoped_transaction(inner, fn _scope -> {:ok, :leaked} end)
        end)
      end

      assert_raise EmployerRepo.UnscopedError, fn ->
        EmployerRepo.all(from(c in "pg_class", select: c.relname, limit: 1))
      end
    end

    test "lets a query the employer is entitled to run through" do
      # The control for everything below: a backstop that refused everything
      # would pass every refusal test in this file and ship a repo nobody can
      # use.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, [_relname | _rest]} =
               EmployerRepo.scoped_transaction(scope, fn _scope ->
                 {:ok, EmployerRepo.all(from(c in "pg_class", select: c.relname, limit: 3))}
               end)
    end
  end

  describe "an employer read outside the wrapper" do
    test "raises rather than running unscoped" do
      assert_raise EmployerRepo.UnscopedError, ~r/scoped_transaction/, fn ->
        EmployerRepo.all(from(c in "pg_class", select: c.relname, limit: 1))
      end
    end

    test "raises for a write too, not only for a read" do
      assert_raise EmployerRepo.UnscopedError, ~r/scoped_transaction/, fn ->
        EmployerRepo.insert_all("pg_class", [%{relname: "nope"}])
      end
    end

    test "raises even inside a bare transaction that set no scope" do
      assert_raise EmployerRepo.UnscopedError, ~r/scoped_transaction/, fn ->
        EmployerRepo.transaction(fn ->
          EmployerRepo.all(from(c in "pg_class", select: c.relname, limit: 1))
        end)
      end
    end

    test "leaves the scoping functions raising rather than resolving to NULL" do
      # A NULL here is the failure mode the one-argument `current_setting`
      # exists to prevent: the view would return no rows, and no rows is
      # indistinguishable from a worker who has disclosed nothing.
      assert_raise Postgrex.Error, ~r/app\.employer_id is not set/, fn ->
        EmployerRepo.query!("SELECT app_current_employer_id()", [])
      end

      assert_raise Postgrex.Error, ~r/app\.now is not set/, fn ->
        EmployerRepo.query!("SELECT app_current_instant()", [])
      end
    end
  end

  describe "the shape the employer-visible view is built on" do
    # U9 owns the view itself. What it will filter on exists now, because the
    # guarantee is this unit's: an escaped read must raise rather than resolve
    # to NULL and return no rows, which is indistinguishable from a worker who
    # has disclosed nothing.
    test "a read outside the wrapper raises where there is anything to return" do
      unscoped = "SELECT c.relname FROM pg_class c WHERE c.oid::text = #{@employer_filter}"

      assert_raise Postgrex.Error, ~r/app\.employer_id is not set/, fn ->
        EmployerRepo.query!(unscoped, [])
      end
    end

    test "a read outside the wrapper that scans nothing returns nothing" do
      # The honest edge of the guarantee, pinned so U9 inherits it as a known
      # fact rather than as a surprise. Postgres evaluates the scoping function
      # per row, so a scan that yields none never calls it and the statement
      # succeeds — with an empty result, which is what a correctly scoped read
      # of the same nothing would also return. The failure mode the one-argument
      # `current_setting` exists to prevent is a *populated* relation filtered
      # down to nothing by a NULL, and that is the test above.
      empty = """
      SELECT t.x FROM (SELECT 1 AS x WHERE false) t WHERE t.x::text = #{@employer_filter}
      """

      assert %{rows: []} = EmployerRepo.query!(empty, [])
    end

    test "a read inside the wrapper resolves the scope's employer" do
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, [[resolved]]} =
               EmployerRepo.scoped_transaction(scope, fn _scope ->
                 %{rows: rows} =
                   EmployerRepo.query!("SELECT app_current_employer_id()::text", [])

                 {:ok, rows}
               end)

      assert resolved == scope.venue_id
    end
  end

  describe "the query backstop" do
    test "refuses a person-zone table named as the query's source" do
      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(from(p in Person, select: p.id))
      end
    end

    test "refuses one named as a string rather than as a schema" do
      assert_raise EmployerRepo.ZoneViolationError, ~r/people_tokens/, fn ->
        employer_query(from(t in "people_tokens", select: t.id))
      end
    end

    test "refuses one reached through an explicit join" do
      query = from(c in "pg_class", join: p in Person, on: true, select: p.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through an association join" do
      # The join's source is nil until the planner resolves it, so a backstop
      # reading `source` alone would wave this through.
      query = from(t in PersonToken, join: p in assoc(t, :person), select: p.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a subquery" do
      query = from(p in subquery(from(p in Person, select: %{id: p.id})), select: p.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a subquery in a where" do
      # Ecto does not put an expression subquery in the binding list. It parks
      # it on a `:subqueries` field of the `where` clause, which a walker
      # reading bindings alone never opens — measured: of eight shapes, only
      # from-position, CTE, union and association joins were refused.
      query =
        from(c in "pg_class",
          where: c.relname in subquery(from(p in Person, select: p.email)),
          select: c.relname
        )

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a subquery in a select" do
      query =
        from(c in "pg_class", select: %{n: subquery(from(p in Person, select: count(p.id)))})

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a subquery in a having" do
      query =
        from(c in "pg_class",
          group_by: c.relname,
          having: count(c.oid) > subquery(from(p in Person, select: count(p.id))),
          select: c.relname
        )

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a subquery in an order_by or a group_by" do
      ordered =
        from(c in "pg_class",
          order_by: [asc: subquery(from(p in Person, select: count(p.id)))],
          select: c.relname
        )

      grouped =
        from(c in "pg_class",
          group_by: subquery(from(p in Person, select: count(p.id))),
          select: c.relname
        )

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn -> employer_query(ordered) end
      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn -> employer_query(grouped) end
    end

    test "does not refuse an expression subquery that reaches nothing forbidden" do
      # The control for the four above. A walker that refused every query
      # carrying a `:subqueries` field would pass all of them.
      query =
        from(c in "pg_class",
          where: c.oid in subquery(from(n in "pg_namespace", select: n.oid)),
          select: c.relname,
          limit: 1
        )

      assert {:ok, _rows} = employer_query(query)
    end

    test "refuses one reached through a common table expression" do
      query =
        "pg_class"
        |> with_cte("hidden", as: ^from(p in Person, select: %{id: p.id}))
        |> select([c], c.relname)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "refuses one reached through a union" do
      query =
        from(p in Person, select: %{id: p.id})
        |> union(^from(t in PersonToken, select: %{id: t.id}))

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(from(c in "pg_class", select: %{id: c.oid}) |> union(^query))
      end
    end

    test "raises inside the BEAM rather than letting Postgres produce the error" do
      # The distinction the plan asks for. A `Postgrex.Error` would mean the
      # statement was sent and refused; this exception means it was never sent,
      # and the message names the table rather than the connection's role.
      error =
        assert_raise EmployerRepo.ZoneViolationError, fn ->
          employer_query(from(p in Person, select: p.id))
        end

      refute is_struct(error, Postgrex.Error)
      assert error.message =~ "person zone"
    end

    test "does not see a write, which Postgres refuses instead" do
      # The documented hole, asserted rather than described. Ecto has no
      # insert-path hook that sees a table, so this statement is sent — and
      # refused by the grant tier, with a message about the connection's role
      # rather than about the zone. This is what it looks like when the only
      # tier that is a guarantee is the one doing the work.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      stamped_at = DateTime.truncate(@now, :second)

      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.scoped_transaction(scope, fn _scope ->
          {:ok,
           EmployerRepo.insert!(%Person{
             email: "smuggled@example.com",
             inserted_at: stamped_at,
             updated_at: stamped_at
           })}
        end)
      end
    end

    test "refuses one reached through a has_many :through" do
      # `Ecto.Association.HasThrough` carries no `:related` key at all, only a
      # chain of association names, so reading `.related` off it raised
      # `KeyError` from inside the backstop — closed, but saying nothing, and
      # closed for a legitimate join as much as for this one. The chain is
      # walked now, and every table it passes through is checked.
      query = from(v in Venue, join: p in assoc(v, :people), select: p.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        employer_query(query)
      end
    end

    test "does not refuse a has_many :through that stays inside the employer zone" do
      # The control, and the regression the clause above would otherwise be:
      # before it, *every* `:through` join raised, whatever it reached.
      query = from(v in Venue, join: s in assoc(v, :shifts_through), select: s.id)

      assert {_query, _opts} = EmployerRepo.prepare_query(:all, query, [])
    end

    test "refuses one whose many_to_many join table is in the person zone" do
      # The related schema is innocent here. `join_through` is the table the
      # query actually reaches, and the backstop never looked at it.
      query = from(v in Venue, join: s in assoc(v, :smuggled_shifts), select: s.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people_tokens/, fn ->
        employer_query(query)
      end
    end

    test "does not refuse a many_to_many whose join table is not" do
      query = from(v in Venue, join: s in assoc(v, :shifts), select: s.id)

      assert {_query, _opts} = EmployerRepo.prepare_query(:all, query, [])
    end

    test "refuses an association join it cannot resolve rather than crashing on it" do
      # An unresolvable association is an association that cannot be placed in
      # a zone. The refusal names the field instead of raising `KeyError` from
      # somewhere in the walker.
      query = from(v in Venue, join: x in assoc(v, :nonexistent), select: x.id)

      assert_raise EmployerRepo.ZoneViolationError, ~r/is not an association/, fn ->
        employer_query(query)
      end
    end

    test "refuses an update_all, a delete_all and a stream, not only an all" do
      # `prepare_query/3`'s spec names five operations and only `:all` was ever
      # exercised. A hook Ecto stopped calling for one of the others would have
      # left that path open with every test in this file still green.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        EmployerRepo.scoped_transaction(scope, fn _scope ->
          {:ok, EmployerRepo.update_all(from(p in Person), set: [email: nil])}
        end)
      end

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        EmployerRepo.scoped_transaction(scope, fn _scope ->
          {:ok, EmployerRepo.delete_all(from(p in Person))}
        end)
      end

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        EmployerRepo.scoped_transaction(scope, fn _scope ->
          {:ok, from(p in Person, select: p.id) |> EmployerRepo.stream() |> Enum.to_list()}
        end)
      end
    end

    test "refuses an insert_all whose rows come from a person-zone query" do
      # The one insert path that carries a query, and therefore the one the
      # zone guard can see at all. The struct path below it cannot be.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      rows = from(p in Person, select: %{relname: p.email})

      assert_raise EmployerRepo.ZoneViolationError, ~r/people/, fn ->
        EmployerRepo.scoped_transaction(scope, fn _scope ->
          {:ok, EmployerRepo.insert_all("pg_class", rows)}
        end)
      end
    end

    test "does not refuse the same operations when they reach nothing forbidden" do
      # The control for the five above. A backstop that refused every
      # non-`:all` operation would pass all of them.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      allowed = from(c in "pg_class", select: c.relname, limit: 1)

      assert {:ok, [_relname]} =
               EmployerRepo.scoped_transaction(scope, fn _scope ->
                 {:ok, allowed |> EmployerRepo.stream() |> Enum.to_list()}
               end)

      assert {_query, _opts} = EmployerRepo.prepare_query(:update_all, allowed, [])
      assert {_query, _opts} = EmployerRepo.prepare_query(:delete_all, allowed, [])
      assert {_query, _opts} = EmployerRepo.prepare_query(:insert_all, allowed, [])
    end

    test "does not refuse the same query issued through the person zone's own repo" do
      # Which is what says the query is well formed and the refusal above is the
      # boundary rather than a typo.
      assert Repo.all(from(p in Person, select: p.id)) == []
    end
  end

  describe "the escapes neither guard closes" do
    # Pinned rather than described. A hole nobody asserts is a hole somebody
    # closes by accident and reopens by accident, and two of these are load
    # bearing: the wrapper is built on the first, and the third is the honest
    # limit of what the whole boundary claims.

    test "raw SQL outside the wrapper is not refused, and must not be" do
      # Ecto dispatches `query/3`, `query!/3`, `query_many/3` and `to_sql/3`
      # straight to `Ecto.Adapters.SQL` without consulting
      # `default_options/1`, so the unscoped guard never sees them.
      #
      # This is the exemption the wrapper comes in through: `write_settings/1`
      # is a raw query issued before the scope is registered, so a `query/3`
      # that went through the guard could never satisfy it. Closing this would
      # close the door.
      assert %{rows: [[1]]} = EmployerRepo.query!("SELECT 1", [])
    end

    test "raw SQL inside the wrapper skips the zone guard and is left to Postgres" do
      # `prepare_query/3` sees an `Ecto.Query`. A string is not one, so the
      # only thing between this statement and `people` is the grant.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.scoped_transaction(scope, fn _scope ->
          {:ok, EmployerRepo.query!("SELECT id FROM people", [])}
        end)
      end
    end

    test "RESET ROLE gives back every privilege the grants were withholding" do
      # The grant tier is one `SET ROLE` deep. Connections log in as the
      # application's own role and assume `employer_role` on connect, and
      # `GRANT employer_role TO CURRENT_USER` from U1 is what lets them — so
      # the login role is still there to go back to, and raw SQL is how you get
      # at it.
      #
      # This is not a tier below the BEAM guards. It is the same tier: code
      # that means to get out, gets out. What the boundary is strong against is
      # accident. Closing it needs `EmployerRepo` to log in as a role of its
      # own, which is infrastructure rather than code and is filed separately.
      #
      # The role is restored by the sandbox: `SET ROLE` is transactional, and
      # every connection here is inside a transaction that is rolled back.
      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.query!("SELECT count(*) FROM people", [])
      end

      EmployerRepo.query!("RESET ROLE", [])

      assert %{rows: [[_count]]} = EmployerRepo.query!("SELECT count(*) FROM people", [])

      EmployerRepo.query!("SET ROLE #{Zones.employer_role()}", [])

      # And back, on this connection, before it can be lent to anything else.
      # Without this the test above would leave an open door behind it and
      # every refusal in this file could start passing for the wrong reason.
      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.query!("SELECT count(*) FROM people", [])
      end
    end
  end

  describe "the scope-first shape, where it is used" do
    # Scoped down from "a person-zone context function", which is what this
    # block used to claim. `sudo_mode?/2` is the only function in `Accounts`
    # that takes a scope; the rest take a bare address, a bare token or a bare
    # `DateTime`, so an employer caller reaches them with `employer_scope.now`
    # and no clause refuses. What is asserted here is that the shape works
    # where it is used — not that the person zone is closed by it.

    test "refuses an employer scope by function clause" do
      # Not a runtime check inside the body. The refusal is the absence of a
      # matching head, so it happens before the function runs and it happens
      # whether or not whoever wrote the function remembered to guard it.
      assert_raise FunctionClauseError, fn -> Accounts.sudo_mode?(scope(:employer)) end
    end

    test "accepts a person scope, including an anonymous one" do
      # Without this the test above passes on a function that refuses
      # everything, which is not the same guarantee at all.
      refute Accounts.sudo_mode?(scope(:person))
    end

    test "is not what keeps an employer caller out of the person zone" do
      # The honest counterpart, pinned so the claim above cannot quietly grow
      # back. An employer caller holds an `EmployerScope` and nothing else, and
      # `get_person_by_email/1` takes no scope at all — so there is no clause
      # to refuse it, and the address comes back. `Accounts` goes through
      # `Repo`, which holds every privilege. What closes the zone is the grant
      # on `EmployerRepo`'s role; the argument shape is legibility.
      employer = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      {:ok, person} = Accounts.register_person(%{email: "reachable@example.com"}, employer.now)

      assert %Person{id: id} = Accounts.get_person_by_email(person.email)
      assert id == person.id
    end
  end

  ## Helpers

  ## The employer zone, built through its own context

  # The person is never persisted: no employer-zone table references `people`,
  # so the employer zone cannot tell the difference — which is the property,
  # and it keeps this block off the person zone's sandbox connection.
  defp venue_with_grant do
    scope = PersonScope.for_person(%Person{id: Ecto.UUID.generate()}, @now)
    attrs = %{name: "rls-#{System.unique_integer([:positive])}", timezone: "Etc/UTC"}

    {:ok, creation} = Venues.create_venue(scope, attrs)
    creation
  end

  defp shift_type_at(%{venue: venue} = creation) do
    {:ok, shift_type} =
      Venues.create_shift_type(scope_of_venue(creation), venue.id, %{
        name: "Open",
        grace_period_minutes: 0
      })

    shift_type
  end

  defp scope_of_venue(%{venue: venue, grant: grant}) do
    EmployerScope.for_grant(venue.id, grant.id, @now)
  end

  # Deliberately unfiltered. The whole point is that nothing in the query says
  # which venue, so what answers is the policy rather than the context.
  defp unfiltered_grant_ids(creation) do
    as_employer(creation, fn ->
      EmployerRepo.all(from(g in "employer_grants", select: type(g.id, Ecto.UUID)))
    end)
  end

  defp unfiltered_venue_ids(creation) do
    as_employer(creation, fn ->
      EmployerRepo.all(from(v in "venues", select: type(v.id, Ecto.UUID)))
    end)
  end

  defp unfiltered_shift_type_ids(creation) do
    as_employer(creation, fn ->
      EmployerRepo.all(from(s in "shift_types", select: type(s.id, Ecto.UUID)))
    end)
  end

  defp live_grants_of(%{venue: venue} = creation) do
    as_employer(creation, fn ->
      EmployerRepo.all(EmployerGrant.live_at(venue.id, @now))
    end)
  end

  defp revoke_everything(%{grant: grant} = creation) do
    as_employer(creation, fn ->
      EmployerRepo.update_all(EmployerGrant,
        set: [revoked_at: @now, revoked_by_grant_id: grant.id]
      )
    end)
  end

  defp as_employer(creation, fun) do
    {:ok, result} =
      EmployerRepo.scoped_transaction(scope_of_venue(creation), fn _scope -> {:ok, fun.()} end)

    result
  end

  defp row_security_flags(tables \\ Zones.employer_zone_tables()) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = ANY($1::text[])
        """,
        [tables]
      )

    Map.new(rows, fn [table, enabled, forced] -> {table, %{enabled: enabled, forced: forced}} end)
  end

  defp policies_on(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT policyname, qual, with_check
        FROM pg_policies
        WHERE schemaname = 'public' AND tablename = $1
        ORDER BY 1
        """,
        [table]
      )

    rows
  end

  # The employer the *connection* is scoped to, as the view will read it, which
  # is the only side of the wrapper that can leak.
  defp current_employer_id do
    %{rows: [[id]]} = EmployerRepo.query!("SELECT app_current_employer_id()::text", [])
    id
  end

  # Runs a query the way the application will: inside the wrapper, so that what
  # refuses it is the zone rule and not the absence of a scope.
  defp employer_query(query) do
    scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)
    EmployerRepo.scoped_transaction(scope, fn _scope -> {:ok, EmployerRepo.all(query)} end)
  end

  # Handed out of a map so the value's type is the union of both scopes rather
  # than one of them. Written inline, Elixir 1.20 proves at compile time that
  # `sudo_mode?/1` has no clause matching an employer scope and warns at the
  # call site — the guarantee holding a step earlier than this file can assert
  # it. That is a good warning and a bad test: a scope built at run time from a
  # session carries no such proof, and it is the run-time refusal that the
  # boundary rests on.
  defp scope(kind) do
    Map.fetch!(
      %{
        person: PersonScope.for_person(nil, @now),
        employer: EmployerScope.for_employer(Ecto.UUID.generate(), @now)
      },
      kind
    )
  end

  # The sandbox lends this test a single connection, so the migrator's own
  # locking transaction would deadlock against the migration it is guarding.
  # The lock exists to serialise concurrent deployers; there are none here.
  @migrator_opts [log: false, migration_lock: false]

  defp migrate(direction) do
    apply(Ecto.Migrator, direction, [
      Repo,
      migration_version(@migration_name),
      GrantZones,
      @migrator_opts
    ])
  end

  defp migrate_employer_zone(direction) do
    apply(Ecto.Migrator, direction, [
      Repo,
      migration_version(@employer_zone_migration),
      GrantEmployerZone,
      @migrator_opts
    ])
  end

  defp migrate_employer_tables(direction) do
    apply(Ecto.Migrator, direction, [
      Repo,
      migration_version(@employer_tables_migration),
      CreateVenues,
      @migrator_opts
    ])
  end

  # U5's three, in the order they were applied. `rolled_back_engagement_zone/1`
  # unwinds them in reverse.
  @engagement_migrations [
    {@engagement_tables_migration, CreateEngagements},
    {@engagement_zone_migration, GrantEngagementZone},
    {@engagement_row_security_migration, EnableEngagementRowLevelSecurity}
  ]

  defp migrate_engagement_zone({name, module}, direction) do
    apply(Ecto.Migrator, direction, [Repo, migration_version(name), module, @migrator_opts])
  end

  # U5's migrations rolled off and put back, around `between`.
  #
  # `engagements` references `venues`, `employer_grants` and `people`, and its
  # policies are written on `app_current_employer_id()` — so every rollback in
  # this file that used to reach a table or a function now has to come through
  # here first. That is the same growth U4 forced on U3, one unit further along,
  # and the list is a record of what the bridge depends on.
  defp rolled_back_engagement_zone(between) do
    @engagement_migrations |> Enum.reverse() |> Enum.each(&migrate_engagement_zone(&1, :down))

    result = between.()

    capture_log(fn -> Enum.each(@engagement_migrations, &migrate_engagement_zone(&1, :up)) end)

    result
  end

  # The employer zone's migrations rolled in the order Ecto uses, which is
  # reverse: U5's come off before U4's, and the policies and privileges come off
  # before the tables they are written on.
  defp round_trip_employer_zone(between) do
    rolled_back_engagement_zone(fn ->
      migrate_row_security(:down)
      migrate_employer_zone(:down)
      migrate_employer_tables(:down)

      result = between.()

      capture_log(fn -> migrate_employer_tables(:up) end)
      capture_log(fn -> migrate_employer_zone(:up) end)
      capture_log(fn -> migrate_row_security(:up) end)

      result
    end)
  end

  defp foreign_keys(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.conname
        FROM pg_constraint c
        WHERE c.contype = 'f' AND c.conrelid = to_regclass($1)
        ORDER BY 1
        """,
        [table]
      )

    Enum.map(rows, &hd/1)
  end

  defp migrate_row_security(direction) do
    apply(Ecto.Migrator, direction, [
      Repo,
      migration_version(@row_security_migration),
      EnableEmployerZoneRowLevelSecurity,
      @migrator_opts
    ])
  end

  # The employer zone's row-level security policies are written on
  # `app_current_employer_id()`, and `grant_zones` drops that function with
  # RESTRICT on purpose. Ecto rolls migrations back in reverse, so the real
  # ordering is this one; a test that rolled `grant_zones` back on its own
  # would be testing an out-of-order rollback and getting the loud failure
  # that ordering exists to produce.
  defp round_trip_grant_zones(between) do
    rolled_back_engagement_zone(fn ->
      migrate_row_security(:down)
      migrate(:down)

      result = between.()

      capture_log(fn -> migrate(:up) end)
      capture_log(fn -> migrate_row_security(:up) end)

      result
    end)
  end

  defp migration_version(migration) do
    Repo
    |> Ecto.Migrator.migrations()
    |> Enum.find_value(fn {_status, version, name} -> name == migration && version end)
  end

  defp load_migration(_migration, true), do: :ok

  defp load_migration(migration, false) do
    Repo
    |> Ecto.Migrator.migrations_path()
    |> Path.join("*_#{migration}.exs")
    |> Path.wildcard()
    |> Enum.each(&Code.require_file/1)
  end

  # Everything the migration is responsible for, in one comparable value: the
  # employer role's effective privilege on every person-zone table, and its
  # execute privilege on each scoping function — with `nil` standing for a
  # function that does not exist, which is what the rolled-back state looks
  # like.
  defp privilege_snapshot do
    %{
      tables: Zones.employer_privileges(Repo),
      functions: Map.new(@scoping_functions, &{&1, function_privilege(&1)})
    }
  end

  defp function_privilege(signature) do
    %{rows: [[held]]} =
      Repo.query!(
        """
        SELECT CASE
                 WHEN to_regprocedure($1) IS NULL THEN NULL
                 ELSE has_function_privilege($2, to_regprocedure($1), 'EXECUTE')
               END
        """,
        [signature, Zones.employer_role()]
      )

    held
  end

  # Objects in this database that the employer role has a shared dependency
  # on. Every one is something that has to be revoked before `DROP ROLE` can
  # succeed — anywhere in the cluster, since the catalogue is cluster-wide.
  #
  # Scoped to `current_database()` and reported as names rather than as a
  # count, both deliberately. Names because a count of five is satisfied by
  # five grants on `people`; scoped because `objid` only resolves in the
  # database that owns it, so a row belonging to another database would come
  # back as a number or as somebody else's object.
  # `HospitalityComs.PostgresRolesTest` is where the rest of the cluster is
  # accounted for.
  #
  # Names come from `pg_describe_object/3` rather than from `objid::regclass`,
  # and there is no `classid` filter. The filtered form dropped every
  # dependency whose class was not `pg_class` — a grant on a function, a
  # sequence or a type — while `DROP ROLE` still failed on it. The
  # `current_database()` narrowing is forced by the catalogue; that one was
  # not.
  defp dependent_objects do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT pg_describe_object(d.classid, d.objid, 0)
        FROM pg_shdepend d
        JOIN pg_authid a ON a.oid = d.refobjid
        WHERE a.rolname = $1
          AND d.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
        ORDER BY 1
        """,
        [Zones.employer_role()]
      )

    Enum.map(rows, &hd/1)
  end

  # Every table a grant migration granted on, as `pg_describe_object/3` names
  # it, which is what `dependent_objects/0` reports.
  #
  # Read off the migrations rather than off the classification, because they are
  # not the same list any more and the difference is the point: the employer
  # role depends on what it was *granted*, and `attested_entries` is an
  # employer-zone table it was granted nothing on.
  defp dependent_zone_tables do
    (GrantEmployerZone.granted_tables() ++ GrantEngagementZone.granted_tables())
    |> Enum.map(&"table #{&1}")
    |> Enum.sort()
  end

  # Both grant migrations rolled off, in the order Ecto uses.
  defp revoke_zone_grants do
    migrate_engagement_zone({@engagement_zone_migration, GrantEngagementZone}, :down)
    migrate_employer_zone(:down)
  end

  defp restore_zone_grants do
    migrate_employer_zone(:up)
    migrate_engagement_zone({@engagement_zone_migration, GrantEngagementZone}, :up)
  end

  # The same sweep the person zone is audited with, pointed at the employer
  # zone. There it asserts an absence; here it asserts an inventory.
  defp employer_zone_privileges do
    Zones.privileges(Repo, Zones.employer_zone_tables())
  end

  defp table_privilege?(table, privilege) do
    %{rows: [[held]]} =
      Repo.query!("SELECT has_table_privilege($1, $2, $3)", [
        Zones.employer_role(),
        table,
        privilege
      ])

    held
  end

  defp updatable_columns(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.attname
        FROM pg_attribute a
        WHERE a.attrelid = to_regclass($1)
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND has_column_privilege($2, a.attrelid, a.attnum, 'UPDATE')
        ORDER BY a.attname
        """,
        [table, Zones.employer_role()]
      )

    Enum.map(rows, &hd/1)
  end

  # Roles named in any `ALTER DEFAULT PRIVILEGES` entry. The mechanism `REVOKE
  # ALL ON TABLE` does not reach and the table sweep cannot see, because it
  # applies to tables that do not exist yet.
  defp default_privilege_grantees do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT grantee.rolname
        FROM pg_default_acl acl
        CROSS JOIN LATERAL aclexplode(acl.defaclacl) AS entry
        JOIN pg_authid grantee ON grantee.oid = entry.grantee
        ORDER BY 1
        """,
        []
      )

    Enum.map(rows, &hd/1)
  end

  # Employer-zone tables with no `venue_id` column. `venues` is exempt: its own
  # id is the venue key.
  defp without_venue_key do
    Enum.reject(Zones.employer_zone_tables(), fn table ->
      table == "venues" or "venue_id" in columns(table)
    end)
  end

  # Extended to the shared zone in U5. `engagements` is what U6's roster entries
  # and room messages will reference — by `(id, venue_id)`, because that is what
  # keeps a message at venue A from naming an engagement at venue B — so the
  # composite-key rule binds the bridge exactly as it binds the employer zone.
  defp without_composite_key do
    with_key = tables_with_composite_key()

    Enum.reject(
      Zones.employer_zone_tables() ++ Zones.shared_tables(),
      &(&1 == "venues" or &1 in with_key)
    )
  end

  # The bridge's foreign key to `people`, as `pg_constraint` and `pg_attribute`
  # record it. `confdeltype` is `r` for RESTRICT.
  defp bridge_key do
    %{rows: [[nullable, on_delete]]} =
      Repo.query!(
        """
        SELECT NOT a.attnotnull, c.confdeltype
        FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
        WHERE c.contype = 'f'
          AND c.conrelid = 'engagements'::regclass
          AND c.confrelid = 'people'::regclass
        """,
        []
      )

    %{nullable: nullable, on_delete: on_delete}
  end

  defp exclusion_constraints(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname FROM pg_constraint WHERE contype = 'x' AND conrelid = to_regclass($1)",
        [table]
      )

    Enum.map(rows, &hd/1)
  end

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.attname
        FROM pg_attribute a
        WHERE a.attrelid = to_regclass($1) AND a.attnum > 0 AND NOT a.attisdropped
        """,
        [table]
      )

    Enum.map(rows, &hd/1)
  end

  # Tables carrying a unique index on exactly `(id, venue_id)`, which is what a
  # composite foreign key from a later table has to reference.
  defp tables_with_composite_key do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT c.relname
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND i.indisunique
          AND (
            SELECT array_agg(a.attname::text ORDER BY a.attname)
            FROM unnest(i.indkey) AS k(attnum)
            JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
          ) = ARRAY['id', 'venue_id']
        """,
        []
      )

    Enum.map(rows, &hd/1)
  end

  # Ecto's own bookkeeping, plus the queue's. None of it is application data and
  # none of it belongs to a zone; anything else that ends up here needs a reason
  # written next to it.
  @unzoned_tables ~w(schema_migrations) ++ @queue_tables

  defp unclassified_tables do
    MapSet.difference(database_tables(), MapSet.new(Zones.classified_tables()))
  end

  # Every relation in `public` that holds rows: ordinary and partitioned
  # tables, and materialised views, which are person data if their sources
  # were. Plain views are excluded — they hold nothing and U9 adds one.
  defp database_tables do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p', 'm')
          AND NOT (c.relname = ANY($1::text[]))
        """,
        [@unzoned_tables]
      )

    rows |> Enum.map(&hd/1) |> MapSet.new()
  end

  defp tables_referencing_people do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT c.conrelid::regclass::text
        FROM pg_constraint c
        WHERE c.contype = 'f' AND c.confrelid = 'people'::regclass
        """,
        []
      )

    rows |> Enum.map(&hd/1) |> MapSet.new()
  end

  defp employer_zone_tables, do: MapSet.new(Zones.employer_zone_tables())

  ## The association shapes the backstop has to resolve

  # Ecto reflects `has_many :through` and `many_to_many` differently from
  # everything else, and neither shape exists in the application yet — U4's
  # roster and U5's bridge are where they arrive. They are declared here rather
  # than in `test/support` because `test/support` is compiled into the
  # application, which would put these in `Zones.all_schemas/0` and fail the
  # totality test with tables nobody ever migrated.
  #
  # None of these tables exists. Nothing here is queried; every assertion stops
  # inside `prepare_query/3`, which runs before Postgres is asked anything.

  defmodule Shift do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "shifts" do
    end
  end

  defmodule VenueShift do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "venue_shifts" do
      field(:venue_id, :binary_id)
      field(:shift_id, :binary_id)
    end
  end

  defmodule Engagement do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "engagements" do
      belongs_to(:venue, Venue, type: :binary_id)
      belongs_to(:person, Person, type: :binary_id)
      many_to_many(:shifts, Shift, join_through: VenueShift)
    end
  end

  defmodule Venue do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "venues" do
      has_many(:engagements, Engagement)

      # Reaches `people` through the bridge, which is the crossing the zone
      # rule exists to refuse.
      has_many(:people, through: [:engagements, :person])

      # Reaches nothing forbidden, and used to raise anyway.
      has_many(:shifts_through, through: [:engagements, :shifts])

      many_to_many(:shifts, Shift, join_through: VenueShift)

      # Innocent related schema, person-zone join table.
      many_to_many(:smuggled_shifts, Shift, join_through: "people_tokens")
    end
  end
end
