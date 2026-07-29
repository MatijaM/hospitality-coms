defmodule HospitalityComs.TestDatabaseGuardTest do
  @moduledoc """
  The guard runs once in `test_helper.exs`, before ExUnit has a test to run, so
  nothing in the suite can observe it doing its job. This file does the same
  thing to the same database on purpose, at the point in the run where that is
  safe.

  Safe means two things. The file is not sandboxed — it writes committed rows,
  like every other file that goes through
  `HospitalityComs.EngagementsFixtures.real_connections/0` — and `async: false`,
  which is what makes `TRUNCATE` legitimate here: ExUnit finishes every async
  module before it starts a synchronous one, so the only committed rows in the
  database while these tests run are the ones they wrote themselves.

  Each test reproduces one of the three residues the guard's moduledoc names,
  and the last reproduces the reason the guard cannot simply call the fixtures'
  purge and trust it.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias HospitalityComs.EngagementsFixtures
  alias HospitalityComs.Repo
  alias HospitalityComs.TestDatabaseGuard

  setup do
    EngagementsFixtures.real_connections()
  end

  describe "sweep/0 on a database with nothing in it" do
    test "prints nothing and leaves it alone" do
      # Swept once so the emptiness is this test's claim rather than an
      # assumption about what ran before it.
      capture_io(:stderr, &TestDatabaseGuard.sweep/0)

      assert capture_io(:stderr, &TestDatabaseGuard.sweep/0) == ""
      assert occupied() == []
    end
  end

  describe "sweep/0 on residue a fixture wrote" do
    test "clears it and reports it as the fixtures' purge's work" do
      {employer, _creation} = EngagementsFixtures.scoped_venue_fixture()
      person = EngagementsFixtures.person_scope_fixture()
      EngagementsFixtures.engagement_fixture(employer, person)

      report = capture_io(:stderr, &TestDatabaseGuard.sweep/0)

      assert report =~ "LEFTOVER TEST DATA CLEARED BEFORE THE FIRST TEST RAN"
      assert report =~ "cleared by the fixtures' purge"
      assert report =~ "engagements 1"
      assert report =~ "venues 1"
      refute report =~ "BEYOND THE FIXTURES' PURGE"
      assert occupied() == []
    end
  end

  describe "sweep/0 on a job that outlived its venue" do
    test "clears it and says the purge could not have" do
      orphan_job(Ecto.UUID.generate())

      # The reviewer's case, and the reason the guard cannot stop at the purge:
      # `purge/0` removes `oban_jobs` by the venues their args name, so a job
      # whose venue is already gone matches nothing and survives every run.
      assert EngagementsFixtures.purge() == :ok
      assert occupied() == ["oban_jobs"]

      report = capture_io(:stderr, &TestDatabaseGuard.sweep/0)

      assert report =~ "queue residue"
      assert report =~ "oban_jobs 1"
      assert report =~ "the purge cannot reach"
      refute report =~ "BEYOND THE FIXTURES' PURGE"
      assert occupied() == []
    end
  end

  describe "sweep/0 on residue no fixture wrote" do
    test "clears it and says so loudly" do
      probe_person("guard-probe@example.com")

      # Nothing removes this one: it matches no prefix, so the purge leaves it,
      # and it is what makes `Repo.aggregate(Person, :count) == 0` in
      # `HospitalityComs.AccountsDeliveryTest` fail in a file that never wrote
      # a person.
      assert EngagementsFixtures.purge() == :ok
      assert occupied() == ["people"]

      report = capture_io(:stderr, &TestDatabaseGuard.sweep/0)

      assert report =~ "BEYOND THE FIXTURES' PURGE"
      assert report =~ "people 1"
      assert report =~ "a hand-made probe"
      assert occupied() == []
    end
  end

  describe "sweep/0 when the fixtures' purge raises on what it finds" do
    test "clears the database anyway and names the failure" do
      engagement_at_an_unprefixed_venue()

      # `purge/0` is one transaction: it deletes engagements by venue, misses
      # this one because the venue no longer carries the prefix, and then
      # hits `foreign_key_violation` deleting the person the engagement
      # names — rolling back everything it had removed. This is the case that
      # does not heal across runs, because every run fails it identically.
      #
      # It surfaces as a `RuntimeError` rather than the underlying
      # `Postgrex.Error` because `purge/0` rescues and re-raises, naming the
      # residue and the remedy. That wrapping is the thing worth pinning: the
      # raw error says a constraint was violated, which reads as a product bug
      # in whatever file happened to run first.
      message = assert_raise RuntimeError, &EngagementsFixtures.purge/0
      assert message.message =~ "foreign_key_violation"
      assert message.message =~ "non-sandboxed run left behind"
      assert message.message =~ "mix ecto.drop"
      assert occupied() != []

      report = capture_io(:stderr, &TestDatabaseGuard.sweep/0)

      assert report =~ "the purge itself raised"
      assert report =~ "foreign_key_violation"
      assert report =~ "BEYOND THE FIXTURES' PURGE"
      assert occupied() == []
    end
  end

  # Tables holding rows, by the same reckoning the guard uses, so a table this
  # checkout has no schema for still counts.
  @spec occupied() :: [String.t()]
  defp occupied do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname <> 'schema_migrations'
          AND (xpath(
                 '/row/n/text()',
                 query_to_xml(
                   format('SELECT count(*) AS n FROM %I.%I', n.nspname, c.relname),
                   false, true, ''
                 )
               ))[1]::text::bigint > 0
        ORDER BY c.relname
        """,
        []
      )

    Enum.map(rows, &hd/1)
  end

  @spec orphan_job(Ecto.UUID.t()) :: :ok
  defp orphan_job(venue_id) do
    Repo.query!(
      "INSERT INTO oban_jobs (queue, worker, args) VALUES ('default', $1, $2::jsonb)",
      ["HospitalityComs.Workers.ExpireEngagement", ~s({"venue_id": "#{venue_id}"})]
    )

    :ok
  end

  @spec probe_person(String.t()) :: :ok
  defp probe_person(email) do
    Repo.query!(
      """
      INSERT INTO people (id, email, display_name, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, 'Captain Nemo', now(), now())
      """,
      [email]
    )

    :ok
  end

  # A prefixed person holding an engagement at a venue the purge cannot find.
  # Built through the fixtures and then renamed, because an engagement is the
  # one row that has to resolve foreign keys into both zones.
  @spec engagement_at_an_unprefixed_venue() :: :ok
  defp engagement_at_an_unprefixed_venue do
    {employer, %{venue: venue}} = EngagementsFixtures.scoped_venue_fixture()
    person = EngagementsFixtures.person_scope_fixture()
    EngagementsFixtures.engagement_fixture(employer, person)

    # `$2::uuid` alone would make Postgres infer the parameter as `uuid` and
    # Postgrex would then want sixteen raw bytes rather than the string an
    # `Ecto.UUID` field carries.
    Repo.query!("UPDATE venues SET name = $1 WHERE id = $2::text::uuid", [
      "guard-probe-venue",
      venue.id
    ])

    :ok
  end
end
