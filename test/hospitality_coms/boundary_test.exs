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
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.EnableBtreeGist}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.CreateEngagements}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.GrantEngagementZone}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.EnableEngagementRowLevelSecurity}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.CreateRooms}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.CreateRosterEntries}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.GrantRoomZone}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.EnableRoomRowLevelSecurity}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.CreatePeerGraph}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.GrantPeerZone}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.CreateProfiles}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.EnableProfileRowLevelSecurity}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.CreateEmployerVisibleView}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.GrantProfileZone}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.AddRetentionColumns}
  @compile {:no_warn_undefined, HospitalityComs.Repo.Migrations.GrantRetentionZone}

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
  alias HospitalityComs.Peers.Connection, as: PeerConnection
  alias HospitalityComs.Peers.ConnectionRequest
  alias HospitalityComs.Repo
  alias HospitalityComs.Repo.Migrations.AddReaperIndexes
  alias HospitalityComs.Repo.Migrations.AddRetentionColumns
  alias HospitalityComs.Repo.Migrations.CreateEmployerVisibleView
  alias HospitalityComs.Repo.Migrations.CreateEngagements
  alias HospitalityComs.Repo.Migrations.CreatePeerGraph
  alias HospitalityComs.Repo.Migrations.CreateProfiles
  alias HospitalityComs.Repo.Migrations.CreateRooms
  alias HospitalityComs.Repo.Migrations.CreateRosterEntries
  alias HospitalityComs.Repo.Migrations.CreateVenues
  alias HospitalityComs.Repo.Migrations.EnableBtreeGist
  alias HospitalityComs.Repo.Migrations.EnableEmployerZoneRowLevelSecurity
  alias HospitalityComs.Repo.Migrations.EnableEngagementRowLevelSecurity
  alias HospitalityComs.Repo.Migrations.EnableProfileRowLevelSecurity
  alias HospitalityComs.Repo.Migrations.EnableRoomRowLevelSecurity
  alias HospitalityComs.Repo.Migrations.GrantEmployerZone
  alias HospitalityComs.Repo.Migrations.GrantEngagementZone
  alias HospitalityComs.Repo.Migrations.GrantPeerZone
  alias HospitalityComs.Repo.Migrations.GrantProfileZone
  alias HospitalityComs.Repo.Migrations.GrantRetentionZone
  alias HospitalityComs.Repo.Migrations.GrantRoomZone
  alias HospitalityComs.Repo.Migrations.GrantZones
  alias HospitalityComs.Rooms.VenueRoomSuspension
  alias HospitalityComs.Rosters.RosterEntry
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
  @btree_gist_migration "enable_btree_gist"
  @engagement_tables_migration "create_engagements"
  @engagement_zone_migration "grant_engagement_zone"
  @engagement_row_security_migration "enable_engagement_row_level_security"
  @room_tables_migration "create_rooms"
  @roster_tables_migration "create_roster_entries"
  @room_zone_migration "grant_room_zone"
  @room_row_security_migration "enable_room_row_level_security"
  @peer_tables_migration "create_peer_graph"
  @peer_zone_migration "grant_peer_zone"
  @profile_tables_migration "create_profiles"
  @profile_row_security_migration "enable_profile_row_level_security"
  @employer_view_migration "create_employer_visible_view"
  @profile_zone_migration "grant_profile_zone"
  @retention_tables_migration "add_retention_columns"
  @retention_zone_migration "grant_retention_zone"
  @reaper_index_migration "add_reaper_indexes"

  # The employer-zone table U5 added that `employer_role` deliberately holds no
  # privilege on. KTD3: hidden attested entries are a per-row rule, which grants
  # cannot express, so the employer reads U9's owner-privileged view and never
  # the base table.
  # U6 adds a second, for a different reason with the same shape. Room
  # conversation is worker-facing: R11's readers are the people who worked the
  # shift, a manager among them, and they read it through their own engagement
  # from the person's side. An employer *session* that could read a venue's
  # conversation in bulk has no reason to exist, so no grant creates one.
  @ungranted_tables ["attested_entries", "room_messages"]

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

  # U8's three. Written out here rather than derived, because this file's job is
  # to disagree with the classification when the classification is wrong.
  @peer_tables ~w(connection_requests peer_connections peer_messages)

  # U9's three, written out for the same reason.
  @profile_tables ~w(declared_entries attested_entry_disclosures correction_requests)
  @profile_person_tables ~w(declared_entries attested_entry_disclosures)

  # U10's two, written out for the same reason. `retention_runs` holds no
  # personal data at all — an instant, four counts and an outcome — and is
  # person zone anyway, because the zones answer which privileges
  # `employer_role` may hold rather than whose data a table holds, and a log of
  # what the deleter did across every venue is a report on other venues.
  @retention_tables ~w(retained_message_copies retention_runs)

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
    load_migration(@btree_gist_migration, Code.ensure_loaded?(EnableBtreeGist))
    load_migration(@engagement_tables_migration, Code.ensure_loaded?(CreateEngagements))
    load_migration(@engagement_zone_migration, Code.ensure_loaded?(GrantEngagementZone))

    load_migration(
      @engagement_row_security_migration,
      Code.ensure_loaded?(EnableEngagementRowLevelSecurity)
    )

    load_migration(@room_tables_migration, Code.ensure_loaded?(CreateRooms))
    load_migration(@roster_tables_migration, Code.ensure_loaded?(CreateRosterEntries))
    load_migration(@room_zone_migration, Code.ensure_loaded?(GrantRoomZone))
    load_migration(@room_row_security_migration, Code.ensure_loaded?(EnableRoomRowLevelSecurity))
    load_migration(@peer_tables_migration, Code.ensure_loaded?(CreatePeerGraph))
    load_migration(@peer_zone_migration, Code.ensure_loaded?(GrantPeerZone))
    load_migration(@profile_tables_migration, Code.ensure_loaded?(CreateProfiles))

    load_migration(
      @profile_row_security_migration,
      Code.ensure_loaded?(EnableProfileRowLevelSecurity)
    )

    load_migration(@employer_view_migration, Code.ensure_loaded?(CreateEmployerVisibleView))
    load_migration(@profile_zone_migration, Code.ensure_loaded?(GrantProfileZone))
    load_migration(@retention_tables_migration, Code.ensure_loaded?(AddRetentionColumns))
    load_migration(@retention_zone_migration, Code.ensure_loaded?(GrantRetentionZone))
    load_migration(@reaper_index_migration, Code.ensure_loaded?(AddReaperIndexes))

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
      # U6 added the first person-zone table since U2, and U1-U5's migrations
      # are not editable — so the comparison is a union over every migration
      # that revoked, which is the same shape "grant on every table the
      # classification places outside the person zone" already has. A
      # person-zone table covered by no migration still fails here.
      revoked =
        GrantZones.person_zone_tables() ++
          GrantRoomZone.person_zone_tables() ++
          GrantPeerZone.person_zone_tables() ++
          GrantProfileZone.person_zone_tables() ++ GrantRetentionZone.person_zone_tables()

      assert Enum.sort(revoked) == Enum.sort(Zones.person_zone_tables())
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
               {"invitations", "INSERT"},
               {"shift_rooms", "SELECT"},
               {"shift_rooms", "INSERT"},
               {"roster_entries", "SELECT"},
               {"roster_entries", "INSERT"},
               {"roster_entries", "UPDATE"},
               {"correction_requests", "SELECT"},
               {"correction_requests", "UPDATE"}
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
      granted =
        GrantEmployerZone.granted_tables() ++
          GrantEngagementZone.granted_tables() ++
          GrantRoomZone.granted_tables() ++
          GrantPeerZone.granted_tables() ++
          GrantProfileZone.granted_tables() ++ GrantRetentionZone.granted_tables()

      assert Enum.sort(granted ++ @ungranted_tables) ==
               Enum.sort(Zones.employer_zone_tables() ++ Zones.shared_tables())
    end

    test "grant SELECT and only SELECT on each of the employer's views" do
      # KTD3's other half, as an inventory. `employer_role` reads a worker's
      # record through these two and through nothing else, so what it holds on
      # them is the whole of what an employer session can do with a profile.
      #
      # A view can be updatable in Postgres when it is simple enough. These two
      # are multi-way joins and are not, but the grant says `SELECT` rather than
      # relying on that: "not auto-updatable" is a property of the view's shape,
      # and the shape is a thing a later unit edits.
      assert Zones.privileges(Repo, Zones.employer_views()) == [
               {"employer_visible_attested_entries", "SELECT"},
               {"employer_visible_correction_requests", "SELECT"}
             ]
    end

    test "grant on the views the migration says it granted on" do
      # The control for the inventory above, and the reason the migration
      # exposes its list: an inventory swept over a list somebody transcribed is
      # an inventory that can miss the view nobody transcribed.
      #
      # **Three-way, because the names are literals in three modules.**
      # `CreateEmployerVisibleView.views/0` is the record of what was created,
      # `GrantProfileZone.granted_views/0` of what was granted on, and
      # `Zones.employer_views/0` of what the classification permits. Any two
      # agreeing while the third drifts is a view that exists and is granted on
      # and is in no zone, or one that is classified and was never made — and
      # both of those are the kind of gap the totality check below cannot see
      # because it compares the database against only one of the three.
      assert Enum.sort(CreateEmployerVisibleView.views()) == Enum.sort(Zones.employer_views())
      assert Enum.sort(GrantProfileZone.granted_views()) == Enum.sort(Zones.employer_views())
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

    test "keys every composite foreign key MATCH FULL unless a column of it can be null" do
      # KTD2 asks for MATCH FULL: a composite key into the employer zone is
      # either wholly null or wholly present, so a row cannot half-reference a
      # grant at some other venue. `MATCH SIMPLE` skips the check the moment
      # *any* column is null, which is what a nullable id needs — `venue_id` is
      # `NOT NULL` everywhere, so MATCH FULL on a key whose id is optional would
      # reject every row that legitimately references nothing.
      #
      # Asserted as the derived rule rather than against a list, because a list
      # is a thing somebody has to remember to extend. Nothing pinned either
      # before this.
      wrong =
        Enum.reject(composite_foreign_keys(), fn key ->
          key.match_type == expected_match_type(key.nullable?)
        end)

      assert wrong == [],
             """
             These composite foreign keys do not match the rule: #{inspect(wrong)}

             A composite key with no nullable column must be MATCH FULL (`f`), \
             so a row cannot reference an id at one venue while naming another. \
             One with a nullable column must be MATCH SIMPLE (`s`), because \
             MATCH FULL would reject every row that references nothing at all.
             """
    end

    test "has exactly these composite foreign keys, and exactly these are nullable" do
      # The inventory the rule above is derived over, so a new key is noticed
      # rather than absorbed. It is also the control: a rule quantified over an
      # empty set holds for any rule at all.
      # `attested_entry_disclosures_engagement_fkey` is the first composite key
      # in the tree whose second column is `person_id` rather than `venue_id`,
      # and the rule is the same rule: an ownership question answered by
      # Postgres rather than by an `exists?` in Elixir. It is in the *person*
      # zone, so it is not KTD2's "no employer-zone table may name a person"
      # being bent — it is that discipline read from the other side.
      assert Map.new(composite_foreign_keys(), &{&1.name, {&1.match_type, &1.nullable?}}) == %{
               "attested_entries_engagement_fkey" => {"f", false},
               "attested_entry_disclosures_engagement_fkey" => {"f", false},
               "correction_requests_engagement_fkey" => {"f", false},
               "correction_requests_resolved_by_grant_fkey" => {"s", true},
               "employer_grants_granted_by_fkey" => {"s", true},
               "employer_grants_revoked_by_fkey" => {"s", true},
               "engagements_grant_fkey" => {"s", true},
               "engagements_invitation_fkey" => {"f", false},
               "invitations_grant_fkey" => {"s", true},
               "invitations_issued_by_grant_fkey" => {"f", false},
               "retained_message_copies_engagement_fkey" => {"f", false},
               "room_messages_author_fkey" => {"f", false},
               "room_messages_shift_room_fkey" => {"s", true},
               "roster_entries_engagement_fkey" => {"f", false},
               "roster_entries_shift_room_fkey" => {"f", false},
               "shift_rooms_shift_type_fkey" => {"f", false}
             }
    end
  end

  describe "the rooms" do
    test "put the suspension in the person zone, where the employer role holds nothing" do
      # KTD18, as the classification it is. Origin R11 lets a person leave the
      # venue room reversibly and requires the employer not to see that they
      # have; a column on `engagements` would arrive with every membership read,
      # because the employer role holds table-level SELECT there.
      #
      # The sweep asks about every table privilege and about column grants, so
      # `GRANT SELECT (resumed_at)` would be caught alongside a table-level one.
      assert "venue_room_suspensions" in Zones.person_zone_tables()
      assert Zones.privileges(Repo, ["venue_room_suspensions"]) == []
    end

    test "and the sweep would notice if it stopped being true" do
      # The control. Postgres default-denies on a table owned by another role,
      # so the assertion above passes on a database where nothing ever revoked
      # anything. This is what distinguishes an audit from a green tick.
      Repo.query!("GRANT SELECT (resumed_at) ON venue_room_suspensions TO employer_role")

      assert {"venue_room_suspensions", "SELECT"} in Zones.employer_privileges(Repo)
    end

    test "leave the suspension carrying no venue key and no person key" do
      # The person zone's own rule, and KTD2's. It names the engagement, which
      # is the one row that already means "this person, at this venue".
      columns = columns("venue_room_suspensions")

      refute "venue_id" in columns
      refute "person_id" in columns
      assert "engagement_id" in columns
    end

    test "give the employer role no privilege at all on room conversation" do
      # `room_messages` is employer zone and ungranted, for the reason
      # `attested_entries` is: the reads it would serve belong to somebody else.
      # A manager reads a room through their own engagement, from the person's
      # side; an employer session that could read a venue's conversation in bulk
      # has no reason to exist, so no grant creates one.
      assert Zones.privileges(Repo, ["room_messages"]) == []
      assert "room_messages" in Zones.employer_zone_tables()
    end

    test "give UPDATE on two columns of roster_entries rather than on the table" do
      # Removal closes a period, and that is the only mutation a roster entry
      # has. A table-level UPDATE would also let a session move `joined_at`
      # backwards, which is the retroactive grant KTD6b's structure exists to
      # make impossible, or move an entry to another engagement or another
      # shift.
      refute table_privilege?("roster_entries", "UPDATE")

      assert updatable_columns("roster_entries") == ["left_at", "updated_at"]
    end

    test "give no UPDATE on shift_rooms at all" do
      # A room's term and its stamped grace are what every membership answer is
      # derived from. A session that could move them could close a room
      # somebody is standing in, or reopen one that shut yesterday.
      refute table_privilege?("shift_rooms", "UPDATE")
      assert updatable_columns("shift_rooms") == []
    end

    test "refuse two overlapping roster periods with the constraint the changeset names" do
      # KTD6b's GiST index, doing two jobs at once. Named, so
      # `HospitalityComs.Rosters.RosterEntry` can declare a matching
      # `exclusion_constraint/3` and the violation arrives as a changeset error
      # rather than raising through the transaction.
      assert to_string(RosterEntry.overlap_constraint()) in exclusion_constraints(
               "roster_entries"
             )

      assert to_string(VenueRoomSuspension.overlap_constraint()) in exclusion_constraints(
               "venue_room_suspensions"
             )
    end

    test "add no second crossing: no U6 table holds a foreign key to people" do
      # The rule stated over this unit's own tables rather than only over the
      # zone lists, so the failure names the unit that broke it.
      u6 = MapSet.new(~w(shift_rooms roster_entries room_messages venue_room_suspensions))

      assert MapSet.to_list(MapSet.intersection(tables_referencing_people(), u6)) == []
    end
  end

  describe "the peer graph" do
    test "is entirely in the person zone, where the employer role holds nothing" do
      # KTD2 permits exactly one crossing and `engagements` is it, so a peer
      # table anywhere but the person zone would be a second one. There is no
      # judgement here: the classification is the only one that passes "is
      # engagements, and it is the only crossing that exists" below.
      #
      # The sweep asks about every table privilege and about column grants, so a
      # `GRANT SELECT (body)` would be caught alongside a table-level one.
      Enum.each(@peer_tables, fn table -> assert table in Zones.person_zone_tables() end)

      assert Zones.privileges(Repo, @peer_tables) == []
    end

    test "and the sweep would notice if that stopped being true" do
      # The control. Postgres default-denies on a table owned by another role,
      # so the assertion above passes on a database where nothing ever revoked
      # anything. A column grant is chosen deliberately: it is invisible to
      # `has_table_privilege` and is the shape the sweep exists to also catch.
      Repo.query!("GRANT SELECT (body) ON peer_messages TO employer_role")

      assert {"peer_messages", "SELECT"} in Zones.employer_privileges(Repo)
    end

    test "carries no venue key and no engagement key on any of its three tables" do
      # The person zone's own rule. A peer connection is between two people and
      # records nothing about where they met — which is also why there is no
      # filter an employer session could add that would make a query over these
      # tables mean anything.
      Enum.each(@peer_tables, fn table ->
        columns = columns(table)

        refute "venue_id" in columns
        refute "engagement_id" in columns
      end)
    end

    test "names people directly, and stays inside the person zone doing it" do
      # The positive half: these tables *do* hold foreign keys to `people`, and
      # `tables_referencing_people/0` finding them is what makes the assertion
      # above about their classification rather than about an absence.
      referencing = tables_referencing_people()

      Enum.each(@peer_tables, fn table -> assert table in referencing end)

      assert MapSet.to_list(
               MapSet.difference(referencing, MapSet.new(Zones.person_zone_tables()))
             ) == ["engagements"]
    end

    test "keeps one current request per pair and one live connection per pair" do
      # The two partial unique indexes the state machine rests on, looked for
      # under the exact names the changesets declare — a string written twice
      # would let a violation raise through the transaction instead of arriving
      # as a changeset error, and the enumerated-error convention would stop
      # being true at the one place it is load bearing.
      assert to_string(ConnectionRequest.current_constraint()) in partial_unique_indexes(
               "connection_requests"
             )

      assert to_string(PeerConnection.live_constraint()) in partial_unique_indexes(
               "peer_connections"
             )
    end

    test "keeps the pair canonical, so those indexes have one spelling to be unique over" do
      # `connection_requests` generates its pair columns; `peer_connections`
      # takes a check constraint instead, because there the two columns are the
      # row's identity rather than a projection of one. Without either, "at most
      # one row for the pair {A, B}" is not expressible as an index at all.
      assert "pair_low_id" in generated_columns("connection_requests")
      assert "pair_high_id" in generated_columns("connection_requests")

      assert "peer_connections_pair_ordered" in check_constraints("peer_connections")
    end

    test "keeps KTD19's block honest in the schema rather than only in the context" do
      # The block may only name a party to the request, and a declined row may
      # only block its requester. The disconnect half is decided on
      # `peer_connections` and cannot be checked from there, which is why there
      # are two constraints here and not three.
      constraints = check_constraints("connection_requests")

      assert "connection_requests_block_names_a_party" in constraints
      assert "connection_requests_decline_blocks_requester" in constraints
      assert "connection_requests_two_people" in constraints
    end

    test "is removed by its own migration's down and restored by its up" do
      # The half of "reversible" only a rollback proves. `peer_messages`
      # references `peer_connections` references `connection_requests`, all with
      # `ON DELETE RESTRICT`, so the `down` has to drop them in an order it
      # states rather than one Ecto infers.
      assert MapSet.subset?(MapSet.new(@peer_tables), database_tables())

      rolled_back =
        round_trip_peer_graph(fn ->
          MapSet.intersection(MapSet.new(@peer_tables), database_tables())
        end)

      assert MapSet.to_list(rolled_back) == []

      assert MapSet.subset?(MapSet.new(@peer_tables), database_tables())
      assert Zones.privileges(Repo, @peer_tables) == []

      assert to_string(ConnectionRequest.current_constraint()) in partial_unique_indexes(
               "connection_requests"
             )
    end

    test "adds no composite foreign key, so U5's MATCH inventory is unchanged" do
      # Every key U8 writes is one column, because there is no venue to carry
      # alongside it — which is the same fact as "these tables are person zone",
      # arrived at from the foreign keys rather than from the columns.
      names = Enum.map(composite_foreign_keys(), & &1.name)

      assert Enum.filter(names, &String.starts_with?(&1, ~w(connection_requests
                        peer_connections peer_messages))) == []
    end
  end

  describe "the profile" do
    test "puts the declared entries and the disclosure ledger in the person zone" do
      # `declared_entries` names a person and nothing else. The ledger names a
      # person *and* a venue, which makes it the first person-zone table in the
      # tree to carry an employer key — deliberately, because the audience of an
      # employer disclosure is a venue and every spelling of that reaches one.
      #
      # It is exactly why the classification matters more here than elsewhere:
      # `WHERE audience_venue_id = <me> AND disclosed = false` is the list of
      # workers concealing something from a venue, which is a strictly worse
      # disclosure than the entries themselves.
      Enum.each(@profile_person_tables, fn table ->
        assert table in Zones.person_zone_tables()
      end)

      assert Zones.privileges(Repo, @profile_person_tables) == []
    end

    test "and the sweep would notice if that stopped being true" do
      # The control. Postgres default-denies on a table owned by another role,
      # so the assertion above passes on a database where nothing ever revoked
      # anything. A column grant is chosen deliberately: it is invisible to
      # `has_table_privilege` and is the shape the sweep exists to also catch.
      Repo.query!("GRANT SELECT (disclosed) ON attested_entry_disclosures TO employer_role")

      assert {"attested_entry_disclosures", "SELECT"} in Zones.employer_privileges(Repo)
    end

    test "adds no second crossing: the ledger names a person and stays person zone" do
      # The positive half. `attested_entry_disclosures` *does* hold a foreign key
      # to `people` — `audience_person_id` — so this is a statement about its
      # classification rather than about an absence, and "engagements is the only
      # crossing" has to survive it.
      referencing = tables_referencing_people()

      assert "declared_entries" in referencing
      assert "attested_entry_disclosures" in referencing
      refute "correction_requests" in referencing

      assert MapSet.to_list(
               MapSet.difference(referencing, MapSet.new(Zones.person_zone_tables()))
             ) == ["engagements"]
    end

    test "keeps the contest in the employer zone, keyed on the bridge" do
      # KTD2 in its usual form: the venue answers the request, so the row is
      # employer zone — and an employer-zone row may not name a human, so it
      # names `engagements (id, venue_id)` instead.
      columns = columns("correction_requests")

      assert "correction_requests" in Zones.employer_zone_tables()
      assert "venue_id" in columns
      assert "engagement_id" in columns
      refute "person_id" in columns
      assert "correction_requests" in tables_with_composite_key()
    end

    test "gives the employer no INSERT on the contest, and UPDATE on four columns" do
      # A session that could write a complaint could then resolve it, so the
      # worker writes it through `HospitalityComs.Repo` as the application's own
      # role — the same manoeuvre the claim makes for an attested entry. What
      # the employer may write is the answer and nothing else.
      refute table_privilege?("correction_requests", "INSERT")
      refute table_privilege?("correction_requests", "UPDATE")

      assert updatable_columns("correction_requests") == [
               "resolution",
               "resolved_at",
               "resolved_by_grant_id",
               "updated_at"
             ]
    end

    test "is removed by its own migrations' downs and restored by their ups" do
      # The half of "reversible" only a rollback proves, and here it covers a
      # kind of object no earlier unit had: a view, which has to come off before
      # the tables it selects from.
      assert MapSet.subset?(MapSet.new(@profile_tables), database_tables())
      assert Enum.sort(database_views()) == Enum.sort(Zones.employer_views())

      # Wrapped in U10's layer, and that is not tidiness: U10's
      # `retained_message_copies` holds a composite key into
      # `engagements (id, person_id)`, and the unique index that makes it
      # referenceable is created by `create_profiles` and dropped by its `down`.
      # Without the wrapper this rollback raises `dependent_objects_still_exist`,
      # which is `RESTRICT` doing its job one unit later.
      rolled_back =
        rolled_back_retention_zone(fn ->
          rolled_back_profile_zone(fn ->
            %{
              tables: MapSet.intersection(MapSet.new(@profile_tables), database_tables()),
              views: database_views()
            }
          end)
        end)

      assert MapSet.to_list(rolled_back.tables) == []
      assert rolled_back.views == []

      assert MapSet.subset?(MapSet.new(@profile_tables), database_tables())
      assert Enum.sort(database_views()) == Enum.sort(Zones.employer_views())
      assert Zones.privileges(Repo, @profile_person_tables) == []
      assert "correction_requests_engagement_fkey" in foreign_keys("correction_requests")
    end
  end

  describe "the retention tables" do
    test "are person zone, and the employer role holds nothing on either" do
      # `retained_message_copies` is a worker's own copy of their own words, so
      # it classifies without argument. `retention_runs` is the interesting one:
      # it holds no personal data at all — an instant, four counts and an
      # outcome — and is person zone anyway, because a zone answers *which
      # privileges may `employer_role` hold* rather than *whose data is this*,
      # and the sweep it logs runs across every venue in the installation.
      #
      # The alternative was the infrastructure exclusion list `oban_jobs` and
      # `oban_peers` are on. That list is for relations with no Ecto schema
      # behind them; a table with a schema that is exempted from the
      # classification is a table nobody decided about.
      Enum.each(@retention_tables, fn table ->
        assert table in Zones.person_zone_tables()
      end)

      assert Zones.privileges(Repo, @retention_tables) == []
    end

    test "and the sweep would notice if that stopped being true" do
      # The control, in the shape the sweep exists to also catch: a column grant
      # is invisible to `has_table_privilege`.
      Repo.query!("GRANT SELECT (body) ON retained_message_copies TO employer_role")

      assert {"retained_message_copies", "SELECT"} in Zones.employer_privileges(Repo)
    end

    test "add no crossing: the archive is keyed on the bridge and names no person directly" do
      # `retained_message_copies.person_id` is half a composite key into
      # `engagements (id, person_id)` — the discipline U9 established — and not a
      # foreign key to `people`. So "engagements is the only table outside the
      # person zone referencing `people`" survives, and so does the reason it
      # can: this table is inside it.
      referencing = tables_referencing_people()

      assert "retained_message_copies" not in referencing
      assert "retention_runs" not in referencing

      crossings = MapSet.difference(referencing, MapSet.new(Zones.person_zone_tables()))
      assert MapSet.to_list(crossings) == ["engagements"]
    end

    test "hold no foreign key into the employer zone, which is the copy's whole point" do
      # `source_message_id` is the idempotence key and deliberately not a
      # reference. `ON DELETE RESTRICT` would make the shift-history sweep fail
      # the instant a copy outlived its original; `ON DELETE CASCADE` would
      # delete the worker's archive on the venue's clock — which is the
      # "shorter deadline silently wins" failure KTD16 rejects, and the reason
      # the copy is a separate row at all.
      assert referenced_tables("retained_message_copies") == ["engagements"]
      assert referenced_tables("retention_runs") == []
    end

    test "key the archive on the bridge with a MATCH FULL composite foreign key" do
      key =
        Enum.find(
          composite_foreign_keys(),
          &(&1.name == "retained_message_copies_engagement_fkey")
        )

      assert key.match_type == "f"
      refute key.nullable?
    end

    test "are removed by their own migrations' downs and restored by their ups" do
      assert MapSet.subset?(MapSet.new(@retention_tables), database_tables())
      assert "delete_after" in columns("room_messages")
      assert "delete_after" in columns("roster_entries")
      assert "closed_at" in columns("venues")

      rolled_back =
        rolled_back_retention_zone(fn ->
          %{
            tables: MapSet.intersection(MapSet.new(@retention_tables), database_tables()),
            message_columns: columns("room_messages"),
            venue_columns: columns("venues")
          }
        end)

      assert MapSet.to_list(rolled_back.tables) == []
      assert "delete_after" not in rolled_back.message_columns
      assert "closed_at" not in rolled_back.venue_columns

      assert MapSet.subset?(MapSet.new(@retention_tables), database_tables())
      assert "delete_after" in columns("room_messages")
      assert "delete_after" in columns("roster_entries")
      assert "closed_at" in columns("venues")
      assert Zones.privileges(Repo, @retention_tables) == []
    end

    test "and issue #15's two indexes come off and go back on with them" do
      # An index-only migration, and the cheapest kind to leave unexercised: a
      # `down` nobody runs is a `down` that is wrong the first time somebody
      # needs it. Nothing else in this nest reaches it — the indexes are on
      # `people` and `people_tokens`, which no rollback here touches — so it is
      # rolled on its own.
      #
      # The predicate is compared as text rather than only the name, because
      # the partial index's `WHERE` is the reap's own two `IS NULL` clauses and
      # an index whose predicate drifted from the query would still be present
      # under the same name.
      before = reaper_indexes()

      assert Enum.any?(before, &(&1 =~ "confirmed_at IS NULL"))
      assert Enum.any?(before, &(&1 =~ "people_tokens"))

      migrate_engagement_zone({@reaper_index_migration, AddReaperIndexes}, :down)

      # The control: comparing two identical nothings would pass on a migration
      # whose `up` and `down` were both empty.
      assert reaper_indexes() == []

      capture_log(fn ->
        migrate_engagement_zone({@reaper_index_migration, AddReaperIndexes}, :up)
      end)

      assert reaper_indexes() == before
    end

    test "refuse to let the profile tables be rolled down beneath them" do
      # Half of `@retention_migrations`' comment is assertable and this is the
      # half. `retained_message_copies`'s composite key references
      # `engagements (id, person_id)` through the unique index `create_profiles`
      # created, so `create_profiles`' `down` meets `RESTRICT`. The other three
      # profile migrations come off first, so the refusal cannot be the view's
      # dependency wearing this one's name.
      #
      # The *second* dependency in that comment is **not** loud, and the comment
      # now says so: rolling `create_roster_entries` down underneath this
      # migration drops `delete_after` with it and raises nothing at all. Safe
      # as written because both sit on one nesting layer, and pinned here from
      # the side that can be pinned.
      [
        {@profile_zone_migration, GrantProfileZone},
        {@employer_view_migration, CreateEmployerVisibleView},
        {@profile_row_security_migration, EnableProfileRowLevelSecurity}
      ]
      |> Enum.each(&migrate_engagement_zone(&1, :down))

      error =
        assert_raise Postgrex.Error, fn ->
          migrate_engagement_zone({@profile_tables_migration, CreateProfiles}, :down)
        end

      assert Exception.message(error) =~ "retained_message_copies"
    end

    test "recompute the shift's deadlines from rows that were already there" do
      # The round trip above runs on an empty database, so `up`'s
      # `UPDATE … FROM shift_rooms` join and the `SET NOT NULL` that follows it
      # were only ever proved on zero rows — which is the one thing a backfill
      # cannot be proved on.
      history = seed_room_history()

      before = %{
        roster: roster_row(history.roster_entry_id),
        shift_message: message_row(history.shift_message_id),
        venue_message: message_row(history.venue_message_id)
      }

      assert before.roster["delete_after"]
      assert before.shift_message["delete_after"]
      refute before.venue_message["delete_after"]

      rolled = rolled_back_retention_zone(fn -> :rolled end)
      assert rolled == :rolled

      # Recomputed from `shift_rooms.closes_at`, which does not move — so the
      # two shift deadlines come back identical and the venue-room one comes
      # back null, which is what it means for that column to have no clock.
      assert roster_row(history.roster_entry_id)["delete_after"] == before.roster["delete_after"]

      assert message_row(history.shift_message_id)["delete_after"] ==
               before.shift_message["delete_after"]

      refute message_row(history.venue_message_id)["delete_after"]

      # `joined_at` is `timestamp(6)` and is the one column in the schema that
      # is not truncated, because flooring it would backdate a rostering.
      # Nothing in this migration touches it and this is what says so.
      assert roster_row(history.roster_entry_id)["joined_at"] == before.roster["joined_at"]
      assert before.roster["joined_at"].microsecond == {123_456, 6}
    end

    test "and a rollback loses the archive and the closure, which is not symmetric" do
      # `down` restores the schema byte for byte and two things come back empty
      # and unrecomputable. On an empty database that is invisible, which is why
      # it was never noticed: a rollback silently extends retention
      # indefinitely, and that is a data-protection regression rather than a
      # tidy-up. The migration's moduledoc carries the capture SQL.
      history = seed_room_history()

      Repo.query!("UPDATE venues SET closed_at = $1 WHERE id = $2", [
        history.instant,
        history.venue_id
      ])

      assert count_of("retained_message_copies") == 1

      rolled_back_retention_zone(fn -> :rolled end)

      assert count_of("retained_message_copies") == 0
      assert %{"closed_at" => nil} = venue_row(history.venue_id)
    end
  end

  describe "the employer-visible view" do
    # KTD3, asserted rather than described. Three properties have to hold
    # together and each of them is a way the mechanism silently stops working:
    # an owner without privilege makes the view return `permission denied`,
    # `security_invoker` makes it resolve as the caller and refuse
    # `employer_role`, and a missing `WHERE` makes it return every venue's rows
    # because the owner bypasses row-level security.

    test "is owned by the role that owns the base table it reads" do
      owner = relation_owner("attested_entries")

      Enum.each(Zones.employer_views(), fn view ->
        assert relation_owner(view) == owner
      end)
    end

    test "is not security_invoker, which would invert the mechanism" do
      # With `security_invoker = on` the view resolves base-table permissions as
      # its *caller*, and `employer_role` holds none on `attested_entries` — so
      # the view would refuse every read. That fails closed and it fails: KTD3's
      # whole shape is the owner's privilege standing behind a filter.
      #
      # **Asserted as the option's value rather than its absence.** The previous
      # spelling refused any `security_invoker` reloption at all, which fails on
      # an explicit `security_invoker = false` — behaviourally identical to the
      # default and a perfectly reasonable thing for a later migration to write
      # down. It fired on the real regression, so it worked; it could not tell
      # "off" from "not set", and only one of those is a defect.
      Enum.each(Zones.employer_views(), fn view ->
        refute security_invoker?(view)
      end)
    end

    test "is what that assertion would report if one were turned on" do
      # The control, and the whole reason the assertion above reads a value.
      # Rolled back with the sandbox transaction, like every other DDL here.
      Repo.query!("CREATE VIEW invoker_view WITH (security_invoker = true) AS SELECT 1 AS x")

      Repo.query!("CREATE VIEW definer_view WITH (security_invoker = false) AS SELECT 1 AS x")

      assert security_invoker?("invoker_view")
      refute security_invoker?("definer_view")
    end

    test "is a security_barrier, so a caller's own predicate cannot be pushed under it" do
      # Postgres may otherwise evaluate a caller's `WHERE` below the view's
      # qualifiers when it looks cheaper. `employer_role` holds no CREATE on any
      # schema and so cannot define a leaky function today; this is the one
      # property of a view that has to be decided when it is created, and it is
      # decided.
      Enum.each(Zones.employer_views(), fn view ->
        assert "security_barrier=true" in relation_options(view)
      end)
    end

    test "reads the scope the wrapper writes, and raises when there is none" do
      # The guarantee U3 built `app_current_employer_id()` to give, now with a
      # real relation behind it. A NULL here would make the view return no rows,
      # which is indistinguishable from a worker who has disclosed nothing —
      # the failure would look like an answer.
      # Either setting will do and the pattern says so: the view calls both
      # scoping functions and Postgres is free to evaluate them in whichever
      # order the planner chooses — measured as `app.now` first today. Pinning
      # one of the two would be pinning a plan.
      assert_raise Postgrex.Error, ~r/app\.(employer_id|now) is not set on this connection/, fn ->
        EmployerRepo.query!("SELECT * FROM employer_visible_attested_entries", [])
      end
    end

    test "is readable by the employer role inside the wrapper" do
      # The control for the refusal above and for every privilege assertion in
      # this block: a view nobody can read satisfies every negative claim about
      # it. Empty because this file's two sandbox transactions cannot see each
      # other's rows — `HospitalityComs.ProfilesTest` populates one.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert {:ok, []} =
               EmployerRepo.scoped_transaction(scope, fn _scope ->
                 {:ok,
                  EmployerRepo.all(from(v in "employer_visible_attested_entries", select: 1))}
               end)
    end

    test "cannot be reached by the employer role through the base table instead" do
      # The other half of KTD3: the view is only a tier if the table under it is
      # closed. Asserted as the privilege bit above and as the refusal here,
      # because a raw statement goes through neither of the BEAM guards.
      scope = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert_raise Postgrex.Error, ~r/permission denied for table attested_entries/, fn ->
        EmployerRepo.scoped_transaction(scope, fn _scope ->
          {:ok, EmployerRepo.query!("SELECT id FROM attested_entries", [])}
        end)
      end
    end

    test "carries exactly these columns, and none of them names a person" do
      # Two claims in one assertion, and the second is the load-bearing one.
      #
      # No `person_id`: the key is a globally stable UUID that `employer_role`
      # can already read off the bridge, so two venues comparing ids out of band
      # could determine that the same human works at both — which is precisely
      # the concurrency this view's default hides. The employer names a worker by
      # their own engagement at their own venue instead.
      #
      # And no `hidden_count`, no `has_hidden_entries`, no column of any kind
      # that answers "is this worker concealing something". The standing
      # incompleteness notice is a UI constant; a computed flag would make every
      # employer read carry an oracle.
      # And no spare columns. Every one of these has a reader in
      # `HospitalityComs.Profiles.Records`; `viewer_venue_id` and the
      # corrections view's `attested_entry_id` had none and are gone, because a
      # column pinned here is a surface that survives by default rather than by
      # decision.
      assert view_columns("employer_visible_attested_entries") == [
               "attested_at",
               "attested_entry_id",
               "ends_at",
               "entry_engagement_id",
               "entry_venue_id",
               "entry_venue_name",
               "role_label",
               "starts_at",
               "viewer_engagement_id"
             ]

      assert view_columns("employer_visible_correction_requests") == [
               "body",
               "correction_request_id",
               "entry_engagement_id",
               "entry_venue_id",
               "requested_at",
               "resolution",
               "resolved_at",
               "viewer_engagement_id"
             ]
    end

    test "does its own tenancy, because its owner bypasses row-level security" do
      # The measurement that makes KTD3 stronger than its own argument. `Repo`
      # connects as a superuser, and a superuser bypasses row-level security
      # whether or not a policy is FORCEd — so the policies on `attested_entries`
      # and `engagements` do nothing for a view owned by that role, and
      # `viewer.venue_id = app_current_employer_id()` inside the view is the
      # only thing confining a read to one venue.
      #
      # Asserted as the two facts rather than as a behaviour, because a
      # behavioural test needs rows both repos can see and this file's sandbox
      # cannot produce them. `HospitalityComs.ProfilesTest` runs the behaviour.
      assert superuser?()
      assert view_definition("employer_visible_attested_entries") =~ "app_current_employer_id()"
      assert view_definition("employer_visible_attested_entries") =~ "app_current_instant()"
    end

    test "computes its concurrency default from periods and never from the instant" do
      # The distinction the unit turns on, asserted against the view's own text
      # because it is the only place the rule exists.
      #
      # The overlap predicate compares `starts_at` and `ends_at` against each
      # other. It does *not* compare either against `app_current_instant()` —
      # that comparison appears exactly twice, and both are about the viewer's
      # engagement being active rather than about concurrency. A default written
      # as "concurrent at this instant" would re-disclose a second job the moment
      # it ended, which is the leak the default exists to prevent.
      definition = view_definition("employer_visible_attested_entries")

      assert definition =~ "NOT (EXISTS"
      assert length(String.split(definition, "app_current_instant()")) - 1 == 2
    end
  end

  describe "the views, against the classification that has to name them" do
    test "every view in the database is classified" do
      # Neither totality check reaches a view. `HospitalityComs.ZonesTest`
      # quantifies over Ecto schemas and there is no schema behind these;
      # `database_tables/0` above asks for `relkind IN ('r','p','m')` and
      # excludes them deliberately, because they hold no rows. So the decision
      # "may the employer role hold privilege on this relation" needs a check of
      # its own, and this is it.
      unclassified = database_views() -- Zones.employer_views()

      assert unclassified == [],
             """
             These views exist in the database and are in no zone: \
             #{inspect(unclassified)}

             A view holds no rows, so neither totality check sees it — and a \
             view the employer role can read is exactly as much of a disclosure \
             as a table it can read. Name it in HospitalityComs.Zones.employer_views/0 \
             and assert what employer_role holds on it.
             """
    end

    test "an unclassified view is what the check above would report" do
      # The control. Rolled back with the sandbox transaction, like every other
      # DDL in this file.
      Repo.query!("CREATE VIEW stowaway_view AS SELECT 1 AS x")

      assert "stowaway_view" in database_views()
    end

    test "the classification names views the database actually has" do
      # And the other direction: a name nobody migrated would make the privilege
      # inventory raise, but nothing said so out loud.
      assert Zones.employer_views() -- database_views() == []
    end
  end

  describe "the btree_gist extension" do
    test "cannot be rolled back under the exclusion constraint that needs it" do
      # The claim its moduledoc makes and nothing asserted: `DROP EXTENSION`
      # plain rather than CASCADE, so an out-of-order rollback stops instead of
      # silently taking `engagements_no_overlap` — and with it R3 — away. Ecto
      # rolls back in reverse, so the ordinary path drops the constraint first;
      # this is the path that does not. `grant_zones` has the parallel test and
      # this one did not.
      assert_raise Postgrex.Error, ~r/dependent_objects_still_exist/, fn ->
        migrate_btree_gist(:down)
      end
    end

    test "drops only an extension it created, and says which case a database is in" do
      # `up` is `IF NOT EXISTS`, so on a database that already had `btree_gist`
      # it does nothing — and a `down` that dropped unconditionally would then
      # remove an extension somebody else installed. `up` records provenance in
      # the extension's comment and `down` reads it back.
      assert extension_comment("btree_gist") ==
               "created by hospitality_coms; see priv/repo/migrations/*_enable_btree_gist.exs"
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

  # U6's four, likewise. `shift_rooms`, `roster_entries`, `room_messages` and
  # `venue_room_suspensions` all reference `engagements`, `shift_types` or
  # `venues` with `ON DELETE RESTRICT`, so they come off before U5's do — the
  # same growth U5 forced on U4 and U4 on U3, one unit further along.
  @room_migrations [
    {@room_tables_migration, CreateRooms},
    {@roster_tables_migration, CreateRosterEntries},
    {@room_zone_migration, GrantRoomZone},
    {@room_row_security_migration, EnableRoomRowLevelSecurity}
  ]

  defp migrate_engagement_zone({name, module}, direction) do
    apply(Ecto.Migrator, direction, [Repo, migration_version(name), module, @migrator_opts])
  end

  # U8's two, in the order they were applied. Nothing else in this file has to
  # roll them off: the peer tables reference `people` alone, which no rollback
  # here touches, and they depend on no scoping function and no venue.
  @peer_migrations [
    {@peer_tables_migration, CreatePeerGraph},
    {@peer_zone_migration, GrantPeerZone}
  ]

  defp round_trip_peer_graph(between) do
    @peer_migrations |> Enum.reverse() |> Enum.each(&migrate_engagement_zone(&1, :down))

    result = between.()

    capture_log(fn -> Enum.each(@peer_migrations, &migrate_engagement_zone(&1, :up)) end)

    result
  end

  # U9's four, in the order they were applied. Every one of them has to come off
  # before U5's do, and the views are why it is not merely the ordinary
  # `ON DELETE RESTRICT` growth: `employer_visible_attested_entries` selects from
  # `engagements` and `attested_entries`, so `DROP TABLE engagements` fails while
  # it exists — a dependency of a kind no earlier unit created.
  @profile_migrations [
    {@profile_tables_migration, CreateProfiles},
    {@profile_row_security_migration, EnableProfileRowLevelSecurity},
    {@employer_view_migration, CreateEmployerVisibleView},
    {@profile_zone_migration, GrantProfileZone}
  ]

  defp rolled_back_profile_zone(between) do
    @profile_migrations |> Enum.reverse() |> Enum.each(&migrate_engagement_zone(&1, :down))

    result = between.()

    capture_log(fn -> Enum.each(@profile_migrations, &migrate_engagement_zone(&1, :up)) end)

    result
  end

  # U10's two, and they are the **outermost** layer rather than merely a later
  # one. Two independent dependencies force it, and each on its own is enough:
  #
  #   * `retained_message_copies`'s composite key references
  #     `engagements (id, person_id)`, and the unique index that makes that
  #     referenceable is created by `create_profiles` and dropped by its `down`.
  #     So this comes off before U9's, not after.
  #   * `roster_entries.delete_after` is `NOT NULL` and is added here, by a
  #     migration later than `create_roster_entries`. Rolling U6's tables down
  #     and back up underneath this one would silently drop the column and leave
  #     every later assertion running against a schema
  #     `HospitalityComs.Rosters.RosterEntry` no longer matches.
  #
  # **Only the first of those two is loud**, and the difference is worth having
  # written down rather than inferred: `create_profiles`' `down` meets
  # `RESTRICT` and raises naming `retained_message_copies`, which "refuse to let
  # the profile tables be rolled down beneath them" asserts. The second raises
  # nothing at all — `DROP TABLE roster_entries` takes the column with it — so
  # the ordering above is what protects it, and there is no failure to pin.
  @retention_migrations [
    {@retention_tables_migration, AddRetentionColumns},
    {@retention_zone_migration, GrantRetentionZone}
  ]

  defp rolled_back_retention_zone(between) do
    @retention_migrations |> Enum.reverse() |> Enum.each(&migrate_engagement_zone(&1, :down))

    result = between.()

    capture_log(fn -> Enum.each(@retention_migrations, &migrate_engagement_zone(&1, :up)) end)

    result
  end

  # One venue's worth of room history, written straight through `Repo` rather
  # than through the fixtures: this file is sandboxed, so the two repos cannot
  # see each other's rows and the ordinary claim path is unavailable. The rows
  # exist only to give the backfill something to backfill.
  #
  # `joined_at` carries microseconds on purpose. It is the one column in the
  # schema that is not truncated — flooring it would backdate a rostering — so
  # a migration that rewrote the table would be visible here.
  defp seed_room_history do
    ids =
      Map.new(
        ~w(person venue grant invitation engagement type room roster shift venue_msg copy)a,
        &{&1, uuid()}
      )

    at = NaiveDateTime.truncate(DateTime.to_naive(@now), :second)
    joined = %{at | microsecond: {123_456, 6}}

    Repo.query!(
      "INSERT INTO people (id, email, inserted_at, updated_at) VALUES ($1, 'bt-retention@example.com', $2, $2)",
      [ids.person, at]
    )

    Repo.query!(
      "INSERT INTO venues (id, name, timezone, inserted_at, updated_at) VALUES ($1, 'bt-retention', 'Etc/UTC', $2, $2)",
      [ids.venue, at]
    )

    Repo.query!(
      "INSERT INTO employer_grants (id, venue_id, granted_at, inserted_at, updated_at) VALUES ($1, $2, $3, $3, $3)",
      [ids.grant, ids.venue, at]
    )

    Repo.query!(
      """
      INSERT INTO invitations
        (id, venue_id, issued_by_grant_id, role_label, starts_at, ends_at,
         claim_code_digest, code_expires_at, issued_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'Bartender', $4, $5, $6, $7, $4, $4, $4)
      """,
      [
        ids.invitation,
        ids.venue,
        ids.grant,
        at,
        NaiveDateTime.add(at, 30, :day),
        :crypto.strong_rand_bytes(32),
        NaiveDateTime.add(at, 7, :day)
      ]
    )

    Repo.query!(
      """
      INSERT INTO engagements
        (id, person_id, venue_id, invitation_id, role_label, starts_at, ends_at,
         accepted_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'Bartender', $5, $6, $5, $5, $5)
      """,
      [ids.engagement, ids.person, ids.venue, ids.invitation, at, NaiveDateTime.add(at, 30, :day)]
    )

    Repo.query!(
      "INSERT INTO shift_types (id, venue_id, name, grace_period_minutes, inserted_at, updated_at) VALUES ($1, $2, 'Evening', 30, $3, $3)",
      [ids.type, ids.venue, at]
    )

    Repo.query!(
      """
      INSERT INTO shift_rooms
        (id, venue_id, shift_type_id, starts_at, ends_at, grace_period_minutes,
         inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, 30, $4, $4)
      """,
      [ids.room, ids.venue, ids.type, at, NaiveDateTime.add(at, 8, :hour)]
    )

    Repo.query!(
      """
      INSERT INTO roster_entries
        (id, venue_id, shift_room_id, engagement_id, joined_at, delete_after,
         inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
      """,
      [ids.roster, ids.venue, ids.room, ids.engagement, joined, shift_deadline(at), at]
    )

    Repo.query!(
      """
      INSERT INTO room_messages
        (id, venue_id, author_engagement_id, shift_room_id, body, sent_at,
         delete_after, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'on the shift', $5, $6, $5, $5)
      """,
      [ids.shift, ids.venue, ids.engagement, ids.room, at, shift_deadline(at)]
    )

    Repo.query!(
      """
      INSERT INTO room_messages
        (id, venue_id, author_engagement_id, body, sent_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'in the venue', $4, $4, $4)
      """,
      [ids.venue_msg, ids.venue, ids.engagement, at]
    )

    Repo.query!(
      """
      INSERT INTO retained_message_copies
        (id, engagement_id, person_id, source_message_id, body, sent_at,
         retained_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'on the shift', $5, $5, $5, $5)
      """,
      [ids.copy, ids.engagement, ids.person, ids.shift, at]
    )

    %{
      instant: at,
      venue_id: ids.venue,
      roster_entry_id: ids.roster,
      shift_message_id: ids.shift,
      venue_message_id: ids.venue_msg
    }
  end

  # `closes_at` is generated as `ends_at + grace`, so this is the deadline the
  # migration's own backfill recomputes.
  defp shift_deadline(at),
    do:
      at
      |> NaiveDateTime.add(8, :hour)
      |> NaiveDateTime.add(30, :minute)
      |> NaiveDateTime.add(30, :day)

  defp uuid, do: Ecto.UUID.bingenerate()

  defp roster_row(id), do: one_row("roster_entries", id)
  defp message_row(id), do: one_row("room_messages", id)
  defp venue_row(id), do: one_row("venues", id)

  defp one_row(table, id) do
    %{columns: columns, rows: [row]} =
      Repo.query!("SELECT * FROM #{table} WHERE id = $1", [id])

    columns |> Enum.zip(row) |> Map.new()
  end

  defp count_of(table) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
    count
  end

  # Partial unique indexes on a table, by name. A partial index is what makes
  # "at most one row per pair *in this state*" expressible at all, and the name
  # is what lets a changeset turn its violation into an error tuple.
  defp partial_unique_indexes(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        WHERE i.indrelid = to_regclass($1)
          AND i.indisunique
          AND i.indpred IS NOT NULL
        ORDER BY 1
        """,
        [table]
      )

    Enum.map(rows, &hd/1)
  end

  defp generated_columns(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.attname
        FROM pg_attribute a
        WHERE a.attrelid = to_regclass($1)
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND a.attgenerated <> ''
        ORDER BY 1
        """,
        [table]
      )

    Enum.map(rows, &hd/1)
  end

  defp check_constraints(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname FROM pg_constraint WHERE contype = 'c' AND conrelid = to_regclass($1)",
        [table]
      )

    Enum.map(rows, &hd/1)
  end

  defp migrate_btree_gist(direction) do
    apply(Ecto.Migrator, direction, [
      Repo,
      migration_version(@btree_gist_migration),
      EnableBtreeGist,
      @migrator_opts
    ])
  end

  # U5's migrations rolled off and put back, around `between`.
  #
  # `engagements` references `venues`, `employer_grants` and `people`, and its
  # policies are written on `app_current_employer_id()` — so every rollback in
  # this file that used to reach a table or a function now has to come through
  # here first. That is the same growth U4 forced on U3, one unit further along,
  # and the list is a record of what the bridge depends on.
  # Three units deep now, so the steps are named rather than nested: U9's come
  # off first, then U6's, then U5's own, and each goes back on in reverse.
  defp rolled_back_engagement_zone(between) do
    engagement_step = fn -> engagement_zone_down(between) end
    room_step = fn -> rolled_back_room_zone(engagement_step) end
    profile_step = fn -> rolled_back_profile_zone(room_step) end

    rolled_back_retention_zone(profile_step)
  end

  defp engagement_zone_down(between) do
    @engagement_migrations |> Enum.reverse() |> Enum.each(&migrate_engagement_zone(&1, :down))

    result = between.()

    capture_log(fn -> Enum.each(@engagement_migrations, &migrate_engagement_zone(&1, :up)) end)

    result
  end

  # U6's migrations rolled off and put back, around `between`. Outermost,
  # because everything it creates hangs off something U5 or U4 created.
  defp rolled_back_room_zone(between) do
    @room_migrations |> Enum.reverse() |> Enum.each(&migrate_engagement_zone(&1, :down))

    result = between.()

    capture_log(fn -> Enum.each(@room_migrations, &migrate_engagement_zone(&1, :up)) end)

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

  # Which tables a table's foreign keys point *at*, distinct and sorted. The
  # question `foreign_keys/1` cannot answer, and the one U10 needs: the archive
  # must reference the bridge and nothing in the employer zone.
  defp referenced_tables(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT t.relname
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.confrelid
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

  # Issue #15's two, by definition rather than by name — see the test that uses
  # this.
  defp reaper_indexes do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT indexdef FROM pg_indexes
        WHERE schemaname = 'public'
          AND indexname IN ('people_tokens_context_inserted_at_index',
                            'people_unconfirmed_inserted_at_index')
        ORDER BY indexname
        """,
        []
      )

    List.flatten(rows)
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
  #
  # Swept over the tables *this* migration revoked rather than over the whole
  # classification, because it is taken while the later units' migrations are
  # rolled off and their tables do not exist. `Zones.privileges/2` raises on a
  # missing table on purpose, and that loud failure is worth keeping — so the
  # sweep is pointed at the tables that survive the rollback, and "the
  # migration's list equals the classification" is asserted separately.
  defp privilege_snapshot do
    %{
      tables: Zones.privileges(Repo, GrantZones.person_zone_tables()),
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
  # U9's grants are the first the employer role holds on something that is not a
  # table, and `pg_describe_object` says `view x` rather than `table x` — so the
  # expected list is built in two halves rather than by mapping one prefix over
  # everything. A test that assumed the prefix would have passed while reporting
  # the wrong objects.
  defp dependent_zone_tables do
    tables =
      GrantEmployerZone.granted_tables() ++
        GrantEngagementZone.granted_tables() ++
        GrantRoomZone.granted_tables() ++
        GrantPeerZone.granted_tables() ++
        GrantProfileZone.granted_tables() ++ GrantRetentionZone.granted_tables()

    Enum.sort(
      Enum.map(tables, &"table #{&1}") ++
        Enum.map(GrantProfileZone.granted_views(), &"view #{&1}")
    )
  end

  # Every grant migration rolled off, in the order Ecto uses.
  defp revoke_zone_grants do
    migrate_engagement_zone({@retention_zone_migration, GrantRetentionZone}, :down)
    migrate_engagement_zone({@profile_zone_migration, GrantProfileZone}, :down)
    migrate_engagement_zone({@room_zone_migration, GrantRoomZone}, :down)
    migrate_engagement_zone({@engagement_zone_migration, GrantEngagementZone}, :down)
    migrate_employer_zone(:down)
  end

  defp restore_zone_grants do
    migrate_employer_zone(:up)
    migrate_engagement_zone({@engagement_zone_migration, GrantEngagementZone}, :up)
    migrate_engagement_zone({@room_zone_migration, GrantRoomZone}, :up)
    migrate_engagement_zone({@profile_zone_migration, GrantProfileZone}, :up)
    migrate_engagement_zone({@retention_zone_migration, GrantRetentionZone}, :up)
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

  # Every foreign key in this schema whose key is more than one column, with the
  # `MATCH` type Postgres recorded and whether any of its columns can be null.
  defp composite_foreign_keys do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.conname,
               c.confmatchtype,
               bool_or(NOT a.attnotnull)
        FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE c.contype = 'f'
          AND n.nspname = 'public'
          AND array_length(c.conkey, 1) > 1
        GROUP BY c.conname, c.confmatchtype
        ORDER BY 1
        """,
        []
      )

    Enum.map(rows, fn [name, match_type, nullable?] ->
      %{name: name, match_type: match_type, nullable?: nullable?}
    end)
  end

  defp expected_match_type(true), do: "s"
  defp expected_match_type(false), do: "f"

  defp extension_comment(name) do
    %{rows: [[comment]]} =
      Repo.query!(
        "SELECT obj_description(oid, 'pg_extension') FROM pg_extension WHERE extname = $1",
        [name]
      )

    comment
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

  # Every plain view in `public`. Deliberately the complement of
  # `database_tables/0`'s `relkind` filter: a view holds no rows, so it is not a
  # zone question in the storage sense — and it is exactly as much of a
  # disclosure as a table when the employer role can read it.
  defp database_views do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind = 'v'
        ORDER BY 1
        """,
        []
      )

    Enum.map(rows, &hd/1)
  end

  defp relation_owner(name) do
    %{rows: [[owner]]} =
      Repo.query!("SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = to_regclass($1)", [
        name
      ])

    owner
  end

  # `reloptions` is NULL for a relation with none, which is a different thing
  # from an empty list and would make `in/2` raise.
  defp relation_options(name) do
    %{rows: [[options]]} =
      Repo.query!(
        "SELECT coalesce(reloptions, '{}') FROM pg_class WHERE oid = to_regclass($1)",
        [name]
      )

    options
  end

  # Whether a view resolves its base-table permissions as its caller. Absent and
  # `=false` are the same answer, which is the distinction the assertion above
  # needs and the reason this reads the value rather than the key.
  defp security_invoker?(name) do
    name
    |> relation_options()
    |> Enum.find_value(false, &invoker_option/1)
  end

  defp invoker_option("security_invoker=" <> value), do: value in ~w(on true yes 1)
  defp invoker_option(_option), do: nil

  defp view_columns(name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.attname
        FROM pg_attribute a
        WHERE a.attrelid = to_regclass($1) AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attname
        """,
        [name]
      )

    Enum.map(rows, &hd/1)
  end

  defp view_definition(name) do
    %{rows: [[definition]]} =
      Repo.query!("SELECT pg_get_viewdef(to_regclass($1), true)", [name])

    definition
  end

  # `HospitalityComs.Repo` connects as a role that bypasses row-level security
  # regardless of FORCE, which is what makes the view the only available tier
  # for a per-row rule. Asserted rather than assumed, because if it ever stops
  # being true the reasoning in KTD3's implementation notes changes.
  defp superuser? do
    %{rows: [[super?]]} =
      Repo.query!("SELECT rolsuper FROM pg_authid WHERE rolname = current_user", [])

    super?
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
