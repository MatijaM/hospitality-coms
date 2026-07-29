defmodule HospitalityComs.Lifecycle.Records do
  @moduledoc """
  Every query the lifecycle context makes, including the ones that delete.

  The rule `HospitalityComs.Profiles.Records` set: the context builds no query
  at all, so a caller reading `HospitalityComs.Lifecycle` sees which rows go and
  in what order, and a caller reading this file sees exactly which rows each
  statement can reach. `HospitalityComs.LifecycleTest` asserts it structurally
  out of the compiled `imports` chunk.

  That matters more here than anywhere else in the tree, because this is the one
  module permitted to delete (KTD21) and half of these queries are the argument
  to a `delete_all`.

  ## Every retention query filters on a stamped column and joins nothing

  `due_*` all read `delete_after < ^instant` and nothing else. There is no join
  to `engagements`, to `shift_rooms` or to `venues` anywhere in this file's
  retention half, and that absence is the unit's central decision rather than an
  optimisation: a join would let a corrected period move a deadline into the
  past and have the next unattended run destroy a worker's messages.

  `<` rather than `<=`, half-open like every other boundary in the tree: a row
  whose deadline is exactly the sweep's instant survives.

  ## The batch bound is a subquery, not a limit on the delete

  Postgres has no `DELETE … LIMIT`, so each `due_*` is a bounded `SELECT id`
  that the delete's `where … in` consumes. The ordering is on the column being
  filtered, so a run that finds a full batch leaves the *newest* deadlines for
  the next one — the same shape `HospitalityComs.Engagements.list_expired/3`
  uses, and for the same reason: a bound with no order pins a limited sweep to
  an arbitrary slice for ever.
  """

  import Ecto.Query

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Lifecycle.RetainedMessageCopy
  alias HospitalityComs.Peers.PeerMessage
  alias HospitalityComs.Profiles.DeclaredEntry
  alias HospitalityComs.Profiles.Disclosure
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rosters.RosterEntry
  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Venues.Venue

  ## Erasure

  @doc """
  The person, locked, if they have not been erased already.

  `FOR UPDATE` rather than a plain read: two concurrent erasure requests would
  otherwise both find `erased_at` null, both pseudonymise, and the second would
  overwrite the first's instant with its own.
  """
  @spec unerased_person(Ecto.UUID.t()) :: Ecto.Query.t()
  def unerased_person(person_id) when is_binary(person_id) do
    from person in Person,
      where: person.id == ^person_id,
      where: is_nil(person.erased_at),
      lock: "FOR UPDATE"
  end

  @doc """
  The person, share-locked, if they have not been erased.

  What every write to the archive resolves first. Read rather than stored,
  because erasure is irreversible: a derived answer cannot fall out of step with
  the row it is about, and a `suppressed` column on `engagements` would be a
  second place for the same fact to live.

  `FOR SHARE` rather than a plain read, and the lock mode is the whole of it. An
  unlocked check followed by an insert is two unsynchronised statements: a
  concurrent `erase_person/1` that commits between them leaves copies behind
  that erasure's own `delete_all` has already run past, and nothing blocks —
  the copy's foreign key takes `FOR KEY SHARE`, which does not conflict with the
  `FOR NO KEY UPDATE` erasure's own update takes. `FOR SHARE` does conflict with
  the `FOR UPDATE` `unerased_person/1` takes, so the archive either wins the row
  and is finished before erasure starts, or parks and then matches nothing.

  Several archive writes may hold it at once, which is what makes `FOR SHARE`
  the right mode rather than `FOR UPDATE`: two messages sent in the same second
  by one person must not serialise on their own person row.
  """
  @spec unerased_person_shared(Ecto.UUID.t()) :: Ecto.Query.t()
  def unerased_person_shared(person_id) when is_binary(person_id) do
    from person in Person,
      where: person.id == ^person_id,
      where: is_nil(person.erased_at),
      lock: "FOR SHARE"
  end

  @doc """
  Every engagement this person holds, at any venue, in any state.

  What the label reduction covers. Erasure is the one operation in the tree that
  crosses venues, which is why it runs as the application's own role rather than
  under any employer scope.
  """
  @spec engagements_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def engagements_of(person_id) when is_binary(person_id) do
    from engagement in Engagement, where: engagement.person_id == ^person_id
  end

  @doc """
  Their ids alone, which is what the job cancellation is resolved through.
  """
  @spec engagement_ids_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def engagement_ids_of(person_id) when is_binary(person_id) do
    from engagement in engagements_of(person_id), select: engagement.id
  end

  @doc """
  Those of them whose term has not closed by `instant`.

  One state wider than active, exactly as
  `HospitalityComs.Engagements.end_engagement/2`'s target set is: an engagement
  claimed before its term opens can be closed too, at its own `starts_at`, which
  is the empty range. Without that, erasing somebody would leave their dates
  reserved against the exclusion constraint for a term nobody will work.
  """
  @spec open_engagements_of(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def open_engagements_of(person_id, %DateTime{} = instant) do
    from engagement in engagements_of(person_id), where: engagement.ends_at > ^instant
  end

  @doc """
  Every token this person holds, of every context.
  """
  @spec tokens_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def tokens_of(person_id) when is_binary(person_id) do
    from token in PersonToken, where: token.person_id == ^person_id, select: token
  end

  @doc """
  Every peer message this person wrote.

  Their own words and nobody else's: R15's survivor keeps their half of the
  conversation, because the erasing party has no claim over it (KTD15c, applied
  one table over).
  """
  @spec peer_messages_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def peer_messages_of(person_id) when is_binary(person_id) do
    from message in PeerMessage, where: message.author_id == ^person_id
  end

  @doc """
  Every declared entry this person published.

  Deleted by erasure, unlike a message body: a declared entry is free text about
  the author's own history with no other party to it, so KTD15c's reason for
  retaining bodies — that deleting them would destroy conversations belonging to
  other people — does not reach it.
  """
  @spec declared_entries_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def declared_entries_of(person_id) when is_binary(person_id) do
    from entry in DeclaredEntry, where: entry.person_id == ^person_id
  end

  @doc """
  The disclosure rows this person wrote about their **own** entries that hand an
  entry *over* rather than take one away.

  The ledger is otherwise kept, and the argument for keeping it holds for
  `disclosed = false` alone: a `false` row narrows what an audience sees, so
  deleting one discloses *more*, and peer visibility runs thirty days past an
  engagement's end. A `true` row is the opposite — `Profiles.Records`'s peer rule
  reads it as an override that beats the computed concurrency default, so
  keeping one means an erased person goes on affirmatively disclosing an entry
  to a named peer for the tail, with no session left to take it back.

  Rows naming this person as the *audience* are somebody else's decision about
  their own entries and are untouched in both directions, which is why this is
  reached through their engagements rather than through `audience_person_id`.
  """
  @spec asserted_disclosures_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def asserted_disclosures_of(person_id) when is_binary(person_id) do
    from disclosure in Disclosure,
      where: disclosure.disclosed == true,
      where: disclosure.engagement_id in subquery(engagement_ids_of(person_id))
  end

  @doc """
  Every retained copy belonging to this person, unordered.

  Unordered because `delete_all` accepts only `where` and `join` — an ordering
  inherited from a list query raises `Ecto.QueryError` from inside the
  transaction, which is the same trap `HospitalityComs.Peers.Records.party_to/2`
  documents. `archive_of/1` is the reading form.
  """
  @spec retained_copies_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def retained_copies_of(person_id) when is_binary(person_id) do
    from copy in RetainedMessageCopy, where: copy.person_id == ^person_id
  end

  @doc """
  The same rows in the order a person reads them.
  """
  @spec archive_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def archive_of(person_id) when is_binary(person_id) do
    from copy in retained_copies_of(person_id), order_by: [asc: copy.sent_at, asc: copy.id]
  end

  @doc """
  Closes every term of this person's that has not closed yet, at the later of
  `instant` and the engagement's own opening.

  `GREATEST` rather than two statements, because the widening is per row: an
  active engagement closes now and a not-yet-started one closes at its own
  `starts_at` — `ends_at == starts_at`, the empty range, active at no instant
  and overlapping nothing. `ends_at < starts_at` is unrepresentable; the
  generated `period` column raises on it.

  `lock_version` is incremented so that a renewal in flight against one of these
  rows loses rather than silently reopening a term the person asked to have
  ended.
  """
  @spec close_open_engagements(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def close_open_engagements(person_id, %DateTime{} = instant) do
    stamped = DateTime.truncate(instant, :second)

    from engagement in open_engagements_of(person_id, instant),
      update: [
        set: [
          ends_at:
            fragment("GREATEST(?, ?)", engagement.starts_at, type(^stamped, :utc_datetime)),
          updated_at: ^stamped
        ],
        inc: [lock_version: 1]
      ]
  end

  @doc """
  Replaces every one of this person's engagement labels with `label`.

  KTD15b: the display label lives on the engagement, so erasure reduces a number
  of rows proportional to *engagements* and no `room_messages` row is touched at
  all. Every engagement, not only the open ones — a term that ended last year
  still renders its author's label on every message it wrote.
  """
  @spec reduce_labels(Ecto.UUID.t(), String.t(), DateTime.t()) :: Ecto.Query.t()
  def reduce_labels(person_id, label, %DateTime{} = instant) when is_binary(label) do
    stamped = DateTime.truncate(instant, :second)

    from engagement in engagements_of(person_id),
      update: [set: [role_label: ^label, updated_at: ^stamped]]
  end

  @doc """
  Nulls the address, overwrites the display name, and stamps `erased_at`, in one
  statement.

  There is no `Person` changeset for this, deliberately.
  `HospitalityComs.Accounts.Person`'s moduledoc says why: the address pair is
  held in opposition by `people_erased_email_removed` and
  `people_present_email_required`, which are database constraints precisely so
  the guarantee survives being reached from a context that is not `Accounts`.

  **The name is overwritten rather than removed**, and it is the reason
  `people_display_name_present` and `people_display_name_within_bound` exist:
  this statement is the one write in the tree that reaches that column with no
  changeset in front of it, so a validation would not be consulted here at all.
  `name` is a parameter rather than a literal for `reduce_labels/3`'s reason —
  the constant lives in `HospitalityComs.Lifecycle` beside the label, where a
  reader looking for what erasure leaves finds both.
  """
  @spec pseudonymise(Ecto.UUID.t(), String.t(), DateTime.t()) :: Ecto.Query.t()
  def pseudonymise(person_id, name, %DateTime{} = instant)
      when is_binary(person_id) and is_binary(name) do
    stamped = DateTime.truncate(instant, :second)

    from person in Person,
      where: person.id == ^person_id,
      update: [set: [email: nil, display_name: ^name, erased_at: ^stamped, updated_at: ^stamped]],
      select: person
  end

  @doc """
  The scheduled expiry jobs belonging to a set of engagements.

  `HospitalityComs.Workers.ExpireEngagement`'s args carry no `person_id` — a
  job's args are a `jsonb` column in `public` and KTD2's rule about where a
  human may be named does not stop at the schemas this application owns — so
  "that person's jobs" is resolved through the engagements the erasure is
  ending.

  Deleting the rows rather than calling `Oban.cancel_job/1` is what makes the
  cancellation part of the transaction: a cancel would survive a rolled-back
  erasure, and would be missing from a committed one that crashed a step later.

  ## No state filter, and that is a decision rather than an omission

  The rows go whatever state they are in, `:executing` included — so a job that
  is running while the erasure commits has its row deleted underneath it.
  Measured on the pinned Oban (2.23): `Oban.Engines.Basic.complete_job/2` is an
  `update_all` whose affected count it discards, returning `:ok` unconditionally,
  and `Oban.Queue.Executor.ack_event/1` discards that in turn. Driven directly
  against a deleted row it answers `:ok` and logs nothing at `:warning`. There is
  no orphan either: the producer's running set is in memory, and no `Lifeline`
  plugin is configured.

  What that job could otherwise have *written* is closed by a different guard
  entirely, not by this one. `HospitalityComs.Lifecycle.retain_own_messages/2`
  resolves the person under `FOR SHARE` and `erase_person/1` holds `FOR UPDATE`
  on the same row for the length of its transaction, so the archive write either
  commits before the erasure starts — and is then deleted by it — or parks and
  finds the person erased. The interleaving is decided there, at the row, rather
  than here by guessing at a job's state.

  A filter also reads backwards. Excluding `:executing` leaves a row that reaches
  `:completed`, which under `HospitalityComs.Workers.ExpireEngagement`'s
  `period: :infinity` uniqueness then *suppresses* the sweeper's replacement —
  the opposite of what "leave the row behind" sounds like — and keeping only the
  incomplete states leaves an erased person's completed announcements in
  `oban_jobs` for the pruner's seven days. Either way it would put a second
  enumeration of Oban's states in the tree, in a module about retention,
  answering a different question from the one `ExpireEngagement`'s `:unique`
  states answer, and a state list with a judgement call in it is a list somebody
  gets wrong later.

  So the contract is about rows and not about a state machine: after an erasure,
  no queued work names this person's engagements. `HospitalityComs.LifecycleTest`
  pins it over three states so that adding a filter fails rather than passes.
  """
  @spec jobs_for_engagements([Ecto.UUID.t()]) :: Ecto.Query.t()
  def jobs_for_engagements(engagement_ids) when is_list(engagement_ids) do
    from job in Oban.Job,
      where: fragment("? ->> 'engagement_id' = ANY(?)", job.args, ^engagement_ids)
  end

  ## The orphaned state KTD17 promises a path out of

  @doc """
  Venues holding a live grant that no active engagement holds.

  KTD17's orphaned state, given a name rather than left to be derived. Erasure
  is exempt from the last-grant-holder invariant — gating a data-subject right
  on an operational convenience is the wrong trade — so this is the list an
  operator re-seeds from.

  "Holding an authority" is `EmployerGrant.live_at/2`, reused rather than
  restated, so "live" cannot come to mean two things. A venue whose only grant
  was revoked is *not* orphaned: it has no authority for anybody to be the last
  holder of, which is a venue that was wound up rather than one that needs a
  manager.

  A venue that was **closed** is not orphaned either, for the same reason and by
  a different route. `close_venue/2` leaves the grant live — it starts a
  retention clock, it does not revoke anybody — so a wound-up venue whose
  manager's term has since ended satisfies every other clause here and would be
  handed to an operator as something to re-seed. Closure is the explicit form of
  the state revocation reaches by accident.
  """
  @spec orphaned_venues(DateTime.t()) :: Ecto.Query.t()
  def orphaned_venues(%DateTime{} = instant) do
    from(venue in Venue, as: :venue)
    |> where([venue], is_nil(venue.closed_at))
    |> where([venue], exists(live_grant(instant)))
    |> where([venue], not exists(live_grant_holder(instant)))
    |> order_by([venue], asc: venue.name, asc: venue.id)
  end

  @spec live_grant(DateTime.t()) :: Ecto.Query.t()
  defp live_grant(instant) do
    from grant in EmployerGrant,
      where: grant.venue_id == parent_as(:venue).id,
      where: grant.granted_at <= ^instant,
      where: is_nil(grant.revoked_at) or grant.revoked_at > ^instant,
      select: 1
  end

  @spec live_grant_holder(DateTime.t()) :: Ecto.Query.t()
  defp live_grant_holder(instant) do
    from engagement in Engagement,
      join: grant in EmployerGrant,
      on: grant.id == engagement.grant_id and grant.venue_id == engagement.venue_id,
      where: engagement.venue_id == parent_as(:venue).id,
      where: engagement.starts_at <= ^instant and engagement.ends_at > ^instant,
      where: grant.granted_at <= ^instant,
      where: is_nil(grant.revoked_at) or grant.revoked_at > ^instant,
      select: 1
  end

  ## Venue closure

  @doc """
  The venue, if it is still trading.

  A predicate and nothing else: **no `select`**, deliberately. It used to carry
  `select: venue`, which is invisible in a function this size and became the
  `RETURNING` clause of `close_venue/2`'s `update_all` a few lines down — so
  `HospitalityComs.Lifecycle`'s `{1, [%Venue{}]}` depended on a select declared
  by a function that knows nothing about it, and dropping it here (to reuse this
  as a subquery predicate, say) would have left `update_all` answering `{1, nil}`
  in another file. The select now lives on the statement whose result is read,
  and Ecto refuses two in one query, so re-adding one here raises rather than
  quietly restoring the coupling.
  """
  @spec open_venue(Ecto.UUID.t()) :: Ecto.Query.t()
  def open_venue(venue_id) when is_binary(venue_id) do
    from venue in Venue,
      where: venue.id == ^venue_id,
      where: is_nil(venue.closed_at)
  end

  @doc """
  Whether a venue of this id exists at all.

  Runs only when `open_venue/1` matched nothing, so it cannot turn a refusal
  into a success — the shape `HospitalityComs.Engagements` uses to tell three
  claim refusals apart.
  """
  @spec venue(Ecto.UUID.t()) :: Ecto.Query.t()
  def venue(venue_id) when is_binary(venue_id) do
    from venue in Venue, where: venue.id == ^venue_id
  end

  @doc """
  A venue's messages that carry no deadline yet.

  The venue-room ones, and **only** those: a shift message's deadline was fixed
  when it was sent, and re-stamping it at closure would let the venue's clock
  overwrite the shift's. Null and "belongs to the venue room" are the same state
  here, which is why the predicate names the deadline rather than the room.
  """
  @spec undated_messages_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def undated_messages_of(venue_id) when is_binary(venue_id) do
    from message in RoomMessage,
      where: message.venue_id == ^venue_id,
      where: is_nil(message.delete_after)
  end

  @doc """
  Closes a venue that is still trading, returning the row.

  Conditional on `closed_at IS NULL` and reporting the affected count, so two
  callers closing at once close it once and the loser is `:already_closed`
  rather than the second write deciding when the venue shut.

  `select: venue` is this statement's `RETURNING` clause, and
  `HospitalityComs.Lifecycle`'s `{1, [%Venue{} = venue]}` is the only thing that
  reads it. It is declared here rather than inherited from `open_venue/1` so
  that the function whose result depends on it is the function that asks for it.
  """
  @spec close_venue(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def close_venue(venue_id, %DateTime{} = instant) when is_binary(venue_id) do
    stamped = DateTime.truncate(instant, :second)

    from venue in open_venue(venue_id),
      update: [set: [closed_at: ^stamped, updated_at: ^stamped]],
      select: venue
  end

  @doc """
  Gives a venue's undated messages the deadline closure just created.
  """
  @spec stamp_undated_messages(Ecto.UUID.t(), DateTime.t(), DateTime.t()) :: Ecto.Query.t()
  def stamp_undated_messages(venue_id, %DateTime{} = deadline, %DateTime{} = instant) do
    stamped = DateTime.truncate(instant, :second)

    from message in undated_messages_of(venue_id),
      update: [set: [delete_after: ^DateTime.truncate(deadline, :second), updated_at: ^stamped]]
  end

  ## The worker's archive

  @doc """
  The messages one engagement authored, oldest first.

  Both room kinds: the archive is "what this person said while they worked
  here", and the venue room is most of it.
  """
  @spec messages_of_engagement(Ecto.UUID.t()) :: Ecto.Query.t()
  def messages_of_engagement(engagement_id) when is_binary(engagement_id) do
    from message in RoomMessage,
      where: message.author_engagement_id == ^engagement_id,
      order_by: [asc: message.sent_at, asc: message.id]
  end

  @doc """
  One engagement, if its term has closed by `instant`.

  The archive's deadline is `ends_at + 90 days`, and it is stamped exactly once
  because this is the state after which `ends_at` can no longer move:
  `renew_engagement/3` answers on activeness and `end_engagement/2` on "has not
  closed", so neither reaches a term already behind the instant asking.
  """
  @spec closed_engagement(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def closed_engagement(engagement_id, %DateTime{} = instant) when is_binary(engagement_id) do
    from engagement in Engagement,
      where: engagement.id == ^engagement_id,
      where: engagement.ends_at <= ^instant
  end

  @doc """
  Gives this engagement's unstamped copies the deadline its closing created.

  `is_nil(delete_after)` is the whole condition, so this is idempotent and can
  never move a deadline that already exists — the property KTD16 asks of every
  write near a retention clock, and the same predicate
  `stamp_undated_messages/3` uses one table over.
  """
  @spec stamp_undated_copies(Ecto.UUID.t(), DateTime.t(), DateTime.t()) :: Ecto.Query.t()
  def stamp_undated_copies(engagement_id, %DateTime{} = deadline, %DateTime{} = instant)
      when is_binary(engagement_id) do
    stamped = DateTime.truncate(instant, :second)

    from copy in RetainedMessageCopy,
      where: copy.engagement_id == ^engagement_id,
      where: is_nil(copy.delete_after),
      update: [set: [delete_after: ^DateTime.truncate(deadline, :second), updated_at: ^stamped]]
  end

  ## The sweep

  @doc """
  Retained copies whose stamped deadline has passed, bounded.
  """
  @spec due_copies(DateTime.t(), pos_integer()) :: Ecto.Query.t()
  def due_copies(%DateTime{} = instant, limit) when is_integer(limit) and limit > 0 do
    from copy in RetainedMessageCopy,
      where: copy.delete_after < ^instant,
      order_by: [asc: copy.delete_after, asc: copy.id],
      limit: ^limit,
      select: copy.id
  end

  @doc """
  Shift-room messages whose stamped deadline has passed, bounded.
  """
  @spec due_shift_messages(DateTime.t(), pos_integer()) :: Ecto.Query.t()
  def due_shift_messages(%DateTime{} = instant, limit) when is_integer(limit) and limit > 0 do
    instant |> due_messages(limit) |> where([message], not is_nil(message.shift_room_id))
  end

  @doc """
  Venue-room messages whose stamped deadline has passed, bounded.

  Null never matches `<`, so this is empty for every venue that is still
  trading — which is KTD16's "venue-room history has no deletion clock while the
  venue exists", expressed as the absence of a value rather than as a special
  case in the sweep.
  """
  @spec due_venue_messages(DateTime.t(), pos_integer()) :: Ecto.Query.t()
  def due_venue_messages(%DateTime{} = instant, limit) when is_integer(limit) and limit > 0 do
    instant |> due_messages(limit) |> where([message], is_nil(message.shift_room_id))
  end

  @doc """
  Roster entries whose stamped deadline has passed, bounded.
  """
  @spec due_roster_entries(DateTime.t(), pos_integer()) :: Ecto.Query.t()
  def due_roster_entries(%DateTime{} = instant, limit) when is_integer(limit) and limit > 0 do
    from entry in RosterEntry,
      where: entry.delete_after < ^instant,
      order_by: [asc: entry.delete_after, asc: entry.id],
      limit: ^limit,
      select: entry.id
  end

  ## The reap (issue #15)

  @doc """
  Tokens whose own context's validity has elapsed at `instant`, bounded.

  **This is the exact complement of the three `verify_*_query` functions in
  `HospitalityComs.Accounts.PersonToken`.** Each of them admits a token when
  `inserted_at > instant - validity`, strictly, so a token whose validity
  elapses exactly at the instant asked about is already refused — and the
  predicate here is therefore `<=` rather than the `<` the retention sweep uses.
  The two boundaries differ by one instant and each matches the rule that
  governs it: a credential's own liveness there, `delete_after` there.

  The three validities are read from `PersonToken` rather than restated. A
  second copy of a number is a copy that drifts from the query that honours it,
  and `HospitalityComs.LifecycleReapTest` asserts the complement behaviourally
  rather than by comparing constants.

  **The fourth clause is a catch-all and it is not padding.** Three contexts
  exist today; an enumeration of them is a hole on the day a later unit writes a
  fourth, and the hole is silent — the table simply starts growing again. An
  unrecognised context is therefore reaped at the longest horizon this
  application honours anywhere, which is the most conservative answer available
  without knowing what the context means.
  """
  @spec expired_tokens(DateTime.t(), pos_integer()) :: Ecto.Query.t()
  def expired_tokens(%DateTime{} = instant, limit) when is_integer(limit) and limit > 0 do
    from token in PersonToken,
      where: ^expired_by_context(instant),
      order_by: [asc: token.inserted_at, asc: token.id],
      limit: ^limit,
      select: token.id
  end

  # Split into the three the application writes and the ones it does not, which
  # is also the shape of the argument: the first half is the complement of three
  # named liveness rules, the second is the conservative answer for a context
  # whose rule nobody has written yet.
  @spec expired_by_context(DateTime.t()) :: Ecto.Query.dynamic_expr()
  defp expired_by_context(instant) do
    session = horizon(instant, PersonToken.session_validity_in_days(), :day)
    login = horizon(instant, PersonToken.magic_link_validity_in_minutes(), :minute)
    change = horizon(instant, PersonToken.change_email_validity_in_days(), :day)

    # The longest validity is the *earliest* horizon, so the catch-all is the
    # minimum of the three rather than a fourth constant.
    longest = Enum.min([session, login, change], DateTime)

    dynamic(
      [token],
      ^known_context_expired(session, login, change) or ^unknown_context_expired(longest)
    )
  end

  @spec known_context_expired(DateTime.t(), DateTime.t(), DateTime.t()) ::
          Ecto.Query.dynamic_expr()
  defp known_context_expired(session, login, change) do
    dynamic(
      [token],
      (token.context == "session" and token.inserted_at <= ^session) or
        (token.context == "login" and token.inserted_at <= ^login) or
        (like(token.context, "change:%") and token.inserted_at <= ^change)
    )
  end

  @spec unknown_context_expired(DateTime.t()) :: Ecto.Query.dynamic_expr()
  defp unknown_context_expired(longest) do
    dynamic(
      [token],
      token.context not in ["session", "login"] and
        not like(token.context, "change:%") and
        token.inserted_at <= ^longest
    )
  end

  @doc """
  People who never confirmed an address and were registered before `horizon`,
  bounded.

  `<` rather than `<=`, half-open in the direction `due_copies/2` and its
  siblings use: a row whose horizon is exactly the instant survives. There is no
  authenticator to complement here, so the tree's own convention decides it.

  Two predicates that look defensive are not. `erased_at IS NULL` keeps the
  pseudonymised tombstone erasure leaves behind, which carries no address and
  which nothing may delete; and `confirmed_at IS NULL` is what makes the row
  safe to delete at all — see `HospitalityComs.Lifecycle.reap/1`.

  There is deliberately no `NOT EXISTS` over the tables that reference `people`.
  Five subqueries would be five chances to write the list wrong, and being wrong
  would be *silent*, where the `ON DELETE RESTRICT` keys those tables already
  carry make it loud.
  """
  @spec unconfirmed_people(DateTime.t(), pos_integer()) :: Ecto.Query.t()
  def unconfirmed_people(%DateTime{} = horizon, limit) when is_integer(limit) and limit > 0 do
    from person in Person,
      where: is_nil(person.confirmed_at),
      where: is_nil(person.erased_at),
      where: person.inserted_at < ^horizon,
      order_by: [asc: person.inserted_at, asc: person.id],
      limit: ^limit,
      select: person.id
  end

  @doc """
  Rows of a table by primary key, which is what every delete here is given.

  A bounded `SELECT id` and then a delete over the ids, because Postgres has no
  `DELETE … LIMIT`.
  """
  @spec by_ids(module(), [Ecto.UUID.t()]) :: Ecto.Query.t()
  def by_ids(schema, ids) when is_atom(schema) and is_list(ids) do
    from row in schema, where: row.id in ^ids
  end

  # `inserted_at` is second-precision on both tables and Ecto refuses to dump a
  # `:utc_datetime` parameter carrying microseconds, so the horizon is truncated
  # rather than compared at a precision the column does not have — the same
  # manoeuvre `PersonToken` makes for the same reason.
  @spec horizon(DateTime.t(), pos_integer(), :day | :minute) :: DateTime.t()
  defp horizon(instant, amount, unit) do
    instant |> DateTime.add(-amount, unit) |> DateTime.truncate(:second)
  end

  @spec due_messages(DateTime.t(), pos_integer()) :: Ecto.Query.t()
  defp due_messages(instant, limit) do
    from message in RoomMessage,
      where: message.delete_after < ^instant,
      order_by: [asc: message.delete_after, asc: message.id],
      limit: ^limit,
      select: message.id
  end
end
