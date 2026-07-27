defmodule HospitalityComs.ZonesTest do
  @moduledoc """
  The classification itself, with no database in the way.

  Two things are asserted here and they answer different questions. Totality
  answers "has anybody decided which side of the boundary this table sits on",
  and it is the constraint the plan calls the most important in the build and
  the one most likely to be forgotten under time pressure: a schema that nobody
  classified fails this file the moment it compiles, not the day somebody
  notices. Disjointness answers "did they decide once", because a table in two
  zones is a table whose grants are argued over rather than derived.

  Table names are never written out here except to name the two the person zone
  must contain. Everything else derives from `__schema__(:source)`, so the sweep
  in `HospitalityComs.BoundaryTest` and the classification cannot drift apart.
  """

  use ExUnit.Case, async: true

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Zones

  # Two schemas defined at the bottom of this file, in the states the
  # classification has to fail on: unclassified, and classified but nameless.
  alias __MODULE__.Embedded
  alias __MODULE__.Ghost

  describe "totality" do
    test "every Ecto schema compiled into the application is classified" do
      unclassified = Zones.unclassified()

      assert unclassified == [],
             """
             These schemas are in no zone: #{inspect(unclassified)}

             Adding a table is not finished until somebody has decided which
             side of the boundary it sits on. Classify them in \
             HospitalityComs.Zones.
             """
    end

    test "an unclassified schema is what the check above would report" do
      # The control, running the same function the assertion above runs. A
      # totality check nobody has watched return a non-empty list is a check
      # nobody has tested. `Ghost` cannot drive `all_schemas/0` — a schema
      # defined in a test file is loaded but not listed in the application — so
      # the list is handed in instead.
      assert Zones.unclassified([Ghost]) == [Ghost]
      assert Zones.unclassified([Person, PersonToken]) == []
      assert Zones.unclassified([Person, Ghost]) == [Ghost]
    end

    test "the schema discovery it rests on actually finds schemas" do
      # Without this the test above passes when `all_schemas/0` returns nothing,
      # which is what a renamed application or an unloaded module list looks
      # like from here.
      schemas = Zones.all_schemas()

      assert Person in schemas
      assert PersonToken in schemas
    end

    test "nothing is classified that is not a schema" do
      assert Zones.classified() -- Zones.all_schemas() == []
    end
  end

  defmodule Ghost do
    @moduledoc "A schema nobody classified, which is the state every new one starts in."

    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "ghosts" do
    end
  end

  describe "zone/1" do
    test "places the person's own tables in the person zone" do
      assert Zones.zone(Person) == {:ok, :person}
      assert Zones.zone(PersonToken) == {:ok, :person}
    end

    test "refuses a module nobody classified" do
      assert Zones.zone(__MODULE__) == {:error, :unclassified}
    end
  end

  describe "disjointness" do
    test "no schema sits in two zones" do
      overlapping = Zones.overlapping()

      assert overlapping == [],
             """
             These schemas are in more than one zone: #{inspect(overlapping)}

             A table in two zones is a table whose grants are argued over \
             rather than derived. Pick one.
             """
    end

    test "a schema in two zones is what the check above would report" do
      # The control, and the reason this check is not written as
      # `person_zone() -- employer_zone() == person_zone()`. The employer and
      # shared lists are empty until U4 and U5, so that spelling is
      # `[A, B] -- [] == [A, B]` — a comparison that cannot fail, and one whose
      # vacuity nothing in this file acknowledged.
      assert Zones.overlapping(person: [Person], employer: [Person]) == [Person]
      assert Zones.overlapping(person: [Person], employer: [PersonToken]) == []

      assert Zones.overlapping(person: [Person, PersonToken], shared: [PersonToken]) ==
               [PersonToken]
    end

    test "no schema is listed twice inside one zone" do
      # A different defect from the one above, and `overlapping/1` deliberately
      # does not conflate them: a schema written twice in one list is one
      # placement typed twice, not two zones disagreeing. It is still worth
      # catching, and this is what catches it.
      assert Zones.overlapping(person: [Person, Person]) == []
      assert Zones.classified() == Enum.uniq(Zones.classified())
    end
  end

  describe "person_zone_tables/0" do
    test "names the person row and the bearer credentials that stand for it" do
      tables = Zones.person_zone_tables()

      assert "people" in tables

      # `people_tokens` holds session credentials. A role that could read it
      # would not need to read `people` to become a worker, so an omission here
      # is invisible and total.
      assert "people_tokens" in tables
    end

    test "derives from the schemas rather than from a second list" do
      assert Zones.person_zone_tables() ==
               Enum.map(Zones.person_zone(), & &1.__schema__(:source))
    end
  end

  describe "tables/1" do
    test "names the tables of the schemas it is handed" do
      # The control. Without it the refusal below passes on a function that
      # refuses everything.
      assert Zones.tables([Person, PersonToken]) == ["people", "people_tokens"]
    end

    test "refuses a schema that names no table" do
      # `__schema__(:source)` is nil for an embedded schema, and a nil is not
      # false to Postgres: `has_table_privilege(role, NULL, priv)` is NULL, the
      # sweep's WHERE drops the row, and the audit reports the table clean
      # having never asked about it. A silent skip is the one failure this
      # module must not have, so it is an exception instead.
      assert_raise ArgumentError, ~r/names no table/, fn -> Zones.tables([Embedded]) end
    end
  end

  defmodule Embedded do
    @moduledoc "A schema with rows but no table of its own, which is what nil means."

    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field(:note, :string)
    end
  end

  describe "person_zone_table?/1" do
    test "recognises a person-zone table" do
      assert Zones.person_zone_table?("people")
      assert Zones.person_zone_table?("people_tokens")
    end

    test "does not recognise a table it has never been told about" do
      refute Zones.person_zone_table?("venues")
      refute Zones.person_zone_table?("schema_migrations")
    end
  end

  describe "person_zone_schema?/1" do
    test "recognises a person-zone schema" do
      assert Zones.person_zone_schema?(Person)
      assert Zones.person_zone_schema?(PersonToken)
    end

    test "does not recognise a module that is not one" do
      refute Zones.person_zone_schema?(__MODULE__)
      refute Zones.person_zone_schema?(nil)
    end
  end
end
