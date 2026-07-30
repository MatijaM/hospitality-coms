defmodule HospitalityComsWeb.ProfileChannel do
  @moduledoc """
  One worker's portable record, on one channel: their own entries, the ledger of
  what they have decided about them, and one peer's record at a time.

  ## This channel carries no server pushes, and that is worth saying out loud

  `HospitalityComs.Profiles` broadcasts nothing. There is no `announce/2` in it,
  no `HospitalityComs.PubSub.broadcast/2` call anywhere in the namespace, and
  `client/src/features/profile/use-profile-surface.ts` registers **zero** push
  handlers — it calls `socket.join` with no `events` key at all. So this is
  request/reply with a join lifecycle, which is HTTP's shape, and the surface
  refreshes on its own actions and on a rejoin.

  It is a channel for two reasons and neither is "channels are for realtime":

    * the client is already written and tested against exactly this contract —
      `client/src/features/profile/contract.ts` is 246 lines of it, written
      ahead of the transport on purpose and arguing every wire name it asks
      for; and
    * **the rooms surface's reason for going HTTP does not transfer.**
      `HospitalityComsWeb.RoomController` exists because two of its four reads
      are lists you need *before* you have a room to ask through — you cannot
      join `venue_room:<venue_id>` until you know which venues you are in. A
      profile topic is keyed on the session's own person id, which the client
      already holds from `GET /api/me`. There is nothing to discover first.

  **What would justify it staying one**, so a later unit has a list rather than
  a rediscovery:

    * an **employer attesting an entry** — the worker's record gains a row with
      no action of theirs, written inside
      `HospitalityComs.Engagements.claim_invitation/2`'s transaction;
    * a **correction being resolved** — the venue answers a contest through
      `HospitalityComs.Profiles.resolve_correction/3`, which today the worker
      sees only on a rejoin;
    * a **disclosure decided on another device** — the ledger is per person, so
      a worker with two tabs open sees two different answers until one rejoins.

  Each is one `Phoenix.PubSub.broadcast/3` on this person's own topic away, and
  the topic is already the right one: the suffix is the person (see below), so
  `Phoenix.Channel.Server` has this channel subscribed to a string only that
  person's channels hold. The day one of those exists it wants a
  `Profiles.topic/1` beside `HospitalityComs.Peers.topic/1`, so that the
  publisher and this file are not two spellings of one string.

  ## The suffix is the person, and the check is a repeated variable

  `join/3` casts the suffix through `HospitalityComsWeb.ChannelAuth.topic_id/1`
  and then `admitted/3` matches it against the joining scope's own person as
  **one binding** — `HospitalityComsWeb.PeerChannel`'s shape, for a sharper
  version of its reason. An `==` in a body below compiles, passes every test
  that only ever joins its own topic, and hands one worker another worker's
  whole record: every term they have served, every venue that asserted one,
  every contest they have raised, and the ledger, which is the list of what they
  did not want seen.

  The cast is also what makes a capitalised suffix work rather than be refused:
  `Ecto.UUID.cast/1` downcases, and the lowercase string is the one every
  broadcast in this application would go to.

  ## One process carries the whole surface (KTD10)

  The cost, stated rather than discovered: an unhandled exception in any
  `handle_in/3` drops the record, the ledger and the open peer profile at once.
  Two of the eight events carry worker-authored text into an Ecto changeset,
  which is the most likely thing here to raise, so every event answers — the
  terminal `handle_in/3` clause and the `handle_info/2` catch-all are both
  present and both tested, and the changeset arm is a reply rather than a
  `raise`.

  That is also why these eight are not clauses on `PeerChannel`: none of the
  names collides with any of its nine, deliberately, so the alternative was a
  one-constant change on the client — but a profile is not a conversation, and
  folding them in would mean a blank label in a form takes down every one of
  that person's conversations.

  ## The instant is per inbound event (KTD5)

  `ChannelAuth.person_scope/1` at the top of every `handle_in/3` and
  `ChannelAuth.join_scope/1` in `join/3`. A channel joined this morning has this
  afternoon's `peer_profile` refused against this afternoon's visibility, on the
  same process, with no rejoin and no job. Nothing here reads
  `HospitalityComs.Clock` directly, which is why `.credo.exs`'s
  `:boundary_modules` does not grow.

  ## What a refusal says, and the one place the rule bends

  Four codes, which is the whole vocabulary
  `client/src/features/profile/refusal-message.ts` enumerates:

    * **`unauthorized`, join only** — no live session, a topic naming somebody
      else, or a suffix that is not an id, in one sentence.
    * **`not_found`** — an entity id that resolves to nothing this person owns.
      Somebody else's engagement, somebody else's declared entry, a person who
      is neither visible nor connected, the caller themselves, an id that names
      nothing, and an id that is not an id: all one answer (AE1). Every id goes
      through `ChannelAuth.topic_id/1` first, because uncast it reaches Ecto's
      query builder and raises, which the transport reports as a crash — so the
      malformed case would be tellable from the unknown one.
    * **`bad_request`** — an event with no clause, and a payload missing
      something the event cannot proceed without.
    * **`unprocessable_entity`** — a changeset, with `fields`. Worker-authored
      text is deliberately *not* pre-checked here: a blank label or a blank body
      goes to the changeset so it comes back naming the input the worker filled
      in, which is what the form renders it beside.

  **`audience_kind` and `audience_id` are one value and a pair that is not an
  audience is `bad_request`**, which is the bend. They are a tagged union rather
  than a key, so an unknown kind and an unparseable id are the same mistake —
  the payload does not name an audience — and both are statements about input
  that came from the caller's own browser. It is also the only answer whose copy
  is right: the client's `not_found` sentence for `set_disclosure` reads *"That
  entry is not one of yours"*, which is a lie about a mistyped venue id. Nothing
  is enumerable through it either, because an audience that names no venue and
  no person is already a foreign-key changeset error by the context's design.

  ## The audience picker, and the two lists it needs (#73)

  `"list_audiences"` takes `%{}` and answers

      %{venues: [%{venue_id, name}], people: [%{person_id, display_name}]}

  which are the two kinds `HospitalityComs.Profiles.Disclosure.audience/0` has.
  Without it the disclosure control made the worker type a raw uuid, because
  nothing on this surface could say which venues or which people one might name.

  **One event rather than two**, so the two halves are answered at one instant —
  both are derived, neither is stored, and a picker showing a venue from 10:00
  beside a peer from 10:05 would be two answers to one question.
  `HospitalityComsWeb.PeerChannel`'s `"list_requests"` is the same shape.

  **It is the only event here that does not call `HospitalityComs.Profiles`**,
  and that is deliberate. The two relations belong to other contexts — *where do
  you work* is `HospitalityComs.Engagements` and *who can see you* is
  `HospitalityComs.Peers` — and a `Profiles.list_audiences/1` composing them
  would have to answer an `Ecto` schema, which #36 forbids that context, or
  invent a third spelling of a venue inside it.

  Each list is exactly the set that can read the record, and neither is a list
  that already existed:

    * the venues are `Engagements.list_engaged_venues/1` — the worker's
      engagements **active at the instant**, which is the employer view's own
      predicate. Not `VisibleEntry.venue_id`, which is the venue that *asserted*
      an entry rather than one that could be an audience for it; not
      `Rooms.list_venue_rooms/1`, which subtracts suspensions (KTD18); and not
      `list_managed_venues/1`, which needs a live grant and would leave an
      ordinary worker's picker empty.
    * the people are `Peers.list_reachable_peers/1` — visible **or** connected,
      which is the pair `Profiles.fetch_peer_profile/2` gates on. The connected
      half is what makes the remedy for the peer-disclosure residue reachable:
      the person a worker most wants to hide an entry from is one who is
      connected and no longer co-rostered.

  ## Nothing here validates what the changeset validates

  The three writes pass the payload straight to the context. `DeclaredEntry`'s
  `cast/3` allowlist is exactly the four fields `contract.ts` sends,
  `CorrectionRequest`'s is exactly `[:body]`, and `Disclosure` casts nothing at
  all — so a `Map.take/2` in front of them would be a second copy of a field
  list with nothing to protect. That is the opposite call from
  `HospitalityComsWeb.EmployerController`'s `@term_fields`, and the difference is
  that there the changeset *would* cast the dangerous field.

  ## Rendering: four shapes, and every entity says `<entity>_id`

  The context answers four render structs and this turns each into a map with
  ISO 8601 instants. There is no shape to invent, which is why `contract.ts`
  could be written before this file existed — and the client's decoders
  **refuse `id`** for the three entities whose Ecto schemas spell it that way,
  so a channel that put a schema on the wire would produce a surface that
  renders empty and says nothing.

  `resolution` and `audience_kind` go on the wire as atoms. `Jason` encodes an
  atom as a JSON string, so the client sees `"accepted"` and `"venue"` and
  narrows them against its own enumerations — which is
  `PeerChannel.rendered_request/1`'s existing treatment of `state` rather than a
  new convention.

  ## The join reply carries the notice, and no profile reply carries anything derived from what was withheld

  `HospitalityComs.Profiles.incompleteness_notice/0` is arity zero so that it
  cannot become an oracle naming which workers conceal something. On a transport
  that means it arrives **once, on the join**, which is about the session and
  which no profile read can influence. So neither profile reply carries a
  notice, a count, a total, or any field whose value depends on what was left
  out.
  """

  use HospitalityComsWeb, :channel

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Engagements
  alias HospitalityComs.Peers
  alias HospitalityComs.Profiles
  alias HospitalityComs.Profiles.Disclosure
  alias HospitalityComs.Profiles.VisibleCorrection
  alias HospitalityComs.Profiles.VisibleDeclaration
  alias HospitalityComs.Profiles.VisibleDisclosure
  alias HospitalityComs.Profiles.VisibleEntry
  alias HospitalityComs.Venues.Venue
  alias HospitalityComsWeb.ChannelAuth
  alias HospitalityComsWeb.ErrorEnvelope
  alias HospitalityComsWeb.RoomChannel
  alias Phoenix.Socket

  # One sentence for a session that is no longer live, a topic naming somebody
  # else, and a topic whose suffix is not a uuid at all — `PeerChannel`'s rule,
  # and here the thing behind the topic is the whole of somebody's working
  # history rather than a conversation.
  @refusal "this session cannot open that record"
  @unknown "no such entry, decision, or person"
  @needs_id "that event needs an id"
  @needs_decision "that event needs an engagement_id, an audience_kind, an audience_id, and disclosed"
  @needs_draft "that event needs the entry it is declaring"
  @bad_audience "that event needs an audience_kind of venue or person, and an audience_id"
  @rejected "that was rejected"

  @typedoc """
  What this channel replies to an inbound event with.

  Spelled out rather than left as `term()`, because the union is the contract
  `client/src/features/profile/contract.ts` is written against.
  """
  @type reply() ::
          {:ok, map()} | {:error, ErrorEnvelope.t() | ErrorEnvelope.with_fields()}

  @typedoc """
  The three lists a reader gets, whoever they are.

  `own_profile/1` and `fetch_peer_profile/2` build the same shape and the client
  decodes both with one decoder, so a second rendering here would be a place for
  the two readings to drift. What a viewer sees is what the worker sees minus
  rows — never minus or plus a field.
  """
  @type rendered_profile() :: %{
          attested_entries: [map()],
          declared_entries: [map()],
          correction_requests: [map()]
        }

  @doc """
  Joins one person's profile surface, if the session is still live and the
  surface is that session's own.

  The session is derived again here rather than taken from the socket, which is
  what stops a socket outliving the token it connected with — see
  `HospitalityComsWeb.ChannelAuth`. There is no membership behind a profile
  topic to refuse a stale session on its way past, so this is the only check
  there is.

  The reply carries the standing incompleteness notice, and it is the only reply
  on this channel that carries one. See the moduledoc.
  """
  @impl true
  @spec join(String.t(), map(), Socket.t()) ::
          {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  def join("profile:" <> suffix, _payload, socket) do
    suffix |> ChannelAuth.topic_id() |> admit(socket)
  end

  @spec admit({:ok, Ecto.UUID.t()} | :error, Socket.t()) ::
          {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  defp admit({:ok, person_id}, socket) do
    socket |> ChannelAuth.join_scope() |> admitted(person_id, socket)
  end

  defp admit(:error, _socket), do: {:error, ErrorEnvelope.new(:unauthorized, @refusal)}

  # The repeated variable is the check: the topic's person and the session's
  # person are one binding, so a topic naming anybody else has no clause. An
  # `==` below would be the same words and a different guarantee — it is a line
  # somebody can delete without the file stopping compiling.
  @spec admitted({:ok, PersonScope.t()} | {:error, :no_session}, Ecto.UUID.t(), Socket.t()) ::
          {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  defp admitted({:ok, %PersonScope{person: %Person{id: person_id}}}, person_id, socket) do
    {:ok, %{person_id: person_id, incompleteness_notice: Profiles.incompleteness_notice()},
     socket}
  end

  defp admitted({:ok, %PersonScope{}}, _person_id, _socket) do
    {:error, ErrorEnvelope.new(:unauthorized, @refusal)}
  end

  defp admitted({:error, :no_session}, _person_id, _socket) do
    {:error, ErrorEnvelope.new(:unauthorized, @refusal)}
  end

  @doc """
  Answers one inbound event, authorised at the instant it arrives.

  Eight events, three fallbacks and a terminal clause. The terminal one is not
  optional: `Phoenix.Channel.Server` dispatches to `handle_in/3`
  unconditionally, so a channel without it crashes on every event a client can
  invent — and here that takes the record, the ledger and the open peer profile
  with it.
  """
  @impl true
  @spec handle_in(String.t(), term(), Socket.t()) :: {:reply, reply(), Socket.t()}
  def handle_in("profile", _payload, socket) do
    profile = socket |> ChannelAuth.person_scope() |> Profiles.own_profile()

    {:reply, {:ok, rendered_profile(profile)}, socket}
  end

  def handle_in("list_disclosures", _payload, socket) do
    decisions = socket |> ChannelAuth.person_scope() |> Profiles.list_disclosures()

    {:reply, {:ok, %{disclosures: Enum.map(decisions, &rendered_disclosure/1)}}, socket}
  end

  def handle_in("list_audiences", _payload, socket) do
    scope = ChannelAuth.person_scope(socket)

    reply = %{
      venues: scope |> Engagements.list_engaged_venues() |> Enum.map(&rendered_venue/1),
      people: scope |> Peers.list_reachable_peers() |> Enum.map(&rendered_person/1)
    }

    {:reply, {:ok, reply}, socket}
  end

  def handle_in(
        "set_disclosure",
        %{
          "engagement_id" => engagement_id,
          "audience_kind" => kind,
          "audience_id" => audience_id,
          "disclosed" => disclosed
        },
        socket
      )
      when is_binary(engagement_id) and is_binary(kind) and is_binary(audience_id) and
             is_boolean(disclosed) do
    kind |> audience(audience_id) |> decided(engagement_id, disclosed, socket)
  end

  def handle_in("declare_entry", %{} = payload, socket) do
    reply =
      socket
      |> ChannelAuth.person_scope()
      |> Profiles.declare_entry(payload)
      |> answered_with(&rendered_declaration/1)

    {:reply, reply, socket}
  end

  def handle_in("amend_declared_entry", %{"declared_entry_id" => entry_id} = payload, socket)
      when is_binary(entry_id) do
    with_id(entry_id, socket, fn scope, id ->
      scope
      |> Profiles.amend_declared_entry(id, payload)
      |> answered_with(&rendered_declaration/1)
    end)
  end

  def handle_in("request_correction", %{"engagement_id" => engagement_id} = payload, socket)
      when is_binary(engagement_id) do
    with_id(engagement_id, socket, fn scope, id ->
      scope
      |> Profiles.request_correction(id, payload)
      |> answered_with(&rendered_correction/1)
    end)
  end

  def handle_in("peer_profile", %{"person_id" => person_id}, socket)
      when is_binary(person_id) do
    with_id(person_id, socket, fn scope, id ->
      scope |> Profiles.fetch_peer_profile(id) |> answered_with(&rendered_profile/1)
    end)
  end

  # `set_disclosure` needs four values, so falling through to the id-only
  # message would tell a client that supplied a perfectly good `engagement_id`
  # that the id is the problem. `PeerChannel`'s `"send"` has the same shape for
  # the same reason.
  def handle_in("set_disclosure", _payload, socket) do
    {:reply, {:error, ErrorEnvelope.new(:bad_request, @needs_decision)}, socket}
  end

  # The one event carrying no id at all: everything in it is worker-authored
  # text the changeset judges, so the only way to arrive here is a payload that
  # is not an object. The terminal clause would say "this channel does not
  # handle that event", which is untrue of an event it does handle.
  def handle_in("declare_entry", _payload, socket) do
    {:reply, {:error, ErrorEnvelope.new(:bad_request, @needs_draft)}, socket}
  end

  def handle_in(event, _payload, socket)
      when event in ~w(amend_declared_entry request_correction peer_profile) do
    {:reply, {:error, ErrorEnvelope.new(:bad_request, @needs_id)}, socket}
  end

  def handle_in(_event, _payload, socket), do: RoomChannel.unknown_event(socket)

  @doc """
  Ignores whatever arrives that no clause matched.

  Nothing publishes to this topic — see the moduledoc — so today this catches
  only strays. It is here rather than left to Phoenix's warn-and-ignore because
  the day something *does* publish here, the clause added for it will opt this
  channel out of that fallback, and the failure mode then is one unhandled
  message taking the whole surface down (KTD10). Putting it back afterwards is
  the step somebody forgets.

  **Measured, so the sentence above is not read as more than it is: deleting
  this clause kills 0 tests.** It is the only `handle_info/2` clause here, so
  removing it makes the module export none, which restores exactly the fallback
  it is standing in for. Add one specific clause and delete it — which is the
  state the day an announcement arrives — and the stray-message test fails. The
  value is visible only as that pair; on its own this is insurance, not a guard.
  """
  @impl true
  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_info(_message, socket), do: RoomChannel.ignored(socket)

  ## Ids, which are user input wherever they arrive from

  # Every id a client supplies goes through the same cast, and a malformed one
  # gets exactly what an unknown one gets. See the moduledoc.
  @spec with_id(String.t(), Socket.t(), (PersonScope.t(), Ecto.UUID.t() -> reply())) ::
          {:reply, reply(), Socket.t()}
  defp with_id(raw, socket, work) do
    scope = ChannelAuth.person_scope(socket)

    raw |> ChannelAuth.topic_id() |> resolved(scope, work) |> replied(socket)
  end

  @spec resolved(
          {:ok, Ecto.UUID.t()} | :error,
          PersonScope.t(),
          (PersonScope.t(), Ecto.UUID.t() -> reply())
        ) :: reply()
  defp resolved(:error, _scope, _work), do: {:error, ErrorEnvelope.new(:not_found, @unknown)}
  defp resolved({:ok, id}, scope, work), do: work.(scope, id)

  @spec replied(reply(), Socket.t()) :: {:reply, reply(), Socket.t()}
  defp replied(answer, socket), do: {:reply, answer, socket}

  ## The audience, which is one value spelled as two fields

  # `Disclosure.put_audience/2`'s own shape, reached from the wire. The pair
  # cannot express "both" or "neither", which is the whole reason the table's
  # two nullable columns are not what goes on it.
  @spec audience(String.t(), String.t()) :: {:ok, Disclosure.audience()} | :error
  defp audience("venue", raw), do: raw |> ChannelAuth.topic_id() |> tagged(:venue)
  defp audience("person", raw), do: raw |> ChannelAuth.topic_id() |> tagged(:person)
  defp audience(_kind, _raw), do: :error

  @spec tagged({:ok, Ecto.UUID.t()} | :error, :venue | :person) ::
          {:ok, Disclosure.audience()} | :error
  defp tagged({:ok, id}, kind), do: {:ok, {kind, id}}
  defp tagged(:error, _kind), do: :error

  @spec decided({:ok, Disclosure.audience()} | :error, String.t(), boolean(), Socket.t()) ::
          {:reply, reply(), Socket.t()}
  defp decided({:ok, audience}, engagement_id, disclosed, socket) do
    with_id(engagement_id, socket, fn scope, id ->
      scope
      |> Profiles.set_disclosure(id, audience, disclosed)
      |> answered_with(&rendered_disclosure/1)
    end)
  end

  defp decided(:error, _engagement_id, _disclosed, socket) do
    {:reply, {:error, ErrorEnvelope.new(:bad_request, @bad_audience)}, socket}
  end

  ## Turning a context answer into a reply

  @spec answered_with({:ok, term()} | {:error, term()}, (term() -> map())) :: reply()
  defp answered_with({:ok, record}, render), do: {:ok, render.(record)}
  defp answered_with(failure, _render), do: refused(failure)

  # Three refusals and no more, because `HospitalityComs.Profiles`' worker-facing
  # functions enumerate three failures between them: `:not_found` from
  # `set_disclosure/4`, `amend_declared_entry/3` and `request_correction/3`,
  # `:not_a_peer` from `fetch_peer_profile/2`, and a changeset from the three
  # writes. There is nothing here that lapses, that is blocked, or that
  # conflicts.
  @spec refused({:error, :not_found | :not_a_peer | Ecto.Changeset.t()}) ::
          {:error, ErrorEnvelope.t() | ErrorEnvelope.with_fields()}
  defp refused({:error, :not_found}), do: {:error, ErrorEnvelope.new(:not_found, @unknown)}
  defp refused({:error, :not_a_peer}), do: {:error, ErrorEnvelope.new(:not_found, @unknown)}

  defp refused({:error, %Ecto.Changeset{} = changeset}) do
    {:error, ErrorEnvelope.for_changeset(:unprocessable_entity, @rejected, changeset)}
  end

  ## Rendering

  @spec rendered_profile(Profiles.profile()) :: rendered_profile()
  defp rendered_profile(%{} = profile) do
    %{
      attested_entries: Enum.map(profile.attested_entries, &rendered_entry/1),
      declared_entries: Enum.map(profile.declared_entries, &rendered_declaration/1),
      correction_requests: Enum.map(profile.correction_requests, &rendered_correction/1)
    }
  end

  # No `person_id`, which is `VisibleEntry`'s own absence carried onto the wire:
  # the key is globally stable, and the entries name venues rather than people.
  @spec rendered_entry(VisibleEntry.t()) :: map()
  defp rendered_entry(%VisibleEntry{} = entry) do
    %{
      attested_entry_id: entry.attested_entry_id,
      entry_engagement_id: entry.entry_engagement_id,
      venue_id: entry.venue_id,
      venue_name: entry.venue_name,
      role_label: entry.role_label,
      starts_at: DateTime.to_iso8601(entry.starts_at),
      ends_at: DateTime.to_iso8601(entry.ends_at),
      attested_at: DateTime.to_iso8601(entry.attested_at)
    }
  end

  # `declared_entry_id`, never `id`. The schema says `id` because it is an Ecto
  # schema; `VisibleDeclaration` is what a reader gets and the client's decoder
  # refuses the other spelling rather than accepting either — which is what
  # stops one entity having two key names on one surface.
  @spec rendered_declaration(VisibleDeclaration.t()) :: map()
  defp rendered_declaration(%VisibleDeclaration{} = declaration) do
    %{
      declared_entry_id: declaration.declared_entry_id,
      role_label: declaration.role_label,
      organisation_name: declaration.organisation_name,
      starts_at: DateTime.to_iso8601(declaration.starts_at),
      ends_at: DateTime.to_iso8601(declaration.ends_at),
      declared_at: DateTime.to_iso8601(declaration.declared_at)
    }
  end

  # `resolved_at` and `resolution` are a pair — `correction_requests_resolution_complete`
  # says a resolved request carries both and an outstanding one carries neither
  # — and they come off one struct here, so they cannot diverge on this side.
  @spec rendered_correction(VisibleCorrection.t()) :: map()
  defp rendered_correction(%VisibleCorrection{} = correction) do
    %{
      correction_request_id: correction.correction_request_id,
      entry_engagement_id: correction.entry_engagement_id,
      venue_id: correction.venue_id,
      body: correction.body,
      requested_at: DateTime.to_iso8601(correction.requested_at),
      resolved_at: iso8601(correction.resolved_at),
      resolution: correction.resolution
    }
  end

  @spec rendered_disclosure(VisibleDisclosure.t()) :: map()
  defp rendered_disclosure(%VisibleDisclosure{} = disclosure) do
    %{
      disclosure_id: disclosure.disclosure_id,
      engagement_id: disclosure.engagement_id,
      audience_kind: disclosure.audience_kind,
      audience_id: disclosure.audience_id,
      disclosed: disclosure.disclosed,
      decided_at: DateTime.to_iso8601(disclosure.decided_at)
    }
  end

  # `venue_id` and **`name`**, which is how a venue listed *as itself* is spelled
  # twice already — `HospitalityComsWeb.EmployerController.render_venue/1` and
  # `HospitalityComsWeb.RoomController.render_venue_room/1`, and both client
  # decoders read it. `venue_name` is what a venue named *inside another entity*
  # is called, which `rendered_entry/1` above does and this is not.
  @spec rendered_venue(Venue.t()) :: %{venue_id: Ecto.UUID.t(), name: String.t()}
  defp rendered_venue(%Venue{} = venue), do: %{venue_id: venue.id, name: venue.name}

  # `person_id` and `display_name`, which is `PeerChannel.rendered_peer/1`'s
  # spelling for the same two values. Field by field rather than passed through,
  # so the wire names live in this file and a field added to
  # `Peers.reachable_peer()` does not reach a browser unreviewed.
  @spec rendered_person(Peers.reachable_peer()) ::
          %{person_id: Ecto.UUID.t(), display_name: String.t()}
  defp rendered_person(%{person_id: person_id, display_name: display_name}) do
    %{person_id: person_id, display_name: display_name}
  end

  @spec iso8601(DateTime.t() | nil) :: String.t() | nil
  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
