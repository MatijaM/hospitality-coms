defmodule HospitalityComs.Repo.Migrations.CreateEngagements do
  @moduledoc """
  The bridge, the invitation that produces it, and the attested entry it writes
  into the person's portable record.

  ## `engagements.person_id` is the crossing, and it is the only one

  KTD2 permits exactly one column anywhere in the schema that names a human on
  the employer's side of the boundary, and this migration creates it. Every rule
  the partition rests on follows from that being *one* column:

    * no employer-zone table carries `person_id` — `attested_entries` here, and
      messages and roster entries in later units, reference
      `engagements (id, venue_id)` instead. So no worker's name is ever stored
      in a row the employer role can read in bulk.
    * the erasure blast radius (KTD15) is one foreign key rather than four, and
      it is `ON DELETE RESTRICT`: erasure pseudonymises the person row in place
      and `person_id` stays `NOT NULL`, so the exclusion constraint below keeps
      working on an erased person exactly as it did before. A `CASCADE` would
      destroy the record the design commits to keeping, and a `SET NULL` would
      drop the engagement out of overlap enforcement entirely.
    * `HospitalityComs.BoundaryTest` asserts against `pg_constraint` that
      `engagements` is the only table outside the person zone with a foreign key
      to `people`. That test is the one that fails if a later unit adds a
      second.

  `engagements` is therefore classified `:shared` in `HospitalityComs.Zones`
  rather than `:employer` — not to get it past the employer-zone rule, but
  because it is what the shared zone was declared for in U3: the one table that
  names a human and a venue in the same row.

  ## Composite foreign keys, and the two that cannot be MATCH FULL

  Every key into the employer zone carries `venue_id` alongside the id, so a row
  at venue A cannot point at a grant or an invitation belonging to venue B. This
  migration adds five of them; three are `MATCH FULL`, which is what KTD2 asks
  for: the key is either wholly null or wholly present.

  Two are `MATCH SIMPLE`, and they are the same shape U4 documented on
  `employer_grants.granted_by_grant_id` and `revoked_by_grant_id`. `grant_id` is
  nullable on both `invitations` and `engagements` — most engagements hold no
  administrative authority — while `venue_id` is `NOT NULL`, so `MATCH FULL`
  would reject every ordinary worker. `MATCH SIMPLE` skips the check only when
  *some* column is null, and the only column that can be is the grant, so "some
  null" and "holds no grant" are the same state; an engagement that does name a
  grant is checked against both columns and degenerates to `MATCH FULL`.

  The rule across the whole schema is therefore "`MATCH FULL` unless a column of
  the key is nullable", and `HospitalityComs.BoundaryTest` asserts it that way
  rather than against a list somebody has to remember to extend.

  ## `down` is written out, and the `execute/1` calls below have no reverse

  Every constraint, generated column and index this migration adds belongs to
  one of its three tables, so `down/0` dropping the tables takes all of it. The
  raw statements are `execute/1` rather than `execute/2` for that reason: a
  reverse handed to `execute/2` is only ever run by `change/0` or by a reversing
  runner, and there is neither here, so it would be a second `down` that never
  executed and could drift from the one that does.

  ## The grant a row *holds*, not the grant that issued it

  `invitations.issued_by_grant_id` is the authority that issued the invitation
  and is `NOT NULL`: an invitation nobody can attribute is an administrative act
  with no author, and a grant is the only attribution the employer zone can hold.

  `invitations.grant_id` and `engagements.grant_id` are a different thing — the
  grant the resulting engagement *holds*. U4 shipped `employer_grants` with no
  holder column, deliberately, and left "who holds this authority" for the
  bridge to answer. This is that answer, and it is what makes KTD17 mean
  anything: a manager's authority derives from an engagement.

  ## The period is a generated `tstzrange`, and half-openness is structural

  `starts_at` and `ends_at` are ordinary `timestamp` columns, matching every
  other instant in this schema. `period` is `GENERATED ALWAYS AS ... STORED`
  over them with `'[)'` bounds, so:

    * the range and the two endpoints cannot disagree — there is no write that
      sets one without the other;
    * half-openness (KTD4) is a property of the schema rather than of whichever
      query happens to be reading. No instant falls in two consecutive periods
      and none falls in a gap, and a renewal that moves `ends_at` moves the
      range with it;
    * queries can still say `starts_at <= t AND ends_at > t`, which is the same
      predicate spelled where it is legible.

  `AT TIME ZONE 'UTC'` is what makes the expression immutable enough for a
  generated column — `timezone(text, timestamp)` is `IMMUTABLE`, unlike the
  session-dependent implicit cast — and it is exact, because every instant this
  application writes is UTC by construction (`HospitalityComs.Clock`).

  There is no open-ended form (R2): both endpoints are `NOT NULL`, so
  `lower_inf` and `upper_inf` are unrepresentable rather than merely unused.

  ## The exclusion constraint is named, and that is not cosmetic

  `engagements_no_overlap` is the database half of R3. It is named explicitly
  so `HospitalityComs.Engagements.Engagement` can declare a matching
  `exclusion_constraint/3`: without the name Ecto cannot map the violation onto
  a changeset, the `Postgrex.Error` raises straight through the transaction, and
  the repository's enumerated-error convention becomes a lie at the one place it
  is load bearing.

  It needs `btree_gist` for the two `uuid WITH =` operands, which the migration
  before this one installs.

  ## The unique index on `invitation_id` is the race guard

  The exclusion constraint is not what stops two people redeeming one claim
  code. Two claimants produce engagements with *different* `person_id`s, so
  nothing overlaps and the constraint never fires. What stops it is this unique
  index plus the conditional consume in
  `HospitalityComs.Engagements.claim_invitation/2`, which requires exactly one
  affected row as the first step of its `Ecto.Multi`. The index is the backstop
  the loser meets if the consume is ever rewritten wrongly.

  ## No contact identifier on an invitation

  R1: an unclaimed invitation creates no person record and names no human. There
  is no email column here and there will not be one. What the invitation carries
  is a digest of a single-use opaque claim code, hashed the same way
  `HospitalityComs.Accounts.PersonToken` hashes a magic link, so the database
  never holds the credential either.
  """

  use Ecto.Migration

  # The bound `HospitalityComs.Venues` already uses for a venue or shift type
  # name, mirrored here so a label the database refuses is a label the changeset
  # would have refused too.
  @max_label_length 160

  # Mirrored from `HospitalityComs.Engagements.Invitation`, for the reason the
  # label bound is mirrored: a lifetime the database refuses is a lifetime the
  # changeset would have refused too.
  @max_code_validity_in_days 14

  @invitation_issuer_fkey "invitations_issued_by_grant_fkey"
  @invitation_grant_fkey "invitations_grant_fkey"
  @engagement_invitation_fkey "engagements_invitation_fkey"
  @engagement_grant_fkey "engagements_grant_fkey"
  @attested_entry_engagement_fkey "attested_entries_engagement_fkey"

  @overlap_constraint "engagements_no_overlap"

  def up do
    create_invitations()
    create_engagements()
    create_attested_entries()
  end

  # In dependency order, which is the reverse of `up`. Every constraint,
  # generated column and index created above belongs to one of these three
  # tables, so `DROP TABLE` takes them with it — unlike U4's `down`, which had
  # to unpick two self-referential foreign keys by hand first.
  def down do
    drop(table(:attested_entries))
    drop(table(:engagements))
    drop(table(:invitations))
  end

  ## Invitations

  defp create_invitations do
    create table(:invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :venue_id, references(:venues, type: :binary_id, on_delete: :restrict), null: false

      # The authority that issued this invitation, and the authority the
      # engagement will hold. Two different questions; see the moduledoc.
      add :issued_by_grant_id, :binary_id, null: false
      add :grant_id, :binary_id

      add :role_label, :string, null: false

      # The fixed term being proposed. Copied onto the engagement at claim
      # rather than joined to, because an invitation is an offer and the
      # engagement is the record: editing the offer afterwards must not move
      # somebody's employment dates.
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false

      # A digest, never the code. The code is returned to the caller once and
      # is not recoverable from the row, exactly as a magic-link token is not.
      add :claim_code_digest, :binary, null: false
      add :code_expires_at, :utc_datetime, null: false

      add :issued_at, :utc_datetime, null: false

      # Null until redeemed. The conditional consume in the claim's first Multi
      # step is `WHERE claimed_at IS NULL`, so this column is the single-use
      # rule rather than a record of it.
      add :claimed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:id, :venue_id])
    create unique_index(:invitations, [:claim_code_digest])
    create index(:invitations, [:venue_id])

    execute("""
    ALTER TABLE invitations
      ADD CONSTRAINT #{@invitation_issuer_fkey}
      FOREIGN KEY (issued_by_grant_id, venue_id)
      REFERENCES employer_grants (id, venue_id)
      MATCH FULL
      ON DELETE RESTRICT
    """)

    # MATCH SIMPLE, and it is one of the two exceptions the moduledoc names:
    # most invitations confer no administrative authority, so `grant_id` is
    # null while `venue_id` never is.
    execute("""
    ALTER TABLE invitations
      ADD CONSTRAINT #{@invitation_grant_fkey}
      FOREIGN KEY (grant_id, venue_id)
      REFERENCES employer_grants (id, venue_id)
      MATCH SIMPLE
      ON DELETE RESTRICT
    """)

    create constraint(:invitations, :invitations_role_label_present,
             check: "length(btrim(role_label)) > 0"
           )

    create constraint(:invitations, :invitations_role_label_within_bound,
             check: "length(role_label) <= #{@max_label_length}"
           )

    # A fixed term with no duration is not a term. The engagement's own period
    # is a range that would be empty, and an empty range contains no instant, so
    # it would be an engagement that is never active.
    create constraint(:invitations, :invitations_term_ordered, check: "ends_at > starts_at")

    # A code that expires before it is issued cannot be redeemed at all, which
    # is an invitation nobody can accept rather than one that has lapsed.
    create constraint(:invitations, :invitations_code_expiry_after_issue,
             check: "code_expires_at > issued_at"
           )

    # And the other end of the same interval. A claim code is a bearer
    # credential that grants a state change to whoever presents it first, and
    # there is no way to withdraw one early — so a lifetime the caller chose
    # freely is a credential that can outlive the venue's interest in it by
    # years. The bound is the one
    # `HospitalityComs.Accounts.PersonToken.session_validity_in_days/0` puts on
    # the other bearer credential in the tree.
    create constraint(:invitations, :invitations_code_expiry_within_bound,
             check: "code_expires_at <= issued_at + interval '#{@max_code_validity_in_days} days'"
           )
  end

  ## The bridge

  defp create_engagements do
    create table(:engagements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # THE CROSSING. One column, `NOT NULL`, `ON DELETE RESTRICT`. See the
      # moduledoc; nothing else in the schema outside the person zone may name
      # a person, and `HospitalityComs.BoundaryTest` is what says so.
      add :person_id, references(:people, type: :binary_id, on_delete: :restrict), null: false

      add :venue_id, references(:venues, type: :binary_id, on_delete: :restrict), null: false

      # The invitation this engagement was claimed from. Unique, so one code
      # produces one engagement even if the consume is ever rewritten wrongly.
      add :invitation_id, :binary_id, null: false

      # The authority this engagement holds, if any. Null for an ordinary
      # worker; set for a manager, which is what KTD17 means by a manager's
      # authority deriving from an engagement.
      add :grant_id, :binary_id

      # KTD15b: the display label lives here rather than on every message, so
      # erasure reduces a number of rows proportional to engagements.
      add :role_label, :string, null: false

      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false

      # KTD13 resolves the origin document's own contradiction: acceptance and
      # the start date are different instants, and an engagement accepted before
      # its start date is confirmed-but-not-yet-active. So this is recorded and
      # deliberately not constrained against `starts_at`.
      add :accepted_at, :utc_datetime, null: false

      # A row does not conflict with itself, so the exclusion constraint is
      # silent about two concurrent renewals and one extension is lost. This is
      # what makes the second one fail instead.
      add :lock_version, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    # The referenced list for every composite foreign key aimed at an
    # engagement — `attested_entries` below, and U6's roster entries and room
    # messages, which reference the bridge rather than the person (KTD2).
    create unique_index(:engagements, [:id, :venue_id])

    # The claim race guard. See the moduledoc.
    create unique_index(:engagements, [:invitation_id])

    create index(:engagements, [:venue_id])
    create index(:engagements, [:person_id])

    # The sweeper's index, and it is deliberately not led by `venue_id`.
    #
    # The sweep is the application acting for itself: it is scoped to no venue
    # at all, and asks `ends_at > since AND ends_at <= now ORDER BY ends_at
    # DESC, id ASC LIMIT n`. A `(venue_id, ends_at)` index cannot serve that —
    # the leading column is unconstrained — so the index that used to be here
    # was named for a query it could never have been used by. `(ends_at, id)`
    # matches the filter and the order both, and the ordering makes the limit a
    # window rather than a floor.
    #
    # The employer's own reads are covered by `[:venue_id]` above, which the
    # row-level security predicate also leans on.
    create index(:engagements, [:ends_at, :id])

    execute("""
    ALTER TABLE engagements
      ADD COLUMN period tstzrange
      GENERATED ALWAYS AS (
        tstzrange(starts_at AT TIME ZONE 'UTC', ends_at AT TIME ZONE 'UTC', '[)')
      ) STORED
    """)

    execute("""
    ALTER TABLE engagements
      ADD CONSTRAINT #{@engagement_invitation_fkey}
      FOREIGN KEY (invitation_id, venue_id)
      REFERENCES invitations (id, venue_id)
      MATCH FULL
      ON DELETE RESTRICT
    """)

    # The second MATCH SIMPLE, for the same reason as the first.
    execute("""
    ALTER TABLE engagements
      ADD CONSTRAINT #{@engagement_grant_fkey}
      FOREIGN KEY (grant_id, venue_id)
      REFERENCES employer_grants (id, venue_id)
      MATCH SIMPLE
      ON DELETE RESTRICT
    """)

    # R3, in the database rather than in a `SELECT ... WHERE NOT EXISTS` that
    # two concurrent claims would both pass. Named, so the violation arrives as
    # a changeset error rather than as a raised `Postgrex.Error`.
    execute("""
    ALTER TABLE engagements
      ADD CONSTRAINT #{@overlap_constraint}
      EXCLUDE USING gist (person_id WITH =, venue_id WITH =, period WITH &&)
    """)

    # `>=` rather than `>`, and the difference is one reachable state.
    #
    # An engagement cannot be *created* with no duration: the invitation it is
    # claimed from carries a strict `ends_at > starts_at`, so every term starts
    # out containing at least one instant. What `>=` permits is ending an
    # engagement at the very instant its term opened, which is an ordinary thing
    # for a manager to do and which produces `tstzrange(a, a, '[)')` — the empty
    # range. That is the correct record of it: an empty range contains no
    # instant, so the engagement is active at none, and it overlaps nothing, so
    # the person can be engaged again over the same dates.
    #
    # A strictly reversed pair never reaches this constraint at all; the
    # generation expression above raises first.
    create constraint(:engagements, :engagements_term_not_reversed, check: "ends_at >= starts_at")

    create constraint(:engagements, :engagements_role_label_present,
             check: "length(btrim(role_label)) > 0"
           )

    create constraint(:engagements, :engagements_role_label_within_bound,
             check: "length(role_label) <= #{@max_label_length}"
           )
  end

  ## The portable record

  defp create_attested_entries do
    create table(:attested_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :venue_id, references(:venues, type: :binary_id, on_delete: :restrict), null: false

      # Employer-zone, and therefore keyed on the engagement rather than on the
      # person (KTD2). Unique, because an engagement is attested once: a
      # renewal extends the engagement and must not produce a second entry.
      add :engagement_id, :binary_id, null: false

      add :attested_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:attested_entries, [:id, :venue_id])
    create unique_index(:attested_entries, [:engagement_id])
    create index(:attested_entries, [:venue_id])

    execute("""
    ALTER TABLE attested_entries
      ADD CONSTRAINT #{@attested_entry_engagement_fkey}
      FOREIGN KEY (engagement_id, venue_id)
      REFERENCES engagements (id, venue_id)
      MATCH FULL
      ON DELETE RESTRICT
    """)
  end
end
