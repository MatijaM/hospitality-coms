defmodule HospitalityComsWeb.PeerChannel do
  @moduledoc """
  Every one of this person's peer conversations, on one channel (KTD10).

  ## Why this exists in U7 rather than in U8

  The peer graph is U8's. What U7 owes is the *topic*, because KTD9's guarantee
  is a statement about two routing tables and a statement about two routing
  tables is vacuous unless both have entries. `HospitalityComsWeb.EmployerSocket`
  routing no `"peer"` topic means something only because
  `HospitalityComsWeb.PersonSocket` routes one and it works.

  ## One channel, not one per conversation

  `"peer"` is an exact topic and carries the whole peer surface for this person.
  `max_channels_per_transport` defaults to 100 in Phoenix 1.8.9, and a worker
  with engagements at three venues is already holding a venue room and several
  shift rooms at each before a conversation is opened; a channel per
  conversation would approach the limit for an ordinary user rather than an
  exotic one. It also means there is no per-conversation topic name that a later
  unit could copy into an employer socket's table by accident.

  ## What it does today

  It authenticates that the joiner is a person and subscribes them to their own
  peer topic — `HospitalityComs.PubSub.subscribe/2` pins the person id to the
  scope in its function head, so this channel cannot subscribe to anybody else's
  even if the topic were parameterised, which it is not.

  U8 adds the conversation events. Nothing here needs to change for it to: the
  channel is already the multiplexing point, and every event it will carry names
  its conversation in the payload rather than in the topic.
  """

  use HospitalityComsWeb, :channel

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.PubSub
  alias HospitalityComsWeb.ChannelAuth
  alias HospitalityComsWeb.ErrorEnvelope
  alias Phoenix.Socket

  @unknown_event "this channel does not handle that event"

  @doc """
  Joins this person's peer surface.

  Refuses an anonymous socket by function clause rather than by a check —
  `HospitalityComsWeb.PersonSocket` cannot produce one, because `connect/3`
  answers `:error` without a live token, so this clause is the belt to that
  brace.
  """
  @impl true
  @spec join(String.t(), map(), Socket.t()) :: {:ok, map(), Socket.t()}
  def join("peer", _payload, socket) do
    %PersonScope{person: %Person{id: person_id}} = scope = ChannelAuth.person_scope(socket)

    :ok = PubSub.subscribe(scope, {:peer, person_id})

    {:ok, %{person_id: person_id}, socket}
  end

  @doc """
  Answers an event this channel does not carry.

  The only clause today, and it is the one U8 adds its conversation events in
  front of. `Phoenix.Channel.Server` dispatches to `handle_in/3` unconditionally
  — a channel exporting none at all raises `UndefinedFunctionError` on every
  event it receives — so a topic that is deliberately still empty needs this
  clause more than a busy one does, not less.
  """
  @impl true
  @spec handle_in(String.t(), map(), Socket.t()) ::
          {:reply, {:error, ErrorEnvelope.t()}, Socket.t()}
  def handle_in(_event, _payload, socket) do
    {:reply, {:error, ErrorEnvelope.new(:bad_request, @unknown_event)}, socket}
  end
end
