defmodule HospitalityComs.Peers.Records do
  @moduledoc """
  Every query the peer graph asks, in one module.

  `HospitalityComs.Peers` is the public API and this is where its `where`
  clauses live, for the reason `AGENTS.md` gives and the reason
  `HospitalityComs.Engagements.Records` and `HospitalityComs.Rooms.Records` give
  more sharply: two of these clauses *are* the authorization model. "Can these
  two see each other" and "who may approach next" are not filters on an answer,
  they are the answer.

  ## Nothing here reads a clock, and one of the answers is not stored anywhere

  Every function takes the instant. It is captured once at the unit-of-work
  boundary and carried on the scope (KTD5); a query module that reached for
  `Clock.now/0` would let two queries in one request disagree about which side
  of a boundary the work fell on. `Ecto.Query.ago/2` and `from_now/2` are banned
  project-wide and a Credo check enforces it.

  `visible_between/2` is the one to read first. There is no visibility table, no
  materialised pair list and no job: the same call at a later instant returns a
  different set because the instant moved. R13's thirty-day tail is arithmetic
  on the engagements that already exist.

  ## The visibility predicate, spelled out

  Two people are visible to each other at a venue over

      [ max(their two starts_at), min(their two ends_at) + 30 days )

  and the predicate below is that interval containing `instant`, written as four
  comparisons rather than as `GREATEST`/`LEAST`:

    * `max(a1, a2) <= t` is `a1 <= t AND a2 <= t`
    * `min(b1, b2) + 30d > t` is `b1 > t - 30d AND b2 > t - 30d`

  which keeps it in plain Ecto with no fragment and puts the thirty days in one
  Elixir function, `HospitalityComs.Peers.Visibility.cutoff/1`, that the
  rendered struct calls too.

  On top of that the two terms have to overlap at all, which is
  `HospitalityComs.Rooms.Records.overlapping_open_interval/1`'s rule with the
  column names changed:

    * `a1 < b2 AND a2 < b1` — each starts before the other ends
    * `a1 < b1 AND a2 < b2` — **neither is empty**

  The emptiness clauses are not decoration. `HospitalityComs.Engagements
  .end_engagement/2` can produce `ends_at == starts_at` — the empty range, which
  is active at no instant and overlaps nothing — for an engagement ended before
  its term opened. Without those two clauses the endpoint form reports an
  overlap for it, exactly as U6 measured on roster entries.

  ## The pair's state is one row, and the index says so

  `current_request/1` reads the row a pair's whole state hangs off:
  `superseded_at IS NULL`, of which a partial unique index permits exactly one.
  Everything `HospitalityComs.Peers` refuses — already requested, already
  connected, blocked — is read off that single row rather than off an ordering
  over the pair's history. `*_create_peer_graph.exs` says why the ordering was
  not safe.

  ## Which side these are asked from

  All of them, from the person's side, through `HospitalityComs.Repo`. There is
  no employer-scoped read here and there will not be one: every table this
  module names is person zone, so an employer-scoped query composing any of it
  raises `HospitalityComs.EmployerRepo.ZoneViolationError` before Postgres is
  asked, and Postgres would refuse it for want of privilege if the backstop were
  removed. `visible_peers/2` joins `engagements` and `venues`, which an employer
  session may read — and it is reached only from a `PersonScope`, because what
  it answers is "where else does this person's colleague work", which is the
  disclosure U9 governs.
  """

  import Ecto.Query

  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Peers.Connection
  alias HospitalityComs.Peers.ConnectionRequest
  alias HospitalityComs.Peers.PeerMessage
  alias HospitalityComs.Peers.Visibility
  alias HospitalityComs.Venues.Venue

  ## Visibility

  @doc """
  Pairs of engagements at one venue whose visibility interval contains
  `instant`.

  The base every visibility question composes from, with both bindings named:
  `:own` is the asking person's engagement and `:peer` is the counterpart's. See
  the moduledoc for the four comparisons and why they are written out rather
  than as `GREATEST`/`LEAST`.
  """
  @spec co_engagements(DateTime.t()) :: Ecto.Query.t()
  def co_engagements(%DateTime{} = instant) do
    cutoff = Visibility.cutoff(instant)

    from own in Engagement,
      as: :own,
      join: peer in Engagement,
      on: peer.venue_id == own.venue_id and peer.person_id != own.person_id,
      as: :peer,
      # Neither term is empty. An engagement ended before it started is the
      # empty range, and an empty interval overlaps nothing.
      where: own.starts_at < own.ends_at,
      where: peer.starts_at < peer.ends_at,
      # The terms overlap: each starts before the other ends.
      where: own.starts_at < peer.ends_at,
      where: peer.starts_at < own.ends_at,
      # `max(starts) <= instant` — they have both begun.
      where: own.starts_at <= ^instant,
      where: peer.starts_at <= ^instant,
      # `min(ends) + 30 days > instant` — the tail has not run out.
      where: own.ends_at > ^cutoff,
      where: peer.ends_at > ^cutoff
  end

  @doc """
  The visibility one person holds at `instant`, as endpoints to render.

  One row per overlapping pair of engagements, so two separate stints at one
  venue are two rows and are not merged — the union of two intervals is not an
  interval, and merging them would make a gap disappear.

  Ordered by venue name with the counterpart's id and the interval's start
  breaking ties, because a venue's name is what a client renders and `id` is
  random on a `binary_id` schema.

  **Selects a field list rather than the structs**, which is the note
  `HospitalityComs.Rooms.list_venue_room_members/2` and
  `HospitalityComs.Engagements.Records.outstanding_invitations/2` both carry.
  What comes back about the counterpart is their `person_id`, the venue they
  share, and the employer-authored `role_label` on their engagement — all three
  of which the viewer can already read off the venue room's roll. No email
  address: it is the only other identifying column `people` has.
  """
  @spec visible_peers(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def visible_peers(person_id, %DateTime{} = instant) when is_binary(person_id) do
    from [own: own, peer: peer] in co_engagements(instant),
      join: venue in Venue,
      on: venue.id == own.venue_id,
      where: own.person_id == ^person_id,
      order_by: [asc: venue.name, asc: peer.person_id, asc: peer.starts_at, asc: peer.id],
      select: %{
        person_id: peer.person_id,
        venue_id: venue.id,
        venue_name: venue.name,
        role_label: peer.role_label,
        own_starts_at: own.starts_at,
        own_ends_at: own.ends_at,
        peer_starts_at: peer.starts_at,
        peer_ends_at: peer.ends_at
      }
  end

  @doc """
  The people this person can see at `instant`, as ids.

  What `HospitalityComs.Peers.list_outgoing_requests/1` decides `:lapsed`
  against. Loading the set once and comparing in Elixir is what keeps a list of
  requests two queries rather than one per row.
  """
  @spec visible_person_ids(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def visible_person_ids(person_id, %DateTime{} = instant) when is_binary(person_id) do
    from [own: own, peer: peer] in co_engagements(instant),
      where: own.person_id == ^person_id,
      distinct: true,
      select: peer.person_id
  end

  @doc """
  Whether two named people are visible to each other at `instant`, anywhere.

  `HospitalityComs.Peers.request_connection/2` is the caller, and the answer is
  the same one `visible_peers/2` would give — one query rather than a filter
  over the other, because a request needs a yes or no and not a list.
  """
  @spec visible_between(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def visible_between(person_id, other_person_id, %DateTime{} = instant)
      when is_binary(person_id) and is_binary(other_person_id) do
    from [own: own, peer: peer] in co_engagements(instant),
      where: own.person_id == ^person_id,
      where: peer.person_id == ^other_person_id
  end

  @doc """
  The venues at which two named people are visible to each other at `instant`,
  as ids.

  `visible_between/3` projected onto the venue the pair share, and the caller is
  outside this context: `HospitalityComs.Profiles.Records` binds a peer to the
  concurrency rule of every venue that is *why* they can see this worker at all,
  and that is this relation rather than a second spelling of it.

  It is here rather than at the call site because the visibility interval —
  R13's thirty-day tail included — is written once, in `co_engagements/1`. A
  profile query that restated the overlap would be a third definition of who can
  see whom, beside this one and the employer view's, and the two that already
  exist are as many as the rule can survive.

  `distinct`, because the answer is a set of venues: a pair with two overlapping
  stints at one place are co-rostered there once.
  """
  @spec visible_venue_ids(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def visible_venue_ids(person_id, other_person_id, %DateTime{} = instant)
      when is_binary(person_id) and is_binary(other_person_id) do
    from [own: own] in visible_between(person_id, other_person_id, instant),
      distinct: true,
      select: own.venue_id
  end

  ## Requests

  @doc """
  The pair's current request, if it has one.

  `superseded_at IS NULL`, of which the partial unique index
  `connection_requests_one_current_per_pair` permits exactly one. The pair is
  matched on the generated `pair_low_id`/`pair_high_id` columns, so the order the
  two ids arrive in changes nothing.
  """
  @spec current_request(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def current_request(person_id, other_person_id)
      when is_binary(person_id) and is_binary(other_person_id) do
    {low, high} = pair(person_id, other_person_id)

    from request in ConnectionRequest,
      where: request.pair_low_id == ^low,
      where: request.pair_high_id == ^high,
      where: is_nil(request.superseded_at)
  end

  @doc """
  The pair's current request, superseded in the same statement that reads it.

  `HospitalityComs.Peers.request_connection/2` composes `update_all` over this
  and decides from what `RETURNING` hands back, which is one statement rather
  than a read followed by a write.

  **That is not a tidiness preference, it is KTD19.** Under `READ COMMITTED` a
  `SELECT … FOR UPDATE` that parks on a row another transaction is superseding
  re-evaluates *that row* when the lock is released and finds it no longer
  current — but the replacement row the other transaction inserted was not in
  the statement's snapshot, so the read answers "this pair has nothing current"
  while a following `update_all`, taking a snapshot of its own, sees the
  replacement and supersedes it. A blocked party's request landed that way: the
  decision was made from one snapshot and the write from another.

  Read and write in one statement removes the second snapshot. Whatever is
  invisible to the decision is equally invisible to the supersede, so the
  partial unique index `connection_requests_one_current_per_pair` refuses the
  insert that follows rather than a superseded predecessor letting it through.
  `HospitalityComs.PeersConcurrencyTest` races exactly that interleaving.
  """
  @spec supersede_current_request(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def supersede_current_request(person_id, other_person_id) do
    person_id |> current_request(other_person_id) |> select([request], request)
  end

  @doc """
  One outstanding request addressed to `person_id`, by id.

  Outstanding means unanswered and not superseded. Answering a request that has
  already been answered matches nothing, which is what makes accepting twice a
  refusal rather than a second connection.
  """
  @spec answerable(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def answerable(person_id, request_id) when is_binary(person_id) and is_binary(request_id) do
    from request in ConnectionRequest,
      where: request.id == ^request_id,
      where: request.addressee_id == ^person_id,
      where: is_nil(request.accepted_at),
      where: is_nil(request.declined_at),
      where: is_nil(request.superseded_at)
  end

  @doc """
  Requests `person_id` sent that nothing has superseded, newest first.
  """
  @spec outgoing_requests(Ecto.UUID.t()) :: Ecto.Query.t()
  def outgoing_requests(person_id) when is_binary(person_id) do
    from request in ConnectionRequest,
      where: request.requester_id == ^person_id,
      where: is_nil(request.superseded_at),
      order_by: [desc: request.requested_at, asc: request.id]
  end

  @doc """
  Requests addressed to `person_id` that are still outstanding, newest first.

  Narrower than `outgoing_requests/1` on purpose: what an addressee is shown is
  what they can answer. A request they declined last month is their own history
  and is reachable through the pair, not through a list of things to do.
  """
  @spec incoming_requests(Ecto.UUID.t()) :: Ecto.Query.t()
  def incoming_requests(person_id) when is_binary(person_id) do
    from request in ConnectionRequest,
      where: request.addressee_id == ^person_id,
      where: is_nil(request.accepted_at),
      where: is_nil(request.declined_at),
      where: is_nil(request.superseded_at),
      order_by: [desc: request.requested_at, asc: request.id]
  end

  @doc """
  One request `person_id` is a party to, by id, answered or not.

  A request between two other people and an id that names nothing match
  identically, so a refusal built on this enumerates nothing (AE1).

  **`superseded_at IS NULL` is part of it**, and it has to be. Without that
  clause a superseded-but-unanswered row comes back here reporting `:pending`
  while `answerable/2` — which every write goes through — matches nothing for
  the same id, so the pair's state would depend on which function asked. The
  four places that derive a state now agree about *superseded* as well as about
  *lapsed*: a row that is not the pair's current one is not a row anybody can
  read a state off.
  """
  @spec request_of(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def request_of(person_id, request_id) when is_binary(person_id) and is_binary(request_id) do
    from request in ConnectionRequest,
      where: request.id == ^request_id,
      where: request.requester_id == ^person_id or request.addressee_id == ^person_id,
      where: is_nil(request.superseded_at)
  end

  @doc """
  One request by id, with no party predicate at all.

  The one query in this module that authorises nothing, and the only caller is
  `HospitalityComs.Peers.disconnect/2` writing KTD19's block on the request its
  connection came out of — an id it read off a `peer_connections` row it had
  already established the caller is a party to. It is here rather than inline at
  that call site because "every query the peer graph asks is in this module" is
  the rule, and a query built at a call site is one the rule cannot see.
  """
  @spec request_by_id(Ecto.UUID.t()) :: Ecto.Query.t()
  def request_by_id(request_id) when is_binary(request_id) do
    from request in ConnectionRequest, where: request.id == ^request_id
  end

  @doc """
  The pair a request is between, whichever end `person_id` is.

  A projection used to ask about visibility for a request that is already
  loaded, so `state/2`'s `:lapsed` and the list reads agree about which pair
  they are talking about.
  """
  @spec pair_of(ConnectionRequest.t(), Ecto.UUID.t()) :: {Ecto.UUID.t(), Ecto.UUID.t()}
  def pair_of(%ConnectionRequest{} = request, person_id) when is_binary(person_id) do
    {person_id, ConnectionRequest.counterpart(request, person_id)}
  end

  ## Connections

  @doc """
  Connections `person_id` is a party to, newest first.

  Closed ones included. R15 leaves each party their own messages after a
  disconnect, and a list that dropped closed conversations would leave those
  messages with nothing to reach them by.
  """
  @spec connections_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def connections_of(person_id) when is_binary(person_id) do
    from connection in party_to(Connection, person_id),
      order_by: [desc: connection.connected_at, asc: connection.id]
  end

  @doc """
  Connections one of whose two people is `person_id`.

  The party predicate on its own, unordered, because
  `HospitalityComs.Peers.disconnect/2` composes it into an `update_all` and Ecto
  permits only `with_cte`, `where` and `join` there — an ordering inherited from
  a list query raises `Ecto.QueryError` from inside the transaction. Written
  once here so the two callers cannot disagree about what "a party to it" means.
  """
  @spec party_to(Ecto.Queryable.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def party_to(queryable, person_id) when is_binary(person_id) do
    from connection in queryable,
      where: connection.person_a_id == ^person_id or connection.person_b_id == ^person_id
  end

  @doc """
  One connection `person_id` is a party to, by id.

  A connection they are not a party to and an id that names nothing match
  identically, so a refusal built on this enumerates nothing (AE1).
  """
  @spec connection_of(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def connection_of(person_id, connection_id)
      when is_binary(person_id) and is_binary(connection_id) do
    Connection |> party_to(person_id) |> where([c], c.id == ^connection_id)
  end

  @doc """
  One **open** connection `person_id` is a party to, taken under `FOR SHARE`.

  What `HospitalityComs.Peers.send_message/3` resolves the conversation with
  before it writes, and the lock mode is the whole of it. `FOR SHARE` conflicts
  with the `FOR NO KEY UPDATE` an ordinary `UPDATE` takes, so a send that
  arrives while the other party's disconnect is in flight parks until that
  disconnect commits — and then re-evaluates the row it was waiting on, finds
  `disconnected_at` set, and matches nothing.

  Several sends may hold it at once, which is what makes `FOR SHARE` the right
  mode rather than `FOR UPDATE`: two people typing at each other are not in
  conflict, and only the disconnect is.

  Matching nothing here means "closed", never "not yours" — the caller has
  already resolved the connection through `connection_of/2` without a lock, so
  the two refusals stay distinguishable and `:not_found` keeps meaning what it
  means everywhere else in this module.
  """
  @spec locked_open_connection_of(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def locked_open_connection_of(person_id, connection_id)
      when is_binary(person_id) and is_binary(connection_id) do
    person_id
    |> connection_of(connection_id)
    |> where([connection], is_nil(connection.disconnected_at))
    |> lock("FOR SHARE")
  end

  @doc """
  Every connection the pair has ever had, live or closed.

  The pair matched canonically, so the order the two ids arrive in changes
  nothing. `HospitalityComs.PeersConcurrencyTest` is the caller — "resolve to
  one connection, not two" is a claim about this count — and it is here rather
  than in the test because the canonical pair is spelled once in this module.
  """
  @spec connection_between(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def connection_between(person_id, other_person_id)
      when is_binary(person_id) and is_binary(other_person_id) do
    {low, high} = pair(person_id, other_person_id)

    from connection in Connection,
      where: connection.person_a_id == ^low,
      where: connection.person_b_id == ^high
  end

  @doc """
  The pair's live connection, if they have one.

  What `request_connection/2` asks before it lets an approach through, and the
  friendly half of the partial unique index that makes one live connection the
  most a pair can hold.
  """
  @spec live_connection(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def live_connection(person_id, other_person_id)
      when is_binary(person_id) and is_binary(other_person_id) do
    from connection in connection_between(person_id, other_person_id),
      where: is_nil(connection.disconnected_at)
  end

  ## Messages

  @doc """
  A conversation's messages, oldest first.

  Unfiltered by instant: a peer conversation has no window and no grace, and it
  stays readable after it closes.
  """
  @spec messages_of(Ecto.UUID.t()) :: Ecto.Query.t()
  def messages_of(connection_id) when is_binary(connection_id) do
    from message in PeerMessage,
      where: message.connection_id == ^connection_id,
      order_by: [asc: message.sent_at, asc: message.id]
  end

  @doc """
  The messages `author_id` wrote in a conversation, oldest first.

  What a disconnected party reads. R15 leaves each of them their own words and
  not the other's — the disconnecting party has no claim over what the other
  person said, and the other person has no claim to keep reading a conversation
  that has been closed. KTD15c's reasoning, applied one table over.
  """
  @spec own_messages_of(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def own_messages_of(connection_id, author_id)
      when is_binary(connection_id) and is_binary(author_id) do
    connection_id |> messages_of() |> where([m], m.author_id == ^author_id)
  end

  ## The canonical pair

  # The same ordering `peer_connections` carries as a check constraint and
  # `connection_requests` generates. Written once here so that every lookup
  # spells the pair the way the indexes do.
  @spec pair(Ecto.UUID.t(), Ecto.UUID.t()) :: {Ecto.UUID.t(), Ecto.UUID.t()}
  defp pair(left, right) when left < right, do: {left, right}
  defp pair(left, right), do: {right, left}
end
