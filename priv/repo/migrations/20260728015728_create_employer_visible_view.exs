defmodule HospitalityComs.Repo.Migrations.CreateEmployerVisibleView do
  @moduledoc """
  KTD3, as two views.

  > Hidden attested entries go through an owner-privileged view, not row-level
  > security. The employer role holds no privilege on the base table and reads a
  > view owned by a privileged role that filters on a transaction-local setting.
  > Row-level security would work but has to be `FORCE`d and must not run as
  > table owner; a view has no equivalent switch to forget.

  ## The measurement that makes the decision stronger than its own argument

  `HospitalityComs.Repo` connects as `postgres`, for which `pg_authid.rolsuper`
  is true. **A superuser bypasses row-level security whether or not a policy is
  `FORCE`d.** So on this deployment an RLS-based hidden-entry rule would not
  merely be a switch somebody could forget — it would read as a tier in the
  migration and provide none in the database, for every connection the
  application makes as itself. The view is the tier, and it is the only shape
  available that is one.

  This is not the employer zone's tenancy policies reversed. Those bind
  `employer_role`, which is neither owner nor superuser, and they are how a
  forgotten `where venue_id = ?` fails closed. What they cannot express is a
  *per-row* rule keyed on the reader, which is what disclosure is.

  ## How the mechanism works, and what each half must be

  A view created here is owned by the migrator's role, which is the role that
  owns `attested_entries`, `engagements` and `venues`. A view that is **not**
  `security_invoker` resolves its base-table permissions as its **owner**, so:

    * `employer_role` holds no privilege on `attested_entries` — since U5, and
      `HospitalityComs.BoundaryTest` asserts it — and cannot read a row of it;
    * `employer_role` holds `SELECT` on this view and nothing else;
    * the view's own `WHERE` is therefore the whole of what an employer session
      can reach, and there is no filter for a caller to forget.

  Three properties have to hold together and each is asserted rather than
  assumed. **Owner**: the view's owner must hold privilege on the base tables,
  or the view returns `permission denied`. **`security_invoker` off**: with it
  on, the view would resolve as the *caller*, and `employer_role` would be
  refused — KTD3's mechanism inverted, failing closed but failing. **Tenancy in
  the view**: because the owner bypasses row-level security, the base tables'
  policies do nothing here, and `viewer.venue_id = app_current_employer_id()` is
  what confines a read to one venue.

  `security_barrier` is on. Postgres may otherwise push a caller's own `WHERE`
  clause below the view's qualifiers when it looks cheaper, and a predicate that
  leaked through an error message or a side effect would see rows the view
  exists to withhold. `employer_role` cannot define a function today — it holds
  no `CREATE` on any schema — so this closes a door that is already shut, and it
  is the one property of a view that has to be decided at creation.

  ## `AT TIME ZONE 'UTC'` on the instant, and it is not decoration

  Ecto's `:utc_datetime` is `timestamp` **without** time zone in Postgres, while
  `app_current_instant()` returns `timestamptz` — and comparing the two makes
  Postgres convert the `timestamp` using the session's `TimeZone` setting, which
  no part of this application sets. On a server whose `TimeZone` is not UTC the
  viewer-active test would then be wrong by that offset, silently, and only for
  engagements whose term boundary fell inside it.

  Converting the *instant* to a UTC `timestamp` makes both sides the column's
  own type and takes the session setting out of the comparison. It is the same
  manoeuvre `create_engagements` makes for the generated `period` column, and it
  is applied here for the same reason rather than by analogy.

  ## The visibility rule, in one place

  `employer_visible_attested_entries` answers three questions and keeps them
  separate, because conflating them is how this goes wrong.

  **Who may this employer session see at all?** People holding an engagement at
  `app_current_employer_id()` that is *active at* `app_current_instant()`. That
  half is time-derived, so an ex-worker leaves the employer's reach with no job
  having run — the property U5 gives membership, applied to the record.

  **How is the worker named?** By `viewer_engagement_id`, the viewer's own
  engagement, which is venue-local by construction. **The view exposes no
  `person_id`**, which is U9 acting on the disclosure CLAUDE.md records against
  `engagements.person_id`: the id is globally stable and two venues comparing
  ids out of band can determine the same human works at both, which is precisely
  the concurrency this default hides. This view does not hand one out.

  ## Every column is a permanent employer-facing surface, so there are no spares

  Two were dropped before this shipped and the argument is the same for both:
  neither had a reader, and a column on these views is pinned by
  `HospitalityComs.BoundaryTest`'s column list, so it survives every later unit
  by default.

    * `viewer_venue_id` was `app_current_employer_id()` restated. The view's own
      `WHERE` fixes it to the value the caller opened the scope with, so it
      could only ever hand back what the caller already knew — and a second
      spelling of a value is a thing that drifts from the first if the `WHERE`
      ever moves.
    * `attested_entry_id` on the **corrections** view was a unique function of
      `entry_engagement_id`, which is beside it, because
      `attested_entries.engagement_id` is unique. It stays on the entries view,
      where it names the row the entry *is*.

  **Which entries?** The venue's own, always — it wrote the assertion, and
  hiding a venue's record from itself is not a thing disclosure means. Every
  other venue's, subject to the worker's override if there is one and to the
  computed default if there is not.

  ## The concurrency default is a comparison of two stored periods

  `NOT EXISTS` an engagement of the same person at the viewing venue whose term
  overlaps the entry's:

      subject.starts_at < stint.ends_at AND stint.starts_at < subject.ends_at

  plus the two non-emptiness clauses U6 measured and U8 needed —
  `HospitalityComs.Engagements.end_engagement/2` can produce
  `ends_at == starts_at`, the empty range, and the endpoint form without them
  reports an overlap for it.

  **No instant appears in that predicate, and that is what makes two of the
  unit's scenarios true at once.** "Changing an engagement's dates corrects the
  default automatically" holds because nothing is materialised. "A hidden entry
  remains hidden after it stops being concurrent" holds because *overlap is a
  fact about two periods rather than about now* — a term that ended in June
  overlapped a term that ran March to December whether it is asked in May or in
  November. A default written as "concurrent at `app_current_instant()`" would
  satisfy the first scenario and fail the second by re-disclosing a second job
  the moment it ended, which is the leak the default exists to prevent.

  `NOT EXISTS` ranges over **every** stint the person has held at the viewing
  venue, not only the one being viewed through. A worker whose first stint at B
  overlapped their engagement at A has already been co-located with B; a join to
  the current stint alone would re-disclose it.

  ## `employer_visible_correction_requests` is built on the first view

  R16 makes a correction request visible to any viewer of the entry it is about,
  which is a claim about the *same* rule rather than a second one — so the
  second view selects from the first and joins the requests to it. There is one
  spelling of the disclosure rule and a change to it cannot reach one view and
  miss the other.

  An employer also reads and answers its **own** venue's requests directly on
  the base table, under the row-level security policy
  `enable_profile_row_level_security` writes. Two paths, and they answer
  different questions: the base table is "requests about assertions I made", and
  the view is "requests attached to entries somebody disclosed to me".

  ## `down` drops both views, and the order matters

  The second depends on the first. Dropping without `CASCADE` is deliberate: a
  `CASCADE` here would remove somebody else's object as a side effect, and the
  objects in question are the only path an employer has to this data at all.
  """

  use Ecto.Migration

  @entries_view "employer_visible_attested_entries"
  @corrections_view "employer_visible_correction_requests"

  @doc """
  The views this migration created, as it was written.

  A historical record rather than a live list, exposed so the proof suite can
  compare it against `HospitalityComs.Zones.employer_views/0` instead of
  transcribing the names a third time.
  """
  @spec views() :: [String.t()]
  def views, do: [@entries_view, @corrections_view]

  def up do
    execute(create_entries_view())
    execute(create_corrections_view())
  end

  # In dependency order, which is the reverse of `up`. No CASCADE; see the
  # moduledoc.
  def down do
    execute("DROP VIEW #{@corrections_view}")
    execute("DROP VIEW #{@entries_view}")
  end

  # `viewer` is the engagement the employer session is looking through, and it
  # is the only thing the employer names a worker by. `subject` is an engagement
  # of the same person anywhere, and `entry` is the assertion it produced.
  defp create_entries_view do
    """
    CREATE VIEW #{@entries_view}
    WITH (security_barrier = true) AS
    SELECT
      viewer.id            AS viewer_engagement_id,
      entry.id             AS attested_entry_id,
      entry.attested_at    AS attested_at,
      subject.id           AS entry_engagement_id,
      subject.venue_id     AS entry_venue_id,
      venue.name           AS entry_venue_name,
      subject.role_label   AS role_label,
      subject.starts_at    AS starts_at,
      subject.ends_at      AS ends_at
    FROM engagements viewer
    JOIN engagements subject
      ON subject.person_id = viewer.person_id
    JOIN attested_entries entry
      ON entry.engagement_id = subject.id
    JOIN venues venue
      ON venue.id = subject.venue_id
    WHERE viewer.venue_id = app_current_employer_id()
      AND viewer.starts_at <= (app_current_instant() AT TIME ZONE 'UTC')
      AND viewer.ends_at > (app_current_instant() AT TIME ZONE 'UTC')
      AND (
        subject.venue_id = viewer.venue_id
        OR COALESCE(
          (
            SELECT disclosure.disclosed
            FROM attested_entry_disclosures disclosure
            WHERE disclosure.engagement_id = subject.id
              AND disclosure.audience_venue_id = viewer.venue_id
          ),
          NOT EXISTS (
            SELECT 1
            FROM engagements stint
            WHERE stint.person_id = viewer.person_id
              AND stint.venue_id = viewer.venue_id
              AND stint.starts_at < stint.ends_at
              AND subject.starts_at < subject.ends_at
              AND subject.starts_at < stint.ends_at
              AND stint.starts_at < subject.ends_at
          )
        )
      )
    """
  end

  defp create_corrections_view do
    """
    CREATE VIEW #{@corrections_view}
    WITH (security_barrier = true) AS
    SELECT
      visible.viewer_engagement_id  AS viewer_engagement_id,
      visible.entry_engagement_id   AS entry_engagement_id,
      visible.entry_venue_id        AS entry_venue_id,
      request.id                    AS correction_request_id,
      request.body                  AS body,
      request.requested_at          AS requested_at,
      request.resolved_at           AS resolved_at,
      request.resolution            AS resolution
    FROM #{@entries_view} visible
    JOIN correction_requests request
      ON request.engagement_id = visible.entry_engagement_id
    """
  end
end
