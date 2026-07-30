defmodule HospitalityComsWeb.RoomChannel do
  @moduledoc """
  The two room channels' shared parts. **This is not itself a channel** — it is
  routed by nothing, and `HospitalityComsWeb.SocketsTest` asserts the two
  routing tables exactly, so an entry pointing here would be caught.

  ## Why it exists

  `HospitalityComsWeb.VenueRoomChannel` and `HospitalityComsWeb.ShiftRoomChannel`
  carried about thirty byte-identical lines between them — the after-join
  presence track, both terminal-push clauses, the wire rendering of a message,
  and the two clauses that stop a channel crashing on an event or a message it
  was not written for. They differed in exactly one thing: the key a payload
  names the room by, `venue_id` on one and `shift_room_id` on the other.

  Thirty lines is not much. What made it worth extracting is that U7's own
  documentation points at these shapes as the ones U8's peer channel and U9's
  employer view build on, so the pattern was positioned to spread to four
  copies before it was shared once. The differing key is now a value —
  `t:closure/0`'s `:room` — rather than a line each channel writes for itself.

  ## What is deliberately *not* here

  `join/3` and the send path. Those are the two places the channels differ in
  substance rather than in spelling: a venue room asks
  `HospitalityComs.Rooms.fetch_venue_room_membership/2` and a shift room asks
  `fetch_shift_room_reader/2`, and a shift room's send has three refusals a
  venue room's does not (KTD6b, the grace window). Folding those together
  behind a parameter would make the one thing worth reading from each file
  invisible in both.
  """

  import Phoenix.Channel, only: [push: 3]

  require Logger

  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComsWeb.ChannelAuth
  alias HospitalityComsWeb.ErrorEnvelope
  alias HospitalityComsWeb.Presence
  alias Phoenix.Socket

  @unknown_event "this channel does not handle that event"

  @typedoc "What a rendered message looks like on the wire. No person id, ever."
  @type rendered() :: %{
          id: Ecto.UUID.t(),
          body: String.t(),
          sent_at: String.t(),
          author_engagement_id: Ecto.UUID.t(),
          author_display_name: String.t(),
          author_role_label: String.t()
        }

  @typedoc """
  What a room channel replies to an inbound event with.

  Spelled out rather than left as `term()`, because the union is the contract
  U12's client is written against: the rendered message on success, and one of
  `HospitalityComsWeb.ErrorEnvelope`'s two shapes on refusal — `with_fields()`
  only where the failure attaches to an input.
  """
  @type reply() :: {:ok, rendered()} | {:error, ErrorEnvelope.t() | ErrorEnvelope.with_fields()}

  @typedoc """
  Why a room channel is stopping, and what it tells the client on its way out.

  `:room` is the one key the two channels do not share — `%{venue_id: id}` or
  `%{shift_room_id: id}` — and carrying it as a value is the whole of what this
  module extracts.
  """
  @type closure() :: %{
          event: String.t(),
          reason: :revoked | :suspended,
          room: %{optional(:venue_id) => Ecto.UUID.t(), optional(:shift_room_id) => Ecto.UUID.t()}
        }

  @typedoc """
  What a broadcast that closes a channel carries.

  `venue_id` is optional because the two closures do not agree on it: an
  engagement ending is about the engagement wherever it is read, while a
  suspension is a person opting out of one venue's room and says which.
  `closed/4` matches on `engagement_id` alone, so a third closure kind may
  carry either.
  """
  @type notice() :: %{
          :engagement_id => Ecto.UUID.t(),
          :at => DateTime.t(),
          optional(:venue_id) => Ecto.UUID.t()
        }

  @doc """
  Tracks the joining channel's presence and hands it the room's current state.

  Called from `handle_info(:after_join, socket)` rather than from `join/3`,
  because a channel cannot track itself before it has finished joining — the
  tracker would be registering a process that is not yet subscribed to its own
  topic.

  The instant is read afresh here rather than carried from the join, which is
  KTD5: `:after_join` is its own message.
  """
  @spec joined(Socket.t()) :: {:noreply, Socket.t()}
  def joined(%Socket{} = socket) do
    scope = ChannelAuth.person_scope(socket)
    {:ok, _ref} = Presence.track_engagement(socket, socket.assigns.engagement, scope.now)
    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  @doc """
  Pushes a terminal notice and stops the channel, if the notice is this one's.

  **The nudge, not the enforcement.** The guarantee is the rejoin `join/3`
  refuses once the database no longer says this session belongs here; this push
  and this stop are what make an already-powerless channel notice, and every
  arrow before that rejoin is best effort (KTD8).

  No `Presence.untrack/2` call: the tracker monitors this process, so the stop
  *is* the leave, and an explicit untrack before it would only be a second way
  to say the same thing — one that would go missing if the channel died for any
  other reason. `HospitalityComsWeb.PresenceTest` proves that by killing a
  channel outright and watching the leave arrive anyway.

  The `false` clause is a notice about a different engagement. It cannot arrive
  today — every subscription is per engagement — and answering it rather than
  crashing is what keeps that a property of the channel rather than an
  assumption about the topic it happens to be subscribed to.
  """
  @spec closed(boolean(), closure(), notice(), Socket.t()) ::
          {:noreply, Socket.t()} | {:stop, {:shutdown, :revoked | :suspended}, Socket.t()}
  def closed(false, _closure, _notice, %Socket{} = socket), do: {:noreply, socket}

  def closed(true, closure, notice, %Socket{} = socket) do
    push(
      socket,
      closure.event,
      Map.merge(closure.room, %{
        engagement_id: notice.engagement_id,
        at: DateTime.to_iso8601(notice.at)
      })
    )

    {:stop, {:shutdown, closure.reason}, socket}
  end

  @doc """
  Answers an inbound event neither room channel handles.

  `Phoenix.Channel.Server` dispatches to `handle_in/3` unconditionally — there
  is no warn-and-ignore fallback for an event the way there is for a message —
  so a channel without a terminal clause crashes on every event it was not
  written for, which a client reaches by inventing one word.
  """
  @spec unknown_event(Socket.t()) :: {:reply, {:error, ErrorEnvelope.t()}, Socket.t()}
  def unknown_event(%Socket{} = socket) do
    {:reply, {:error, ErrorEnvelope.new(:bad_request, @unknown_event)}, socket}
  end

  @doc """
  Ignores a message no clause matched, and says so at debug.

  Phoenix falls back to warn-and-ignore only for a channel that exports no
  `handle_info/2` at all; exporting one opts out of that, so this puts it back.
  It matters more here than it would elsewhere because **the engagement topic is
  shared by every channel that engagement opened** — a crash there does not take
  down one channel, it takes down the venue room and every shift room at once.

  The topic and nothing else. An unmatched message is by definition a term
  nobody has audited, and `AGENTS.md`'s redaction list cannot cover one.
  """
  @spec ignored(Socket.t()) :: {:noreply, Socket.t()}
  def ignored(%Socket{} = socket) do
    Logger.debug("unmatched channel message topic=#{socket.topic}")
    {:noreply, socket}
  end

  @doc """
  A message as a client sees it: the engagement that wrote it, never the person.

  KTD2 keeps `person_id` off every employer-zone row and KTD15b makes
  attribution the engagement, which is venue-local by construction and is
  already what `room_messages.author_engagement_id` holds. A client that can
  render a message can render a presence entry with the same key.

  ## Three values, and no two of them do the same work

  `author_display_name` is the person's own (#66) and `author_role_label` is the
  venue's own words for what they do (#65). Both are joined on the read by
  `HospitalityComs.Rooms.Records.with_author/1`, and both sends read the row
  back through that same query rather than assembling it from what they hold.

    * **The name** says who spoke. It is global and it is deliberately **not
      unique** — a globally unique readable name would be a second `person_id`
      in plain text.
    * **The label** says what that person does *at this venue*, which in a work
      chat is often what decides whether you act on the message. It is
      venue-local and it is not unique either: a venue can have two Bartenders.
    * **The engagement id** is what actually distinguishes them, and it is the
      only one of the three that does. Drop it and two colleagues who drew the
      same character and hold the same job are one speaker.

  ## An erased author reads as two constants, deliberately

  Erasure overwrites `people.display_name` with
  `HospitalityComs.Lifecycle.erased_display_name/0` and
  `engagements.role_label` with `HospitalityComs.Lifecycle.erased_label/0`, so
  their history renders **Former colleague · Former team member · 4a3f…**. That
  doubling is on purpose and is named here so it is not read as an oversight:
  the two are different facts about different things — who a person called
  themselves, and what an employer wrote about a job — kept as separate
  constants with no asserted relation, and suppressing one would be the only
  special case in a render function that has none.

  **One disclosure follows and it is on the record rather than closed.** The id
  is venue-local by construction; the name is the same string at every venue. So
  a worker engaged at two venues can tell from the messages alone that one human
  speaks in both rooms — a capability
  `HospitalityComs.Rooms.list_venue_room_members/2` already hands out through
  `person_id`, now reachable without the join.
  `HospitalityComs.Accounts.Person`'s moduledoc carries the full statement.

  **A second, smaller one arrives with the label.** That roll is the venue's
  *active* engagements and peer visibility lapses thirty days past a term's end,
  while a venue room keeps full history — so somebody who joined last week can
  now read out of the history that a person who left two years ago was the head
  chef. It is a job title at a venue, authored by that venue, attached to words
  that venue already retains indefinitely (KTD15c). `CLAUDE.md`'s "Five
  disclosures on the record" carries it.

  It matches on both fields being binaries rather than reading them, so a
  message read by a path that forgot the join is a `FunctionClauseError` here
  rather than a `null` on the wire and an `undefined` in a heading. That is
  `HospitalityComsWeb.RoomController.rendered_shift_room/1`'s manoeuvre against
  an unloaded association, applied to two virtual fields.
  """
  @spec rendered(RoomMessage.t()) :: rendered()
  def rendered(%RoomMessage{author_display_name: name, author_role_label: label} = message)
      when is_binary(name) and is_binary(label) do
    %{
      id: message.id,
      body: message.body,
      sent_at: DateTime.to_iso8601(message.sent_at),
      author_engagement_id: message.author_engagement_id,
      author_display_name: name,
      author_role_label: label
    }
  end
end
