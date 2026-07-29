defmodule HospitalityComsWeb.EmployerControllerTest do
  @moduledoc """
  The employer's first two HTTP reads, and the resolver every later one copies.

  Four things are asserted here and they answer different questions.

  **That the rendered engagement names no human.** `Engagement` structs carry
  `person_id` — the globally stable cross-venue key, and a disclosure
  `CLAUDE.md` records — so the render is a field list and the assertion is an
  **exact key set** against a literal written out below. An exact set is the
  only assertion that fails when a field is *added*, which is the direction
  `person_id` arrives from. Beside it, the control: `Engagement.__schema__
  (:fields)` still contains `:person_id`, so an empty render cannot pass for a
  redacted one. Beside *that*, every list is asserted **non-empty before
  anything is asserted about it**, because the environment failure this file's
  setup exists to avoid has exactly one signature — every employer list coming
  back empty.

  **That a refusal enumerates nothing.** A venue somebody else manages, a venue
  this session is merely engaged at, an id naming nothing and a malformed id are
  one answer: `404`, one sentence, the envelope. They are compared for
  *equality* rather than matched separately, which is what proves flatness (R17).

  **That the acting grant is resolved per request, and the test that proves it
  is not the obvious one.** Revoking a grant between two HTTP requests and
  asserting the second is refused **cannot fail for the mechanism this unit
  builds**: every employer context call opens with
  `HospitalityComs.Venues.fetch_acting_grant/1`, which resolves the grant
  live-at-instant inside the transaction, so `list_engagements/1` refuses a
  stale grant id whatever the transport did. The assertion that carries R16 is
  therefore against `HospitalityComsWeb.EmployerAuth.employer_scope/2`
  **directly**, and the route-level one is labelled as end-to-end coverage.
  Both are in this file so a reader meets the distinction in one place.

  **That the venue picker does not consult suspensions.** OQ1's decision, on the
  transport. A manager who used the person-side venue-room opt-out keeps full
  authority and must keep appearing in their own picker;
  `HospitalityComs.EngagementsTest` carries the context half with its control.

  ## Why this file is not sandboxed

  `HospitalityComsWeb.RoomControllerTest`'s reason, and here it is mandatory
  rather than stylistic: an employer surface reads through
  `HospitalityComs.EmployerRepo` by definition, and the bridge it reads is
  written through `HospitalityComs.Repo`. Under the sandbox those are two
  transactions that cannot see each other's rows, so every list would come back
  empty and **every negative assertion in this file would pass for the wrong
  reason**. `HospitalityComsWeb.ConnCase` is the sandboxed alternative and must
  not be used here.

  The clock is pinned because a request reads it through
  `HospitalityComsWeb.PersonAuth.fetch_person_scope/2`, and the fixtures hang
  off `HospitalityComs.EngagementsFixtures.fixed_instant/0`.
  """

  use ExUnit.Case, async: false

  import HospitalityComs.EngagementsFixtures
  import Phoenix.ConnTest

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Rooms
  alias HospitalityComs.Venues
  alias HospitalityComsWeb.EmployerAuth
  alias HospitalityComsWeb.PersonAuth

  @endpoint HospitalityComsWeb.Endpoint

  @now HospitalityComs.EngagementsFixtures.fixed_instant()
  @term_ends DateTime.add(@now, 90, :day)

  # The literals R18 pins against. Written out here rather than derived from the
  # controller, because a key set read from the thing under test asserts only
  # that it equals itself.
  @venue_keys ~w(venue_id name)
  @engagement_keys ~w(engagement_id role_label starts_at ends_at)

  setup do
    real_connections()
    :ok = Clock.Offset.set(@now)
    on_exit(&Clock.Offset.reset/0)

    {:ok, conn: build_conn()}
  end

  ## The venue picker

  describe "GET /api/employer/venues" do
    test "answers the venues this session may act for, by name", %{conn: conn} do
      %{person: person, venue: venue} = manager()

      body = json_get(conn, person, "/api/employer/venues")

      assert %{"venues" => [listed]} = body
      assert listed["venue_id"] == venue.id
      assert listed["name"] == venue.name
      assert Map.keys(listed) |> Enum.sort() == Enum.sort(@venue_keys)
    end

    test "still lists a venue whose venue room this manager suspended", %{conn: conn} do
      # OQ1 on the transport. The control is the second request: the venue-room
      # list must drop the venue at the same instant, or the suspension did
      # nothing and the first assertion means nothing.
      %{person: person, venue: venue} = manager()

      {:ok, _suspension} = Rooms.suspend_venue_room(person_scope(person), venue.id)

      assert %{"venues" => [listed]} = json_get(conn, person, "/api/employer/venues")
      assert listed["venue_id"] == venue.id

      assert %{"venue_rooms" => []} = json_get(conn, person, "/api/venue-rooms")
    end

    test "answers an empty list for a person who manages nothing", %{conn: conn} do
      # AE10's server half. A refusal here would be an error page where the
      # requirement asks for one sentence.
      %{worker: worker} = manager()

      assert %{"venues" => []} = json_get(conn, worker, "/api/employer/venues")
    end
  end

  ## The venue's people

  describe "GET /api/employer/venues/:venue_id/engagements" do
    test "answers the venue's active engagements, oldest first", %{conn: conn} do
      %{person: person, venue: venue, engagement: held, worker_engagement: worker} = manager()

      assert %{"engagements" => listed} =
               json_get(conn, person, "/api/employer/venues/#{venue.id}/engagements")

      # Non-empty before anything is asserted about it. The environment failure
      # this file's setup avoids answers every one of these with `[]`.
      assert length(listed) == 2
      assert Enum.map(listed, & &1["engagement_id"]) == [held.id, worker.id]
    end

    test "renders a field list and no person id, and the schema still carries one", %{conn: conn} do
      # AE6, R7 and KTD-E4. The exact key set is what fails when a field is
      # added; the `__schema__` line beside it is what stops an empty render
      # passing for a redacted one.
      %{person: person, venue: venue, engagement: held} = manager()

      assert %{"engagements" => [listed | _rest]} =
               json_get(conn, person, "/api/employer/venues/#{venue.id}/engagements")

      assert Map.keys(listed) |> Enum.sort() == Enum.sort(@engagement_keys)
      assert listed["engagement_id"] == held.id
      assert listed["role_label"] == held.role_label
      assert listed["starts_at"] == DateTime.to_iso8601(held.starts_at)
      assert listed["ends_at"] == DateTime.to_iso8601(held.ends_at)

      assert :person_id in Engagement.__schema__(:fields)
    end

    test "refuses a venue this session is engaged at and holds no grant at", %{conn: conn} do
      # AE5. The control is the second request: the *same session*, at the venue
      # it does manage, answers `200` — so the refusal is about the grant rather
      # than about the session or the route.
      %{worker: worker, venue: venue} = manager()
      elsewhere = manager_for(worker)

      assert %{"error" => %{"code" => "not_found"}} =
               json_get(conn, worker, "/api/employer/venues/#{venue.id}/engagements", 404)

      assert %{"engagements" => [_first | _rest]} =
               json_get(conn, worker, "/api/employer/venues/#{elsewhere.id}/engagements")
    end

    test "answers an unknown venue, a malformed id and sixteen raw bytes identically",
         %{conn: conn} do
      # R17's flatness, asserted by equality rather than by three separate
      # matches. The sixteen-byte case is the one that kills the mutation:
      # delete `byte_size(id) == 36` from `EntityId.cast/1` and
      # `Ecto.UUID.cast/1` encodes sixteen raw bytes into a valid-looking id
      # naming nothing. A thirty-five-character id is *not* the same claim —
      # `cast/1` rejects it unaided — so it is not tested here as evidence.
      %{person: person} = manager()

      unknown = refusal(conn, person, Ecto.UUID.generate())
      malformed = refusal(conn, person, "not-a-uuid")
      sixteen_bytes = refusal(conn, person, "0123456789abcdef")

      assert byte_size("0123456789abcdef") == 16

      assert unknown == malformed
      assert unknown == sixteen_bytes
      assert %{"error" => %{"code" => "not_found"}} = unknown
    end

    test "leaves out a term that has not opened, and includes it once the instant passes",
         %{conn: conn} do
      # `list_engagements/1` is active-at-instant, and KTD-E5's `starts_at`
      # default rests on that being true. Pinned here so U2 inherits a checked
      # claim rather than a sentence.
      %{person: person, venue: venue, employer: employer} = manager()
      opens = DateTime.add(@now, 1, :day)
      path = "/api/employer/venues/#{venue.id}/engagements"

      later =
        engagement_fixture(employer, person_scope(person_fixture(@now)), %{
          starts_at: opens,
          ends_at: @term_ends
        })

      assert %{"engagements" => before} = json_get(conn, person, path)
      refute later.id in Enum.map(before, & &1["engagement_id"])

      :ok = Clock.Offset.set(DateTime.add(opens, 1, :hour))

      assert %{"engagements" => after_it_opens} = json_get(conn, person, path)
      assert later.id in Enum.map(after_it_opens, & &1["engagement_id"])
    end

    test "refuses once the grant has been revoked", %{conn: conn} do
      # **End-to-end coverage, not proof of re-derivation.** It cannot fail for
      # the mechanism this unit builds — see the moduledoc, and see
      # "the acting grant is resolved on every call" below for the assertion
      # that can.
      %{person: person, venue: venue, employer: employer, grant: grant} = manager()
      path = "/api/employer/venues/#{venue.id}/engagements"

      assert %{"engagements" => [_first | _rest]} = json_get(conn, person, path)

      assert {:ok, _revoked} = Venues.revoke_grant(employer, grant.id)

      assert %{"error" => %{"code" => "not_found"}} = json_get(conn, person, path, 404)
    end
  end

  ## The resolver itself

  describe "the acting grant is resolved on every call" do
    test "builds a scope carrying the venue, the grant and the person scope's instant" do
      %{person: person, venue: venue, grant: grant} = manager()
      scope = person_scope(person)

      assert {:ok, %EmployerScope{} = employer} = EmployerAuth.employer_scope(scope, venue.id)
      assert employer.venue_id == venue.id
      assert employer.grant_id == grant.id
      assert employer.now == scope.now
    end

    test "answers :no_grant once the grant is revoked, having answered :ok before" do
      # **R16's proof.** The route-level version of this cannot fail for this
      # unit's mechanism; this one can, and does — cache the grant id anywhere
      # between the two calls and the second answer stops being `:no_grant`.
      %{person: person, venue: venue, employer: employer, grant: grant} = manager()
      scope = person_scope(person)
      grant_id = grant.id

      assert {:ok, %EmployerScope{grant_id: ^grant_id}} =
               EmployerAuth.employer_scope(scope, venue.id)

      assert {:ok, _revoked} = Venues.revoke_grant(employer, grant.id)

      assert {:error, :no_grant} = EmployerAuth.employer_scope(scope, venue.id)
    end

    test "answers :no_grant for a venue this person is merely engaged at" do
      %{worker: worker, venue: venue} = manager()

      assert {:error, :no_grant} = EmployerAuth.employer_scope(person_scope(worker), venue.id)
    end
  end

  ## The session

  describe "authentication" do
    test "refuses both routes without a bearer token, and answers both with one", %{conn: conn} do
      # The second half is the control: a pipeline that refused everything would
      # satisfy the first alone.
      %{person: person, venue: venue} = manager()

      paths = [
        "/api/employer/venues",
        "/api/employer/venues/#{venue.id}/engagements"
      ]

      for path <- paths do
        assert %{"error" => %{"code" => "unauthorized"}} =
                 conn |> get(path) |> json_response(401)

        assert conn |> with_session(person) |> get(path) |> json_response(200)
      end
    end
  end

  ## Helpers

  defp json_get(conn, person, path, status \\ 200) do
    conn |> with_session(person) |> get(path) |> json_response(status)
  end

  defp refusal(conn, person, venue_id) do
    json_get(conn, person, "/api/employer/venues/#{venue_id}/engagements", 404)
  end

  defp with_session(conn, person) do
    token =
      person
      |> PersonScope.for_person(@now)
      |> Accounts.generate_person_session_token()
      |> PersonAuth.encode_token()

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp person_scope(person), do: PersonScope.for_person(person, @now)

  # A venue with two live grants — the founding one stays so that
  # `Venues.revoke_grant/2` has a survivor to permit a revocation against — plus
  # a manager holding the second and an ordinary worker holding none.
  # `employer_venue_channel_test.exs`'s shape, which is the other file that
  # needs a revocable manager.
  defp manager do
    {employer, creation} = scoped_venue_fixture(@now)
    manager = person_fixture(@now)
    worker = person_fixture(@now)

    {:ok, held} = Venues.issue_grant(employer)

    # The two terms open an hour apart so that "oldest first" is a total order
    # rather than a coin toss: `Records.oldest_first/1` breaks ties on `id`,
    # which is random on a `binary_id` schema.
    engagement =
      engagement_fixture(employer, person_scope(manager), %{
        starts_at: DateTime.add(@now, -1, :hour),
        ends_at: @term_ends,
        grant_id: held.id
      })

    worker_engagement =
      engagement_fixture(employer, person_scope(worker), %{
        starts_at: @now,
        ends_at: @term_ends
      })

    %{
      venue: creation.venue,
      employer: employer,
      grant: held,
      person: manager,
      worker: worker,
      engagement: engagement,
      worker_engagement: worker_engagement
    }
  end

  # A second venue the given person does manage, so that a refusal at the first
  # can be shown to be about the grant rather than about the session.
  defp manager_for(person) do
    {employer, creation} = scoped_venue_fixture(@now)

    engagement_fixture(employer, person_scope(person), %{
      starts_at: @now,
      ends_at: @term_ends,
      grant_id: creation.grant.id
    })

    creation.venue
  end
end
