defmodule HospitalityComsWeb.PeerChannelTest do
  @moduledoc """
  The whole peer surface on one topic (KTD10), and the two properties that only
  hold because it is one topic.

  ## What is asserted here rather than in `HospitalityComs.PeersTest`

  The context is where the state machine is proved. What the transport adds is
  multiplexing, and multiplexing has two consequences a context test cannot see:

    * **every event names its conversation in the payload**, so one channel can
      carry conversations with different people that were opened and closed at
      different times; and
    * **one conversation closing must not stop the channel**, because the
      others are on it. A room channel stops on revocation because the topic
      *is* the room; here the topic is the person.

  ## Why the broadcast tests join only one side

  Both parties' channels push to the same test process, so a test with two
  channels joined cannot say *which* of them received a push. Where the claim is
  "the other party hears about it", only the other party's channel is joined and
  the acting party goes through `HospitalityComs.Peers` directly — so the one
  push that arrives can only have come from the channel under test.
  """

  use HospitalityComsWeb.ChannelCase

  alias HospitalityComs.Peers
  alias HospitalityComs.PeersFixtures
  alias HospitalityComsWeb.PersonSocket

  @now HospitalityComs.EngagementsFixtures.fixed_instant()

  describe "the peer channel" do
    test "joins and names the person it is multiplexing for" do
      person = person_fixture(@now)
      socket = person_socket(person)

      assert {:ok, reply, _channel} = subscribe_and_join(socket, "peer", %{})
      assert reply == %{person_id: person.id}
    end

    test "answers an event it does not handle rather than crashing on it" do
      person = person_fixture(@now)
      {:ok, _reply, channel} = subscribe_and_join(person_socket(person), "peer", %{})

      ref = push(channel, "open_conversation", %{"with" => "somebody"})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "bad_request"

      assert Process.alive?(channel.channel_pid)
    end

    test "ignores a message no clause matches rather than dying on it" do
      # The peer topic is shared by every conversation this person has, so a
      # crash here does not take down one conversation — it takes down all of
      # them at once. `Phoenix.Channel` only warns-and-ignores for a channel
      # that exports no `handle_info/2` at all, and this one exports five.
      person = person_fixture(@now)
      {:ok, _reply, channel} = subscribe_and_join(person_socket(person), "peer", %{})

      send(channel.channel_pid, {:something_else, %{}})

      ref = push(channel, "list_conversations", %{})
      assert_reply ref, :ok, _reply
      assert Process.alive?(channel.channel_pid)
    end
  end

  describe "one topic carrying the whole surface" do
    test "lists peers, sends a request, accepts it, and talks — all on one channel" do
      # KTD10 as a behaviour. Nine events, two people, and exactly two channels
      # between them: no per-conversation topic exists to be joined.
      %{first: first, second: second} = PeersFixtures.co_rostered(@now)

      mine = joined(first)
      theirs = joined(second)

      ref = push(mine, "list_peers", %{})
      assert_reply ref, :ok, %{peers: [peer]}
      assert peer.person_id == second.person.id
      assert peer.venue_name =~ venue_prefix()

      ref = push(mine, "request", %{"person_id" => second.person.id})
      assert_reply ref, :ok, %{request_id: request_id, state: :pending}

      ref = push(theirs, "list_requests", %{})
      assert_reply ref, :ok, %{incoming: [incoming], outgoing: []}
      assert incoming.request_id == request_id

      ref = push(theirs, "accept", %{"request_id" => request_id})
      assert_reply ref, :ok, %{connection_id: connection_id, peer_id: peer_id, open: true}
      assert peer_id == first.person.id

      ref = push(mine, "send", %{"connection_id" => connection_id, "body" => "hello"})
      assert_reply ref, :ok, %{body: "hello", connection_id: ^connection_id}

      ref = push(theirs, "history", %{"connection_id" => connection_id})
      assert_reply ref, :ok, %{messages: [%{body: "hello"}]}
    end

    test "names the conversation in every payload, never in the topic" do
      # The property multiplexing rests on: two live conversations on one
      # channel, told apart by the payload alone.
      %{first: first, second: second, employer: employer} = PeersFixtures.co_rostered(@now)
      third = person_scope_fixture(@now)
      PeersFixtures.engage(employer, third, %{}, @now)

      one = PeersFixtures.connection_fixture(first, second)
      two = PeersFixtures.connection_fixture(first, third)

      mine = joined(first)

      ref = push(mine, "send", %{"connection_id" => one.id, "body" => "to the first"})
      assert_reply ref, :ok, %{connection_id: first_id}

      ref = push(mine, "send", %{"connection_id" => two.id, "body" => "to the second"})
      assert_reply ref, :ok, %{connection_id: second_id}

      assert first_id == one.id
      assert second_id == two.id
      assert mine.topic == "peer"

      ref = push(mine, "list_conversations", %{})
      assert_reply ref, :ok, %{conversations: conversations}
      assert MapSet.new(conversations, & &1.connection_id) == MapSet.new([one.id, two.id])
    end
  end

  describe "what arrives on the other party's channel" do
    test "a request, on the addressee's topic" do
      %{first: first, second: second} = PeersFixtures.co_rostered(@now)
      _theirs = joined(second)

      {:ok, request} = Peers.request_connection(first, second.person.id)

      assert_push "peer_request", notice
      assert notice.request_id == request.id
      assert notice.requester_id == first.person.id
    end

    test "an acceptance, with the peer resolved from the reader's own side" do
      # One broadcast serves both parties, so the payload names both people and
      # the channel picks the one its own person is not.
      %{first: first, second: second} = PeersFixtures.co_rostered(@now)
      _mine = joined(first)

      request = PeersFixtures.request_fixture(first, second)
      {:ok, connection} = Peers.accept_request(second, request.id)

      assert_push "peer_connected", notice
      assert notice.connection_id == connection.id
      assert notice.peer_id == second.person.id
      refute Map.has_key?(notice, :person_a_id)
    end

    test "a decline, on the requester's topic" do
      %{first: first, second: second} = PeersFixtures.co_rostered(@now)
      _mine = joined(first)

      request = PeersFixtures.request_fixture(first, second)
      {:ok, _declined} = Peers.decline_request(second, request.id)

      assert_push "peer_request_declined", notice
      assert notice.request_id == request.id
    end

    test "a message, naming its conversation" do
      %{first: first, second: second} = PeersFixtures.co_rostered(@now)
      connection = PeersFixtures.connection_fixture(first, second)
      _theirs = joined(second)

      {:ok, message} = Peers.send_message(first, connection.id, "over here")

      assert_push "peer_message", notice
      assert notice.connection_id == connection.id
      assert notice.message_id == message.id
      assert notice.body == "over here"
      assert notice.author_id == first.person.id
    end

    test "a disconnect, which does not stop the channel" do
      # The whole of why this is one topic. A room channel stops on revocation
      # because the topic is the room; stopping here would take down every other
      # conversation this person has.
      %{first: first, second: second, employer: employer} = PeersFixtures.co_rostered(@now)
      third = person_scope_fixture(@now)
      PeersFixtures.engage(employer, third, %{}, @now)

      closing = PeersFixtures.connection_fixture(first, second)
      surviving = PeersFixtures.connection_fixture(second, third)

      theirs = joined(second)

      {:ok, _closed} = Peers.disconnect(first, closing.id)

      assert_push "peer_disconnected", notice
      assert notice.connection_id == closing.id
      assert notice.disconnected_by_id == first.person.id

      assert Process.alive?(theirs.channel_pid)

      ref = push(theirs, "send", %{"connection_id" => surviving.id, "body" => "still talking"})
      assert_reply ref, :ok, %{body: "still talking"}
    end
  end

  describe "a refusal on the peer channel" do
    test "answers the same way for a conversation that is somebody else's and one that is nothing" do
      # AE1 at the transport. A malformed id gets it too: uncast it would reach
      # Ecto's query builder and raise, which the transport reports as a crash —
      # so a caller could tell a malformed id from an unknown one by which
      # answer they got.
      %{first: first, second: second} = PeersFixtures.co_rostered(@now)
      %{first: outsider} = PeersFixtures.co_rostered(@now)
      connection = PeersFixtures.connection_fixture(first, second)

      channel = joined(outsider)

      ref = push(channel, "send", %{"connection_id" => connection.id, "body" => "hi"})
      assert_reply ref, :error, theirs
      assert theirs.error.code == "not_found"

      ref = push(channel, "send", %{"connection_id" => Ecto.UUID.generate(), "body" => "hi"})
      assert_reply ref, :error, nothing
      assert nothing.error.code == "not_found"

      ref = push(channel, "send", %{"connection_id" => "not-a-uuid", "body" => "hi"})
      assert_reply ref, :error, malformed
      assert malformed.error.code == "not_found"

      assert Process.alive?(channel.channel_pid)
    end

    test "says a request is outstanding rather than pretending it is not" do
      %{first: first, second: second} = PeersFixtures.co_rostered(@now)
      PeersFixtures.request_fixture(first, second)

      channel = joined(first)

      ref = push(channel, "request", %{"person_id" => second.person.id})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "conflict"
    end

    test "hides a person the caller is not co-rostered with behind not_found" do
      %{first: first} = PeersFixtures.co_rostered(@now)
      %{first: stranger} = PeersFixtures.co_rostered(@now)

      channel = joined(first)

      ref = push(channel, "request", %{"person_id" => stranger.person.id})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "not_found"
    end

    test "answers an event whose payload carries no id" do
      %{first: first} = PeersFixtures.co_rostered(@now)
      channel = joined(first)

      ref = push(channel, "send", %{"body" => "no conversation named"})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "bad_request"
    end
  end

  describe "the instant is the event's, not the join's" do
    test "refuses a send into a conversation the other party closed after this channel joined" do
      # KTD5 on the peer surface. No rejoin, no job, and nothing cached on the
      # socket — the context re-derives the conversation's state on every event.
      %{first: first, second: second} = PeersFixtures.co_rostered(@now)
      connection = PeersFixtures.connection_fixture(first, second)

      channel = joined(first)

      # The control: it worked a moment ago on this same channel.
      ref = push(channel, "send", %{"connection_id" => connection.id, "body" => "before"})
      assert_reply ref, :ok, _sent

      {:ok, _closed} = Peers.disconnect(second, connection.id)

      ref = push(channel, "send", %{"connection_id" => connection.id, "body" => "after"})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "conflict"
    end

    test "lapses a request between two people whose visibility ran out while the channel lived" do
      ends_at = DateTime.add(@now, 10, :day)

      %{first: first, second: second} =
        PeersFixtures.co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      channel = joined(first)

      ref = push(channel, "list_peers", %{})
      assert_reply ref, :ok, %{peers: [_peer]}

      at(DateTime.add(ends_at, 31, :day))

      ref = push(channel, "list_peers", %{})
      assert_reply ref, :ok, %{peers: []}

      ref = push(channel, "request", %{"person_id" => second.person.id})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "not_found"
    end
  end

  defp joined(scope) do
    {:ok, _reply, channel} = subscribe_and_join(person_socket(scope.person), "peer", %{})
    channel
  end

  defp person_socket(person) do
    {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person, @now)))
    socket
  end
end
