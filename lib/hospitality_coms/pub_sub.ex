defmodule HospitalityComs.PubSub do
  @moduledoc """
  Every topic this application publishes on, and the door that scope-checks a
  subscription to one.

  **It is not the only way a process becomes a subscriber, and saying so
  mattered enough to correct.** `Phoenix.Channel.Server` subscribes every
  joined channel to its own topic, from inside the framework, without passing
  through `subscribe/2` — which is exactly how a room channel comes to receive
  the messages `broadcast!/3` sends. What this module governs is the
  subscriptions the *application* makes on purpose: the employer topic, and an
  engagement's revocation.

  The peer topic is the case where the two coincide.
  `HospitalityComsWeb.PeerChannel`'s topic **is** `topic({:peer, person_id})`,
  so Phoenix's own subscription is the one that delivers a peer announcement and
  calling `subscribe/2` there as well would deliver each notice twice. The
  `{:peer, _}` clause below stays because the topic is public — `HospitalityComs
  .Peers.topic/1` hands the string out — and any process that is not that
  channel still has to come through a door that pins the id to the scope.

  ## Why subscription needs a boundary of its own

  U3's boundary is about *queries*: `HospitalityComs.EmployerRepo` refuses a
  query that reaches a person-zone table, and Postgres refuses it again for want
  of privilege. That is the guarantee, and it has one gap that no amount of
  repo-level analysis can see — **`subscribe` issues no query at all**. A
  process that registers itself against `"peer:<person_id>"` is handed every
  message published there, having asked the database nothing, so nothing in the
  grant tier is in a position to have an opinion.

  So subscription gets the same treatment context functions get: the scope
  struct is the first argument and it is matched in the head. An employer scope
  handed a person-zone topic raises `FunctionClauseError` before a registration
  exists (KTD9's reasoning, applied one layer below the routing table).

  ## The refusal is two-way, and the ids are pinned

  The plan only asks that an employer scope handed a peer topic raise. Two extra
  properties cost nothing and are worth having:

    * A **person** scope handed `{:employer_venue, _}` raises too. A one-way
      check is a check somebody can read as "employer scopes are the dangerous
      ones", which is not what the partition says.
    * The **id is pinned to the scope** wherever the scope carries one.
      `{:peer, person_id}` matches only when `person_id` is this scope's own
      person, and `{:employer_venue, venue_id}` only when it is this scope's own
      venue — repeating the variable in the head is what enforces it. So a
      person cannot subscribe to another person's peer topic, and the refusal is
      a function clause rather than a comparison somebody has to write.

  ## Three targets are not gated here at all, and that is worth stating plainly

  `{:venue_room, _}`, `{:shift_room, _}` and `{:engagement, _}` accept **any**
  id from any person scope. There is nothing on a person scope to pin them
  against, and no query is issued, so this module cannot and does not decide
  who may listen to them.

  **The caller authorizes them, not this module.** `HospitalityComsWeb
  .VenueRoomChannel` and `ShiftRoomChannel` derive membership from the database
  and subscribe to the engagement the read returned; that derivation is the
  authorization, and a second caller that subscribed to an id it got from a
  payload would be authorized by nothing. Read these three clauses as a
  *type* check — is this the right kind of scope — and never as an access
  check.

  Nothing in the grant tier would notice if that changed. `subscribe` issues no
  query, so no privilege, no `EmployerRepo` backstop and no row-level security
  policy is in a position to have an opinion; the whole database-tier defence is
  blind here. That is the reason this paragraph is not a footnote.

  What this module *does* refuse, in both directions, is the kind of caller: an
  employer scope handed any of the three, and a person scope handed the
  employer's.

  ## The module and the server share a name

  `HospitalityComs.PubSub` is also the name the `Phoenix.PubSub` process is
  registered under, from `HospitalityComs.Application`. A registered process
  name and a module name are both atoms, so the two coexist, and the module
  naming the server it routes through reads better than inventing a second name
  would.

  ## Revocation is U5's, not a second mechanism

  `{:engagement, id}` resolves through `HospitalityComs.Engagements.topic/1` and
  subscribes through `HospitalityComs.Engagements.subscribe/1`. U5 already
  broadcasts a revocation after commit and only after commit (KTD8); this module
  is a door in front of that topic, not another way to open it.
  """

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Engagements

  @typedoc """
  What a subscriber is asking to hear about.

  Four of the five are person-zone topics in the sense that matters here — only
  a person scope may subscribe to them — and the fifth is the employer's.
  """
  @type target() ::
          {:peer, Ecto.UUID.t()}
          | {:venue_room, Ecto.UUID.t()}
          | {:shift_room, Ecto.UUID.t()}
          | {:engagement, Ecto.UUID.t()}
          | {:employer_venue, Ecto.UUID.t()}

  @typedoc """
  Either scope struct. Spelled out rather than left to `struct()`, because which
  two structs these are is the whole of the refusal.
  """
  @type scope() :: PersonScope.t() | EmployerScope.t()

  @doc """
  The topic string a target publishes on.

  Scope-free, because naming a topic discloses nothing: a topic name crosses
  distributed Erlang on every broadcast and shows up in telemetry, so it is
  built from ids that are already the caller's. Subscribing is the operation
  that needs a scope.

  The room topics are the channel topics `HospitalityComsWeb.PersonSocket`
  routes, deliberately — a process subscribing to `{:venue_room, id}` hears
  exactly what a client joined to that room hears, which is what makes the
  transport testable from outside a channel.
  """
  @spec topic(target()) :: String.t()
  def topic({:peer, person_id}) when is_binary(person_id), do: "peer:" <> person_id
  def topic({:venue_room, venue_id}) when is_binary(venue_id), do: "venue_room:" <> venue_id
  def topic({:shift_room, room_id}) when is_binary(room_id), do: "shift_room:" <> room_id
  def topic({:engagement, id}) when is_binary(id), do: Engagements.topic(id)

  def topic({:employer_venue, venue_id}) when is_binary(venue_id),
    do: "employer_venue:" <> venue_id

  @doc """
  Subscribes the calling process to a target, if this scope may hear it.

  Raises `FunctionClauseError` when the scope is the wrong kind for the target,
  when a person scope names a person other than its own, when an employer scope
  names a venue other than its own, and when the scope is anonymous — an
  anonymous caller holds no engagements and belongs to no room, so there is
  nothing for it to be subscribed to.

  It raises for **no** id handed to `{:venue_room, _}`, `{:shift_room, _}` or
  `{:engagement, _}` by a person scope. Those three are authorized by the caller
  that resolved the id and by nothing here; see the moduledoc.

  `{:error, {:already_registered, pid}}` is `Registry.register/3`'s only failure
  and it cannot happen here: `Phoenix.PubSub`'s registry is `keys: :duplicate`
  and a duplicate registry accepts every registration. It is enumerated rather
  than dropped because the library's contract, not this function, is what would
  have to change for it to appear — the same reasoning
  `HospitalityComs.Engagements.subscribe/1` carries.
  """
  @spec subscribe(scope(), target()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(%PersonScope{person: %Person{id: person_id}}, {:peer, person_id} = target) do
    register(target)
  end

  def subscribe(%PersonScope{person: %Person{}}, {:venue_room, venue_id} = target)
      when is_binary(venue_id) do
    register(target)
  end

  def subscribe(%PersonScope{person: %Person{}}, {:shift_room, room_id} = target)
      when is_binary(room_id) do
    register(target)
  end

  def subscribe(%PersonScope{person: %Person{}}, {:engagement, engagement_id})
      when is_binary(engagement_id) do
    Engagements.subscribe(engagement_id)
  end

  def subscribe(%EmployerScope{venue_id: venue_id}, {:employer_venue, venue_id} = target) do
    register(target)
  end

  @spec register(target()) :: :ok | {:error, {:already_registered, pid()}}
  defp register(target), do: Phoenix.PubSub.subscribe(__MODULE__, topic(target))
end
