defmodule HospitalityComs.Lifecycle do
  @moduledoc """
  The only module in the application permitted to delete a row (KTD21).

  Two operations live here and nothing else does: **erasure**, which a person
  asks for once and cannot take back, and the **retention sweep**, which runs
  unattended on a schedule. Containment rather than a soft-delete policy — every
  other context ends or reduces a record instead of removing it, and keeping the
  two that genuinely destroy data in one file is what makes them findable.

  `HospitalityComs.LifecycleTest` asserts that structurally, out of the compiled
  `imports` chunk, with one enumerated exemption: `HospitalityComs.Accounts`
  deletes `people_tokens` and nothing else. That is credential expiry rather
  than record destruction — magic-link redemption claims the link, log-out ends
  the session, an email change expires every token — and routing log-out through
  a module about retention would be worse than the carve-out. The exemption is
  written into the test as a literal, and a second test bounds it by counting
  every other table across a log-out.

  ## It runs as the application's own role, and never as an employer

  Every read and write here goes through `HospitalityComs.Repo`.
  `HospitalityComs.EmployerRepo` is not reachable from this module and must not
  become so, for two independent reasons:

    * erasure crosses venues — it ends every engagement a person holds, at every
      employer — which is precisely what no employer session may do;
    * `employer_role` holds no privilege on any person-zone table and no
      privilege at all on `room_messages`, so an employer connection could not
      perform either operation even if it were allowed to try.

  `grant_retention_zone` grants no `DELETE` to anybody, and
  `HospitalityComs.BoundaryTest` asserts the employer zone's privilege inventory
  still contains none.

  ## Erasure pseudonymises; it never deletes the person (KTD15)

  Every table referencing `people` forces a choice between `CASCADE`, which
  destroys records the design commits to keeping, and `SET NULL`, which drops an
  engagement out of the overlap exclusion constraint entirely. Neither is
  acceptable, so the row stays: `erased_at` is stamped and `email` is nulled in
  one statement, and `people_erased_email_removed` and
  `people_present_email_required` — the two check constraints U2 wrote for this
  moment — hold the pair in opposition from the database rather than from a
  changeset this context could forget to use.

  **That same statement overwrites `display_name` with `erased_display_name/0`**
  (#66). The address is the only column `people` holds that must be *absent*
  afterwards; the name has to be *replaced*, because a room keeps full history
  and a message with no author's name renders as nothing. Two identifying
  columns, two different remedies, one statement. Nothing holds this one in
  opposition to `erased_at` from the database and
  `HospitalityComs.Accounts.Person`'s moduledoc says why; what does hold it is
  `HospitalityComs.LifecycleTest`'s field-by-field comparison of the whole
  person row across an erasure, which fails on a column this statement forgets.

  What it *does* delete is bounded and enumerated: auth tokens, the erasing
  party's own peer messages, their declared entries, the disclosure rows that
  hand one of their own entries *over* to a named peer, their retained
  own-message copies, and their scheduled Oban rows.

  What it deliberately does **not** delete is the interesting half:

    * `room_messages` — not one row is written. KTD15b put the display label on
      the engagement, so erasure reduces a number of rows proportional to
      engagements and every conversation stays readable under
      `erased_label/0`. KTD15c: bodies survive on a legitimate-interest basis
      and can still name people, which means venue-room history holds personal
      data indefinitely. That is a stated position for this POC, not an
      oversight.
    * `connection_requests` — the row *is* KTD19's block, and
      `peer_connections.request_id` is `NOT NULL ON DELETE RESTRICT`. Deleting
      it would destroy the counterpart's protection and orphan the connection.
    * `attested_entry_disclosures` **where `disclosed` is false**, from both
      sides, and this is the counter-intuitive one. A `false` row narrows what
      an audience sees, so deleting one *discloses more*; peer visibility runs
      thirty days past an engagement's end, so a tidy-up here would re-reveal,
      to every peer, exactly the entries the worker had hidden, at the moment
      they asked for erasure. Rows naming them as the *audience* belong to
      somebody else besides, whichever way those rows point.

      **A `true` row is the opposite and is deleted.** `Profiles.Records`'s peer
      rule reads it as an override that beats the computed concurrency default,
      so keeping one leaves an erased person affirmatively disclosing an entry
      to a named peer for the whole tail, with no session left to withdraw it.
      The old claim — "a disclosure row only ever narrows" — was true of one of
      the two values and the test wrote only that one.
    * `correction_requests` — addressed to a venue, which is the other party, on
      the same test KTD15c applies to a message body. `Profiles` also serves one
      to any peer who can see the entry it contests (R16), so this is not purely
      a two-party record: an erased person's own free text reaches third parties
      for the thirty-day tail, while their declared entries — the same kind of
      self-authored text with no other party to it — are deleted. The asymmetry
      is deliberate rather than overlooked. A correction request is an assertion
      *against* a venue's attestation, and R16 exists so a reader of the
      attestation sees it is contested; deleting the contest while keeping the
      attestation leaves the record worse for the erased person than leaving
      both. It is written down here because it is the one place erasure keeps
      free text the erasing party wrote.
    * `venue_room_suspensions` — keyed on the engagement and naming no person,
      so it discloses nothing once the label is reduced, and deleting one would
      silently put an erased person back on a room roll they had opted out of.
      Listed because the two enumerations above read as exhaustive and this is
      the table that was in neither.

  **The thirty-day tail is a disclosure, not a defect.** A peer co-engaged with
  the erased person keeps seeing their attested entries — venue names,
  employer-authored role labels, dates — for thirty days after the last
  engagement ends. No email, no declared entries. That is identifier erasure
  applied consistently, and it is written down here rather than found later.

  **A second residue of the same tail**: an erased person stays on a co-engaged
  peer's `Peers.list_visible_peers/1` for those thirty days, so a request can be
  sent to somebody who has no session left to answer it — leaving a permanently
  current `connection_requests` row that nothing supersedes. Nothing leaks: the
  list carries the `person_id` and the employer-authored role label the venue
  room already disclosed, and no email. Filtering erased people out of visibility
  is the obvious fix and is **not** taken here, because visibility is derived
  from engagements alone and adding a `people` predicate to it makes erasure
  reach into a query that has nothing else to do with a person's row — a U8
  decision rather than a retention one.

  ## Erasure is exempt from the last-grant-holder invariant (KTD17)

  Gating a data-subject right on an operational convenience is the wrong trade,
  and the failure would be silent from the requester's side. So erasing a
  venue's sole grant-holder succeeds and leaves the venue **orphaned**: a live
  grant that no active engagement holds. `orphaned_venues/1` is that state given
  a name, because KTD17 promises an operator re-seed path and a path to a state
  nobody can enumerate is not a path.

  ## Open sockets, decided rather than inherited

  A channel derives its session per join and authorises per inbound event
  (KTD5). Erasure returns the token rows it deleted, exactly as
  `HospitalityComs.Accounts.delete_person_session_token/1` does, so the surface
  that exposes it disconnects the transports the way log-out already does — this
  module does not call `HospitalityComsWeb.PersonAuth`, because no context calls
  the web layer.

  The teardown is not what makes the channel powerless. Every engagement is
  ended and every connection disconnected in the same transaction, so a channel
  that survived the broadcast can still send the frame and is refused on the
  next event, on the same process, with nothing having rejoined.
  `HospitalityComsWeb.RevocationTest` asserts that rather than arguing it.

  ## Retention reads stamped deadlines and joins nothing (KTD16)

  Four triggers, four `delete_after` columns, and **no join to the period the
  deadline came from**. Computing at sweep time would let a manager entering a
  backdated end date move a deletion deadline into the past and have the next
  unattended run destroy a worker's messages with no notice. Every query is in
  `HospitalityComs.Lifecycle.Records` and every one of them filters on the
  column alone.

    * own-message copies, ninety days past the engagement's end — and **null
      until the term closes**, because that is the instant after which `ends_at`
      can no longer move;
    * shift-room messages, thirty days past the room's `closes_at`;
    * roster entries, on the same instant from the same room;
    * venue-room messages, thirty days past `close_venue/2` — and **null until
      then**, so the sweep passes over them for ever while the venue trades.

  Two of the four are null until an event happens, and it means the same thing
  in both: no clock yet, because the event that starts it has not occurred.

  Engagements and attested entries carry no deadline at all: they are the
  person's portable record.

  `<` rather than `<=`, half-open like every other boundary in the tree. A row
  whose deadline is exactly the sweep's instant survives.

  ## Bounded, and recorded whichever way it goes

  Each trigger deletes at most `batch_size/0` rows, and a run whose total
  exceeds `ceiling/0` rolls **every** trigger back. The two numbers are a pair:
  the default ceiling is deliberately above what a full batch per trigger can
  reach, so it is a guard against a batch bound that is missing or wrong rather
  than a throttle. A ceiling a correct run could hit would refuse the same rows
  for ever and the sweep would never make progress again.

  That ordering is checked at compile time below, over
  `RetentionRun.triggers/0` rather than over the number four — which used to be
  written out in prose here, again lower down, and once more in
  `config/config.exs`, none of which a fifth trigger would have disturbed.

  Either way a `HospitalityComs.Lifecycle.RetentionRun` is written, carrying the
  instant the sweep *used* and the four counts. On the ordinary path it is
  written inside the deleting transaction, so a committed deletion is never
  unrecorded; on the refusal path it is written after the rollback, because the
  case a record matters most for is the one where everything else was undone.

  ## The archive is taken with the message, and dated when the term closes

  KTD16 says the retained copy is written "inside the engagement-end
  transaction". That is not available, and the reason is the zone partition
  rather than an oversight: `HospitalityComs.Engagements.end_engagement/2` runs
  inside `EmployerRepo.scoped_transaction/2`, and `employer_role` holds no
  privilege on any person-zone table. An after-commit write through `Repo` would
  be a second connection's transaction with no backstop.

  Writing it when the expiry was *announced* was the first answer and it lost
  data. **A copy cannot be taken later than the instant its source may be
  deleted**, and the earliest such instant is a shift message's
  `closes_at + 30 days` — which every ordinary term outlives by months. So the
  venue's copy was swept before the announcement fired and the worker's copy was
  never created: the failure KTD16 names in its own words, arriving through the
  trigger rather than through the schema.

  So `retain_message/3` is called by `HospitalityComs.Rooms` inside the
  transaction that inserts the message. Both rows go through `Repo`, so this is
  one transaction rather than two connections, which is closer to what KTD16
  asked for than the announcement ever was. The copy's `delete_after` is null
  until the term closes.

  `retain_own_messages/2` stays, and is now the backstop rather than the
  mechanism: `HospitalityComs.Workers.ExpireEngagement` calls it when a term has
  closed, it stamps the deadline once, and it copies anything with no copy —
  words written before this existed, or a copy whose own transaction rolled
  back. It covers natural expiry and explicit ending alike, because
  `end_engagement/2` rewrites `ends_at` to the closing instant and
  `EngagementSweeper`'s window then finds it.

  The permanent-loss gap CLAUDE.md records for expiry *announcements* does not
  reach the archive's contents: the copies are already written. What a lost
  announcement leaves is an archive with **no deadline**, which over-retains
  rather than losing anything, and which the next announcement of that
  engagement stamps. Uniqueness suppresses a replacement only once the job has
  `:completed`, and `:discarded` is excluded, so a permanently failed job is
  re-inserted by the sweeper.
  """

  alias Ecto.Multi
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Lifecycle.Records
  alias HospitalityComs.Lifecycle.RetainedMessageCopy
  alias HospitalityComs.Lifecycle.RetentionRun
  alias HospitalityComs.Peers
  alias HospitalityComs.Peers.Connection
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rosters.RosterEntry
  alias HospitalityComs.Venues.Venue

  # The label every one of an erased person's engagements is reduced to. It is
  # what a client renders beside their messages afterwards, so it has to read as
  # a person rather than as a tombstone.
  @erased_label "Former team member"

  # The name an erased person is shown under, written by `pseudonymise/3` in the
  # same statement that nulls the address (#66). A readable name left behind is
  # an identifying value surviving erasure, which is KTD15 broken outright.
  #
  # A **separate constant** from `@erased_label` above, and no relation is
  # asserted between the two. One is what an employer wrote about a job and the
  # other is what a person called themselves; they are the same length of string
  # and different kinds of fact, and a linking sentence between two values
  # nothing checks is how `HospitalityComs.Profiles.DeclaredEntry` came to state
  # a wrong bound for the life of a unit (issue #42).
  @erased_display_name "Former colleague"

  # Shift history and venue-room history, thirty days past the clock that starts
  # them. The worker's own copy of the same words lives three times as long, and
  # the gap is the whole of KTD16's argument for physically separate rows: one
  # row cannot carry two deadlines, and the shorter would silently win.
  @history_retention_days 30
  @own_copy_retention_days 90

  # Per trigger, per run. The same order of magnitude as
  # `HospitalityComs.Workers.EngagementSweeper`'s batch, for the same reason: an
  # unattended statement over a growing table is a statement that eventually
  # stops finishing.
  @default_batch_size 500

  # One full batch per trigger cannot reach this, so a correctly configured run
  # cannot either. That is deliberate. The ceiling is the guard that fires when a
  # batch bound is missing or a later trigger is added without one; a ceiling an
  # ordinary run could hit would roll back the same rows on every tick and the
  # sweep would never make progress again.
  @default_ceiling 5_000

  # The ordering above, checked rather than described (issue #42, item 4). Both
  # numbers stay declared because neither derives from the other — the ceiling is
  # constrained from below and nothing says by how much — which is PR #41's rule
  # for `@unconfirmed_retention_days` and the reason that one raises too.
  #
  # The multiplier is read from `RetentionRun.triggers/0` rather than written as
  # four. "Four" was a prose literal in three places, and a fifth trigger would
  # have invalidated every one of them silently; a trigger has to have a column
  # on the run record to be counted at all, so that list is the honest source.
  # The remote call is also what puts this module in `RetentionRun`'s
  # compile-time dependency set, so adding a trigger recompiles this file.
  @trigger_count length(RetentionRun.triggers())

  if @default_batch_size * @trigger_count >= @default_ceiling do
    raise """
    @default_ceiling is #{@default_ceiling}, which #{@trigger_count} triggers of \
    @default_batch_size #{@default_batch_size} can reach \
    (#{@default_batch_size * @trigger_count}).

    The ceiling is a guard against a missing batch bound, not a throttle. One an \
    ordinary run can hit rolls the same rows back on every tick and the sweep \
    never makes progress again. Raise the ceiling or lower the batch size; do \
    not delete this check.
    """
  end

  # How long a `people` row that never confirmed an address survives (issue
  # #15). Chosen against a constraint rather than picked: it must exceed every
  # token validity in `HospitalityComs.Accounts.PersonToken`, because
  # `people_tokens.person_id` is the one foreign key into `people` that is
  # `ON DELETE CASCADE`, so reaping a person takes their tokens with them and
  # this ordering is what makes "never a live credential" true without appealing
  # to the argument that an unconfirmed person cannot hold a session token.
  #
  # The constraint is an *ordering* rather than an equality, so the number is
  # declared and the ordering is checked below at compile time — which is the
  # difference between a value that cannot ship broken and one a test reports on
  # after it already has. The three remote calls are also what put this module
  # in `PersonToken`'s compile-time dependency set, so shortening this horizon
  # or lengthening a validity recompiles whichever file did not change.
  @unconfirmed_retention_days 30

  @token_validity_ceiling_in_minutes Enum.max([
                                       PersonToken.session_validity_in_days() * 24 * 60,
                                       PersonToken.change_email_validity_in_days() * 24 * 60,
                                       PersonToken.magic_link_validity_in_minutes()
                                     ])

  if @unconfirmed_retention_days * 24 * 60 <= @token_validity_ceiling_in_minutes do
    raise """
    @unconfirmed_retention_days is #{@unconfirmed_retention_days} days, which does \
    not outlive every validity in HospitalityComs.Accounts.PersonToken (the \
    longest is #{@token_validity_ceiling_in_minutes} minutes).

    people_tokens.person_id is ON DELETE CASCADE, so reaping an unconfirmed \
    person deletes their tokens. Raise the retention or shorten the validity; \
    do not delete this check.
    """
  end

  # Rows per `insert_all` on the archive's backfill path. `insert_all` binds one
  # parameter per field per row and Postgres refuses more than 65535 of them, so
  # ten fields put the hard wall at 6553; this is the same order of magnitude as
  # every other bound in the unit and comfortably under it.
  @copy_chunk_size 500

  @typedoc """
  What one erasure did.

  `tokens` are the deleted rows, carrying the stored digest rather than a
  credential, so the caller can disconnect the sockets they belong to the way
  log-out does. `connections` are the conversations that were closed, so the
  caller can announce them.
  """
  @type erasure() :: %{
          person: Person.t(),
          tokens: [PersonToken.t()],
          connections: [Connection.t()],
          engagements_ended: non_neg_integer(),
          labels_reduced: non_neg_integer(),
          peer_messages_deleted: non_neg_integer(),
          declared_entries_deleted: non_neg_integer(),
          disclosures_withdrawn: non_neg_integer(),
          retained_copies_deleted: non_neg_integer(),
          jobs_cancelled: non_neg_integer()
        }

  @typedoc "What closing a venue did."
  @type closure() :: %{venue: Venue.t(), messages_stamped: non_neg_integer()}

  @typedoc """
  What one reap deleted: tokens past their own context's validity, and people
  who never confirmed an address.
  """
  @type reaping() :: %{
          expired_tokens: non_neg_integer(),
          unconfirmed_people: non_neg_integer()
        }

  @typedoc """
  What one archive pass did: copies it wrote, and copies whose deletion clock it
  started. Both are zero on a term that has not closed and on an erased person.
  """
  @type archive() :: %{written: non_neg_integer(), stamped: non_neg_integer()}

  ## Constants the rest of the tree reads rather than restates

  @doc """
  The role label an erased person's engagements are reduced to.
  """
  @spec erased_label() :: String.t()
  def erased_label, do: @erased_label

  @doc """
  The display name an erased person's row is overwritten with.
  """
  @spec erased_display_name() :: String.t()
  def erased_display_name, do: @erased_display_name

  @doc """
  How long shift and venue-room history outlive the clock that starts them.
  """
  @spec history_retention_days() :: pos_integer()
  def history_retention_days, do: @history_retention_days

  @doc """
  How long a worker's own copy outlives their engagement.
  """
  @spec own_copy_retention_days() :: pos_integer()
  def own_copy_retention_days, do: @own_copy_retention_days

  @doc """
  The deadline a shift's history gets, from the room's `closes_at`.

  Called by `HospitalityComs.Rooms.RoomMessage` and
  `HospitalityComs.Rosters.RosterEntry` at insert, which is the only time it is
  ever evaluated for a row — that is what "stamped, not joined" means.

  Whole seconds, because the column is `timestamp(0)` and the sweep's comparison
  is `delete_after < instant`: a second of slop moves a deletion by a second
  rather than shortening a period that has already elapsed, which is the
  distinction `roster_entries`' own bounds are microseconds for.
  """
  @spec history_deadline(DateTime.t()) :: DateTime.t()
  def history_deadline(%DateTime{} = closes_at) do
    closes_at |> DateTime.add(@history_retention_days, :day) |> DateTime.truncate(:second)
  end

  @doc """
  The deadline a worker's own copy gets, from their engagement's closed end.
  """
  @spec archive_deadline(DateTime.t()) :: DateTime.t()
  def archive_deadline(%DateTime{} = ends_at) do
    ends_at |> DateTime.add(@own_copy_retention_days, :day) |> DateTime.truncate(:second)
  end

  @doc """
  How long a person who never confirmed an address survives.
  """
  @spec unconfirmed_retention_days() :: pos_integer()
  def unconfirmed_retention_days, do: @unconfirmed_retention_days

  @doc """
  How many rows one trigger deletes in one run.
  """
  @spec batch_size() :: pos_integer()
  def batch_size, do: setting(:batch_size, @default_batch_size)

  @doc """
  The total above which a run rolls back rather than committing.
  """
  @spec ceiling() :: pos_integer()
  def ceiling, do: setting(:ceiling, @default_ceiling)

  ## Erasure

  @doc """
  Erases the scope's own person, irreversibly.

  One transaction. It ends every engagement the person holds at every venue,
  reduces every engagement's label, nulls the address and stamps `erased_at`,
  deletes every auth token, disconnects every live peer connection and deletes
  the messages this person wrote in them, deletes their declared entries, the
  disclosure rows handing one of their own entries over to a named peer, and
  their retained own-message copies, and deletes the Oban rows scheduled against
  their engagements.

  Announcements — the peer disconnections — go out after the commit and only if
  there was one, for `HospitalityComs.Engagements.end_engagement/2`'s reason:
  nothing is announced that a rollback could take back.

  `{:error, :already_erased}` is decided under `FOR UPDATE` on the person row,
  so two concurrent requests produce one erasure rather than a second
  pseudonymisation overwriting the first's instant.

  Exempt from the last-grant-holder invariant (KTD17). See the moduledoc and
  `orphaned_venues/1`.
  """
  @spec erase_person(PersonScope.t()) ::
          {:ok, erasure()} | {:error, :already_erased | :request_gone}
  def erase_person(%PersonScope{person: %Person{id: person_id}, now: now})
      when is_binary(person_id) do
    Multi.new()
    |> Multi.run(:person, fn repo, _changes -> lock_unerased(repo, person_id) end)
    |> Multi.run(:engagements_ended, fn repo, _changes -> close_terms(repo, person_id, now) end)
    |> Multi.run(:labels_reduced, fn repo, _changes -> reduce_labels(repo, person_id, now) end)
    |> Multi.run(:pseudonymised, fn repo, _changes -> pseudonymise(repo, person_id, now) end)
    |> Multi.run(:tokens, fn repo, _changes -> delete_tokens(repo, person_id) end)
    |> Multi.run(:connections, fn repo, _changes -> Peers.disconnect_all(repo, person_id, now) end)
    |> Multi.run(:peer_messages_deleted, fn repo, _changes ->
      count(repo.delete_all(Records.peer_messages_of(person_id)))
    end)
    |> Multi.run(:declared_entries_deleted, fn repo, _changes ->
      count(repo.delete_all(Records.declared_entries_of(person_id)))
    end)
    |> Multi.run(:disclosures_withdrawn, fn repo, _changes ->
      count(repo.delete_all(Records.asserted_disclosures_of(person_id)))
    end)
    |> Multi.run(:retained_copies_deleted, fn repo, _changes ->
      count(repo.delete_all(Records.retained_copies_of(person_id)))
    end)
    |> Multi.run(:jobs_cancelled, fn repo, _changes -> cancel_jobs(repo, person_id) end)
    |> Repo.transaction()
    |> erased()
  end

  @spec lock_unerased(Ecto.Repo.t(), Ecto.UUID.t()) ::
          {:ok, Person.t()} | {:error, :already_erased}
  defp lock_unerased(repo, person_id) do
    person_id |> Records.unerased_person() |> repo.one() |> unerased()
  end

  @spec unerased(Person.t() | nil) :: {:ok, Person.t()} | {:error, :already_erased}
  defp unerased(%Person{} = person), do: {:ok, person}
  defp unerased(nil), do: {:error, :already_erased}

  @spec close_terms(Ecto.Repo.t(), Ecto.UUID.t(), DateTime.t()) :: {:ok, non_neg_integer()}
  defp close_terms(repo, person_id, now) do
    count(repo.update_all(Records.close_open_engagements(person_id, now), []))
  end

  @spec reduce_labels(Ecto.Repo.t(), Ecto.UUID.t(), DateTime.t()) :: {:ok, non_neg_integer()}
  defp reduce_labels(repo, person_id, now) do
    count(repo.update_all(Records.reduce_labels(person_id, @erased_label, now), []))
  end

  @spec pseudonymise(Ecto.Repo.t(), Ecto.UUID.t(), DateTime.t()) :: {:ok, Person.t()}
  defp pseudonymise(repo, person_id, now) do
    query = Records.pseudonymise(person_id, @erased_display_name, now)
    {1, [%Person{} = person]} = repo.update_all(query, [])
    {:ok, person}
  end

  @spec delete_tokens(Ecto.Repo.t(), Ecto.UUID.t()) :: {:ok, [PersonToken.t()]}
  defp delete_tokens(repo, person_id) do
    {_count, deleted} = repo.delete_all(Records.tokens_of(person_id))
    {:ok, deleted}
  end

  # The args carry no `person_id` — a job's args are a `jsonb` column in
  # `public`, and KTD2's rule about where a human may be named does not stop at
  # the schemas this application owns — so the jobs are found through the
  # engagements the erasure just ended.
  @spec cancel_jobs(Ecto.Repo.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  defp cancel_jobs(repo, person_id) do
    ids = person_id |> Records.engagement_ids_of() |> repo.all()

    count(repo.delete_all(Records.jobs_for_engagements(ids)))
  end

  @spec count({non_neg_integer(), term()}) :: {:ok, non_neg_integer()}
  defp count({affected, _rows}), do: {:ok, affected}

  @spec erased({:ok, map()} | {:error, atom(), term(), map()}) ::
          {:ok, erasure()} | {:error, :already_erased | :request_gone}
  defp erased({:ok, changes}) do
    Enum.each(changes.connections, &Peers.announce_disconnection/1)

    {:ok,
     %{
       person: changes.pseudonymised,
       tokens: changes.tokens,
       connections: changes.connections,
       engagements_ended: changes.engagements_ended,
       labels_reduced: changes.labels_reduced,
       peer_messages_deleted: changes.peer_messages_deleted,
       declared_entries_deleted: changes.declared_entries_deleted,
       disclosures_withdrawn: changes.disclosures_withdrawn,
       retained_copies_deleted: changes.retained_copies_deleted,
       jobs_cancelled: changes.jobs_cancelled
     }}
  end

  defp erased({:error, _step, reason, _changes}), do: {:error, reason}

  ## KTD17's orphaned state

  @doc """
  Venues holding a live grant that no active engagement holds, at `instant`.

  What erasing a venue's sole grant-holder leaves behind, and the list an
  operator re-seeds from. Derived rather than stored: the same clock advance
  that ends the manager's engagement puts the venue on this list with nothing
  having run.

  A venue whose only grant was *revoked* is not on it. There is no authority for
  anybody to be the last holder of, which is a venue that was wound up rather
  than one that needs a manager — and `EmployerGrant.live_at/2`'s predicate is
  reused so "live" cannot come to mean two things.
  """
  @spec orphaned_venues(DateTime.t()) :: [Venue.t()]
  def orphaned_venues(%DateTime{} = instant) do
    instant |> Records.orphaned_venues() |> Repo.all()
  end

  ## Venue closure

  @doc """
  Closes a venue and starts the clock on its venue-room history.

  KTD16's third trigger. Venue-room history has no deletion clock at all while
  the venue exists, so `room_messages.delete_after` is null for every venue-room
  message until this runs; closure stamps it, and the sweep deletes them thirty
  days later.

  It stamps **only** the messages whose deadline is still null. A shift
  message's deadline was fixed when it was sent, and re-stamping it here would
  let the venue's clock overwrite the shift's — the "shorter deadline silently
  wins" failure KTD16 rejects, arriving from the other direction.

  There is no employer-session path to this and there should not be. Closing a
  venue destroys, on a clock, the conversation history of everybody who ever
  worked there, `employer_role` holds no privilege on `room_messages` at all, and
  KTD21 confines deletion to this context. `{:error, :already_closed}` on a
  second call, `{:error, :not_found}` for an id that names nothing.
  """
  @spec close_venue(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, closure()} | {:error, :not_found | :already_closed}
  def close_venue(venue_id, %DateTime{} = instant) when is_binary(venue_id) do
    Multi.new()
    |> Multi.run(:venue, fn repo, _changes -> close(repo, venue_id, instant) end)
    |> Multi.run(:messages_stamped, fn repo, _changes -> stamp(repo, venue_id, instant) end)
    |> Repo.transaction()
    |> closed()
  end

  @spec close(Ecto.Repo.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Venue.t()} | {:error, :not_found | :already_closed}
  defp close(repo, venue_id, instant) do
    venue_id
    |> Records.close_venue(instant)
    |> repo.update_all([])
    |> closed_or_diagnose(repo, venue_id)
  end

  # The list in the first clause is `Records.close_venue/2`'s own `select:
  # venue`, handed back by `update_all` as `RETURNING`. That select is declared
  # by the statement this reads rather than inherited from the predicate it
  # composes, so the obligation is one function away and visible from here.
  #
  # The second clause runs only when the conditional update matched nothing, so
  # it cannot turn a refusal into a success.
  @spec closed_or_diagnose({non_neg_integer(), [Venue.t()] | nil}, Ecto.Repo.t(), Ecto.UUID.t()) ::
          {:ok, Venue.t()} | {:error, :not_found | :already_closed}
  defp closed_or_diagnose({1, [%Venue{} = venue]}, _repo, _venue_id), do: {:ok, venue}

  defp closed_or_diagnose({0, _rows}, repo, venue_id) do
    venue_id |> Records.venue() |> repo.exists?() |> diagnose()
  end

  @spec diagnose(boolean()) :: {:error, :not_found | :already_closed}
  defp diagnose(true), do: {:error, :already_closed}
  defp diagnose(false), do: {:error, :not_found}

  @spec stamp(Ecto.Repo.t(), Ecto.UUID.t(), DateTime.t()) :: {:ok, non_neg_integer()}
  defp stamp(repo, venue_id, instant) do
    deadline = history_deadline(instant)

    count(repo.update_all(Records.stamp_undated_messages(venue_id, deadline, instant), []))
  end

  @spec closed({:ok, map()} | {:error, atom(), term(), map()}) ::
          {:ok, closure()} | {:error, :not_found | :already_closed}
  defp closed({:ok, %{venue: venue, messages_stamped: stamped}}) do
    {:ok, %{venue: venue, messages_stamped: stamped}}
  end

  defp closed({:error, _step, reason, _changes}), do: {:error, reason}

  ## The worker's archive

  @doc """
  Writes the author's own copy of one message, in the transaction that wrote it.

  Called by `HospitalityComs.Rooms` from inside the send's `Ecto.Multi`, on both
  room kinds. **The instant a copy is taken has to be no later than the instant
  its source can be deleted**, and the earliest deadline any source carries is a
  shift message's `closes_at + 30 days` — which an ordinary term outlives by
  months. Taking the archive when the *engagement* closed therefore lost exactly
  the rows KTD16 names: "a person whose engagement ended long after a shift
  would lose their own copy on the shift's clock". Writing it with the message
  is the only trigger that cannot be late.

  `delete_after` is **null** here, exactly as a venue-room message's is while its
  venue trades: the copy's clock is `ends_at + 90 days` and `ends_at` can still
  move while the term is open. `retain_own_messages/2` stamps it once the term
  has closed, which is the state after which it cannot move again.

  `{:ok, 0}` for an **erased person**, resolved under `FOR SHARE` so a concurrent
  `erase_person/1` cannot commit between the check and the insert. See
  `HospitalityComs.Lifecycle.Records.unerased_person_shared/1`.
  """
  @spec retain_message(Ecto.Repo.t(), RoomMessage.t(), Engagement.t()) ::
          {:ok, non_neg_integer()}
  def retain_message(repo, %RoomMessage{} = message, %Engagement{} = engagement) do
    engagement.person_id
    |> Records.unerased_person_shared()
    |> repo.one()
    |> retained(repo, message, engagement)
  end

  @spec retained(Person.t() | nil, Ecto.Repo.t(), RoomMessage.t(), Engagement.t()) ::
          {:ok, non_neg_integer()}
  defp retained(nil, _repo, _message, _engagement), do: {:ok, 0}

  defp retained(%Person{}, repo, message, engagement) do
    {:ok, insert_copies(repo, [copy_of(message, engagement, message.sent_at, nil)])}
  end

  @doc """
  Brings this engagement's archive up to date, and stamps its deletion clock.

  Called by `HospitalityComs.Workers.ExpireEngagement`, which is the one event
  in the system that means "this term has closed" and already carries a
  scheduled trigger, a periodic backstop and idempotence. Two things happen and
  the second is the one that matters:

    * every message of this engagement with no copy yet is copied — the backstop
      for words written before U10 existed, and for a copy whose own transaction
      rolled back;
    * every copy of this engagement with no deadline is stamped
      `ends_at + 90 days`. `is_nil(delete_after)` is the whole condition, so it
      runs once and can never move a deadline that already exists.

  `%{written: 0, stamped: 0}` covers the three cases where there is nothing to
  do, and they are deliberately not told apart — the contract is "this
  engagement's archive is up to date", not "here is why it is empty":

    * an engagement whose term has not closed at `instant`;
    * an id that names nothing;
    * **an erased person**, which is the issue's "suppresses retained-copy
      creation". It is derived from `people.erased_at` rather than stored,
      because erasure is irreversible and a derived answer cannot fall out of
      step with the row it is about. A `suppressed` column on `engagements`
      would be a second place for one fact to live, and the sweeper would have
      to remember to read it.

  Always `{:ok, _}`; a refusal is one of the three above rather than an error.
  """
  @spec retain_own_messages(Ecto.UUID.t(), DateTime.t()) :: {:ok, archive()}
  def retain_own_messages(engagement_id, %DateTime{} = instant) when is_binary(engagement_id) do
    Multi.new()
    |> Multi.run(:engagement, fn repo, _changes -> closed(repo, engagement_id, instant) end)
    |> Multi.run(:person, fn repo, %{engagement: engagement} ->
      unerased_or_skip(repo, engagement.person_id)
    end)
    |> Multi.run(:written, fn repo, %{engagement: engagement} ->
      {:ok, backfill_copies(repo, engagement, instant)}
    end)
    |> Multi.run(:stamped, fn repo, %{engagement: engagement} ->
      count(repo.update_all(deadline_stamp(engagement, instant), []))
    end)
    |> Repo.transaction()
    |> archived()
  end

  @spec closed(Ecto.Repo.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Engagement.t()} | {:error, :still_open}
  defp closed(repo, engagement_id, instant) do
    engagement_id |> Records.closed_engagement(instant) |> repo.one() |> closed_term()
  end

  @spec closed_term(Engagement.t() | nil) :: {:ok, Engagement.t()} | {:error, :still_open}
  defp closed_term(%Engagement{} = engagement), do: {:ok, engagement}
  defp closed_term(nil), do: {:error, :still_open}

  @spec unerased_or_skip(Ecto.Repo.t(), Ecto.UUID.t()) :: {:ok, Person.t()} | {:error, :erased}
  defp unerased_or_skip(repo, person_id) do
    person_id |> Records.unerased_person_shared() |> repo.one() |> present_person()
  end

  @spec present_person(Person.t() | nil) :: {:ok, Person.t()} | {:error, :erased}
  defp present_person(%Person{} = person), do: {:ok, person}
  defp present_person(nil), do: {:error, :erased}

  @spec deadline_stamp(Engagement.t(), DateTime.t()) :: Ecto.Query.t()
  defp deadline_stamp(%Engagement{} = engagement, instant) do
    Records.stamp_undated_copies(engagement.id, archive_deadline(engagement.ends_at), instant)
  end

  # Chunked, because `insert_all` binds one parameter per field per row and
  # Postgres refuses more than 65535 of them — ten fields put the wall at 6553
  # messages, which is an ordinary year at a busy venue. Past it the statement
  # raised `Postgrex.QueryError` out of `perform/1`, the job failed every
  # attempt, was discarded, was re-inserted by the sweeper and failed again.
  # `on_conflict: :nothing` is what makes partial progress safe.
  #
  # The read is still one `Repo.all`: a bound on the statement, not on memory.
  # An engagement with millions of messages would want a cursor, and this is a
  # POC with a sweep bounded at five hundred rows a tick.
  @spec backfill_copies(Ecto.Repo.t(), Engagement.t(), DateTime.t()) :: non_neg_integer()
  defp backfill_copies(repo, %Engagement{} = engagement, instant) do
    deadline = archive_deadline(engagement.ends_at)
    stamped_at = DateTime.truncate(instant, :second)

    engagement.id
    |> Records.messages_of_engagement()
    |> repo.all()
    |> Enum.map(&copy_of(&1, engagement, stamped_at, deadline))
    |> Enum.chunk_every(@copy_chunk_size)
    |> Enum.reduce(0, fn chunk, written -> written + insert_copies(repo, chunk) end)
  end

  @spec insert_copies(Ecto.Repo.t(), [map()]) :: non_neg_integer()
  defp insert_copies(repo, rows) do
    {written, _rows} =
      repo.insert_all(RetainedMessageCopy, rows,
        on_conflict: :nothing,
        conflict_target: [:engagement_id, :source_message_id]
      )

    written
  end

  # `insert_all` is not on Ecto's insert path, so a `binary_id` primary key is
  # not autogenerated and is minted here.
  @spec copy_of(RoomMessage.t(), Engagement.t(), DateTime.t(), DateTime.t() | nil) :: map()
  defp copy_of(%RoomMessage{} = message, %Engagement{} = engagement, retained_at, deadline) do
    stamped_at = DateTime.truncate(retained_at, :second)

    %{
      id: Ecto.UUID.generate(),
      engagement_id: engagement.id,
      person_id: engagement.person_id,
      source_message_id: message.id,
      body: message.body,
      sent_at: message.sent_at,
      retained_at: stamped_at,
      delete_after: deadline,
      inserted_at: stamped_at,
      updated_at: stamped_at
    }
  end

  @spec archived({:ok, map()} | {:error, atom(), term(), map()}) :: {:ok, archive()}
  defp archived({:ok, %{written: written, stamped: stamped}}) do
    {:ok, %{written: written, stamped: stamped}}
  end

  defp archived({:error, _step, _reason, _changes}), do: {:ok, %{written: 0, stamped: 0}}

  @doc """
  A person's own archive of what they said, oldest first.

  The person zone's side of KTD16: these rows survive the deletion of the
  employer-zone messages they were copied from, which is what a filtered view
  over one row could not have done.
  """
  @spec list_retained_messages(PersonScope.t()) :: [RetainedMessageCopy.t()]
  def list_retained_messages(%PersonScope{person: %Person{id: person_id}})
      when is_binary(person_id) do
    person_id |> Records.archive_of() |> Repo.all()
  end

  ## The sweep

  @doc """
  Deletes everything whose stamped deadline has passed at `instant`, and records
  the run.

  Bounded per trigger by `batch_size/0` and in total by `ceiling/0`; above the
  ceiling **every** trigger rolls back, not only the one that overflowed, and
  the record says what it would have deleted.

  Always `{:ok, run}`. A refusal is an outcome the sweep reports rather than an
  error it raises: the next tick asks again, and the record is the trace an
  unattended deleter owes.
  """
  @spec sweep(DateTime.t()) :: {:ok, RetentionRun.t()}
  def sweep(%DateTime{} = instant) do
    ceiling = ceiling()

    Repo.transaction(fn -> delete_due(instant, ceiling) end)
    |> recorded(instant, ceiling)
  end

  @spec delete_due(DateTime.t(), pos_integer()) :: RetentionRun.t() | no_return()
  defp delete_due(instant, ceiling) do
    limit = batch_size()

    counts = %{
      own_message_copies: delete_batch(RetainedMessageCopy, Records.due_copies(instant, limit)),
      shift_messages: delete_batch(RoomMessage, Records.due_shift_messages(instant, limit)),
      venue_room_messages: delete_batch(RoomMessage, Records.due_venue_messages(instant, limit)),
      roster_entries: delete_batch(RosterEntry, Records.due_roster_entries(instant, limit))
    }

    counts
    |> total()
    |> Kernel.<=(ceiling)
    |> commit_or_refuse(counts, instant, ceiling)
  end

  # Two statements rather than one `DELETE … WHERE id IN (subquery)`, because
  # Postgres has no `DELETE … LIMIT` and the bound has to be a `SELECT`. Both
  # run inside the sweep's transaction, so nothing can slip between them.
  @spec delete_batch(module(), Ecto.Query.t()) :: non_neg_integer()
  defp delete_batch(schema, due) do
    {deleted, _rows} = schema |> Records.by_ids(Repo.all(due)) |> Repo.delete_all()
    deleted
  end

  @spec total(RetentionRun.counts()) :: non_neg_integer()
  defp total(counts), do: counts |> Map.values() |> Enum.sum()

  @spec commit_or_refuse(boolean(), RetentionRun.counts(), DateTime.t(), pos_integer()) ::
          RetentionRun.t() | no_return()
  defp commit_or_refuse(true, counts, instant, ceiling) do
    insert_run(instant, :completed, ceiling, counts)
  end

  defp commit_or_refuse(false, counts, _instant, _ceiling), do: Repo.rollback(counts)

  # On the ordinary path the record is written inside the deleting transaction,
  # so a committed deletion is never unrecorded. On the refusal path it is
  # written after the rollback, because the case a record matters most for is
  # the one where everything else was undone.
  @spec recorded(
          {:ok, RetentionRun.t()} | {:error, RetentionRun.counts()},
          DateTime.t(),
          pos_integer()
        ) ::
          {:ok, RetentionRun.t()}
  defp recorded({:ok, %RetentionRun{} = run}, _instant, _ceiling), do: {:ok, run}

  defp recorded({:error, counts}, instant, ceiling) do
    {:ok, insert_run(instant, :refused, ceiling, counts)}
  end

  @spec insert_run(DateTime.t(), RetentionRun.outcome(), pos_integer(), RetentionRun.counts()) ::
          RetentionRun.t()
  defp insert_run(instant, outcome, ceiling, counts) do
    instant |> RetentionRun.changeset(outcome, ceiling, counts) |> Repo.insert!()
  end

  ## The reap

  @doc """
  Deletes expired auth tokens and people who never confirmed an address.

  Issue #15's second and third halves. `POST /api/log-in` writes a `people` row
  and a `people_tokens` row for any address an anonymous caller posts, and
  nothing removed either past its horizon except consumption — so both tables
  grew monotonically behind an endpoint that had no limiter in front of it
  either.

  One transaction, two bounded statements, each capped at `batch_size/0`, and
  **no lower bound on either**. That is deliberate and it is the opposite of
  `HospitalityComs.Engagements.list_expired/3`, which needs a window precisely
  because it does *not* consume the rows it finds: a limit with no floor pins
  that sweep to the same oldest batch for ever. Both statements here delete what
  they select, so the sweep advances by construction, and a floor would leave
  everything older than the window unreaped for ever — which is the growth this
  function exists to stop, arriving through the fix.

  ## This is not `sweep/1` and it is deliberately not two more of its triggers

  Every trigger in `sweep/1` reads a `delete_after` column that was **stamped
  once, by an event, from a value that can no longer move**, and never computes
  a deadline (KTD16). Both predicates here **compute** one, from `inserted_at`.
  That is correct in this case for reasons that do not generalise — the column
  is written at insert and no changeset in the tree rewrites it, and the horizon
  is a constant rather than another row's period — and a list of six triggers,
  four of which must never compute and two of which do, is a list a future
  author copies the wrong half of.

  ## Why an unconfirmed `people` row can be deleted at all

  `people_tokens.person_id` is the only foreign key into `people` that is not
  `ON DELETE RESTRICT`; every other one — `engagements`, the three peer tables,
  `declared_entries`, `attested_entry_disclosures` — is. **An unconfirmed person
  can hold none of them**, and structurally rather than by survey:
  `confirmed_at` is set by `HospitalityComs.Accounts.login_person_by_magic_link/2`,
  which is the only path that mints a session token, and every context function
  that writes any of those tables takes a `PersonScope` carrying a real person,
  which needs one.

  If a later unit breaks that, the delete raises `foreign_key_violation`, this
  transaction rolls back and the job fails. **A loudly failing unattended
  deleter is the right failure**, and it is why the predicate is not padded with
  a list of `NOT EXISTS` subqueries: a list of five tables is a list somebody
  gets wrong later, and getting it wrong is silent where the foreign key is not.

  ## Sweeping frees the address, and that is the accepted trade

  `people_email_index` is partial on `erased_at IS NULL` and the reaped row is
  *gone* rather than pseudonymised, so **an unconfirmed address becomes
  re-registerable**, exactly as if it had never been used. An address that was
  sent a link and never redeemed for a month is not in use; and the alternative
  — keeping the row for ever so the address can never be claimed again — hands
  an anonymous caller a permanent way to burn other people's addresses, which is
  the abuse this issue is about rather than a defence against it.

  No `HospitalityComs.Lifecycle.RetentionRun` is written and no table records
  this. That record exists because retention destroys the only surviving copy of
  a person's words; this destroys a credential the authenticator had already
  stopped honouring at the same instant, and a row whose owner recovers it by
  typing the same address into the same endpoint. The counts are returned, and
  `HospitalityComs.Workers.AccountReaper` logs them.

  Always `{:ok, _}`.
  """
  @spec reap(DateTime.t()) :: {:ok, reaping()}
  def reap(%DateTime{} = instant) do
    Repo.transaction(fn -> reap_due(instant) end)
  end

  # Tokens first, so the count is every token that was expired in its own right;
  # the person delete that follows cascades only the tokens still inside their
  # horizon, of which an unconfirmed person thirty days old has none.
  @spec reap_due(DateTime.t()) :: reaping()
  defp reap_due(instant) do
    limit = batch_size()

    %{
      expired_tokens: delete_batch(PersonToken, Records.expired_tokens(instant, limit)),
      unconfirmed_people:
        delete_batch(Person, Records.unconfirmed_people(unconfirmed_horizon(instant), limit))
    }
  end

  @spec unconfirmed_horizon(DateTime.t()) :: DateTime.t()
  defp unconfirmed_horizon(instant) do
    instant |> DateTime.add(-@unconfirmed_retention_days, :day) |> DateTime.truncate(:second)
  end

  @spec setting(atom(), pos_integer()) :: pos_integer()
  defp setting(key, default) do
    :hospitality_coms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
