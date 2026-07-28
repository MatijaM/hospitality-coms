defmodule HospitalityComs.Profiles.Records do
  @moduledoc """
  Every query the profile asks, in one module.

  `HospitalityComs.Profiles` is the public API and this is where its `where`
  clauses live, for the reason `AGENTS.md` gives and the reason
  `HospitalityComs.Engagements.Records` and `HospitalityComs.Peers.Records` give
  more sharply: some of these clauses *are* the disclosure model, and a query
  rebuilt at a call site is a rule that can drift from the one three call sites
  over. `HospitalityComs.ProfilesTest` asserts the rule structurally, out of the
  compiled `imports` chunk, the way `peers_test.exs` does — and here the context
  reaches **zero** query builders, because every write is a whole query this
  module hands over.

  ## Two readers, two repos, and the harder one is a view

  The person side runs through `HospitalityComs.Repo` under a `PersonScope`: the
  worker's own record, and a peer's view of it.

  The employer side runs through `HospitalityComs.EmployerRepo` inside
  `scoped_transaction/2` and reads `employer_visible_attested_entries` and
  `employer_visible_correction_requests` — **never** `attested_entries`, which
  `employer_role` holds no privilege on (KTD3). Those two queries name the views
  as bare strings rather than as schemas, deliberately: a view-backed Ecto
  schema would be classified by `HospitalityComs.Zones` as though it stored
  rows, and would then have to satisfy the employer zone's structural rules —
  a `venue_id` column and a unique `(id, venue_id)` index — which a view cannot
  have. The views are classified as views, in `Zones.employer_views/0`.

  ## The disclosure rule is in the view, not here

  Nothing in this module recomputes the concurrency default. The employer-side
  queries filter on `viewer_engagement_id` and take whatever the view returns,
  which is the whole point of the view: one spelling of the rule, in the one
  place `employer_role`'s privileges make reachable.

  The **peer** default is different and it is here, because it is not the
  concurrency rule: a peer sees an entry unless the worker wrote a peer-audience
  row saying otherwise. `hidden_from/1` is that predicate and it is one
  subquery.

  ## Nothing here reads a clock

  Every predicate that needs an instant takes it (KTD5), and the employer view
  takes its own from `app_current_instant()`, which
  `EmployerRepo.scoped_transaction/2` wrote from the scope.
  `Ecto.Query.ago/2` and `from_now/2` are banned project-wide.
  """

  import Ecto.Query

  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Records, as: EngagementRecords
  alias HospitalityComs.Peers.Records, as: PeerRecords
  alias HospitalityComs.Profiles.AttestedEntry
  alias HospitalityComs.Profiles.CorrectionRequest
  alias HospitalityComs.Profiles.DeclaredEntry
  alias HospitalityComs.Profiles.Disclosure
  alias HospitalityComs.Venues.Venue

  @entries_view "employer_visible_attested_entries"
  @corrections_view "employer_visible_correction_requests"

  ## The person's own engagements

  @doc """
  One engagement belonging to one person, by id, active or not.

  What authorises every write the worker makes about their own record. An
  engagement belonging to somebody else and an id that names nothing match
  identically, so a refusal built on this enumerates nothing (AE1).

  Not filtered by activeness: a worker may hide, disclose or contest an entry
  from a term that closed years ago, which is the point of a portable record.
  """
  @spec own_engagement(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def own_engagement(person_id, engagement_id)
      when is_binary(person_id) and is_binary(engagement_id) do
    from engagement in Engagement,
      where: engagement.person_id == ^person_id,
      where: engagement.id == ^engagement_id
  end

  ## Attested entries, from the person's side

  @doc """
  Every attested entry one person's engagements have produced, oldest term
  first.

  Reached through the bridge, because there is no other way: `attested_entries`
  carries no `person_id` and never will. Selects the field list
  `HospitalityComs.Profiles.VisibleEntry` renders rather than the structs, so
  the worker's own read, a peer's read and an employer's read all produce the
  same shape.
  """
  @spec attested_entries_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def attested_entries_of(person_id) when is_binary(person_id) do
    from entry in AttestedEntry,
      join: engagement in Engagement,
      on: engagement.id == entry.engagement_id,
      as: :engagement,
      join: venue in Venue,
      on: venue.id == entry.venue_id,
      where: engagement.person_id == ^person_id,
      order_by: [asc: engagement.starts_at, asc: entry.id],
      select: %{
        attested_entry_id: entry.id,
        entry_engagement_id: engagement.id,
        venue_id: venue.id,
        venue_name: venue.name,
        role_label: engagement.role_label,
        starts_at: engagement.starts_at,
        ends_at: engagement.ends_at,
        attested_at: entry.attested_at
      }
  end

  @doc """
  The attested entries of `person_id` that `viewer_id` may see as a peer at
  `instant`.

  **The peer default is disclosed for the venues the peer has nothing to do
  with, and is the concurrency rule of every venue that binds them for the rest.**
  Those are two halves of one predicate and neither is the whole of it:

    * A peer was co-rostered with this worker and the venue room's roll already
      told them the venue and the employer-authored role label (KTD15b), so a
      default that hid what they can already infer would be ceremony. That is
      why an entry from a venue their own venues know nothing about reaches
      them.
    * An employer session is a person session plus a venue, so a venue's
      manager necessarily holds an engagement there — which makes them
      co-rostered with every worker at that venue, which makes them a visible
      peer. Left at "disclosed", the concurrency default the employer view
      enforces was recoverable by asking the same question through the peer
      door, with no grant, nothing manufactured, and no consent step. So a
      venue's rule follows whoever works there, **and whoever that venue is
      still making visible** — see `concealed_from/3` for why the second half
      is not the first restated.

  `peer_disclosure/4` is the whole of it, and the override is layered on top in
  both directions: a `false` row takes an entry away, a `true` row hands one
  over, and only where there is no row does the computed default decide.
  """
  @spec attested_entries_disclosed_to(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          Ecto.Query.t()
  def attested_entries_disclosed_to(person_id, viewer_id, %DateTime{} = instant)
      when is_binary(person_id) and is_binary(viewer_id) do
    person_id
    |> attested_entries_of()
    |> peer_disclosure(person_id, viewer_id, instant)
  end

  # `COALESCE(the worker's row, the computed default)`, spelled as two `where`
  # clauses because Ecto has no `COALESCE` over a subquery and the view's own
  # spelling is not available here. The first kills an explicit `false`; the
  # second admits an explicit `true` or, failing that, asks the default.
  #
  # Composes over any query that names the `:engagement` binding, which is both
  # of the peer's two reads — R16 makes a correction request visible to any
  # viewer of the entry it contests, so there is one rule and one place it is
  # written.
  @spec peer_disclosure(Ecto.Query.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          Ecto.Query.t()
  defp peer_disclosure(query, person_id, viewer_id, instant) do
    from [engagement: engagement] in query,
      where: engagement.id not in subquery(hidden_from(viewer_id)),
      where:
        engagement.id in subquery(disclosed_to(viewer_id)) or
          engagement.id not in subquery(concealed_from(person_id, viewer_id, instant))
  end

  # The engagements one viewer has been shut out of, as ids. A subquery rather
  # than a join, so the outer query's row count cannot depend on how many
  # decisions happen to exist.
  @spec hidden_from(Ecto.UUID.t()) :: Ecto.Query.t()
  defp hidden_from(viewer_id), do: peer_decisions(viewer_id, false)

  # And the ones they have been let into by name, which is what makes the
  # override beat the computed default rather than only the open one.
  @spec disclosed_to(Ecto.UUID.t()) :: Ecto.Query.t()
  defp disclosed_to(viewer_id), do: peer_decisions(viewer_id, true)

  @spec peer_decisions(Ecto.UUID.t(), boolean()) :: Ecto.Query.t()
  defp peer_decisions(viewer_id, disclosed) when is_boolean(disclosed) do
    from disclosure in Disclosure,
      where: disclosure.audience_person_id == ^viewer_id,
      where: disclosure.disclosed == ^disclosed,
      select: disclosure.engagement_id
  end

  # The subject's engagements a venue that binds the viewer would hide, as ids.
  #
  # `employer_visible_attested_entries` says the same thing about one venue and
  # this says it about every venue that binds the viewer. Two bindings, which
  # are two of the view's three roles: `subject` is the engagement whose entry
  # is being asked about, and `stint` is another engagement of the same person
  # somewhere else. The view's third role — the viewer's own post at `stint`'s
  # venue — is the two-way membership test below rather than a join, because it
  # was only ever an existence check and a join spells that as a row multiplier.
  #
  # **A venue binds the viewer two ways, and neither contains the other.** They
  # work there at `instant` (`venues_worked_at/2`), or the venue is what makes
  # the two of them visible to each other at `instant`
  # (`PeerRecords.visible_venue_ids/3`). The first is where an employer session
  # can exist; the second is *why the viewer can see this person at all*, and it
  # is what carries the rule through R13's thirty-day tail, during which the
  # viewer holds no post anywhere and the first half binds nothing. Without it a
  # manager whose own engagement ended yesterday read the open default for
  # thirty days — the exact access this predicate exists to remove, on a delay.
  #
  # Neither half is redundant. Two engagements active at one venue at one
  # instant are necessarily co-rostered there, so where the *subject* is also
  # active the first half implies the second — but the first is a fact about the
  # viewer alone, so it binds a venue the subject left before the viewer
  # arrived, and the second does not. `NOT EXISTS` in the view ranges over every
  # stint the person ever held there, so a viewer bound only by co-rostering is
  # handed a returning worker's older concurrency the view withholds. Deleting
  # either disjunct kills a test.
  #
  # For a viewer who has left, the binding lapses when visibility does, and that
  # is deliberate: past the tail no venue is why they can see this worker, and
  # what remains is a connection the worker themselves accepted. See
  # `HospitalityComs.Profiles.fetch_peer_profile/2`.
  #
  # The overlap is the view's, clause for clause, including the two
  # non-emptiness comparisons — `HospitalityComs.Engagements.end_engagement/2`
  # can produce `ends_at == starts_at`, and the endpoint form without them
  # reports an overlap for the empty range.
  #
  # `stint.venue_id != subject.venue_id` is the view's own-venue branch: an
  # entry a venue itself attested is always visible to the people who work
  # there, because that is exactly what its roll already discloses. A viewer
  # bound at two venues is bound by both, so what they see is what every venue
  # binding them would show them — the intersection, not the union. Showing what
  # the more permissive of two would show is how somebody holding two jobs
  # becomes a channel out of the stricter one.
  @spec concealed_from(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  defp concealed_from(person_id, viewer_id, %DateTime{} = instant) do
    from subject in Engagement,
      join: stint in Engagement,
      on: stint.person_id == subject.person_id and stint.venue_id != subject.venue_id,
      where: subject.person_id == ^person_id,
      where:
        stint.venue_id in subquery(venues_worked_at(viewer_id, instant)) or
          stint.venue_id in subquery(PeerRecords.visible_venue_ids(viewer_id, person_id, instant)),
      where: stint.starts_at < stint.ends_at,
      where: subject.starts_at < subject.ends_at,
      where: subject.starts_at < stint.ends_at,
      where: stint.starts_at < subject.ends_at,
      select: subject.id
  end

  # The venues the viewer is inside at `instant`: they hold an engagement there
  # whose term contains it, which is `EngagementRecords.active_at/2` and not a
  # second spelling of activeness.
  #
  # This is the half the employer view has, and it is the half that keeps the
  # two answers equal wherever an employer session exists at all. Holding one
  # takes a grant-holding engagement active at the instant, and the view shows a
  # worker only while *their* engagement there is active too — so a venue whose
  # employer door is open to this worker is always a venue the viewer works at,
  # and the peer read subtracts everything the employer read subtracts.
  @spec venues_worked_at(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  defp venues_worked_at(viewer_id, instant) do
    from post in EngagementRecords.active_at(Engagement, instant),
      where: post.person_id == ^viewer_id,
      select: post.venue_id
  end

  ## Declared entries

  @doc """
  Every declared entry one person wrote, oldest term first.
  """
  @spec declared_entries_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def declared_entries_of(person_id) when is_binary(person_id) do
    from entry in DeclaredEntry,
      where: entry.person_id == ^person_id,
      order_by: [asc: entry.starts_at, asc: entry.id]
  end

  @doc """
  One declared entry belonging to one person, by id.

  Somebody else's entry and an id that names nothing match identically (AE1).
  """
  @spec declared_entry_of(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def declared_entry_of(person_id, entry_id)
      when is_binary(person_id) and is_binary(entry_id) do
    from entry in DeclaredEntry,
      where: entry.person_id == ^person_id,
      where: entry.id == ^entry_id
  end

  ## The disclosure ledger

  @doc """
  Every decision one person has taken about their own entries, newest first.

  The worker's own view of the ledger. There is no employer-facing counterpart
  and there must not be one: a venue that could read this would learn which of
  its workers is concealing something, which is strictly more than the entries
  themselves disclose.
  """
  @spec disclosures_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def disclosures_of(person_id) when is_binary(person_id) do
    from disclosure in Disclosure,
      join: engagement in Engagement,
      on: engagement.id == disclosure.engagement_id,
      where: engagement.person_id == ^person_id,
      order_by: [desc: disclosure.decided_at, asc: disclosure.id]
  end

  ## Correction requests, from the person's side

  @doc """
  Every correction request one person has raised, newest first.
  """
  @spec correction_requests_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def correction_requests_of(person_id) when is_binary(person_id) do
    from request in CorrectionRequest,
      join: engagement in Engagement,
      on: engagement.id == request.engagement_id,
      as: :engagement,
      where: engagement.person_id == ^person_id,
      order_by: [desc: request.requested_at, asc: request.id],
      select: %{
        correction_request_id: request.id,
        entry_engagement_id: request.engagement_id,
        venue_id: request.venue_id,
        body: request.body,
        requested_at: request.requested_at,
        resolved_at: request.resolved_at,
        resolution: request.resolution
      }
  end

  @doc """
  The correction requests of `person_id` that `viewer_id` may see as a peer.

  R16 makes a request visible to any viewer of the entry it contests, so this is
  the entry's rule applied to a join rather than a rule of its own — the same
  relationship `employer_visible_correction_requests` has to
  `employer_visible_attested_entries`. It is literally the same function:
  `peer_disclosure/4` composes over both, so a change to the rule cannot reach
  one read and miss the other. A request carries `venue_id`,
  `entry_engagement_id` and the worker's own free text, so a rule that reached
  the entry and not the request would hand back what it had just withheld.
  """
  @spec correction_requests_disclosed_to(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          Ecto.Query.t()
  def correction_requests_disclosed_to(person_id, viewer_id, %DateTime{} = instant)
      when is_binary(person_id) and is_binary(viewer_id) do
    person_id
    |> correction_requests_of()
    |> peer_disclosure(person_id, viewer_id, instant)
  end

  ## The employer's reads, which go through the views and nowhere else

  @doc """
  The attested entries one employer session may see behind one of its own
  engagements, oldest term first.

  Names the view as a string rather than as a schema; see the moduledoc.
  `viewer_engagement_id` is the only filter, because the view's own `WHERE`
  already confines every row to `app_current_employer_id()` at
  `app_current_instant()` — an engagement belonging to another venue matches
  nothing here rather than being refused, so the read enumerates nothing.
  """
  @spec employer_visible_entries(Ecto.UUID.t()) :: Ecto.Query.t()
  def employer_visible_entries(viewer_engagement_id) when is_binary(viewer_engagement_id) do
    from row in @entries_view,
      where: row.viewer_engagement_id == type(^viewer_engagement_id, Ecto.UUID),
      order_by: [asc: row.starts_at, asc: row.attested_entry_id],
      select: %{
        attested_entry_id: type(row.attested_entry_id, Ecto.UUID),
        entry_engagement_id: type(row.entry_engagement_id, Ecto.UUID),
        venue_id: type(row.entry_venue_id, Ecto.UUID),
        venue_name: row.entry_venue_name,
        role_label: row.role_label,
        # `type/2` on every instant, and it is load-bearing rather than tidy. A
        # schemaless query carries no field types, and Ecto's `:utc_datetime` is
        # `timestamp` without time zone in Postgres — so an untyped select hands
        # back a `NaiveDateTime` here while the person-side query, which reads
        # the same columns through a schema, hands back a `DateTime`. One shape
        # rendered two ways is exactly what `VisibleEntry` exists to prevent.
        starts_at: type(row.starts_at, :utc_datetime),
        ends_at: type(row.ends_at, :utc_datetime),
        attested_at: type(row.attested_at, :utc_datetime)
      }
  end

  @doc """
  The correction requests attached to those entries, newest first.
  """
  @spec employer_visible_corrections(Ecto.UUID.t()) :: Ecto.Query.t()
  def employer_visible_corrections(viewer_engagement_id) when is_binary(viewer_engagement_id) do
    from row in @corrections_view,
      where: row.viewer_engagement_id == type(^viewer_engagement_id, Ecto.UUID),
      order_by: [desc: row.requested_at, asc: row.correction_request_id],
      select: %{
        correction_request_id: type(row.correction_request_id, Ecto.UUID),
        entry_engagement_id: type(row.entry_engagement_id, Ecto.UUID),
        venue_id: type(row.entry_venue_id, Ecto.UUID),
        body: row.body,
        requested_at: type(row.requested_at, :utc_datetime),
        resolved_at: type(row.resolved_at, :utc_datetime),
        resolution: row.resolution
      }
  end

  ## The employer's own correction requests, which are its own data

  @doc """
  Every correction request raised against one venue's own assertions, newest
  first.

  The base table rather than a view, and that is the difference between the two
  employer paths: this is "requests about assertions I made", which is the
  venue's own data and which the row-level security policy on `venue_id`
  confines. `employer_visible_corrections/1` is "requests attached to entries
  somebody disclosed to me", which needs the disclosure rule and therefore the
  view.

  Selects the field list `HospitalityComs.Profiles.VisibleCorrection` renders,
  like the other three reads. It did not, and the divergence had been asserted
  into the suite: this path handed back raw `CorrectionRequest` structs, so
  `resolution` was `"declined"` here and `:declined` on the other three, and the
  id arrived under `id` rather than `correction_request_id`. **That is the
  third time this shape has drifted in this tree** — U8's `sent_at`/`at` was
  the second — and it is why the render struct exists.
  """
  @spec venue_corrections(Ecto.UUID.t()) :: Ecto.Query.t()
  def venue_corrections(venue_id) when is_binary(venue_id) do
    from request in CorrectionRequest,
      where: request.venue_id == ^venue_id,
      order_by: [desc: request.requested_at, asc: request.id],
      select: %{
        correction_request_id: request.id,
        entry_engagement_id: request.engagement_id,
        venue_id: request.venue_id,
        body: request.body,
        requested_at: request.requested_at,
        resolved_at: request.resolved_at,
        resolution: request.resolution
      }
  end

  @doc """
  One unresolved correction request at one venue that `instant` can answer,
  selected so that the statement which resolves it also reports what it
  resolved.

  `HospitalityComs.Profiles.resolve_correction/3` composes `update_all` over
  this. Read and write in one statement, so two managers answering at once
  resolve to one answer: the loser's predicate no longer matches, and the
  refusal is `:already_resolved` rather than an overwrite.

  **`requested_at <= instant` is in the predicate rather than left to the
  database**, and that is a refusal rather than a nicety.
  `correction_requests_resolved_after_requested` refuses a resolution stamped
  before its request, and an `update_all` carries no changeset, so the CHECK
  arrived as a raw `Postgrex.Error` out of a function whose spec enumerates
  three atoms. Reachable through `HospitalityComs.Clock.Offset`, which U11's
  demo controls drive. Filtered here, the statement matches nothing and
  `diagnose/1` answers `:already_resolved` or `:not_found` — a refusal in the
  shape the caller was promised.
  """
  @spec resolvable_correction(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def resolvable_correction(venue_id, request_id, %DateTime{} = instant)
      when is_binary(venue_id) and is_binary(request_id) do
    from request in CorrectionRequest,
      where: request.venue_id == ^venue_id,
      where: request.id == ^request_id,
      where: is_nil(request.resolved_at),
      where: request.requested_at <= ^instant,
      select: request
  end

  @doc """
  One correction request at one venue that existed by `instant`, resolved or
  not.

  Only ever used to say *why* a resolve matched no row. It runs on the failure
  path alone, so it cannot turn a refusal into a success — the worst it can do
  is name the wrong one of two refusals, and both are refusals.

  It carries `requested_at <= instant` for the reason `resolvable_correction/3`
  does, and here the reason is the answer's honesty rather than the statement's:
  a request raised after the asking instant has not been raised yet, so
  `:already_resolved` would be a claim about a row that does not exist at the
  time being asked about. `:not_found` is what an id naming nothing gets, which
  is what this is (AE1).
  """
  @spec correction_at_venue(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def correction_at_venue(venue_id, request_id, %DateTime{} = instant)
      when is_binary(venue_id) and is_binary(request_id) do
    from request in CorrectionRequest,
      where: request.venue_id == ^venue_id,
      where: request.id == ^request_id,
      where: request.requested_at <= ^instant
  end
end
