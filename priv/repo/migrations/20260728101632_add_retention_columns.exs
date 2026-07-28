defmodule HospitalityComs.Repo.Migrations.AddRetentionColumns do
  @moduledoc """
  The stamped deadlines KTD16 asks for, the worker's own archive, and the log
  the unattended deleter writes.

  ## A deadline is a column, never a join

  This is the unit's whole thesis and the reason this migration exists at all.
  Every one of the four retention triggers reads a `delete_after` column written
  when the row was created — or, for venue-room history, when the venue was
  closed. None of them joins the period the deadline was derived from.

  Computing at sweep time reads as the tidier design and is the dangerous one: a
  manager entering a backdated end date, or correcting a shift's hours, would
  move a deletion deadline into the past, and the next unattended run would
  destroy a worker's messages with no notice and no way back. A stamped column
  turns "does any write anywhere move a deadline backwards" from a question
  about every future code path into a question about this migration.

  ## Four deadlines, three columns, and one that is deliberately null

    * `room_messages.delete_after` is `closes_at + 30 days` for a shift-room
      message, stamped at insert from the room the sender had already resolved,
      and **null** for a venue-room message. Venue-room history has no clock
      while the venue exists (KTD16), and `delete_after < instant` never matches
      a null — so the sweeper passes over it for ever without needing to know
      why.
    * `roster_entries.delete_after` is the same instant, from the same room, so
      a shift's messages and its roster go together. It is `NOT NULL`: a roster
      entry always names a room, so the deadline is always knowable, and a
      nullable column would be a second state nothing means.
    * `venues.closed_at` is the trigger for the third. Closing a venue stamps
      `delete_after` on the venue-room messages whose deadline is still null —
      **only** those, so a shift message's already-fixed deadline is neither
      extended nor shortened by the venue closing, and the "shorter deadline
      silently wins" failure KTD16 names cannot arise from this direction.
    * `retained_message_copies.delete_after` is the engagement's closed upper
      bound plus ninety days, and — like the venue-room column above — **null
      until the event that starts the clock happens**. A copy is written when
      the message is, while the term is still open and `ends_at` can still
      move; the deadline is stamped once, when the term closes and `ends_at`
      can no longer move. Null therefore means one thing in both columns: no
      clock yet, because the event that starts it has not occurred.

  Engagements and attested entries get no deadline at all, deliberately: they
  are the person's portable record.

  ## `retained_message_copies` carries the body, not a reference

  KTD16 requires the worker's archive to be physically separate rows rather than
  a filtered view over the employer-zone message, because one row cannot carry
  two deadlines — a person whose engagement ended long after a shift would lose
  their own copy on the shift's clock. So the copy holds the body and the
  instant it was sent, and outlives the row it came from.

  **The copy is written in the same transaction as the message.** Writing it
  when the *engagement* closed reintroduced the exact failure the sentence above
  names: a shift message dies at `closes_at + 30 days` and an ordinary term
  outlives its shifts by more than a month, so the venue's copy was swept long
  before the archive was taken and the worker's copy was never created at all.
  The trigger has to fire no later than the source row's own deadline, and the
  earliest such instant is the insert.

  `source_message_id` is the idempotence key and is **not** a foreign key. Two
  reasons, each independently sufficient:

    * `ON DELETE RESTRICT` would make the shift-history sweep fail the moment a
      copy outlived its original, which is the copy's entire purpose;
    * `ON DELETE CASCADE` would delete the worker's archive on the venue's
      clock, which is the failure the separation exists to prevent.

  It is **not** because a person-zone key into the employer zone would be a
  second crossing. It would not be: KTD2's single crossing is about naming a
  *person*, arrows point into the employer zone freely, and
  `attested_entry_disclosures.audience_venue_id` is already exactly such a key.
  The two reasons above are the whole of it.

  Ownership is still a database rule rather than an application one:
  `(engagement_id, person_id)` is a `MATCH FULL` composite key into
  `engagements (id, person_id)` — the index U9's `create_profiles` created for
  `attested_entry_disclosures`, reused here rather than duplicated. That is what
  makes this migration depend on `create_profiles`, and why the proof suite has
  to roll it down before it.

  ## `retention_runs` is a log, and it is person zone

  It names no person and no venue, and holds nothing but an instant, four counts
  and an outcome. It is classified person zone because that is what the person
  zone *means* in `HospitalityComs.Zones` — the tables `employer_role` holds no
  privilege on — and there is no reading under which a venue's session should be
  able to read what the deleter did across every venue in the installation.

  The instant it records is the one the sweep *used*, not the one the row was
  written at. Those differ whenever the clock is injected, which is every run in
  the suite and every run of U11's demo control, and the useful one is the first.

  ## `roster_entries.delete_after` is `NOT NULL` with no default, and that
  ## constrains the deploy order

  `up` backfills from `shift_rooms` before adding the constraint rather than
  defaulting it: a default would be a deadline nobody derived, on rows the
  sweeper deletes. The consequence is that **code which predates U10 cannot
  insert a roster entry once this migration has run** — `Rosters.add_to_roster/3`
  stamps the column, and a build without that change writes a null and is
  refused. So this migration is deploy-before-migrate: ship the application
  first, migrate second. The three-phase alternative — add nullable, deploy the
  writer, backfill and `SET NOT NULL` in a second migration — buys a
  rolling-deploy window and costs two migrations and a period in which the
  column means nothing; it is the right shape at scale and is deliberately not
  taken here.

  `add_room_deadlines/0` is the same trade one step further: `ADD COLUMN`, a
  full backfill, `SET NOT NULL` and two index builds against `room_messages` —
  every chat message in the product — inside one transaction holding
  `ACCESS EXCLUSIVE`, with no `@disable_ddl_transaction` and no `CONCURRENTLY`.
  At production scale that is a write outage on the messaging path. Recorded
  rather than fixed: `CONCURRENTLY` cannot run inside a migration's transaction,
  so fixing it means the same three-phase split.

  ## `down` gives the three columns and the two tables back, and **loses data**

  The schema comes back byte for byte. Two things do not:

    * `retained_message_copies` returns **empty**, and where the shift sweep has
      already taken the source rows the words are gone from both tables. Rolling
      forward again re-creates copies only for messages that still exist.
    * `venues.closed_at` returns **empty**, so a venue that was wound up reverts
      to trading and its venue-room messages revert to a null deadline —
      indefinite retention, which is a data-protection regression rather than a
      tidy-up. Rolling forward again does not restore it: `close_venue/2` has to
      be run a second time, at a new instant.

  Capture both before rolling back, and restore them by hand afterwards:

      COPY (SELECT * FROM retained_message_copies) TO '/tmp/copies.csv' CSV HEADER;
      COPY (SELECT id, closed_at FROM venues WHERE closed_at IS NOT NULL)
        TO '/tmp/closures.csv' CSV HEADER;

  `room_messages.delete_after` and `roster_entries.delete_after` are the
  reversible half: `up` recomputes both from `shift_rooms.closes_at`, which does
  not move. Venue-room deadlines are not, for the reason above.
  """

  use Ecto.Migration

  # Mirrored from `HospitalityComs.Rooms.RoomMessage.max_body_length/0`, for the
  # reason `create_rooms` mirrors a grace bound from `ShiftType`: a body the
  # database refuses is a body the changeset would have refused too.
  @max_body_length 4000

  # Mirrored from `HospitalityComs.Lifecycle.history_retention_days/0`. A
  # migration cannot call the module — it may not be compiled when the migration
  # runs — so the number is written here and pinned against the function by
  # `HospitalityComs.Workers.RetentionSweeperTest`, which derives every
  # boundary it sweeps at from the function rather than from a literal.
  @history_retention_days 30

  @copy_engagement_fkey "retained_message_copies_engagement_fkey"

  def up do
    add_room_deadlines()
    add_venue_closure()
    create_retained_message_copies()
    create_retention_runs()
  end

  # In dependency order, which is the reverse of `up`.
  def down do
    drop(table(:retention_runs))
    drop(table(:retained_message_copies))

    alter table(:venues) do
      remove(:closed_at)
    end

    drop(index(:roster_entries, [:delete_after, :id]))
    drop(index(:room_messages, [:delete_after, :id]))

    alter table(:roster_entries) do
      remove(:delete_after)
    end

    alter table(:room_messages) do
      remove(:delete_after)
    end
  end

  ## The shift's clock, on both tables it reaches

  defp add_room_deadlines do
    alter table(:room_messages) do
      # Null is the venue room, which has no clock until the venue closes.
      add(:delete_after, :utc_datetime)
    end

    alter table(:roster_entries) do
      add(:delete_after, :utc_datetime)
    end

    # Backfilled from the room rather than defaulted, so every existing row
    # carries the deadline it would have been stamped with. `closes_at` is the
    # generated column `create_rooms` added.
    execute("""
    UPDATE room_messages AS m
       SET delete_after = r.closes_at + interval '#{@history_retention_days} days'
      FROM shift_rooms AS r
     WHERE m.shift_room_id = r.id
    """)

    execute("""
    UPDATE roster_entries AS e
       SET delete_after = r.closes_at + interval '#{@history_retention_days} days'
      FROM shift_rooms AS r
     WHERE e.shift_room_id = r.id
    """)

    alter table(:roster_entries) do
      modify(:delete_after, :utc_datetime, null: false)
    end

    # The sweep's own indexes, on the column it filters and the tie-break it
    # orders by. `AGENTS.md`: a new query on a new column combination ships with
    # an index in the same migration.
    create(index(:room_messages, [:delete_after, :id]))
    create(index(:roster_entries, [:delete_after, :id]))
  end

  ## The venue's clock

  defp add_venue_closure do
    alter table(:venues) do
      add(:closed_at, :utc_datetime)
    end
  end

  ## The worker's archive

  defp create_retained_message_copies do
    create table(:retained_message_copies, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # The bridge, from the person's side, paired with the owner so the
      # composite key below can say whose engagement it is. The reference is
      # added after the table because Ecto's `references/2` writes a
      # single-column key and this one is two.
      add(:engagement_id, :binary_id, null: false)
      add(:person_id, :binary_id, null: false)

      # The idempotence key, and deliberately not a foreign key. See the
      # moduledoc.
      add(:source_message_id, :binary_id, null: false)

      add(:body, :text, null: false)
      add(:sent_at, :utc_datetime, null: false)

      add(:retained_at, :utc_datetime, null: false)

      # Null while the engagement is open, exactly as `room_messages` is null
      # while the venue trades. The copy is written with the message, when
      # `ends_at` can still move; the deadline is stamped when the term closes,
      # from a bound that can no longer move — `renew_engagement/3` answers on
      # activeness and `end_engagement/2` on "has not closed", so neither can
      # reach a closed term.
      add(:delete_after, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    # One copy per message per engagement, which is what makes re-running the
    # expiry announcement free.
    create(unique_index(:retained_message_copies, [:engagement_id, :source_message_id]))

    # The person's own read of their archive, in the order it is read.
    create(index(:retained_message_copies, [:person_id, :sent_at, :id]))

    create(index(:retained_message_copies, [:delete_after, :id]))

    # MATCH FULL: neither column of the key is nullable, so a row either names
    # one of this person's own engagements or is refused.
    execute("""
    ALTER TABLE retained_message_copies
      ADD CONSTRAINT #{@copy_engagement_fkey}
      FOREIGN KEY (engagement_id, person_id)
      REFERENCES engagements (id, person_id)
      MATCH FULL
      ON DELETE RESTRICT
    """)

    create(
      constraint(:retained_message_copies, :retained_message_copies_body_present,
        check: "length(btrim(body)) > 0"
      )
    )

    create(
      constraint(:retained_message_copies, :retained_message_copies_body_within_bound,
        check: "length(body) <= #{@max_body_length}"
      )
    )

    # A deadline before the message was sent would be a copy retained for a
    # negative length of time, which the sweeper would delete on its first run.
    #
    # The `IS NULL` disjunct is spelled out rather than left to Postgres. A
    # CHECK is satisfied by null, so `delete_after >= sent_at` would already
    # admit an unstamped copy — writing it down is what stops a later reader
    # concluding the column must be set, which is the trap
    # `connection_requests_decline_blocks_requester` was written into once.
    create(
      constraint(:retained_message_copies, :retained_message_copies_deadline_after_sending,
        check: "delete_after IS NULL OR delete_after >= sent_at"
      )
    )
  end

  ## The deleter's log

  defp create_retention_runs do
    create table(:retention_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # The instant the sweep *used*, which is not the instant the row was
      # written whenever the clock is injected.
      add(:ran_at, :utc_datetime, null: false)

      add(:outcome, :string, null: false)
      add(:ceiling, :integer, null: false)

      add(:own_message_copies, :integer, null: false)
      add(:shift_messages, :integer, null: false)
      add(:roster_entries, :integer, null: false)
      add(:venue_room_messages, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:retention_runs, [:ran_at, :id]))

    create(
      constraint(:retention_runs, :retention_runs_outcome_known,
        check: "outcome IN ('completed', 'refused')"
      )
    )

    create(
      constraint(:retention_runs, :retention_runs_counts_not_negative,
        check:
          "own_message_copies >= 0 AND shift_messages >= 0 AND " <>
            "roster_entries >= 0 AND venue_room_messages >= 0"
      )
    )

    create(constraint(:retention_runs, :retention_runs_ceiling_positive, check: "ceiling > 0"))
  end
end
