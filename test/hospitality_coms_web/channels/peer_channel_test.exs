defmodule HospitalityComsWeb.PeerChannelTest do
  @moduledoc """
  What the peer topic does today, which is join and answer.

  The conversation events are U8's. What U7 owes is the topic itself — KTD9's
  claim about two routing tables is vacuous unless both have entries, so
  `HospitalityComsWeb.SocketsTest` asserts the join works as the control for the
  employer socket's refusal.

  What is asserted *here* is the thing that has nothing to do with U8: a channel
  exporting no `handle_in/3` at all is dispatched to unconditionally by
  `Phoenix.Channel.Server`, so every event it receives is an
  `UndefinedFunctionError` and every event a client can invent is a crash. The
  terminal clause is what U8 will add its events in front of.
  """

  use HospitalityComsWeb.ChannelCase

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
  end

  defp person_socket(person) do
    {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person, @now)))
    socket
  end
end
