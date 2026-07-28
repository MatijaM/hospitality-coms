defmodule HospitalityComs.Repo.Migrations.CreateProfiles do
  @moduledoc """
  The three tables the profile needs that U5 did not already build, and the
  columns it deliberately does not have.

  `attested_entries` exists since U5 — it is written inside the claim's
  transaction and by nothing else — so this migration adds the *rules about who
  may read it* and the worker's own half of the record.

  ## `declared_entries` is person zone, and it is the half the worker owns

  R16 splits the taxonomy in two: an attested entry is an employer's assertion
  and the worker cannot edit it, and a declared entry is the worker's own
  statement about work this application knows nothing about. The second is a
  person-zone row keyed on `person_id`, because there is no engagement behind it
  and no venue in it — which is also why it never reaches the employer-visible
  view. The plan's zone diagram routes only `attested_entries` through the view,
  and that is the right line: the view carries what employers asserted, and a
  worker's own claim needs no database tier to be believed or doubted.

  ## `attested_entry_disclosures` is the worker's override, and it is a decision

  The concurrency *default* is computed inside the view from period overlap
  (KTD3, and the unit's approach) and is stored nowhere. What is stored here is
  the worker's departure from it: one row per (entry, audience), carrying a
  boolean. Nothing computes "this worker chose to reveal their second job", so
  it is a row rather than a derivation.

  The subject is the **engagement**, not the attested entry, for the reason
  `venue_room_suspensions` names an engagement: an attested entry is an
  employer-zone row, and a person-zone table pointing at one would be reaching
  across the boundary for no gain. The engagement is the row that already means
  "this person, at this venue", and `attested_entries.engagement_id` is unique,
  so an engagement names exactly one entry.

  ## The audience venue is an employer key on a person-zone table

  The first in this tree, and it is deliberate rather than an oversight. The
  audience of an employer disclosure *is* a venue; there is no spelling of that
  which does not reach one. Two alternatives were considered:

    * naming the audience through one of the person's own engagements at that
      venue keeps the person zone employer-key-free, and re-discloses a hidden
      entry the moment the worker takes a *new* engagement at the same venue —
      unless the view resolves the venue off the engagement anyway, at which
      point the venue is one join away and the privacy property is identical,
      with the per-(entry, audience) uniqueness guarantee lost;
    * putting the ledger in the employer zone hands every venue the answer to
      "which of my workers is concealing something", which is exactly the oracle
      the standing incompleteness notice exists not to be.

  So it is a column, and the mitigation is the classification: `employer_role`
  holds nothing on this table, `HospitalityComs.EmployerRepo`'s backstop refuses
  any employer query that reaches it, and the only path to the disclosure rule
  is a view that returns the *result* of applying it and never the ledger.

  Exactly one audience per row, and the CHECK says so as
  `(audience_venue_id IS NULL) <> (audience_person_id IS NULL)`. Both operands
  of `<>` are non-null booleans, so the constraint is NULL-proof by
  construction — unlike `x IS NULL OR y = z`, which is satisfied by a NULL `y`
  and is the shape U8 shipped and had caught.

  ## `correction_requests` is employer zone, because the employer answers it

  R16 lets a worker contest an assertion, and the assertion belongs to a venue.
  So the row lives in the employer zone, carries `venue_id`, and is keyed on
  `engagements (id, venue_id)` rather than on a person (KTD2) — the same shape
  `attested_entries`, `roster_entries` and `room_messages` already have.

  The worker *writes* it, through `HospitalityComs.Repo` under a `PersonScope`,
  which is the manoeuvre `claim_invitation/2` already makes when it writes an
  attested entry the employer role holds no privilege to write. The employer
  *resolves* it, through `EmployerRepo`, with `SELECT` and a column-scoped
  `UPDATE`.

  Resolving does not change the entry, and cannot: an attested entry derives
  from its engagement and there is no write path to one. An accepted correction
  is an acknowledgement, and any actual correction is a change to the engagement
  through `HospitalityComs.Engagements`. That is written down here rather than
  discovered later.

  ## What is *not* here

  No `hidden_count`, no `has_hidden_entries`, no column of any kind that answers
  "is this worker concealing something". The standing incompleteness notice is a
  UI constant (`HospitalityComs.Profiles.incompleteness_notice/0`), and a
  computed flag would turn it into an oracle disclosing strictly more than the
  entries it stands in for.

  No retention column. KTD16 gives attested entries no deletion clock at all,
  and the other three tables are U10's to stamp if it wants them stamped.

  ## `down` drops the three tables and takes everything with them

  Every index and constraint here belongs to one of them, in dependency order.
  The raw statements are `execute/1` rather than `execute/2` for the reason
  `create_engagements` and `create_peer_graph` give: a reverse handed to
  `execute/2` is only ever run by a reversing runner, and there is none here.
  """

  use Ecto.Migration

  # The same bound `engagements.role_label` carries, so a declared entry and an
  # attested one render in the same width.
  @max_label_length 120

  # Long enough to say what is wrong with an assertion, short enough that the
  # column is not a document. The same bound `room_messages` and `peer_messages`
  # carry.
  @max_body_length 4000

  @correction_engagement_fkey "correction_requests_engagement_fkey"
  @correction_resolved_by_fkey "correction_requests_resolved_by_grant_fkey"

  def up do
    create_declared_entries()
    create_attested_entry_disclosures()
    create_correction_requests()
  end

  # In dependency order, which is the reverse of `up`.
  def down do
    drop(table(:correction_requests))
    drop(table(:attested_entry_disclosures))
    drop(table(:declared_entries))
  end

  ## The half the worker owns

  defp create_declared_entries do
    create table(:declared_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Person zone, so the person key is the whole of it. There is no
      # engagement behind a declared entry — that is what makes it declared.
      add :person_id, references(:people, type: :binary_id, on_delete: :restrict), null: false

      add :role_label, :string, null: false
      add :organisation_name, :string, null: false

      # Half-open like every other period in the tree (KTD4), and strictly
      # ordered: a declared entry is written rather than ended, so the empty
      # range `end_engagement/2` can produce has no counterpart here.
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false

      add :declared_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:declared_entries, [:person_id, :starts_at, :id])

    create constraint(:declared_entries, :declared_entries_term_ordered,
             check: "ends_at > starts_at"
           )

    create constraint(:declared_entries, :declared_entries_role_label_present,
             check: "length(btrim(role_label)) > 0"
           )

    create constraint(:declared_entries, :declared_entries_role_label_within_bound,
             check: "length(role_label) <= #{@max_label_length}"
           )

    create constraint(:declared_entries, :declared_entries_organisation_present,
             check: "length(btrim(organisation_name)) > 0"
           )

    create constraint(:declared_entries, :declared_entries_organisation_within_bound,
             check: "length(organisation_name) <= #{@max_label_length}"
           )
  end

  ## The override

  defp create_attested_entry_disclosures do
    create table(:attested_entry_disclosures, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The subject, named as the engagement rather than as the attested entry.
      # See the moduledoc.
      add :engagement_id, references(:engagements, type: :binary_id, on_delete: :restrict),
        null: false

      # Exactly one of these two. See the moduledoc for why the venue is a
      # column here at all.
      add :audience_venue_id, references(:venues, type: :binary_id, on_delete: :restrict)

      add :audience_person_id, references(:people, type: :binary_id, on_delete: :restrict)

      add :disclosed, :boolean, null: false
      add :decided_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # One row per (subject, audience), which is what makes the view's scalar
    # subquery legal: a scalar subquery returning two rows raises, and these
    # indexes are why it cannot.
    create unique_index(:attested_entry_disclosures, [:engagement_id, :audience_venue_id],
             where: "audience_venue_id IS NOT NULL",
             name: :attested_entry_disclosures_one_per_venue
           )

    create unique_index(:attested_entry_disclosures, [:engagement_id, :audience_person_id],
             where: "audience_person_id IS NOT NULL",
             name: :attested_entry_disclosures_one_per_person
           )

    # Exactly one audience. Both operands of `<>` are non-null booleans, so this
    # is NULL-proof by construction: both null is `TRUE <> TRUE`, both set is
    # `FALSE <> FALSE`, and each is rejected.
    create constraint(:attested_entry_disclosures, :attested_entry_disclosures_one_audience,
             check: "(audience_venue_id IS NULL) <> (audience_person_id IS NULL)"
           )
  end

  ## The contest

  defp create_correction_requests do
    create table(:correction_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :venue_id, references(:venues, type: :binary_id, on_delete: :restrict), null: false

      # Employer zone, and therefore keyed on the engagement rather than on the
      # person (KTD2). The composite foreign key below is what stops a request
      # at venue A naming an engagement at venue B.
      add :engagement_id, :binary_id, null: false

      add :body, :text, null: false
      add :requested_at, :utc_datetime, null: false

      # Null until the attesting venue answers. `resolution` is `accepted` or
      # `declined`; both leave the entry and the request readable (R16).
      add :resolved_at, :utc_datetime
      add :resolution, :string
      add :resolved_by_grant_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    # The composite-key discipline: every employer-zone table a later row could
    # reference carries one, and it is what makes a composite foreign key
    # possible at all.
    create unique_index(:correction_requests, [:id, :venue_id])

    create index(:correction_requests, [:engagement_id, :requested_at, :id])
    create index(:correction_requests, [:venue_id, :requested_at, :id])

    # MATCH FULL: neither column of the key is nullable, so the row is either
    # wholly present or the insert is refused.
    execute("""
    ALTER TABLE correction_requests
      ADD CONSTRAINT #{@correction_engagement_fkey}
      FOREIGN KEY (engagement_id, venue_id)
      REFERENCES engagements (id, venue_id)
      MATCH FULL
      ON DELETE RESTRICT
    """)

    # MATCH SIMPLE, for the reason `engagements.grant_id` is: the grant is
    # nullable — an unresolved request names none — while `venue_id` is NOT
    # NULL, so MATCH FULL would reject every outstanding request.
    execute("""
    ALTER TABLE correction_requests
      ADD CONSTRAINT #{@correction_resolved_by_fkey}
      FOREIGN KEY (resolved_by_grant_id, venue_id)
      REFERENCES employer_grants (id, venue_id)
      MATCH SIMPLE
      ON DELETE RESTRICT
    """)

    # Both or neither, spelled with paired `IS NULL` comparisons so the CHECK
    # cannot be satisfied by a NULL: a resolved request always says when, how
    # and under which authority, and an outstanding one says none of the three.
    create constraint(:correction_requests, :correction_requests_resolution_complete,
             check:
               "(resolved_at IS NULL) = (resolution IS NULL) AND " <>
                 "(resolved_at IS NULL) = (resolved_by_grant_id IS NULL)"
           )

    create constraint(:correction_requests, :correction_requests_resolution_known,
             check: "resolution IS NULL OR resolution IN ('accepted', 'declined')"
           )

    create constraint(:correction_requests, :correction_requests_resolved_after_requested,
             check: "resolved_at IS NULL OR resolved_at >= requested_at"
           )

    create constraint(:correction_requests, :correction_requests_body_present,
             check: "length(btrim(body)) > 0"
           )

    create constraint(:correction_requests, :correction_requests_body_within_bound,
             check: "length(body) <= #{@max_body_length}"
           )
  end
end
