defmodule HospitalityComs.Zones do
  @moduledoc """
  Which side of the boundary a table sits on, and the audit that checks
  Postgres agrees.

  The product's central claim is that an employer-scoped session can never
  resolve a peer conversation or a hidden profile entry. Standard multi-tenancy
  would make that a question about filters — did anyone forget a
  `WHERE venue_id = ?`. It is not that question here, because almost every
  forbidden table carries no employer key at all: there is no filter to forget.
  What replaces it is a privilege question, which Postgres answers rather than
  the codebase promising (KTD1).

  Three zones, and the classification is total:

    * **person zone** — tables the employer role holds no privilege on. A
      forgotten `where` surfaces as `permission denied for table peer_messages`
      rather than as a row that should not have been returned.

      Every one of them but `attested_entry_disclosures` carries no employer key
      at all, and that is what makes the Problem Frame's inversion literal:
      there is no filter to forget because there is no column to filter on.
      U9's disclosure ledger is the exception and it is a deliberate one — the
      audience of an employer disclosure *is* a venue, so
      `audience_venue_id` is there and an employer-scoped query over it would
      mean something. Which is exactly why it is in this zone: see the U9
      section below.
    * **employer zone** — every row carries `venue_id`, and no row may carry
      `person_id`. Messages, roster entries, and attested entries reference
      `engagements(id, venue_id)` instead, so no worker's name is ever stored
      in an employer-zone row (KTD2).
    * **shared** — reachable from both sides. `engagements` lives here: it is
      the single bridge, the only table that names a human and an employer in
      one row, and the only crossing the design permits.

  Adding a table is not finished until somebody has decided where it sits: the
  totality test in `HospitalityComs.ZonesTest` fails on any schema that is in
  none of the three.

  U4 filled the employer zone with `venues`, `employer_grants` and
  `shift_types`, and in doing so turned two of the proof suite's assertions
  from vacuous into load-bearing: the disjointness check had two non-empty
  lists to disagree about, and "no employer-zone table holds a foreign key to
  `people`" had tables to check. None of the three carries a person key, and
  none ever will — a grant records that a venue has an outstanding authority,
  and *who holds it* is recorded on the bridge, from the person's side.

  ## U5 filled the shared zone, and it has exactly one member

  `engagements` is `:shared` rather than `:employer`, and the distinction is
  what the shared zone was declared for. It is not a way of getting the bridge
  past the employer zone's "no foreign key to `people`" rule; it is the
  statement that this table is *the* crossing, which is why the rule can be
  absolute on the employer side. `HospitalityComs.BoundaryTest` asserts both
  halves — no employer-zone table references `people`, and `engagements` is the
  only table outside the person zone that does.

  Classification decides which privileges the employer role may hold, not which
  rows it sees once it holds them. `engagements` carries a row-level security
  policy on `venue_id` like every employer-zone table, because the employer's
  *view* of the bridge is per venue even though the table is not the employer's
  alone.

  U5 also added `invitations` and `attested_entries` to the employer zone. Both
  carry `venue_id` and neither names a person: an invitation is addressed to
  nobody (R1) and an attested entry is keyed on `engagements (id, venue_id)`,
  which is KTD2's rule in its narrowest form. `employer_role` holds SELECT and
  INSERT on `invitations` and, deliberately, **nothing at all** on
  `attested_entries` — the hidden-entry rule is per row and grants cannot
  express it, so the employer reads U9's owner-privileged view (KTD3).

  ## U6 is the first unit to add a person-zone table

  `shift_rooms`, `roster_entries` and `room_messages` are employer zone on the
  ordinary test: each carries `venue_id`, none carries `person_id`. A roster
  entry names an `engagement`, and so does a message's author (KTD15b), which is
  KTD2's rule doing exactly what it was written for. `employer_role` holds
  SELECT and INSERT on the first two, UPDATE on `roster_entries.left_at` alone —
  removal closes a period and there is no other mutation — and, deliberately,
  **nothing at all** on `room_messages`: room conversation is worker-facing, a
  manager reads it through their own engagement from the person's side, and an
  employer session that could read a venue's conversation in bulk has no reason
  to exist.

  `venue_room_suspensions` is the first table in the **person zone** that U2 did
  not create, and its classification is the whole of KTD18. Origin R11 lets a
  person leave the venue room reversibly and requires the employer not to see
  that they have — employer visibility of the flag would make it a retaliation
  surface rather than an opt-out. A column on `engagements` could not deliver
  that, because `employer_role` holds table-level SELECT there and the only
  thing hiding the flag would be somebody remembering to trim a `select`. In its
  own person-zone table, three things hold at once and none is a convention: the
  privilege sweep asserts the employer role holds nothing on it,
  `HospitalityComs.EmployerRepo`'s query backstop refuses any employer query
  that reaches it, and Postgres would refuse the same statement anyway.

  It carries no `venue_id` — a person-zone table with an employer key is the
  thing the partition forbids — and no `person_id` either. It names the
  *engagement*, which is the one row that already means "this person, at this
  venue", and pointing at it from the person's side is what the bridge is for.

  A person-zone table is not free of obligations. U3's `grant_zones` migration
  wrote its revoked list out by hand, deliberately, and U6's `grant_room_zone`
  and U8's `grant_peer_zone` write out their own;
  `HospitalityComs.BoundaryTest` asserts the union of the three equals
  `person_zone_tables/0`, so the day a person-zone table is added without a
  migration covering it is the day somebody is told.

  ## U8 puts the whole peer graph in the person zone, and had no choice

  `connection_requests`, `peer_connections` and `peer_messages` each hold at
  least two foreign keys to `people` and hold nothing else that identifies
  anything — no `venue_id`, no `engagement_id`, no employer key of any kind.
  There is no reading under which they could sit anywhere else: KTD2 permits one
  crossing and `engagements` is it, so a peer table in the employer or shared
  zone would be a second one. `HospitalityComs.BoundaryTest` asserts that
  positively — `engagements` is the only table *outside* the person zone with a
  foreign key to `people` — which is what turns this classification from a
  judgement into the only option that passes the suite.

  `employer_role` holds nothing on any of the three, and there is not even a
  filter that would make an employer-scoped query over them mean something,
  because a peer connection records no venue. That is the Problem Frame's
  inversion of ordinary multi-tenancy at its sharpest: the question is not
  whether somebody forgot a `where`, it is whether the connection holds the
  privilege.

  Table names are derived from `__schema__(:source)` rather than written out
  a second time. The privilege sweep, the query backstop in
  `HospitalityComs.EmployerRepo`, and the classification therefore cannot
  drift apart — there is one list and it is a list of schemas.

  ## U9 adds a kind of relation the zones had never had: a view

  `employer_visible_attested_entries` and `employer_visible_correction_requests`
  are how the employer reads a worker's record at all (KTD3), and neither is a
  table. That difference is not cosmetic and it is why `employer_views/0` is a
  list of names rather than another list of schemas:

    * **Neither totality check reaches a view.** `HospitalityComs.ZonesTest`
      quantifies over Ecto schemas, and there is no schema here — a view-backed
      one would be classified as though it stored rows.
      `HospitalityComs.BoundaryTest`'s sweep over the database asks for
      `relkind IN ('r', 'p', 'm')`, which excludes plain views deliberately,
      because they hold nothing. So a view is classified by a check of its own,
      which that file adds.
    * **The employer zone's structural rules are about storage and do not
      apply.** Every employer-zone table carries `venue_id` and a unique
      `(id, venue_id)`; a view can have neither, and demanding them would mean
      either weakening the rule for tables or inventing an exemption. The
      questions that *do* apply — which privileges may the employer role hold,
      who owns it, does it filter on the transaction-local scope — are asked of
      the views directly.

  What the classification means here is the same thing it means for a table:
  `employer_role` may hold privilege on exactly these relations and nothing
  else. `HospitalityComs.BoundaryTest` pins the privilege to `SELECT`, the owner
  to the role that owns the base tables, and the absence of `security_invoker` —
  the one option that would invert KTD3's mechanism by resolving the view as its
  caller.

  U9's three tables classify without argument on the ordinary test.
  `correction_requests` carries `venue_id`, names no person, and is keyed on
  `engagements (id, venue_id)`, so it is employer zone. `declared_entries` and
  `attested_entry_disclosures` name people and are person zone — and the second
  is the first person-zone table in the tree to carry an employer key, which
  `*_create_profiles.exs` argues for at length. The short version: the audience
  of an employer disclosure *is* a venue, and the alternative placement hands
  each venue the answer to "which of my workers is concealing something".

  ## U10 puts the deleter's own two tables in the person zone

  `retained_message_copies` classifies without argument: it is a worker's own
  copy of their own words, keyed on `(engagement_id, person_id)` into the
  bridge, and it carries no employer key of any kind. The one thing worth
  writing down is what it *deliberately lacks* — `source_message_id` is a plain
  `binary_id` with no foreign key into `room_messages`, because either
  `ON DELETE` behaviour would defeat the reason the copy exists (see
  `*_add_retention_columns.exs`).

  That absence is **not** a KTD2 consequence, and an earlier version of this
  paragraph said it was. A person-zone key into the employer zone is not a
  second crossing: KTD2's single crossing is about naming a *person*, arrows
  point into the employer zone freely, and `attested_entry_disclosures`
  carries exactly such a key one section above, argued for at length. The
  `ON DELETE` reasons are the whole of it.

  `retention_runs` is the interesting one, because it holds no personal data at
  all: an instant, four counts and an outcome. It is person zone anyway, and the
  reason is that the zones answer *which privileges may `employer_role` hold*
  rather than *whose data is this*. The answer here is none — the sweep runs
  across every venue in the installation, and a log of what the application
  deleted everywhere is a report on other venues' activity. The alternative was
  the infrastructure exclusion list `HospitalityComs.BoundaryTest` keeps for
  `oban_jobs` and `oban_peers`; that list is for relations with no Ecto schema
  behind them, and a table with a schema that is exempted from the
  classification is a table nobody decided about.

  ## What the sweep is for

  `employer_privileges/1` is the audit, and it exists as a function rather than
  as an assertion inside a test for one reason: the test that proves the
  boundary holds and the test that proves the proof is not vacuous have to run
  the *same* code. `employer_role` holds no privilege on `people` today partly
  because no migration ever granted it — Postgres default-denies — so an
  assertion that the privilege is absent passes whether or not this
  application's grant migration does anything at all. The suite grants a
  privilege behind the sweep's back and asserts the sweep catches it, which is
  the only thing that distinguishes a working audit from a silent one.

  ## The sweep requires PostgreSQL 17

  `MAINTAIN` became a table privilege in PostgreSQL 17, and it is in the list
  the sweep asks about. On 16 or earlier `has_table_privilege` answers
  `unrecognized privilege type` and the sweep raises rather than answering.

  That is the deliberate choice. The alternative — reading `server_version_num`
  and dropping `MAINTAIN` below 17 — makes the audit's coverage depend on the
  server it happens to run against, so the suite would be strong in CI and
  quietly weaker somewhere else, which is the failure this whole module exists
  to avoid. A hard minimum states the requirement where somebody will read it,
  and 17 is what this project already runs.
  """

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Invitation
  alias HospitalityComs.Lifecycle.RetainedMessageCopy
  alias HospitalityComs.Lifecycle.RetentionRun
  alias HospitalityComs.Peers.Connection
  alias HospitalityComs.Peers.ConnectionRequest
  alias HospitalityComs.Peers.PeerMessage
  alias HospitalityComs.Profiles.AttestedEntry
  alias HospitalityComs.Profiles.CorrectionRequest
  alias HospitalityComs.Profiles.DeclaredEntry
  alias HospitalityComs.Profiles.Disclosure
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rooms.VenueRoomSuspension
  alias HospitalityComs.Rosters.RosterEntry
  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Venues.ShiftType
  alias HospitalityComs.Venues.Venue

  @typedoc "Which side of the boundary a schema sits on."
  @type zone() :: :person | :employer | :shared

  @typedoc "A privilege `employer_role` holds on a relation it must not hold one on."
  @type offence() :: {relation :: String.t(), privilege :: String.t()}

  @person_zone [
    Person,
    PersonToken,
    VenueRoomSuspension,
    ConnectionRequest,
    Connection,
    PeerMessage,
    DeclaredEntry,
    Disclosure,
    RetainedMessageCopy,
    RetentionRun
  ]
  @employer_zone [
    Venue,
    EmployerGrant,
    ShiftType,
    Invitation,
    AttestedEntry,
    ShiftRoom,
    RosterEntry,
    RoomMessage,
    CorrectionRequest
  ]
  @shared [Engagement]

  # Relations the employer role may hold privilege on that are not tables. See
  # the moduledoc: a view is classified by name because there is no schema
  # behind it and the zones' structural rules are about storage.
  @employer_views ~w(employer_visible_attested_entries employer_visible_correction_requests)

  @employer_role "employer_role"
  @employer_login_role "employer_login"

  # Every table-level privilege Postgres can grant. The sweep asks about all of
  # them rather than about `SELECT`, because `INSERT` on `people` is a way to
  # manufacture a worker and `UPDATE` on `people_tokens` is a way to mint a
  # session, and neither is a read.
  #
  # `MAINTAIN` is a PostgreSQL 17 privilege and this list is why the
  # application requires 17 or later. See the moduledoc.
  @table_privileges ~w(SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER MAINTAIN)

  # The subset that can also be granted per column. `has_any_column_privilege`
  # raises `unrecognized privilege type` on the others — measured, not assumed:
  # DELETE, TRUNCATE, TRIGGER and MAINTAIN all fail — so the predicate has to
  # know which is which rather than asking about all eight.
  @column_privileges ~w(SELECT INSERT UPDATE REFERENCES)

  @doc """
  The Postgres role the employer zone acts as.

  What `HospitalityComs.EmployerRepo`'s connections *become*, not what they log
  in as — see `employer_login_role/0`.
  """
  @spec employer_role() :: String.t()
  def employer_role, do: @employer_role

  @doc """
  The Postgres role `HospitalityComs.EmployerRepo` authenticates as.

  A credential and nothing else. It is `NOINHERIT`, it is a member of
  `employer_role/0` and of no other role, and it holds no privilege on any
  relation in its own name — so `RESET ROLE` on an employer connection lands on
  a role holding *less* than the one it started with rather than more.

  That is the whole of issue #17. Before it, `EmployerRepo` borrowed the
  application's own superuser credentials and assumed `employer_role`
  afterwards, so a single raw `RESET ROLE` — which neither BEAM guard sees —
  put the owner of every table in this database back on the connection, and the
  grant tier was defeatable from the same code position as the guards it was
  supposed to sit beneath.

  It is granted no object privilege, deliberately, including `CONNECT` on the
  database and `USAGE` on the schema: it holds both through `PUBLIC`, and a
  grant of its own would write a `pg_shdepend` row and make
  `DROP ROLE employer_login` fail from every *other* database on the cluster.
  """
  @spec employer_login_role() :: String.t()
  def employer_login_role, do: @employer_login_role

  @doc """
  Schemas whose tables the employer role holds no privilege on.
  """
  @spec person_zone() :: [module()]
  def person_zone, do: @person_zone

  @doc """
  Schemas whose every row carries a venue key and no person key.
  """
  @spec employer_zone() :: [module()]
  def employer_zone, do: @employer_zone

  @doc """
  Schemas reachable from both zones, the bridge among them.
  """
  @spec shared() :: [module()]
  def shared, do: @shared

  @doc """
  Every view in the database, by name, and they are the employer's.

  **A totality list rather than a description of a use.** Views get one bucket
  and it is the permissive one, so `HospitalityComs.BoundaryTest` fails on any
  view in `public` that is not named here — including one no employer ever
  reads. Adding a view means deciding about it, and the decision this list
  records is "`employer_role` may hold privilege on exactly these relations",
  which is the same thing the three zones record about tables.

  Names rather than schemas, because a view has no rows and therefore no zone in
  the storage sense — see the moduledoc.
  """
  @spec employer_views() :: [String.t()]
  def employer_views, do: @employer_views

  @doc """
  Every schema that has been classified, in every zone.
  """
  @spec classified() :: [module()]
  def classified, do: @person_zone ++ @employer_zone ++ @shared

  @doc """
  Every Ecto schema compiled into the application, classified or not.

  Read out of the application's own module list rather than from a list
  somebody maintains, so a schema added by a later unit is discovered the day
  it compiles.
  """
  @spec all_schemas() :: [module()]
  def all_schemas do
    {:ok, modules} = :application.get_key(:hospitality_coms, :modules)
    Enum.filter(modules, &schema?/1)
  end

  @doc """
  Schemas in none of the three zones.

  An empty list is the classification being total. Takes the list to check so
  that the test asserting it is empty and the test asserting it catches
  something can run the same code — a totality check nobody has ever seen
  return a non-empty list is a check nobody has tested.
  """
  @spec unclassified([module()]) :: [module()]
  def unclassified(schemas \\ all_schemas()), do: schemas -- classified()

  @doc """
  The zone a schema belongs to.

  Returns `{:error, :unclassified}` for anything nobody has placed, which is
  the state a newly generated schema is in and the state the totality test
  fails on.
  """
  @spec zone(module()) :: {:ok, zone()} | {:error, :unclassified}
  def zone(schema) do
    Enum.find_value(zones(), {:error, :unclassified}, &placed_in(&1, schema))
  end

  @doc """
  Schemas that sit in more than one zone.

  An empty list is the classification being unambiguous — a table in two zones
  is a table whose grants are argued over rather than derived.

  Takes the zone lists for the same reason `unclassified/1` does. Two of the
  three are empty until U4 and U5 fill them, so the obvious spelling of this
  check is `person_zone() -- employer_zone() == person_zone()`, which is
  `[A, B] -- [] == [A, B]` and cannot fail. Handing the lists in is what lets
  the test that asserts the classification is clean and the test that watches
  the check catch something run the same code.
  """
  @spec overlapping([{zone(), [module()]}]) :: [module()]
  def overlapping(zone_lists \\ zones()) do
    zone_lists
    |> Enum.flat_map(fn {_zone, schemas} -> Enum.uniq(schemas) end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_schema, placements} -> placements > 1 end)
    |> Enum.map(fn {schema, _placements} -> schema end)
  end

  @spec placed_in({zone(), [module()]}, module()) :: {:ok, zone()} | nil
  defp placed_in({zone, schemas}, schema) do
    schema |> Kernel.in(schemas) |> placement(zone)
  end

  @spec placement(boolean(), zone()) :: {:ok, zone()} | nil
  defp placement(true, zone), do: {:ok, zone}
  defp placement(false, _zone), do: nil

  # A keyword list rather than three literal memberships. It was written this
  # way because two of the three lists were empty until U4 and U5 filled them,
  # and `schema in []` is a compile-time falsehood the type checker is right to
  # warn about; it stays that way because `overlapping/1` and the tests that
  # watch it catch something have to run the same code.
  @spec zones() :: [{zone(), [module()]}]
  defp zones, do: [person: @person_zone, employer: @employer_zone, shared: @shared]

  @doc """
  The table names of the given schemas.

  Raises `ArgumentError` on a schema that names no table. Takes the list for
  the same reason `unclassified/1` does: the loud failure and the test that
  watches it fail have to run the same code.
  """
  @spec tables([module()]) :: [String.t()]
  def tables(schemas), do: Enum.map(schemas, &table_source!/1)

  @spec table_source!(module()) :: String.t()
  defp table_source!(schema), do: named!(schema.__schema__(:source), schema)

  @spec named!(String.t() | nil, module()) :: String.t()
  defp named!(source, _schema) when is_binary(source), do: source

  defp named!(nil, schema) do
    raise ArgumentError, """
    #{inspect(schema)} is classified in a zone but names no table.

    `__schema__(:source)` is nil for an embedded schema. A nil reaches the \
    privilege sweep as has_table_privilege(role, NULL, privilege), which is \
    NULL rather than false — so the row is dropped and the sweep reports \
    nothing, having looked at nothing. The zones are a statement about \
    tables; classify the schema that persists the rows.
    """
  end

  @doc """
  The table names of the person zone.
  """
  @spec person_zone_tables() :: [String.t()]
  def person_zone_tables, do: tables(@person_zone)

  @doc """
  The table names of the employer zone.
  """
  @spec employer_zone_tables() :: [String.t()]
  def employer_zone_tables, do: tables(@employer_zone)

  @doc """
  The table names of the shared zone.
  """
  @spec shared_tables() :: [String.t()]
  def shared_tables, do: tables(@shared)

  @doc """
  Every table name any zone claims.

  What the classification says the database contains. The proof suite compares
  it against what the database actually contains, because a table created by a
  migration with no schema module is invisible to `all_schemas/0` and just as
  much person data.
  """
  @spec classified_tables() :: [String.t()]
  def classified_tables, do: tables(classified())

  @doc """
  Whether the named table belongs to the person zone.
  """
  @spec person_zone_table?(String.t() | nil) :: boolean()
  def person_zone_table?(table) when is_binary(table), do: table in person_zone_tables()
  def person_zone_table?(_table), do: false

  @doc """
  Whether the given module is a person-zone schema.
  """
  @spec person_zone_schema?(module() | nil) :: boolean()
  def person_zone_schema?(schema) when is_atom(schema) and not is_nil(schema),
    do: schema in @person_zone

  def person_zone_schema?(_schema), do: false

  @doc """
  Privileges the employer role holds on person-zone tables.

  An empty list is the boundary holding. Anything else is a leak, named as
  `{table, privilege}` pairs so the failure says which door is open rather than
  that one is.

  `has_table_privilege/3` reports the *effective* privilege, so a grant reached
  through role membership or through `PUBLIC` is caught alongside a direct one.
  It raises on a table that does not exist, which is the loud failure wanted
  here: a person-zone schema pointing at a missing table would otherwise make
  the sweep skip it in silence.

  It is not, on its own, enough. `has_table_privilege` answers about the
  *table*, and a column grant is not one — measured:

      GRANT SELECT (email) ON people TO employer_role;
      has_table_privilege('employer_role','people','SELECT')      -> f
      has_any_column_privilege('employer_role','people','SELECT') -> t

  So `GRANT SELECT (email) ON people` would have left the sweep reporting an
  empty list while the employer role could read every worker's address, and no
  control in the proof suite could have caught it because they all grant at
  table level. The predicate therefore asks both questions, and a column grant
  is reported under the table's name: the fix differs but the exposure does
  not, and the sweep's job is to say which door is open.
  """
  @spec employer_privileges(Ecto.Repo.t()) :: [offence()]
  def employer_privileges(repo), do: privileges(repo, person_zone_tables())

  @doc """
  Every privilege the employer role effectively holds on the given relations.

  The same sweep `employer_privileges/1` runs, over a list the caller chooses.
  On the person zone an empty result is the boundary holding; on the employer
  zone the result is the *inventory* — what the zone's own grants actually
  confer, which is worth pinning as exactly as the absence is, since the grants
  are what U4 spent a cluster-wide `pg_shdepend` dependency on.

  **Relations rather than tables, since U9.** `has_table_privilege` and
  `has_any_column_privilege` answer about a view as readily as about a table, so
  the same sweep is what `HospitalityComs.BoundaryTest` runs over
  `employer_views/0` to pin those to `SELECT` and nothing else. Nothing in the
  query is table-specific; only the name of the parameter was.

  Sharing one implementation is deliberate. If the sweep ever stops seeing a
  kind of grant, the employer-zone inventory goes short at the same moment the
  person-zone audit goes quiet, and one of the two is a test that fails.

  **Role rather than `employer_role`, since #17.** The model has a second role
  in it — `employer_login_role/0`, the credential `EmployerRepo` authenticates
  as — and the claim about it is stronger than the claim about `employer_role`:
  it holds nothing on *any* relation, in either zone, rather than nothing on
  the person zone. That claim is an absence like every other one here, so it
  needs the same control, and a control that grants the login role a privilege
  proves nothing against a sweep hard-coded to ask about `employer_role`. The
  parameter is what lets one sweep answer for both and lets the control fail
  when it should.
  """
  @spec privileges(Ecto.Repo.t(), [String.t()], String.t()) :: [offence()]
  def privileges(repo, relations, role \\ @employer_role) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT r.name, p.privilege
        FROM unnest($1::text[]) WITH ORDINALITY AS r(name, rord)
        CROSS JOIN unnest($2::text[]) WITH ORDINALITY AS p(privilege, pord)
        WHERE has_table_privilege($3, r.name, p.privilege)
           OR (p.privilege = ANY($4::text[])
               AND has_any_column_privilege($3, r.name, p.privilege))
        ORDER BY r.rord, p.pord
        """,
        [relations, @table_privileges, role, @column_privileges]
      )

    Enum.map(rows, fn [relation, privilege] -> {relation, privilege} end)
  end

  @spec schema?(module()) :: boolean()
  defp schema?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)
  end
end
