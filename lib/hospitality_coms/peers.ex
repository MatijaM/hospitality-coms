defmodule HospitalityComs.Peers do
  @moduledoc """
  The one relationship in this product that belongs to the workers and to
  nobody else.

  Two people who worked at the same venue at the same time can see each other
  for thirty days past the end of the first of their two engagements. Either may
  ask the other to connect; the other may accept, decline, or leave it. A
  connection made that way is **permanent** — it outlives the visibility that
  produced it and every engagement either of them holds — until one of them
  ends it, which either may do alone.

  ## The employer is absent, and the absence is the unit

  R6 is the requirement the whole product exists for: an employer-scoped session
  cannot resolve a peer conversation through any transport, query, or
  subscription path. Five things hold it, and they are not five spellings of one
  thing:

    * **The grants.** `connection_requests`, `peer_connections` and
      `peer_messages` are classified `:person` in `HospitalityComs.Zones`, and
      `employer_role` holds no privilege on any of them. That is the only tier
      whose violation is an error rather than a leak (KTD1).
    * **The query backstop.** An employer-scoped query reaching one of the three
      raises `HospitalityComs.EmployerRepo.ZoneViolationError` naming the table,
      before Postgres is asked.
    * **The schema.** None of the three carries a `venue_id`. There is no filter
      an employer session could add that would make such a query mean anything —
      which is the Problem Frame's inversion of ordinary multi-tenancy, stated
      as a table.
    * **The transport.** `HospitalityComsWeb.EmployerSocket` routes no `"peer"`
      topic, so a join is refused in Phoenix's dispatch with no application code
      running (KTD9).
    * **This module.** Every function heads on a
      `HospitalityComs.Accounts.PersonScope`, so an employer scope is a
      `FunctionClauseError` before the body runs.

  Everything here runs through `HospitalityComs.Repo` as the application's own
  role. There is no `EmployerRepo` call in this file and there will not be one.

  ## Visibility is derived, and it is the only thing gating discovery

  `HospitalityComs.Peers.Visibility` holds the interval and the argument for it.
  What matters at this level is the division of labour: **visibility gates
  discovery and requests, and gates nothing about a conversation that already
  exists.** A connection survives both engagements ending, and both parties keep
  writing to it — that is R13's "permanent" and it is what makes the plan's
  payoff moment (a person holding zero engagements whose account still works)
  reachable at all.

  ## The request state machine is one row

  A pair has at most one *current* `connection_requests` row — a partial unique
  index guarantees it — and that row carries the whole state. Who may approach
  next is read off it:

  | Current row | Who may initiate |
  |---|---|
  | none | either |
  | outstanding | neither; one is already in flight |
  | declined | anyone who is not its `blocked_initiator_id`, which is the requester |
  | accepted, connection live | neither; they are connected |
  | accepted, connection closed | anyone who is not its `blocked_initiator_id`, which is the counterpart of whoever disconnected |

  ## KTD19, in one sentence and its consequence

  **The party who refused keeps the initiative; the party who was refused does
  not.** A decline blocks the requester. A disconnect blocks the counterpart of
  whoever disconnected — because disconnection is the origin document's only
  stated remedy for harm in a peer conversation, and a symmetric reading would
  hand that remedy straight back to the person it was used against.

  The block is a column on the request row rather than a rule over engagements,
  and that is the whole of "it survives new co-rostering": a block derived from
  employment would evaporate the moment the pair worked together again.

  "Without fresh acceptance" read forwards: the blocked party cannot *initiate*,
  and is connectable again the moment the other party asks and they accept. At
  that point a new current row exists and the old block is not consulted again.

  ## `:lapsed` is derived, which means it can un-lapse

  A pending request whose pair cannot see each other **at the asking instant**
  reports `:lapsed`, and accepting it is refused. Nothing stores that: the same
  clock advance that lapses the visibility lapses the request, in the same
  query, with no sweeper and no column.

  The consequence is worth stating rather than discovering. If the pair is
  co-rostered again, the same row reports `:pending` again and can be answered.
  Nothing was destroyed and nothing has to be un-destroyed, which is exactly
  what a stored `expired_at` would have made impossible — it would have needed a
  job that visited every outstanding request whenever any engagement moved, and
  that job is the design KTD6b rejects at membership scale. An addressee can
  decline a lapsed request at any time, so a requester is never left holding a
  row nobody can clear.

  ## Refusals enumerate nothing

  `:not_visible` covers a person who is not co-rostered with the caller, an id
  that names nobody, and the caller themselves, identically. `:not_found` covers
  a request or a connection that does not exist and one the caller is not a
  party to, identically. That is AE1's not-found-rather-than-forbidden rule
  applied at the one surface where the caller supplies the id.

  What is *not* hidden is the caller's own history: `:blocked`,
  `:already_requested` and `:already_connected` are all statements about
  something the caller was party to.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Peers.Connection
  alias HospitalityComs.Peers.ConnectionRequest
  alias HospitalityComs.Peers.Conversation
  alias HospitalityComs.Peers.PeerMessage
  alias HospitalityComs.Peers.Records
  alias HospitalityComs.Peers.Visibility
  alias HospitalityComs.PubSub
  alias HospitalityComs.Repo

  @typedoc """
  Why an approach was refused, by `Ecto.Multi` step name.

  The shape `HospitalityComs.Engagements.claim_invitation/2` uses, for the same
  reason: the steps fail for unrelated reasons and collapsing them would lose
  which one. `:visible` is the only refusal that discloses nothing; the other
  three are all statements about something the caller was party to.
  """
  @type request_failure() ::
          {:error, :visible, :not_visible, map()}
          | {:error, :permitted, :already_requested | :already_connected | :blocked, map()}
          | {:error, :request, Ecto.Changeset.t(ConnectionRequest.t()), map()}

  @typedoc """
  Why an acceptance was refused, by step name.

  `:not_found` covers a request that does not exist, one addressed to somebody
  else, one the caller sent themselves, and one that has already been answered.
  `:lapsed` is the derived state — the pair cannot see each other at this
  instant — and it is the one refusal here that can stop being true without
  anything being written.
  """
  @type acceptance_failure() ::
          {:error, :answer, :not_found, map()}
          | {:error, :visible, :lapsed, map()}
          | {:error, :connect, Ecto.Changeset.t(Connection.t()), map()}

  @typedoc """
  Why a disconnect was refused, by step name.
  """
  @type disconnect_failure() ::
          {:error, :close, :not_found | :already_disconnected, map()}

  ## Visibility

  @doc """
  Every counterpart this person can see at their scope's instant, with the venue
  they share and the interval it runs over.

  One entry per overlapping pair of engagements, so two separate stints at one
  venue are two entries and are not merged. Ordered by venue name, then by the
  counterpart, then by when the interval opened.

  Nothing is stored. Advancing the clock past `visible_until` removes an entry
  with no job having run, which is this unit's verification condition.

  Refuses an employer scope and an anonymous person scope by function clause.
  """
  @spec list_visible_peers(PersonScope.t()) :: [Visibility.t()]
  def list_visible_peers(%PersonScope{person: %Person{id: person_id}, now: now})
      when is_binary(person_id) do
    person_id
    |> Records.visible_peers(now)
    |> Repo.all()
    |> Enum.map(&Visibility.new/1)
  end

  @doc """
  Whether this person and another can see each other at the scope's instant.

  False for an id that names nobody and false for the caller's own id — a person
  is never co-rostered with themselves — so the answer discloses nothing about
  which ids are real.
  """
  @spec visible?(PersonScope.t(), Ecto.UUID.t()) :: boolean()
  def visible?(%PersonScope{person: %Person{id: person_id}, now: now}, other_person_id)
      when is_binary(person_id) and is_binary(other_person_id) do
    person_id |> Records.visible_between(other_person_id, now) |> Repo.exists?()
  end

  ## Requests

  @doc """
  Asks another person to connect.

  Four steps, and the first two are refusals rather than writes:

    1. `:visible` — the pair can see each other at this instant. An id that
       names nobody, a person who is not co-rostered, and the caller themselves
       all fail here identically (AE1).
    2. `:permitted` — the pair's current request row, taken under `FOR UPDATE`,
       does not stop this approach. See the module's table.
    3. `:supersede` — the previous current row stops being current, so the pair
       has exactly one again.
    4. `:request` — the row, with the partial unique index underneath it as the
       half that is safe when two people ask at once.

  The lock in step 2 is what makes step 3 mean something: without it two
  requesters both read the same declined row, both supersede it, and both
  insert — which the index refuses anyway, but with a constraint error where a
  considered refusal was available.
  """
  @spec request_connection(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, ConnectionRequest.t()} | request_failure()
  def request_connection(%PersonScope{person: %Person{id: person_id}, now: now}, addressee_id)
      when is_binary(person_id) and is_binary(addressee_id) do
    Multi.new()
    |> Multi.run(:visible, fn repo, _changes ->
      co_rostered(repo, person_id, addressee_id, now)
    end)
    |> Multi.run(:permitted, fn repo, _changes ->
      may_initiate(repo, person_id, addressee_id)
    end)
    |> Multi.run(:supersede, fn repo, _changes ->
      supersede_current(repo, person_id, addressee_id, now)
    end)
    # `mode: :savepoint` explicit, because `ecto_sql` opens a savepoint only
    # when asked. The unique-index violation this can meet is turned into a
    # changeset error, and without a savepoint the surrounding transaction is
    # left aborted — invisible today only because nothing follows this step, and
    # a landmine for the step somebody adds after it.
    |> Multi.insert(:request, ConnectionRequest.open_changeset(person_id, addressee_id, now),
      mode: :savepoint
    )
    |> Repo.transaction()
    |> requested()
  end

  @spec co_rostered(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, :co_rostered} | {:error, :not_visible}
  defp co_rostered(repo, person_id, addressee_id, now) do
    person_id
    |> Records.visible_between(addressee_id, now)
    |> repo.exists?()
    |> visible_or_refuse()
  end

  @spec visible_or_refuse(boolean()) :: {:ok, :co_rostered} | {:error, :not_visible}
  defp visible_or_refuse(true), do: {:ok, :co_rostered}
  defp visible_or_refuse(false), do: {:error, :not_visible}

  # The pair's current row and whether they are connected right now, decided
  # together because the two answers are one question about one pair.
  @spec may_initiate(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, :may_initiate}
          | {:error, :already_requested | :already_connected | :blocked}
  defp may_initiate(repo, person_id, addressee_id) do
    current = person_id |> Records.locked_current_request(addressee_id) |> repo.one()
    connected? = person_id |> Records.live_connection(addressee_id) |> repo.exists?()

    permitted(current, connected?, person_id)
  end

  @spec permitted(ConnectionRequest.t() | nil, boolean(), Ecto.UUID.t()) ::
          {:ok, :may_initiate}
          | {:error, :already_requested | :already_connected | :blocked}
  defp permitted(_current, true, _person_id), do: {:error, :already_connected}
  defp permitted(nil, false, _person_id), do: {:ok, :may_initiate}

  defp permitted(%ConnectionRequest{blocked_initiator_id: person_id}, false, person_id) do
    {:error, :blocked}
  end

  defp permitted(%ConnectionRequest{} = current, false, _person_id) do
    current |> ConnectionRequest.outstanding?() |> outstanding_or_permitted()
  end

  @spec outstanding_or_permitted(boolean()) ::
          {:ok, :may_initiate} | {:error, :already_requested}
  defp outstanding_or_permitted(true), do: {:error, :already_requested}
  defp outstanding_or_permitted(false), do: {:ok, :may_initiate}

  # The previous current row, if there is one, stops being current. Its outcome
  # and its block are left exactly as they were: the row is the pair's history
  # and this only says it is no longer the pair's present.
  @spec supersede_current(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, non_neg_integer()}
  defp supersede_current(repo, person_id, addressee_id, now) do
    stamped_at = DateTime.truncate(now, :second)

    {superseded, _rows} =
      person_id
      |> Records.current_request(addressee_id)
      |> repo.update_all(set: [superseded_at: stamped_at, updated_at: stamped_at])

    {:ok, superseded}
  end

  @spec requested({:ok, map()} | request_failure()) ::
          {:ok, ConnectionRequest.t()} | request_failure()
  defp requested({:ok, %{request: %ConnectionRequest{} = request}}) do
    announce(
      [request.requester_id, request.addressee_id],
      {:peer_request,
       %{
         request_id: request.id,
         requester_id: request.requester_id,
         addressee_id: request.addressee_id,
         at: request.requested_at
       }}
    )

    {:ok, %{request | state: :pending}}
  end

  defp requested({:error, _step, _reason, _changes} = failure), do: failure

  @doc """
  Accepts a request addressed to this person, creating the connection.

  `:answer` is the race-safe half: one conditional `UPDATE` decides that the
  request is still answerable and answers it, so two concurrent accepts cannot
  both proceed and the loser gets `:not_found` — which is the same answer a
  request addressed to somebody else gets, and the same answer an id naming
  nothing gets.

  `:visible` refuses a **lapsed** request. The pair has to be able to see each
  other at this instant for a connection to be made between them; deciding it
  after the answer rather than before costs nothing, because a failure rolls the
  answer back with it and the request is outstanding again.
  """
  @spec accept_request(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, Connection.t()} | acceptance_failure()
  def accept_request(%PersonScope{person: %Person{id: person_id}, now: now}, request_id)
      when is_binary(person_id) and is_binary(request_id) do
    Multi.new()
    |> Multi.run(:answer, fn repo, _changes -> answer(repo, person_id, request_id, now) end)
    |> Multi.run(:visible, fn repo, changes -> still_visible(repo, changes, person_id, now) end)
    |> Multi.insert(:connect, &connection(&1, now), mode: :savepoint)
    |> Repo.transaction()
    |> accepted(person_id)
  end

  @spec answer(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, ConnectionRequest.t()} | {:error, :not_found}
  defp answer(repo, person_id, request_id, now) do
    stamped_at = DateTime.truncate(now, :second)

    person_id
    |> Records.answerable(request_id)
    |> select([request], request)
    |> repo.update_all(set: [accepted_at: stamped_at, updated_at: stamped_at])
    |> answered()
  end

  @spec answered({non_neg_integer(), [ConnectionRequest.t()] | nil}) ::
          {:ok, ConnectionRequest.t()} | {:error, :not_found}
  defp answered({1, [%ConnectionRequest{} = request]}), do: {:ok, request}
  defp answered({0, _rows}), do: {:error, :not_found}

  @spec still_visible(Ecto.Repo.t(), map(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, :co_rostered} | {:error, :lapsed}
  defp still_visible(repo, %{answer: %ConnectionRequest{} = request}, person_id, now) do
    {own, other} = Records.pair_of(request, person_id)

    own
    |> Records.visible_between(other, now)
    |> repo.exists?()
    |> unlapsed()
  end

  @spec unlapsed(boolean()) :: {:ok, :co_rostered} | {:error, :lapsed}
  defp unlapsed(true), do: {:ok, :co_rostered}
  defp unlapsed(false), do: {:error, :lapsed}

  @spec connection(map(), DateTime.t()) :: Ecto.Changeset.t(Connection.t())
  defp connection(%{answer: %ConnectionRequest{} = request}, now) do
    Connection.open_changeset(request, now)
  end

  @spec accepted({:ok, map()} | acceptance_failure(), Ecto.UUID.t()) ::
          {:ok, Connection.t()} | acceptance_failure()
  defp accepted({:ok, %{connect: %Connection{} = connection}}, _person_id) do
    announce(
      Connection.parties(connection),
      {:peer_connected,
       %{
         connection_id: connection.id,
         request_id: connection.request_id,
         person_a_id: connection.person_a_id,
         person_b_id: connection.person_b_id,
         at: connection.connected_at
       }}
    )

    {:ok, connection}
  end

  defp accepted({:error, _step, _reason, _changes} = failure, _person_id), do: failure

  @doc """
  Declines a request addressed to this person, and blocks its requester.

  KTD19's decline half: the requester may not approach again, and the decliner
  may approach whenever they like. A check constraint on the table keeps that
  from being a sentence — a declined row whose block names anybody but its
  requester is refused by Postgres.

  Deliberately **not** gated on visibility. An addressee may always say no, and
  refusing to record a decline because the pair has stopped being co-rostered
  would leave the requester holding an outstanding row that nobody could clear.

  One conditional `UPDATE`, so declining twice, declining a request addressed to
  somebody else, declining one this person sent, and declining an id that names
  nothing are all `:not_found`.
  """
  @spec decline_request(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, ConnectionRequest.t()} | {:error, :not_found}
  def decline_request(%PersonScope{person: %Person{id: person_id}, now: now}, request_id)
      when is_binary(person_id) and is_binary(request_id) do
    stamped_at = DateTime.truncate(now, :second)

    person_id
    |> Records.answerable(request_id)
    |> select([request], request)
    # `blocked_initiator_id` is set from the row's own `requester_id` rather
    # than from a value this function carries, so KTD19's decline half is one
    # statement with nothing to read first — and it is the same column the check
    # constraint `connection_requests_decline_blocks_requester` compares against.
    |> update([request],
      set: [
        declined_at: ^stamped_at,
        updated_at: ^stamped_at,
        blocked_initiator_id: request.requester_id
      ]
    )
    |> Repo.update_all([])
    |> answered()
    |> declined()
  end

  @spec declined({:ok, ConnectionRequest.t()} | {:error, :not_found}) ::
          {:ok, ConnectionRequest.t()} | {:error, :not_found}
  defp declined({:ok, %ConnectionRequest{} = request}) do
    announce(
      [request.requester_id, request.addressee_id],
      {:peer_request_declined,
       %{
         request_id: request.id,
         requester_id: request.requester_id,
         addressee_id: request.addressee_id,
         at: request.declined_at
       }}
    )

    {:ok, %{request | state: :declined}}
  end

  defp declined({:error, :not_found} = failure), do: failure

  @doc """
  Requests this person sent that nothing has superseded, newest first, each
  carrying its derived state.

  Two queries rather than one per row: the counterparts this person can see
  right now are loaded once and the states are decided against that set. A
  request whose pair has stopped being visible reports `:lapsed`, which is what
  tells the requester their approach has expired without anything having been
  written.
  """
  @spec list_outgoing_requests(PersonScope.t()) :: [ConnectionRequest.t()]
  def list_outgoing_requests(%PersonScope{person: %Person{id: person_id}, now: now})
      when is_binary(person_id) do
    person_id
    |> Records.outgoing_requests()
    |> Repo.all()
    |> with_states(person_id, now)
  end

  @doc """
  Requests addressed to this person that are still outstanding, newest first.

  Narrower than `list_outgoing_requests/1`, and deliberately: what an addressee
  is shown is what they can answer. One they declined last month is their own
  history rather than something to do.
  """
  @spec list_incoming_requests(PersonScope.t()) :: [ConnectionRequest.t()]
  def list_incoming_requests(%PersonScope{person: %Person{id: person_id}, now: now})
      when is_binary(person_id) do
    person_id
    |> Records.incoming_requests()
    |> Repo.all()
    |> with_states(person_id, now)
  end

  @spec with_states([ConnectionRequest.t()], Ecto.UUID.t(), DateTime.t()) ::
          [ConnectionRequest.t()]
  defp with_states([], _person_id, _now), do: []

  defp with_states(requests, person_id, now) do
    visible = person_id |> Records.visible_person_ids(now) |> Repo.all() |> MapSet.new()

    Enum.map(requests, fn request ->
      ConnectionRequest.with_state(
        request,
        MapSet.member?(visible, ConnectionRequest.counterpart(request, person_id))
      )
    end)
  end

  @doc """
  One request this person is a party to, by id, with its derived state.

  `:not_found` for a request between two other people and for an id that names
  nothing, identically.
  """
  @spec fetch_request(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, ConnectionRequest.t()} | {:error, :not_found}
  def fetch_request(%PersonScope{person: %Person{id: person_id}, now: now}, request_id)
      when is_binary(person_id) and is_binary(request_id) do
    person_id
    |> Records.request_of(request_id)
    |> Repo.one()
    |> found_request()
    |> stated(person_id, now)
  end

  @spec found_request(ConnectionRequest.t() | nil) ::
          {:ok, ConnectionRequest.t()} | {:error, :not_found}
  defp found_request(nil), do: {:error, :not_found}
  defp found_request(%ConnectionRequest{} = request), do: {:ok, request}

  @spec stated({:ok, ConnectionRequest.t()} | {:error, :not_found}, Ecto.UUID.t(), DateTime.t()) ::
          {:ok, ConnectionRequest.t()} | {:error, :not_found}
  defp stated({:error, :not_found} = failure, _person_id, _now), do: failure

  defp stated({:ok, %ConnectionRequest{} = request}, person_id, now) do
    {own, other} = Records.pair_of(request, person_id)
    visible? = own |> Records.visible_between(other, now) |> Repo.exists?()

    {:ok, ConnectionRequest.with_state(request, visible?)}
  end

  ## Conversations

  @doc """
  Every conversation this person is a party to, newest first.

  Closed ones included. A disconnect leaves each party their own messages, and a
  list that dropped closed conversations would leave those messages with nothing
  to reach them by.
  """
  @spec list_conversations(PersonScope.t()) :: [Conversation.t()]
  def list_conversations(%PersonScope{person: %Person{id: person_id}})
      when is_binary(person_id) do
    person_id
    |> Records.connections_of()
    |> Repo.all()
    |> Enum.map(&Conversation.of_connection(&1, person_id))
  end

  @doc """
  One conversation, seen from this person's side.

  `:not_found` for a connection between two other people and for an id that
  names nothing, identically (AE1).
  """
  @spec fetch_conversation(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, Conversation.t()} | {:error, :not_found}
  def fetch_conversation(%PersonScope{} = scope, connection_id)
      when is_binary(connection_id) do
    with {:ok, connection} <- fetch_connection(scope, connection_id) do
      {:ok, Conversation.of_connection(connection, scope.person.id)}
    end
  end

  @doc """
  A conversation's messages, oldest first.

  While it is open, both parties read the whole of it. Once it has been
  disconnected, **each party reads their own messages and only their own** — the
  disconnecting party has no claim over what the other person said, and the
  other person has no claim to keep reading a conversation that has been closed.
  Nothing is deleted to achieve that; deletion is `HospitalityComs.Lifecycle`'s
  alone (KTD21).

  Not gated on visibility. A conversation outlives the co-rostering that
  produced it.
  """
  @spec list_messages(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, [PeerMessage.t()]} | {:error, :not_found}
  def list_messages(%PersonScope{} = scope, connection_id) when is_binary(connection_id) do
    with {:ok, connection} <- fetch_connection(scope, connection_id) do
      {:ok, connection |> readable_messages(scope.person.id) |> Repo.all()}
    end
  end

  @spec readable_messages(Connection.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  defp readable_messages(%Connection{disconnected_at: nil, id: id}, _person_id) do
    Records.messages_of(id)
  end

  defp readable_messages(%Connection{id: id}, person_id) do
    Records.own_messages_of(id, person_id)
  end

  @doc """
  Sends a message to an open conversation.

  Refused with `:not_found` for a connection this person is not a party to and
  for an id that names nothing, and with `:disconnected` once it has been
  closed — which is a statement about a conversation the caller was in, so it
  discloses nothing they did not already have.

  Not gated on visibility or on any engagement: a connection is permanent, and a
  person holding no engagements at all can still talk to the people they
  connected with.
  """
  @spec send_message(PersonScope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, PeerMessage.t()}
          | {:error, :not_found | :disconnected | Ecto.Changeset.t(PeerMessage.t())}
  def send_message(%PersonScope{} = scope, connection_id, body)
      when is_binary(connection_id) and is_binary(body) do
    with {:ok, connection} <- fetch_connection(scope, connection_id),
         {:ok, open} <- still_open(connection) do
      open
      |> PeerMessage.sent_changeset(scope.person.id, body, scope.now)
      |> Repo.insert()
      |> sent(open)
    end
  end

  @spec still_open(Connection.t()) :: {:ok, Connection.t()} | {:error, :disconnected}
  defp still_open(%Connection{disconnected_at: nil} = connection), do: {:ok, connection}
  defp still_open(%Connection{}), do: {:error, :disconnected}

  @spec sent(
          {:ok, PeerMessage.t()} | {:error, Ecto.Changeset.t(PeerMessage.t())},
          Connection.t()
        ) :: {:ok, PeerMessage.t()} | {:error, Ecto.Changeset.t(PeerMessage.t())}
  defp sent({:ok, %PeerMessage{} = message} = result, connection) do
    announce(
      Connection.parties(connection),
      {:peer_message,
       %{
         connection_id: message.connection_id,
         message_id: message.id,
         author_id: message.author_id,
         body: message.body,
         at: message.sent_at
       }}
    )

    result
  end

  defp sent({:error, %Ecto.Changeset{}} = failure, _connection), do: failure

  @doc """
  Ends a conversation, from either side.

  Unilateral by design: R15 makes a peer conversation revocable by either party,
  and the origin document has no other remedy for harm in one. The conversation
  closes for both — neither can send again — and each of them keeps their own
  messages.

  Two steps:

    1. `:close` — one conditional `UPDATE` on `disconnected_at IS NULL`, so two
       parties disconnecting at once close it once and the loser is
       `:already_disconnected`. Before this shape, both read the same open row,
       both wrote, and whichever transaction committed second decided when the
       conversation ended.
    2. `:block` — KTD19's disconnect half, written on the request the connection
       came out of: the **counterpart** of whoever disconnected may not approach
       again, and the disconnecting party may.

  `:not_found` covers a connection this person is not a party to and an id that
  names nothing, identically.
  """
  @spec disconnect(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, Connection.t()} | disconnect_failure()
  def disconnect(%PersonScope{person: %Person{id: person_id}, now: now}, connection_id)
      when is_binary(person_id) and is_binary(connection_id) do
    Multi.new()
    |> Multi.run(:close, fn repo, _changes -> close(repo, person_id, connection_id, now) end)
    |> Multi.run(:block, fn repo, changes -> block_counterpart(repo, changes, person_id, now) end)
    |> Repo.transaction()
    |> disconnected()
  end

  @spec close(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Connection.t()} | {:error, :not_found | :already_disconnected}
  defp close(repo, person_id, connection_id, now) do
    stamped_at = DateTime.truncate(now, :second)

    person_id
    |> Records.connection_of(connection_id)
    |> where([connection], is_nil(connection.disconnected_at))
    |> select([connection], connection)
    |> repo.update_all(
      set: [
        disconnected_at: stamped_at,
        disconnected_by_id: person_id,
        updated_at: stamped_at
      ]
    )
    |> closed(repo, person_id, connection_id)
  end

  @spec closed(
          {non_neg_integer(), [Connection.t()] | nil},
          Ecto.Repo.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t()
        ) :: {:ok, Connection.t()} | {:error, :not_found | :already_disconnected}
  defp closed({1, [%Connection{} = connection]}, _repo, _person_id, _connection_id) do
    {:ok, connection}
  end

  # Runs only when the conditional update matched nothing, so it cannot turn a
  # refusal into a success — the same shape `HospitalityComs.Engagements` uses
  # to tell three claim refusals apart.
  defp closed({0, _rows}, repo, person_id, connection_id) do
    person_id
    |> Records.connection_of(connection_id)
    |> repo.exists?()
    |> diagnose()
  end

  @spec diagnose(boolean()) :: {:error, :not_found | :already_disconnected}
  defp diagnose(true), do: {:error, :already_disconnected}
  defp diagnose(false), do: {:error, :not_found}

  # KTD19's disconnect half. The block goes on the request the connection came
  # out of, which is still the pair's current row — nothing supersedes it until
  # somebody asks again — so "who may initiate next" is read off one row as it
  # is everywhere else.
  @spec block_counterpart(Ecto.Repo.t(), map(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Ecto.UUID.t()}
  defp block_counterpart(repo, %{close: %Connection{} = connection}, person_id, now) do
    stamped_at = DateTime.truncate(now, :second)
    blocked = Connection.counterpart(connection, person_id)

    {1, _rows} =
      repo.update_all(
        from(request in ConnectionRequest, where: request.id == ^connection.request_id),
        set: [blocked_initiator_id: blocked, updated_at: stamped_at]
      )

    {:ok, blocked}
  end

  @spec disconnected({:ok, map()} | disconnect_failure()) ::
          {:ok, Connection.t()} | disconnect_failure()
  defp disconnected({:ok, %{close: %Connection{} = connection}}) do
    announce(
      Connection.parties(connection),
      {:peer_disconnected,
       %{
         connection_id: connection.id,
         disconnected_by_id: connection.disconnected_by_id,
         at: connection.disconnected_at
       }}
    )

    {:ok, connection}
  end

  defp disconnected({:error, _step, _reason, _changes} = failure), do: failure

  ## Reading a connection

  # The one place a connection is resolved, so "this person is a party to it"
  # is written once. A connection between two other people and an id that names
  # nothing come back the same way (AE1).
  @spec fetch_connection(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, Connection.t()} | {:error, :not_found}
  defp fetch_connection(%PersonScope{person: %Person{id: person_id}}, connection_id)
       when is_binary(person_id) do
    person_id
    |> Records.connection_of(connection_id)
    |> Repo.one()
    |> found_connection()
  end

  @spec found_connection(Connection.t() | nil) :: {:ok, Connection.t()} | {:error, :not_found}
  defp found_connection(nil), do: {:error, :not_found}
  defp found_connection(%Connection{} = connection), do: {:ok, connection}

  ## Announcements

  @doc """
  The PubSub topic one person's peer surface is announced on.

  `HospitalityComs.PubSub.topic/1`'s `{:peer, id}`, exposed here so that a test
  and a channel are looking at the same string. Naming a topic is scope-free;
  *subscribing* to one is what `HospitalityComs.PubSub.subscribe/2` pins to the
  caller's own person.
  """
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(person_id) when is_binary(person_id), do: PubSub.topic({:peer, person_id})

  # Every announcement goes to **both** parties' own topics, and a channel picks
  # what it needs out of a payload that names both. One broadcast shape rather
  # than one per recipient: a payload tailored per side would be two messages
  # that could disagree.
  #
  # **Best effort, and logged rather than propagated**, exactly as
  # `HospitalityComs.Engagements`' revocation and `HospitalityComs.Rooms`'
  # suspension nudges are. The write has committed by the time this runs;
  # failing somebody's disconnect in order to report that a socket was not told
  # would be the wrong trade, and every read re-derives from the database in any
  # case.
  #
  # `{:error, :no_such_group}` is the one failure the `:pg` adapter can name,
  # and on OTP's `:pg` it is unreachable — `:pg.get_members/2` answers `[]` for
  # a group nobody has joined. The clause is here because the library's
  # contract allows it. The log line carries ids and no body: `AGENTS.md`'s
  # redaction list covers free text, and a message body is the freest there is.
  @spec announce([Ecto.UUID.t()], tuple()) :: :ok
  defp announce(person_ids, message) when is_list(person_ids) do
    Enum.each(person_ids, &broadcast(&1, message))
  end

  @spec broadcast(Ecto.UUID.t(), tuple()) :: :ok
  defp broadcast(person_id, message) do
    HospitalityComs.PubSub
    |> Phoenix.PubSub.broadcast(topic(person_id), message)
    |> announced(elem(message, 0))
  end

  @spec announced(:ok | {:error, term()}, atom()) :: :ok
  defp announced(:ok, _event), do: :ok

  defp announced({:error, reason}, event) do
    Logger.warning(
      "peer announcement was not delivered " <>
        "event=#{event} reason_code=#{inspect(reason)}"
    )

    :ok
  end
end
