defmodule HospitalityComs.PubSubTest do
  @moduledoc """
  The gap a repo-only analysis misses.

  U3's boundary is a statement about queries, and `subscribe` issues none. A
  process that registers itself against a peer topic is handed every message
  published there having asked the database nothing, so no privilege, no query
  backstop and no `where` clause is in a position to have an opinion. This file
  asserts the one thing that is: the scope struct in the function head.

  Every refusal below is a `FunctionClauseError` rather than an error tuple,
  deliberately. A tuple is a value somebody can ignore; a clause that does not
  exist is a call that does not return.

  Nothing here touches the database, so it is `async: true` — and every topic is
  namespaced by a generated id, because `Phoenix.PubSub` is global across async
  tests and two files broadcasting on the same literal topic would see each
  other's messages.
  """

  use ExUnit.Case, async: true

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.PubSub

  @now ~U[2026-03-01 12:00:00.000000Z]

  describe "an employer scope" do
    test "cannot subscribe to a peer topic" do
      # The one KTD9 names. An employer session reaching a peer conversation
      # through the subscription path is the failure the transport's two routing
      # tables cannot see, because no route was taken.
      scope = employer_scope()

      assert_raise FunctionClauseError, fn ->
        PubSub.subscribe(scope, {:peer, Ecto.UUID.generate()})
      end
    end

    test "cannot subscribe to a venue room, a shift room, or an engagement" do
      scope = employer_scope()

      for target <- [
            {:venue_room, Ecto.UUID.generate()},
            {:shift_room, Ecto.UUID.generate()},
            {:engagement, Ecto.UUID.generate()}
          ] do
        assert_raise FunctionClauseError, fn -> PubSub.subscribe(scope, target) end
      end
    end

    test "cannot subscribe to another venue's employer topic" do
      # The id is pinned to the scope by repeating the variable in the head, so
      # "the right kind of scope" is not the same as "this scope".
      scope = employer_scope()

      assert_raise FunctionClauseError, fn ->
        PubSub.subscribe(scope, {:employer_venue, Ecto.UUID.generate()})
      end
    end

    test "can subscribe to its own venue's employer topic" do
      # The control. Every refusal above passes against a module whose only
      # clause raises.
      scope = employer_scope()
      target = {:employer_venue, scope.venue_id}

      assert :ok = PubSub.subscribe(scope, target)
      assert delivered?(target)
    end
  end

  describe "a person scope" do
    test "cannot subscribe to an employer topic" do
      # The refusal is two-way. A one-way check reads as "employer scopes are
      # the dangerous ones", which is not what the partition says.
      scope = person_scope()

      assert_raise FunctionClauseError, fn ->
        PubSub.subscribe(scope, {:employer_venue, Ecto.UUID.generate()})
      end
    end

    test "cannot subscribe to another person's peer topic" do
      scope = person_scope()

      assert_raise FunctionClauseError, fn ->
        PubSub.subscribe(scope, {:peer, Ecto.UUID.generate()})
      end
    end

    test "can subscribe to its own peer topic" do
      scope = person_scope()
      target = {:peer, scope.person.id}

      assert :ok = PubSub.subscribe(scope, target)
      assert delivered?(target)
    end

    test "can subscribe to a room topic and to an engagement's revocation" do
      # The two targets that cannot be pinned structurally. What authorizes them
      # is the join that resolved them — see the moduledoc of
      # `HospitalityComs.PubSub` — and what this module refuses is the kind of
      # caller.
      scope = person_scope()

      for target <- [
            {:venue_room, Ecto.UUID.generate()},
            {:shift_room, Ecto.UUID.generate()},
            {:engagement, Ecto.UUID.generate()}
          ] do
        assert :ok = PubSub.subscribe(scope, target)
        assert delivered?(target)
      end
    end
  end

  describe "an anonymous person scope" do
    test "cannot subscribe to anything" do
      # A caller who has not authenticated holds no engagements and belongs to
      # no room, so there is nothing for them to be subscribed to. The clause
      # heads on `%Person{}` rather than on the struct, so nil is refused.
      scope = PersonScope.for_person(nil, @now)

      for target <- [
            {:peer, Ecto.UUID.generate()},
            {:venue_room, Ecto.UUID.generate()},
            {:shift_room, Ecto.UUID.generate()},
            {:engagement, Ecto.UUID.generate()}
          ] do
        assert_raise FunctionClauseError, fn -> PubSub.subscribe(scope, target) end
      end
    end
  end

  describe "topic/1" do
    test "names the channel topics the person socket routes" do
      # The room topics are the channel topics, which is what lets a test
      # subscribe from outside a channel and hear what a client hears.
      venue_id = Ecto.UUID.generate()
      room_id = Ecto.UUID.generate()

      assert PubSub.topic({:venue_room, venue_id}) == "venue_room:" <> venue_id
      assert PubSub.topic({:shift_room, room_id}) == "shift_room:" <> room_id
    end

    test "resolves an engagement through U5 rather than respelling it" do
      # Not a second mechanism (KTD8): the revocation topic is the one
      # `HospitalityComs.Engagements` already broadcasts on after commit.
      engagement_id = Ecto.UUID.generate()

      assert PubSub.topic({:engagement, engagement_id}) ==
               HospitalityComs.Engagements.topic(engagement_id)
    end
  end

  defp person_scope, do: scope(:person)
  defp employer_scope, do: scope(:employer)

  # Through a map for the reason `HospitalityComs.BoundaryTest` builds its
  # scopes this way: every call below is deliberately a pairing the type checker
  # is right to reject, and a test whose subject is the rejection should not have
  # to carry the warning for making it.
  defp scope(kind) do
    Map.fetch!(
      %{
        person: PersonScope.for_person(%Person{id: Ecto.UUID.generate()}, @now),
        employer: EmployerScope.for_grant(Ecto.UUID.generate(), Ecto.UUID.generate(), @now)
      },
      kind
    )
  end

  defp delivered?(target) do
    message = {:ping, System.unique_integer([:positive])}
    :ok = Phoenix.PubSub.broadcast(HospitalityComs.PubSub, PubSub.topic(target), message)

    receive do
      ^message -> true
    after
      500 -> false
    end
  end
end
