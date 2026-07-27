defmodule HospitalityComs.Repo.Migrations.CreateVenues do
  @moduledoc """
  The first three tables of the employer zone: `venues`, `employer_grants` and
  `shift_types`.

  ## No column here names a person, and that is the constraint

  KTD2 partitions the schema so that `engagements.person_id` is the single
  crossing between the zones. Every employer-zone table therefore carries
  `venue_id` and never `person_id`, and the proof suite asserts it against
  `pg_constraint` rather than against a convention. These are the first tables
  that rule can bind on — until now it was true because the employer zone was
  empty.

  A grant is consequently a row about a *venue*, not about a human: it says
  this venue has an administrable authority outstanding. Which person holds it
  is recorded on the bridge, which U5 builds — `engagements` will carry
  `grant_id` referencing `employer_grants (id, venue_id)`. The arrow points
  from the bridge into the employer zone, never the other way, which is why
  this unit can create these tables with no forward reference to a table that
  does not exist yet.

  ## The composite unique indexes are not redundant

  `unique_index(:employer_grants, [:id, :venue_id])` looks like noise next to a
  primary key on `id` alone, and it is the load-bearing half of KTD2. A
  composite foreign key can only reference a uniquely-constrained column list,
  so without it no later table can say
  `FOREIGN KEY (grant_id, venue_id) REFERENCES employer_grants (id, venue_id)`
  — and a plain `FOREIGN KEY (grant_id) REFERENCES employer_grants (id)` lets a
  row at venue A point at a grant belonging to venue B, which is precisely the
  cross-tenant edge the zone partition exists to make unrepresentable.

  `employer_grants.granted_by_grant_id` uses one already, so the pattern is
  exercised inside this unit rather than only promised to later ones.

  `venues` gets none: a venue's own `id` *is* the venue key, so a plain
  reference to `venues (id)` already carries the whole of the tenancy.

  ## Time is stored as instants and activeness is derived

  A grant has `granted_at` and a nullable `revoked_at`, and is live at an
  instant `t` when `granted_at <= t < revoked_at` — half-open, matching KTD4.
  Nothing stores whether a grant is active, because a cached authorization
  decision is the failure the whole design exists to prevent.

  `venues.timezone` is an IANA name and is required (KTD20). Engagement end is
  end-of-day in venue time and close shifts cross midnight routinely, so a
  venue whose zone is unknown has no defined expiry instant. Postgres cannot
  check the name in a table constraint — the timezone database is not immutable
  — so the check is `HospitalityComs.Venues.Venue`'s, against
  `pg_timezone_names`. What is enforced here is that the column is present and
  not empty, which is the part a constraint can hold.
  """

  use Ecto.Migration

  # Two hours, in minutes. A shift room accepts messages until its type's grace
  # period elapses (R11); a grace longer than this stops being a grace and
  # starts being a second shift.
  @max_grace_minutes 120

  @grant_lineage_constraint "employer_grants_granted_by_fkey"

  def up do
    create table(:venues, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :timezone, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create constraint(:venues, :venues_name_present, check: "length(btrim(name)) > 0")
    create constraint(:venues, :venues_timezone_present, check: "length(btrim(timezone)) > 0")

    create table(:employer_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :venue_id, references(:venues, type: :binary_id, on_delete: :restrict), null: false

      # The grant that issued this one. Null on the grant seeded at venue
      # creation, which is the only one with nobody above it — that is what
      # makes the founding grant identifiable without naming its holder.
      add :granted_by_grant_id, :binary_id

      add :granted_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # The referenced list for every composite foreign key aimed at a grant,
    # this migration's own included. See the moduledoc.
    create unique_index(:employer_grants, [:id, :venue_id])
    create index(:employer_grants, [:venue_id])

    # Added after the unique index rather than inline in `create table`,
    # because a foreign key needs the constraint it references to exist first.
    #
    # MATCH SIMPLE, deliberately, and it is the one place in this schema where
    # the plan's "MATCH FULL throughout" does not apply. MATCH FULL means a
    # composite key is either wholly null or wholly present — the right rule
    # when every column of the key is mandatory. Here `venue_id` is `NOT NULL`
    # and `granted_by_grant_id` is null on the founding grant, so MATCH FULL
    # would reject the one row every venue must have. MATCH SIMPLE skips the
    # check only when some column is null, and the only column that can be is
    # the lineage — so "some null" and "no lineage" are the same state, and a
    # grant that *does* name a parent is checked against both columns.
    execute(
      """
      ALTER TABLE employer_grants
        ADD CONSTRAINT #{@grant_lineage_constraint}
        FOREIGN KEY (granted_by_grant_id, venue_id)
        REFERENCES employer_grants (id, venue_id)
        MATCH SIMPLE
        ON DELETE RESTRICT
      """,
      "ALTER TABLE employer_grants DROP CONSTRAINT #{@grant_lineage_constraint}"
    )

    create constraint(:employer_grants, :employer_grants_revoked_after_granted,
             check: "revoked_at IS NULL OR revoked_at >= granted_at"
           )

    # A grant cannot have issued itself. The composite foreign key above is
    # satisfied by a self-reference, and a self-issued grant would be a
    # founding grant wearing a lineage.
    create constraint(:employer_grants, :employer_grants_not_self_issued,
             check: "granted_by_grant_id IS NULL OR granted_by_grant_id <> id"
           )

    create table(:shift_types, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :venue_id, references(:venues, type: :binary_id, on_delete: :restrict), null: false

      add :name, :string, null: false
      add :grace_period_minutes, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:shift_types, [:id, :venue_id])
    create unique_index(:shift_types, [:venue_id, :name])

    create constraint(:shift_types, :shift_types_grace_within_two_hours,
             check: "grace_period_minutes >= 0 AND grace_period_minutes <= #{@max_grace_minutes}"
           )

    create constraint(:shift_types, :shift_types_name_present, check: "length(btrim(name)) > 0")
  end

  def down do
    drop table(:shift_types)

    execute("ALTER TABLE employer_grants DROP CONSTRAINT #{@grant_lineage_constraint}")

    drop table(:employer_grants)
    drop table(:venues)
  end
end
