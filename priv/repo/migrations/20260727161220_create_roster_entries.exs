defmodule HospitalityComs.Repo.Migrations.CreateRosterEntries do
  @moduledoc """
  The table KTD6b replaced a job with.

  ## What this is instead of

  The earlier design materialised a shift room's membership at shift start, so
  that a later roster correction could not retroactively withdraw access to
  messages somebody had already been able to read. It inverts under its own
  failure mode: a job firing ten minutes late captures the roster *as
  corrected*, which is the exact retroactive withdrawal it existed to prevent —
  and a run that never happened is indistinguishable from a roster that was
  empty, so nothing downstream can detect the miss.

  A roster entry carries a half-open period instead. Removal sets the upper
  bound; nothing deletes the row. Read membership is
  `roster_entries.period && [starts_at, ends_at + grace)`, which makes
  non-retroactivity **structural** — there is no write anywhere that can shorten
  an overlap that has already happened, because closing a period at `now` can
  only ever leave the part before `now` intact.

  The whole class of missed-job, double-run and message-before-snapshot failures
  goes with the job. So does a demo problem: an injected clock advance does not
  make Oban fire, so under the snapshot design the one thing the demo could not
  exercise was the room mechanism it exists to show.

  ## The period, and the two bounds it does not have

  `[joined_at, left_at)`, generated into a `tstzrange` from the same two columns
  the queries read, exactly as `engagements.period` is. `left_at` is null while
  the person is still rostered, which makes the range unbounded above — the
  right reading of "still on this shift's roster", and the one that makes an
  entry added mid-shift overlap the rest of the room's open interval without
  anybody having to decide what its upper bound should be.

  There is no lower-infinite form and no `NOT NULL` on `left_at`. A roster entry
  is not an engagement (R2's "no open-ended form" is about engagements), and the
  interval that bounds it is the shift's, which is fixed.

  `joined_at` is the instant the rostering happened, not the shift's start. That
  is what makes "rostered on Monday for Friday's shift, removed on Tuesday" a
  period that ends before the room ever opens — no overlap, so the person never
  appears in it and never could have. Stamping `joined_at` at the shift's start
  instead would make that case indistinguishable from somebody who worked the
  shift.

  ## The exclusion constraint is the GiST index KTD6b asks for

  `EXCLUDE USING gist (shift_room_id WITH =, engagement_id WITH =, period WITH
  &&)` is the same shape as `engagements_no_overlap`, and it does two jobs at
  once: it refuses two overlapping roster periods for one person on one shift,
  and the index it builds is the one the overlap query wants. Named explicitly,
  so `HospitalityComs.Rosters.RosterEntry` can declare a matching
  `exclusion_constraint/3` and the violation arrives as a changeset error rather
  than raising through the transaction — without the name, the repository's
  enumerated-error convention is a lie at the one place it is load bearing.

  It needs `btree_gist` for the two `uuid WITH =` operands, which U5's
  `*_enable_btree_gist.exs` installs. That migration's `down` is now refused by
  a third exclusion constraint rather than by one, which is `RESTRICT` doing its
  job.

  Adjacent periods are not a violation: removing somebody at `t` and rostering
  them again at `t` gives `[a, t)` and `[t, ∞)`, which do not overlap. Neither
  is an entry removed at the instant it was added — `[t, t)` is the empty range,
  which overlaps nothing at all, including the room. It is the correct record of
  a rostering somebody undid immediately: the person was never in the room, and
  their dates are free again.

  ## It names the engagement, and that is KTD2 rather than convenience

  `roster_entries` is an employer-zone table and therefore may not carry
  `person_id` — no employer-zone row anywhere names a human. It references
  `engagements (id, venue_id)` with a `MATCH FULL` composite key, so a roster
  entry at venue A cannot name an engagement at venue B whatever the context
  believes, and the association to a person is made from the person's side by
  following the bridge.

  Both composite keys here are `MATCH FULL`: every column of both is `NOT NULL`,
  so neither meets the exception U4, U5 and `create_rooms` documented.
  """

  use Ecto.Migration

  @shift_room_fkey "roster_entries_shift_room_fkey"
  @engagement_fkey "roster_entries_engagement_fkey"

  @overlap_constraint "roster_entries_no_overlap"

  def up do
    create table(:roster_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :venue_id, references(:venues, type: :binary_id, on_delete: :restrict), null: false

      add :shift_room_id, :binary_id, null: false

      # The bridge, not the person. See the moduledoc.
      add :engagement_id, :binary_id, null: false

      add :joined_at, :utc_datetime, null: false

      # Null while the person is still rostered. Removal sets it; nothing
      # deletes the row, which is the whole of KTD6b.
      add :left_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Nothing references a roster entry yet. The index is here because the
    # employer zone's rule is that every table other than `venues` carries one,
    # and a rule with an exception is a rule somebody argues with.
    create unique_index(:roster_entries, [:id, :venue_id])

    create index(:roster_entries, [:venue_id])
    create index(:roster_entries, [:engagement_id])

    execute("""
    ALTER TABLE roster_entries
      ADD CONSTRAINT #{@shift_room_fkey}
      FOREIGN KEY (shift_room_id, venue_id)
      REFERENCES shift_rooms (id, venue_id)
      MATCH FULL
      ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE roster_entries
      ADD CONSTRAINT #{@engagement_fkey}
      FOREIGN KEY (engagement_id, venue_id)
      REFERENCES engagements (id, venue_id)
      MATCH FULL
      ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE roster_entries
      ADD COLUMN period tstzrange
      GENERATED ALWAYS AS (
        tstzrange(joined_at AT TIME ZONE 'UTC', left_at AT TIME ZONE 'UTC', '[)')
      ) STORED
    """)

    execute("""
    ALTER TABLE roster_entries
      ADD CONSTRAINT #{@overlap_constraint}
      EXCLUDE USING gist (shift_room_id WITH =, engagement_id WITH =, period WITH &&)
    """)

    # `>=` rather than `>`, matching every other period in this schema: an entry
    # removed at the instant it was added is the empty range, which is a real
    # and meaningful state. A strictly reversed pair never reaches the
    # constraint — the generation expression raises first.
    create constraint(:roster_entries, :roster_entries_period_not_reversed,
             check: "left_at IS NULL OR left_at >= joined_at"
           )
  end

  # One table, so `DROP TABLE` takes the generated column, the exclusion
  # constraint and its index with it.
  def down do
    drop(table(:roster_entries))
  end
end
