defmodule HospitalityComs.Zones do
  @moduledoc """
  Which side of the boundary a table sits on, and the audit that checks
  Postgres agrees.

  The product's central claim is that an employer-scoped session can never
  resolve a peer conversation or a hidden profile entry. Standard multi-tenancy
  would make that a question about filters — did anyone forget a
  `WHERE venue_id = ?`. It is not that question here, because the forbidden
  tables carry no employer key at all: there is no filter to forget. What
  replaces it is a privilege question, which Postgres answers rather than the
  codebase promising (KTD1).

  Three zones, and the classification is total:

    * **person zone** — tables with no employer key and none coming. The
      employer role holds no privilege on any of them. A forgotten `where`
      surfaces as `permission denied for table peer_messages`.
    * **employer zone** — every row carries `venue_id`, and no row may carry
      `person_id`. Messages, roster entries, and attested entries reference
      `engagements(id, venue_id)` instead, so no worker's name is ever stored
      in an employer-zone row (KTD2).
    * **shared** — reachable from both sides. `engagements` will live here: it
      is the single bridge, the only table that names a human and an employer
      in one row, and the only crossing the design permits.

  Both other lists are empty until U4 creates the employer zone and U5 creates
  the bridge. They are declared now because the totality test in
  `HospitalityComs.ZonesTest` fails on any schema that is in none of them, so
  adding a table is not finished until somebody has decided where it sits.

  Table names are derived from `__schema__(:source)` rather than written out
  a second time. The privilege sweep, the query backstop in
  `HospitalityComs.EmployerRepo`, and the classification therefore cannot
  drift apart — there is one list and it is a list of schemas.

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
  """

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonToken

  @typedoc "Which side of the boundary a schema sits on."
  @type zone() :: :person | :employer | :shared

  @typedoc "A privilege `employer_role` holds on a table it must not hold one on."
  @type offence() :: {table :: String.t(), privilege :: String.t()}

  @person_zone [Person, PersonToken]
  @employer_zone []
  @shared []

  @employer_role "employer_role"

  # Every table-level privilege Postgres can grant. The sweep asks about all of
  # them rather than about `SELECT`, because `INSERT` on `people` is a way to
  # manufacture a worker and `UPDATE` on `people_tokens` is a way to mint a
  # session, and neither is a read.
  @table_privileges ~w(SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER)

  @doc """
  The Postgres role the employer zone connects as.
  """
  @spec employer_role() :: String.t()
  def employer_role, do: @employer_role

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
  The zone a schema belongs to.

  Returns `{:error, :unclassified}` for anything nobody has placed, which is
  the state a newly generated schema is in and the state the totality test
  fails on.
  """
  @spec zone(module()) :: {:ok, zone()} | {:error, :unclassified}
  def zone(schema) do
    Enum.find_value(zones(), {:error, :unclassified}, &placed_in(&1, schema))
  end

  @spec placed_in({zone(), [module()]}, module()) :: {:ok, zone()} | nil
  defp placed_in({zone, schemas}, schema) do
    schema |> Kernel.in(schemas) |> placement(zone)
  end

  @spec placement(boolean(), zone()) :: {:ok, zone()} | nil
  defp placement(true, zone), do: {:ok, zone}
  defp placement(false, _zone), do: nil

  # A keyword list rather than three literal memberships: two of the three are
  # empty until U4 and U5 fill them, and `schema in []` is a compile-time
  # falsehood the type checker is right to warn about.
  @spec zones() :: [{zone(), [module()]}]
  defp zones, do: [person: @person_zone, employer: @employer_zone, shared: @shared]

  @doc """
  The table names of the person zone.
  """
  @spec person_zone_tables() :: [String.t()]
  def person_zone_tables, do: Enum.map(@person_zone, & &1.__schema__(:source))

  @doc """
  The table names of the employer zone.
  """
  @spec employer_zone_tables() :: [String.t()]
  def employer_zone_tables, do: Enum.map(@employer_zone, & &1.__schema__(:source))

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
  """
  @spec employer_privileges(Ecto.Repo.t()) :: [offence()]
  def employer_privileges(repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT t.name, p.privilege
        FROM unnest($1::text[]) WITH ORDINALITY AS t(name, tord)
        CROSS JOIN unnest($2::text[]) WITH ORDINALITY AS p(privilege, pord)
        WHERE has_table_privilege($3, t.name, p.privilege)
        ORDER BY t.tord, p.pord
        """,
        [person_zone_tables(), @table_privileges, @employer_role]
      )

    Enum.map(rows, fn [table, privilege] -> {table, privilege} end)
  end

  @spec schema?(module()) :: boolean()
  defp schema?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)
  end
end
