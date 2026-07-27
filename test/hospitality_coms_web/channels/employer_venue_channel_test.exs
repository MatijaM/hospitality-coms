defmodule HospitalityComsWeb.EmployerVenueChannelTest do
  @moduledoc """
  The employer's half of KTD8, which nothing exercised.

  `HospitalityComsWeb.RevocationTest` proves the worker's side in both
  directions: the refused rejoin, and the control that the same socket still
  reaches the other venue. The employer's side has the same shape — connect
  authenticates, `join/3` asks
  `HospitalityComs.Engagements.fetch_grant_holding_engagement/2` again — and
  until now only its happy path ran.

  Every refusal below is the same string, because the caller supplies the venue
  id: an answer that told a revoked grant apart from a venue that does not exist
  would enumerate the venues this session does not manage (AE1). The tests are
  therefore written as a set — four ways in, one answer out — rather than one
  test per cause, and the happy path sits beside them so a `join/3` that refused
  everything cannot pass them.
  """

  use HospitalityComsWeb.ChannelCase

  alias HospitalityComs.Engagements
  alias HospitalityComs.Venues
  alias HospitalityComsWeb.EmployerSocket

  @now HospitalityComs.EngagementsFixtures.fixed_instant()
  @term_ends DateTime.add(@now, 30, :day)

  @refused %{code: "unauthorized", message: "this session holds no live grant at that venue"}

  describe "joining a venue's employer surface" do
    test "succeeds for an engagement holding a live grant" do
      # The control for every refusal below.
      %{venue: venue, grant: grant, socket: socket} = manager()

      assert {:ok, reply, _channel} = subscribe_and_join(socket, topic(venue), %{})
      assert reply == %{venue_id: venue.id, grant_id: grant.id}
    end

    test "is refused for an engagement that holds no grant" do
      # A worker is engaged at the venue and holds nothing. The person socket is
      # theirs; this one is not.
      %{venue: venue} = creation = venue_fixture(@now)
      employer = employer_scope_fixture(creation, @now)
      worker = person_scope_fixture(@now)
      engagement_fixture(employer, worker, %{starts_at: @now, ends_at: @term_ends})

      assert {:error, refusal} = join(employer_socket(worker), topic(venue), %{})
      assert refusal.error == @refused
    end

    test "is refused once the grant has been revoked" do
      # The employer analogue of the refused rejoin: the socket is the one that
      # joined a moment ago, and what changed is the answer the database gives.
      # `revoke_grant/2` refuses a venue's last live grant, so the venue is
      # founded with a second grant that survives to do the revoking.
      %{venue: venue, employer: employer, grant: grant, socket: socket} = manager()

      assert {:ok, _reply, _channel} = subscribe_and_join(socket, topic(venue), %{})

      assert {:ok, _revoked} = Venues.revoke_grant(employer, grant.id)

      assert {:error, refusal} = join(socket, topic(venue), %{})
      assert refusal.error == @refused
    end

    test "is refused once the engagement has ended, with the grant still live" do
      # The grant is untouched — what ended is the bridge row that made this
      # human its holder. Both halves are asked, so neither can carry the
      # refusal on its own.
      world = manager()

      %{venue: venue, employer: employer, engagement: engagement, grant: grant, socket: socket} =
        world

      # A second holder, so ending this one is not `end_engagement/2` refusing
      # to orphan the venue (R22, KTD17) — that refusal is U5's and is asserted
      # there.
      engagement_fixture(employer, person_scope_fixture(@now), %{
        starts_at: @now,
        ends_at: @term_ends,
        grant_id: world.founding_grant.id
      })

      assert {:ok, _reply, _channel} = subscribe_and_join(socket, topic(venue), %{})

      assert {:ok, _ended} = Engagements.end_engagement(employer, engagement.id)
      assert {:ok, live} = Venues.list_grants(employer)
      assert grant.id in Enum.map(live, & &1.id)

      assert {:error, refusal} = join(socket, topic(venue), %{})
      assert refusal.error == @refused
    end

    test "is refused with no write at all, once the term's upper bound passes" do
      # The same refusal reached by moving the clock rather than by ending
      # anything: derived, with no job having run.
      %{venue: venue, socket: socket} = manager(ends_at: DateTime.add(@now, 1, :hour))

      assert {:ok, _reply, _channel} = subscribe_and_join(socket, topic(venue), %{})

      at(DateTime.add(@now, 2, :hour))

      assert {:error, refusal} = join(socket, topic(venue), %{})
      assert refusal.error == @refused
    end

    test "is refused for a venue this session manages nothing at" do
      %{socket: socket} = manager()
      %{venue: other_venue} = venue_fixture(@now)

      assert {:error, refusal} = join(socket, topic(other_venue), %{})
      assert refusal.error == @refused
    end

    test "gives another venue's grant no purchase on this one" do
      # A manager at venue A joining venue B. The venue is taken from the topic
      # and the grant is resolved against *that* venue, so holding one elsewhere
      # answers nothing here.
      %{socket: socket} = manager()
      %{venue: elsewhere} = other = venue_fixture(@now)
      other_employer = employer_scope_fixture(other, @now)
      stranger = person_scope_fixture(@now)

      engagement_fixture(other_employer, stranger, %{
        starts_at: @now,
        ends_at: @term_ends,
        grant_id: other.grant.id
      })

      assert {:error, refusal} = join(socket, topic(elsewhere), %{})
      assert refusal.error == @refused

      # And the holder of that venue's grant does reach it, so the refusal above
      # is about this session rather than about the venue.
      assert {:ok, _reply, _channel} =
               subscribe_and_join(employer_socket(stranger), topic(elsewhere), %{})
    end

    test "gives a topic suffix that is not a uuid the identical refusal" do
      # Two ways this crashed rather than refusing: the id reached Ecto's query
      # builder and raised `Ecto.Query.CastError`, and
      # `EmployerScope.for_grant/3` raises `ArgumentError` on anything that is
      # not a canonical uuid. Both are now the venue-does-not-exist answer.
      %{socket: socket} = manager()

      for suffix <- ["", "nope", "not-a-uuid", String.duplicate("x", 36)] do
        assert {:error, refusal} = join(socket, "employer_venue:" <> suffix, %{})
        assert refusal.error == @refused
      end
    end

    test "answers an event it does not handle rather than crashing on it" do
      # This channel exports no `handle_in/3` for U9 to grow, so without a
      # terminal clause every event a client invents is an
      # `UndefinedFunctionError`.
      %{venue: venue, socket: socket} = manager()
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(venue), %{})

      ref = push(channel, "list_engagements", %{})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "bad_request"

      assert Process.alive?(channel.channel_pid)
    end
  end

  ## Fixtures

  defp topic(venue), do: "employer_venue:" <> venue.id

  # A venue with two live grants: the founding one, which stays so that
  # `Venues.revoke_grant/2` has a survivor to permit revocation against, and a
  # second one the joining session holds.
  defp manager(opts \\ []) do
    %{venue: venue, grant: founding} = creation = venue_fixture(@now)
    employer = employer_scope_fixture(creation, @now)
    person = person_scope_fixture(@now)

    {:ok, held} = Venues.issue_grant(employer)

    engagement =
      engagement_fixture(employer, person, %{
        starts_at: @now,
        ends_at: Keyword.get(opts, :ends_at, @term_ends),
        grant_id: held.id
      })

    %{
      venue: venue,
      employer: employer,
      founding_grant: founding,
      grant: held,
      person: person,
      engagement: engagement,
      socket: employer_socket(person)
    }
  end

  defp employer_socket(person) do
    {:ok, socket} = connect(EmployerSocket, %{}, auth(session_token(person.person, @now)))
    socket
  end
end
