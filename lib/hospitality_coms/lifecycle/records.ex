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
  Whether this person has been erased.

  Read rather than stored on the copy path, because erasure is irreversible: a
  derived answer cannot fall out of step with the row it is about, and a
  `suppressed` column on `engagements` would be a second place for the same fact
  to live.
  """
  @spec erased_person(Ecto.UUID.t()) :: Ecto.Query.t()
  def erased_person(person_id) when is_binary(person_id) do
    from person in Person, where: person.id == ^person_id, where: not is_nil(person.erased_at)
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
  Nulls the address and stamps `erased_at`, in one statement.

  There is no `Person` changeset for this, deliberately.
  `HospitalityComs.Accounts.Person`'s moduledoc says why: the pair is held in
  opposition by `people_erased_email_removed` and
  `people_present_email_required`, which are database constraints precisely so
  the guarantee survives being reached from a context that is not `Accounts`.
  """
  @spec pseudonymise(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def pseudonymise(person_id, %DateTime{} = instant) when is_binary(person_id) do
    stamped = DateTime.truncate(instant, :second)

    from person in Person,
      where: person.id == ^person_id,
      update: [set: [email: nil, erased_at: ^stamped, updated_at: ^stamped]],
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
  """
  @spec orphaned_venues(DateTime.t()) :: Ecto.Query.t()
  def orphaned_venues(%DateTime{} = instant) do
    from(venue in Venue, as: :venue)
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
  """
  @spec open_venue(Ecto.UUID.t()) :: Ecto.Query.t()
  def open_venue(venue_id) when is_binary(venue_id) do
    from venue in Venue,
      where: venue.id == ^venue_id,
      where: is_nil(venue.closed_at),
      select: venue
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
  """
  @spec close_venue(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def close_venue(venue_id, %DateTime{} = instant) when is_binary(venue_id) do
    stamped = DateTime.truncate(instant, :second)

    from venue in open_venue(venue_id),
      update: [set: [closed_at: ^stamped, updated_at: ^stamped]]
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

  @doc """
  Rows of a table by primary key, which is what every delete here is given.

  A bounded `SELECT id` and then a delete over the ids, because Postgres has no
  `DELETE … LIMIT`.
  """
  @spec by_ids(module(), [Ecto.UUID.t()]) :: Ecto.Query.t()
  def by_ids(schema, ids) when is_atom(schema) and is_list(ids) do
    from row in schema, where: row.id in ^ids
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
