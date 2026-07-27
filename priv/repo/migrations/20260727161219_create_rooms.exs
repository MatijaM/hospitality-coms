defmodule HospitalityComs.Repo.Migrations.CreateRooms do
  @moduledoc """
  Shift rooms, the messages both room kinds hold, and the suspension that takes
  a person out of a venue room without telling the employer.

  ## There is no `venue_rooms` table, and that is the unit's thesis

  A venue room is exactly one per venue, its membership is a query over active
  engagements, and there is no state it could hold that is not already held by
  `venues` and `engagements`. So it has no row. `HospitalityComs.Rooms.VenueRoom`
  is a struct derived from a venue, and a message belonging to a venue room is a
  `room_messages` row whose `shift_room_id` is null.

  Materialising it would have been the same mistake in miniature that KTD6b
  rejects at full size: a second place for membership to be, which can disagree
  with the first.

  ## A shift room *is* the shift

  There is no separate `shifts` table either. The plan's zone diagram lists both
  `shifts` and `membership_snapshots`; KTD6b deleted the second, and the first
  never had a field the room did not. One row carries the term, the type it was
  built from, and the grace it closes writes after.

  ## The grace is copied, not joined

  `grace_period_minutes` is stamped on the room from its shift type at creation
  and never read back through the association. This is the rule U5 applied to an
  invitation's term: the offer is copied onto the engagement so that editing the
  offer afterwards cannot move somebody's employment dates. The same argument
  runs here and is sharper — a shift type edited on Tuesday would otherwise
  reopen Monday's closed room, or close a room that is open, retroactively and
  for every room of that type at once.

  The bound is mirrored from `HospitalityComs.Venues.ShiftType` for the reason
  U5 mirrored a label length: a grace the database refuses is a grace the
  changeset would have refused too.

  ## The open interval, and the one place it is written down

  `closes_at` is `GENERATED ALWAYS AS (ends_at + make_interval(mins =>
  grace_period_minutes)) STORED`, and `open_period` is `GENERATED ALWAYS AS
  tstzrange(starts_at, closes_at, '[)') STORED` — spelled out from the base
  columns, because Postgres will not let one generated column read another.

  Both are immutable enough to generate only because `starts_at` and `ends_at`
  are `timestamp without time zone`: `timestamptz + interval` is `STABLE`, since
  a month or a day depends on the session's zone, while `timestamp + interval`
  is `IMMUTABLE`. `AT TIME ZONE 'UTC'` then converts, exactly and immutably,
  because every instant this application writes is UTC by construction
  (`HospitalityComs.Clock`). This is the same manoeuvre `create_engagements`
  makes for `engagements.period` and for the same reason.

  `open_period` is what `HospitalityComs.RoomsTest` checks the application's
  overlap predicate against, case by case. Two spellings of one rule is one more
  than ideal; a generated column is the database's own spelling, written once
  here, and a test that compares the two is worth more than a comment claiming
  they agree.

  ## `room_messages` holds both room kinds and names no person

  `author_engagement_id` is KTD15b: authorship resolves through the engagement,
  which already carries the employer-authored role label, so no worker's name is
  ever written into a message row and erasure reduces a number of rows
  proportional to engagements rather than to messages. It is a composite key
  into `engagements (id, venue_id)`, `MATCH FULL`, so a message at venue A
  cannot be attributed to an engagement at venue B.

  `shift_room_id` is null for a venue-room message and set for a shift-room one.
  Its composite key is `MATCH SIMPLE` — the third instance of the exception U4
  and U5 documented, and the same shape: `venue_id` is `NOT NULL` while the
  other column of the key is legitimately nullable, so `MATCH FULL` would reject
  every venue-room message. "Some column null" and "belongs to the venue room"
  are the same state, and a message that *does* name a shift room is checked
  against both columns and degenerates to `MATCH FULL`.

  No retention column. KTD16 keys shift history to the shift and venue-room
  history to venue closure, on stamped deadlines rather than computed ones —
  U10's `*_add_retention_columns.exs` owns them, and stamping a deadline before
  the sweeper that reads it exists would be a column nobody could have tested.

  ## The suspension is in the person zone, which is the whole of KTD18

  Origin R11 is one sentence carrying the document's central privacy claim:
  a person may take themselves out of the venue room, reversibly, and the
  employer must not be able to see that they have. Employer visibility of the
  flag would make it a retaliation surface rather than an opt-out.

  A column on `engagements` could not deliver that — `employer_role` holds
  table-level `SELECT` there, so the flag would arrive with every membership
  read. A column anywhere in the employer zone could not either. So the row
  lives in a table of its own that the employer role holds *no* privilege on and
  that `HospitalityComs.EmployerRepo`'s query backstop refuses to join, and the
  invisibility is a property of the grant tier rather than of a `select` list
  somebody has to remember to trim.

  It names the engagement rather than the person, which is what lets a
  person-zone table say "this person, at this venue" without carrying a venue
  key: the bridge is the one row that means both, and pointing at it from the
  person's side is what the bridge is for. There is no `venue_id` here and there
  will not be one.

  ## Suspension is a period, not a boolean

  `[suspended_at, resumed_at)`, half-open, generated into a `tstzrange` and
  guarded by an exclusion constraint on `(engagement_id, period)`. Nothing
  stores "is suspended", for the reason nothing stores "is active": a cached
  authorization decision that outlives its reason is the failure the whole
  design exists to prevent, and the same clock advance that expires an
  engagement resolves a suspension's boundary without a write.

  It also makes "suspend twice" a database error rather than a second row nobody
  notices, and it leaves a record of when the person was out — which is theirs,
  in their own zone, and reaches no employer.

  ## `down` drops the three tables and takes everything with them

  Every index, constraint and generated column here belongs to one of them. The
  raw statements are `execute/1` rather than `execute/2` for the reason
  `create_engagements` gives: a reverse handed to `execute/2` would only ever be
  run by a reversing runner, and there is none here, so it would be a second
  `down` that never executed and could drift from the one that does.
  """

  use Ecto.Migration

  # Mirrored from `HospitalityComs.Venues.ShiftType.max_grace_minutes/0`. See
  # the moduledoc.
  @max_grace_minutes 120

  # Long enough for a shift handover, short enough that the column is not a file
  # upload with extra steps.
  @max_body_length 4000

  @shift_room_shift_type_fkey "shift_rooms_shift_type_fkey"
  @message_shift_room_fkey "room_messages_shift_room_fkey"
  @message_author_fkey "room_messages_author_fkey"

  @suspension_overlap_constraint "venue_room_suspensions_no_overlap"

  def up do
    create_shift_rooms()
    create_room_messages()
    create_venue_room_suspensions()
  end

  # In dependency order, which is the reverse of `up`.
  def down do
    drop(table(:venue_room_suspensions))
    drop(table(:room_messages))
    drop(table(:shift_rooms))
  end

  ## Shift rooms

  defp create_shift_rooms do
    create table(:shift_rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :venue_id, references(:venues, type: :binary_id, on_delete: :restrict), null: false

      # The type the room was built from. Kept for provenance and for the name
      # a client renders; the grace it contributed is copied below rather than
      # read back through here.
      add :shift_type_id, :binary_id, null: false

      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false

      # Stamped at creation. See the moduledoc.
      add :grace_period_minutes, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    # The referenced list for `roster_entries` and `room_messages`, both of
    # which carry a composite key into this table.
    create unique_index(:shift_rooms, [:id, :venue_id])

    create index(:shift_rooms, [:venue_id])
    create index(:shift_rooms, [:venue_id, :starts_at, :id])

    execute("""
    ALTER TABLE shift_rooms
      ADD CONSTRAINT #{@shift_room_shift_type_fkey}
      FOREIGN KEY (shift_type_id, venue_id)
      REFERENCES shift_types (id, venue_id)
      MATCH FULL
      ON DELETE RESTRICT
    """)

    # `timestamp + interval` is IMMUTABLE where `timestamptz + interval` is only
    # STABLE, which is why these columns are `timestamp` and why the conversion
    # to `timestamptz` happens after the addition rather than before it.
    execute("""
    ALTER TABLE shift_rooms
      ADD COLUMN closes_at timestamp
      GENERATED ALWAYS AS (ends_at + make_interval(mins => grace_period_minutes)) STORED
    """)

    # Spelled out from the base columns because a generated column may not read
    # another generated column. It is the same interval `closes_at` closes.
    execute("""
    ALTER TABLE shift_rooms
      ADD COLUMN open_period tstzrange
      GENERATED ALWAYS AS (
        tstzrange(
          starts_at AT TIME ZONE 'UTC',
          (ends_at + make_interval(mins => grace_period_minutes)) AT TIME ZONE 'UTC',
          '[)'
        )
      ) STORED
    """)

    # A shift with no duration is not a shift, and an empty open interval would
    # be a room nobody could ever be in. Strict, unlike `engagements`, because
    # nothing closes a shift room early — there is no operation here
    # corresponding to ending an engagement.
    create constraint(:shift_rooms, :shift_rooms_term_ordered, check: "ends_at > starts_at")

    create constraint(:shift_rooms, :shift_rooms_grace_within_bound,
             check: "grace_period_minutes >= 0 AND grace_period_minutes <= #{@max_grace_minutes}"
           )
  end

  ## Messages, for both room kinds

  defp create_room_messages do
    create table(:room_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :venue_id, references(:venues, type: :binary_id, on_delete: :restrict), null: false

      # Null means the venue room. See the moduledoc.
      add :shift_room_id, :binary_id

      # KTD15b: authorship through the bridge, never through `people`.
      add :author_engagement_id, :binary_id, null: false

      add :body, :text, null: false
      add :sent_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:room_messages, [:id, :venue_id])

    # The history read, in the order it is read: one room's messages, oldest
    # first. `shift_room_id` is nullable and Postgres indexes nulls, so the same
    # index serves the venue room.
    create index(:room_messages, [:venue_id, :shift_room_id, :sent_at, :id])
    create index(:room_messages, [:author_engagement_id])

    # MATCH SIMPLE, and it is the documented exception: `shift_room_id` is null
    # on every venue-room message while `venue_id` never is.
    execute("""
    ALTER TABLE room_messages
      ADD CONSTRAINT #{@message_shift_room_fkey}
      FOREIGN KEY (shift_room_id, venue_id)
      REFERENCES shift_rooms (id, venue_id)
      MATCH SIMPLE
      ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE room_messages
      ADD CONSTRAINT #{@message_author_fkey}
      FOREIGN KEY (author_engagement_id, venue_id)
      REFERENCES engagements (id, venue_id)
      MATCH FULL
      ON DELETE RESTRICT
    """)

    create constraint(:room_messages, :room_messages_body_present,
             check: "length(btrim(body)) > 0"
           )

    create constraint(:room_messages, :room_messages_body_within_bound,
             check: "length(body) <= #{@max_body_length}"
           )
  end

  ## The person's own opt-out

  defp create_venue_room_suspensions do
    create table(:venue_room_suspensions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The bridge, from the person's side. No `venue_id` and no `person_id`:
      # one names an employer key in the person zone, the other duplicates the
      # single crossing. The engagement is the row that already means both.
      add :engagement_id, references(:engagements, type: :binary_id, on_delete: :restrict),
        null: false

      add :suspended_at, :utc_datetime, null: false

      # Null while the person is out. Resuming sets it; nothing deletes the row.
      add :resumed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:venue_room_suspensions, [:engagement_id])

    execute("""
    ALTER TABLE venue_room_suspensions
      ADD COLUMN period tstzrange
      GENERATED ALWAYS AS (
        tstzrange(suspended_at AT TIME ZONE 'UTC', resumed_at AT TIME ZONE 'UTC', '[)')
      ) STORED
    """)

    # One suspension at a time per engagement. Without it, suspending twice
    # leaves two open rows and resuming closes one of them, so the person stays
    # out of the room with nothing to show why.
    #
    # A null `resumed_at` makes the range unbounded above, so an open suspension
    # overlaps every later one — which is exactly the rule.
    execute("""
    ALTER TABLE venue_room_suspensions
      ADD CONSTRAINT #{@suspension_overlap_constraint}
      EXCLUDE USING gist (engagement_id WITH =, period WITH &&)
    """)

    # `>=` rather than `>`, matching `engagements_term_not_reversed`: suspending
    # and resuming at the same instant produces the empty range, which contains
    # no instant, so the person was never out. A strictly reversed pair never
    # reaches the constraint — the generation expression raises first.
    create constraint(:venue_room_suspensions, :venue_room_suspensions_period_not_reversed,
             check: "resumed_at IS NULL OR resumed_at >= suspended_at"
           )
  end
end
