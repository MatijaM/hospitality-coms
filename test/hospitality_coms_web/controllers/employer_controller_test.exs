defmodule HospitalityComsWeb.EmployerControllerTest do
  @moduledoc """
  The employer's HTTP surface: two reads, the offer that starts the handshake,
  and the resolver every later route copies.

  Five things are asserted here and they answer different questions.

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

  **That an offer discloses its code once and its digest never**, that its three
  instants default from the request's instant, and that the fourteen-day bound
  on a code's life is exercised **from both sides**. A bound tested from one
  side is satisfied by no bound at all. The digest has the same two-pin shape
  `person_id` has — an exact key set, plus `Invitation.__schema__(:fields)`
  beside it — and one more that nothing else here needs: the returned code is
  hashed and compared against the stored digest, because "the response carries a
  plaintext code" and "the response carries a string" are otherwise the same
  green.

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
  import HospitalityComs.RoomsFixtures, except: [fixed_instant: 0]
  import Phoenix.ConnTest

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Invitation
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rosters.RosterEntry
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.ShiftType
  alias HospitalityComsWeb.EmployerAuth
  alias HospitalityComsWeb.PersonAuth

  @endpoint HospitalityComsWeb.Endpoint

  @now HospitalityComs.EngagementsFixtures.fixed_instant()
  @term_ends DateTime.add(@now, 90, :day)
  @an_hour_on DateTime.add(@now, 1, :hour)

  # A shift that opens an hour from `@now` and runs eight hours, which is the
  # shape `rooms_test.exs` uses for the same reason: it is inside every term
  # these fixtures build.
  @shift_starts DateTime.add(@now, 1, :hour)
  @shift_ends DateTime.add(@now, 9, :hour)

  # Every instant column in `invitations` is second-precision, so a response
  # compared against a *computed* value has to be compared against a truncated
  # one. The reads above compare against values read back off a struct and never
  # meet this.
  @issued_at DateTime.truncate(@now, :second)

  # The literals R18 pins against. Written out here rather than derived from the
  # controller, because a key set read from the thing under test asserts only
  # that it equals itself.
  @venue_keys ~w(venue_id name)
  @engagement_keys ~w(engagement_id role_label starts_at ends_at)
  @issued_keys ~w(invitation claim_code)
  @invitation_keys ~w(invitation_id role_label starts_at ends_at code_expires_at)
  @shift_type_keys ~w(shift_type_id name grace_period_minutes)
  @shift_room_keys ~w(shift_room_id venue_id shift_type_name starts_at ends_at closes_at)
  @shift_room_page_keys ~w(shift_rooms complete)
  @roster_entry_keys ~w(engagement_id role_label joined_at)

  # KTD-E5's three durations and the bound they sit inside, written out here
  # rather than read from `HospitalityComsWeb.EmployerController`'s attributes
  # or from `Invitation.max_code_validity_in_days/0`. A test that reads the
  # constant it pins asserts only that the constant equals itself — and issue
  # #42 is a live sweep of constant pairs held together by prose, of which "the
  # default is inside the bound" would be one more.
  #
  # `engagements_test.exs` cannot do this: its both-sides tests derive their
  # input from `max_code_validity_in_days/0` and therefore move with it, which
  # that function's own docstring says.
  @default_term_in_days 90
  @default_code_validity_in_days 7
  @code_validity_bound_in_days 14

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
      # matches.
      #
      # **What each id proves here, measured rather than assumed.** The
      # *malformed* one is what kills the mutation: without
      # `HospitalityComsWeb.EntityId.cast/1` in front of the resolver it reaches
      # Ecto's query builder and raises `Ecto.Query.CastError`, so Phoenix
      # answers `500` and a caller can tell a malformed id from an unknown one
      # by the status — AE1 lost at the one place the id comes from outside.
      #
      # The **sixteen-byte** one is carried as input-class coverage and **is not
      # evidence for `byte_size(id) == 36`** on this route, contrary to what a
      # reading of `room_controller_test.exs` would suggest. Measured: dropping
      # that guard kills nothing in this file. Both branches converge here —
      # `Ecto.UUID.cast/1` alone encodes sixteen raw bytes into a valid-looking
      # id, which then names no venue, which is the same `404` with the same
      # body. That is R17 working, not a hole. The guard *is* observable on
      # `GET /api/venues/:venue_id/shift-rooms`, which answers `200 []` for a
      # castable unknown id and `404` for an uncastable one, and
      # `room_controller_test.exs` is where it is pinned.
      #
      # A thirty-five-character id would prove less still — `Ecto.UUID.cast/1`
      # rejects it unaided — so it is not here at all.
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

  ## The offer

  describe "POST /api/employer/venues/:venue_id/invitations" do
    test "issues an offer from a role label alone and returns the code once", %{conn: conn} do
      # AE1, R1, R3. The exact key sets are what fail when a field is *added*,
      # which is the direction `claim_code_digest` would arrive from; the
      # `__schema__` line beside them is what stops an empty render passing for
      # a redacted one.
      %{person: person, venue: venue} = manager()

      body = issue(conn, person, venue, %{"role_label" => "Runner"})

      assert body |> Map.keys() |> Enum.sort() == Enum.sort(@issued_keys)
      assert %{"invitation" => invitation, "claim_code" => code} = body
      assert invitation |> Map.keys() |> Enum.sort() == Enum.sort(@invitation_keys)
      assert invitation["role_label"] == "Runner"
      assert is_binary(code) and code != ""

      assert :claim_code_digest in Invitation.__schema__(:fields)
    end

    test "returns the credential itself, and the row keeps only its digest", %{conn: conn} do
      # The pin nothing else provides. An exact key set says a `claim_code` key
      # exists; only this says the value in it is the thing that redeems the
      # offer, and that what was stored is not.
      %{person: person, venue: venue} = manager()

      %{"invitation" => invitation, "claim_code" => code} =
        issue(conn, person, venue, %{"role_label" => "Runner"})

      row = Repo.get!(Invitation, invitation["invitation_id"])

      assert row.claim_code_digest == Invitation.digest(code)
      refute row.claim_code_digest == code
    end

    test "defaults the three instants from the request's instant", %{conn: conn} do
      # KTD-E5. A crude form cannot ask for three date-times and a client that
      # computed them would be a second clock — `Clock.Offset` moves this
      # server's instant and would not move a browser's.
      %{person: person, venue: venue} = manager()

      %{"invitation" => invitation} = issue(conn, person, venue, %{"role_label" => "Runner"})

      assert invitation["starts_at"] == DateTime.to_iso8601(@issued_at)

      assert invitation["ends_at"] ==
               DateTime.to_iso8601(DateTime.add(@issued_at, @default_term_in_days, :day))

      assert invitation["code_expires_at"] ==
               DateTime.to_iso8601(DateTime.add(@issued_at, @default_code_validity_in_days, :day))
    end

    test "puts the defaulted expiry strictly inside the bound and strictly after issue",
         %{conn: conn} do
      # The seven and the fourteen are independent constants (issue #42), and
      # this is the only relationship asserted between them: a checkable one
      # rather than a sentence in a moduledoc.
      %{person: person, venue: venue} = manager()

      %{"invitation" => invitation} = issue(conn, person, venue, %{"role_label" => "Runner"})

      {:ok, expires_at, 0} = DateTime.from_iso8601(invitation["code_expires_at"])
      bound = DateTime.add(@issued_at, @code_validity_bound_in_days, :day)

      assert DateTime.compare(expires_at, @issued_at) == :gt
      assert DateTime.compare(expires_at, bound) == :lt
    end

    test "lets the body override all three instants", %{conn: conn} do
      %{person: person, venue: venue} = manager()

      starts_at = DateTime.add(@issued_at, 2, :day)
      ends_at = DateTime.add(@issued_at, 20, :day)
      code_expires_at = DateTime.add(@issued_at, 3, :day)

      %{"invitation" => invitation} =
        issue(conn, person, venue, %{
          "role_label" => "Runner",
          "starts_at" => DateTime.to_iso8601(starts_at),
          "ends_at" => DateTime.to_iso8601(ends_at),
          "code_expires_at" => DateTime.to_iso8601(code_expires_at)
        })

      assert invitation["starts_at"] == DateTime.to_iso8601(starts_at)
      assert invitation["ends_at"] == DateTime.to_iso8601(ends_at)
      assert invitation["code_expires_at"] == DateTime.to_iso8601(code_expires_at)
    end

    test "accepts an expiry exactly fourteen days out and refuses one second later",
         %{conn: conn} do
      # **Both directions**, which is the point: a bound exercised from one side
      # only is `docs/solutions/test-failures/tests-that-certify-nothing.md`'s
      # shape, and a route with no bound at all passes the accepting half.
      #
      # This pins the **changeset's** bound. `invitations_code_expiry_within_bound`
      # is a separate declaration of the same number, item 3 of issue #42, and is
      # `constant_agreement_test.exs`'s; nothing here covers it.
      %{person: person, venue: venue} = manager()
      bound = DateTime.add(@issued_at, @code_validity_bound_in_days, :day)

      %{"invitation" => accepted} =
        issue(conn, person, venue, %{
          "role_label" => "Runner",
          "code_expires_at" => DateTime.to_iso8601(bound)
        })

      assert accepted["code_expires_at"] == DateTime.to_iso8601(bound)

      refused =
        refused_offer(conn, person, venue, %{
          "role_label" => "Runner",
          "code_expires_at" => DateTime.to_iso8601(DateTime.add(bound, 1, :second))
        })

      assert %{"error" => %{"code" => "unprocessable_entity", "fields" => fields}} = refused

      assert "must be within #{@code_validity_bound_in_days} day(s) of issue" in fields[
               "code_expires_at"
             ]
    end

    test "refuses a term whose end does not follow its start", %{conn: conn} do
      %{person: person, venue: venue} = manager()

      refused =
        refused_offer(conn, person, venue, %{
          "role_label" => "Runner",
          "starts_at" => DateTime.to_iso8601(DateTime.add(@issued_at, 2, :day)),
          "ends_at" => DateTime.to_iso8601(@issued_at)
        })

      assert %{"error" => %{"code" => "unprocessable_entity", "fields" => fields}} = refused
      assert "must be after the start" in fields["ends_at"]
    end

    test "refuses an offer naming no role", %{conn: conn} do
      %{person: person, venue: venue} = manager()

      refused = refused_offer(conn, person, venue, %{})

      assert %{"error" => %{"code" => "unprocessable_entity", "fields" => fields}} = refused
      assert "can't be blank" in fields["role_label"]
    end

    test "confers nothing when the body names a grant", %{conn: conn} do
      # The crude form offers no way to make another manager, and a field the
      # form does not offer must not be castable from the body anyway. Four
      # fields are taken off it and `grant_id` is not one of them.
      %{person: person, venue: venue, employer: employer, grant: grant} = manager()

      %{"invitation" => invitation} =
        issue(conn, person, venue, %{"role_label" => "Runner", "grant_id" => grant.id})

      assert Repo.get!(Invitation, invitation["invitation_id"]).grant_id == nil

      # Control: the field is real and this grant is conferrable, so the `nil`
      # above is the route declining to cast it rather than conferral being
      # broken everywhere.
      %{invitation: conferred} = invitation_fixture(employer, %{grant_id: grant.id})
      assert conferred.grant_id == grant.id
    end

    test "answers a venue it cannot act for and a malformed id identically", %{conn: conn} do
      # R17 on a write route, asserted by equality rather than by two matches.
      # The control is the third request: the *same session*, at the venue it
      # does manage, answers `201`.
      %{worker: worker, venue: venue} = manager()
      elsewhere = manager_for(worker)
      offer = %{"role_label" => "Runner"}

      refused = refused_offer(conn, worker, venue, offer, 404)

      malformed =
        json_post(conn, worker, "/api/employer/venues/not-a-uuid/invitations", offer, 404)

      assert refused == malformed
      assert %{"error" => %{"code" => "not_found"}} = refused

      assert %{"invitation" => _issued} = issue(conn, worker, elsewhere, offer)
    end

    test "refuses without a bearer token, and answers with one", %{conn: conn} do
      # The second half is the control: a route that refused everything would
      # satisfy the first alone.
      %{person: person, venue: venue} = manager()
      path = "/api/employer/venues/#{venue.id}/invitations"

      assert %{"error" => %{"code" => "unauthorized"}} =
               conn |> post(path, %{"role_label" => "Runner"}) |> json_response(401)

      assert %{"invitation" => _issued} = issue(conn, person, venue, %{"role_label" => "Runner"})
    end
  end

  ## Shift types

  describe "GET /api/employer/venues/:venue_id/shift-types" do
    test "answers the venue's shift types oldest first, as a field list", %{conn: conn} do
      # The two types are created an hour apart on purpose: `ShiftType.of_venue/1`
      # breaks ties on `id`, which is random on a `binary_id` schema, so two
      # types stamped in the same second would order by coin toss.
      %{person: person, venue: venue, employer: employer} = manager()
      early = shift_type_fixture(employer, 45)
      late = shift_type_fixture(employer_at(employer, @an_hour_on), 0)

      body = json_get(conn, person, "/api/employer/venues/#{venue.id}/shift-types")

      assert %{"shift_types" => [first, second]} = body
      assert Enum.map([first, second], & &1["shift_type_id"]) == [early.id, late.id]

      assert first |> Map.keys() |> Enum.sort() == Enum.sort(@shift_type_keys)
      assert first["name"] == early.name
      assert first["grace_period_minutes"] == 45
      assert second["grace_period_minutes"] == 0

      # Control: the struct carries a field the render leaves out, so an empty
      # render cannot pass for a projected one.
      assert :venue_id in ShiftType.__schema__(:fields)
    end

    test "answers a venue with no shift types with an empty list, not a refusal", %{conn: conn} do
      # Having configured nothing is not an error. It does mean no shift can be
      # created there, which the seed's second venue is an example of.
      %{person: person, venue: venue} = manager()

      assert %{"shift_types" => []} =
               json_get(conn, person, "/api/employer/venues/#{venue.id}/shift-types")
    end
  end

  ## Creating a shift

  describe "POST /api/employer/venues/:venue_id/shift-rooms" do
    test "creates the shift and takes the grace off the type, not off the body", %{conn: conn} do
      # **The control is inside the request**: the body asks for two hours of
      # grace and the type allows forty-five minutes. Against a body echoing the
      # type's own value the "not castable" claim would be untested.
      #
      # The `venue_id` in the body cannot be tested the same way — Phoenix
      # merges path parameters over body ones, so the path's venue wins before
      # the controller sees it. What is asserted instead is that the stored row
      # carries the venue the *type* belongs to.
      %{person: person, venue: venue, employer: employer} = manager()
      shift_type = shift_type_fixture(employer, 45)

      body =
        create_shift(conn, person, venue, %{
          "shift_type_id" => shift_type.id,
          "starts_at" => iso(@shift_starts),
          "ends_at" => iso(@shift_ends),
          "grace_period_minutes" => 120,
          "venue_id" => Ecto.UUID.generate()
        })

      assert body |> Map.keys() |> Enum.sort() == ["shift_room"]
      assert %{"shift_room" => room} = body
      assert room |> Map.keys() |> Enum.sort() == Enum.sort(@shift_room_keys)
      assert room["shift_type_name"] == shift_type.name
      assert room["venue_id"] == venue.id
      assert room["starts_at"] == iso(@shift_starts)
      assert room["closes_at"] == iso(DateTime.add(@shift_ends, 45, :minute))

      stored = Repo.get!(ShiftRoom, room["shift_room_id"])
      assert stored.grace_period_minutes == 45
      assert stored.venue_id == venue.id

      # Control: the struct carries two fields the render leaves out.
      assert :grace_period_minutes in ShiftRoom.__schema__(:fields)
      assert :shift_type_id in ShiftRoom.__schema__(:fields)
    end

    test "refuses a term whose end does not follow its start", %{conn: conn} do
      %{person: person, venue: venue, employer: employer} = manager()
      shift_type = shift_type_fixture(employer)

      refused =
        json_post(
          conn,
          person,
          "/api/employer/venues/#{venue.id}/shift-rooms",
          %{
            "shift_type_id" => shift_type.id,
            "starts_at" => iso(@shift_ends),
            "ends_at" => iso(@shift_starts)
          },
          422
        )

      assert %{"error" => %{"code" => "unprocessable_entity", "fields" => fields}} = refused
      assert "must be after the shift starts" in fields["ends_at"]
    end

    test "answers another venue's type, an unknown id and a malformed id identically",
         %{conn: conn} do
      # **AE7 on the create route**, asserted by equality rather than by three
      # separate matches. The malformed one is what kills the mutation: handed
      # to the context uncast it reaches Ecto's query builder and raises, so
      # Phoenix answers `500` and a caller tells malformed from unknown by the
      # status.
      %{person: person, venue: venue, employer: employer} = manager()
      {other_employer, _other} = scoped_venue_fixture(@now)
      elsewhere = shift_type_fixture(other_employer)

      theirs = refused_shift(conn, person, venue, elsewhere.id)
      unknown = refused_shift(conn, person, venue, Ecto.UUID.generate())
      malformed = refused_shift(conn, person, venue, "not-a-uuid")

      assert theirs == unknown
      assert theirs == malformed
      assert %{"error" => %{"code" => "not_found"}} = theirs

      # Control: a type this venue does run is accepted, so a route refusing
      # everything cannot pass the three above.
      mine = shift_type_fixture(employer)
      assert %{"shift_room" => _created} = create_shift_of(conn, person, venue, mine)
    end

    test "answers a body naming no shift type with bad_request, not a refusal", %{conn: conn} do
      # A client that did not name the thing is a client bug, and the answer
      # says so. The inequality is the assertion: it is what proves the two
      # causes are not one answer.
      %{person: person, venue: venue} = manager()

      missing =
        json_post(
          conn,
          person,
          "/api/employer/venues/#{venue.id}/shift-rooms",
          %{"starts_at" => iso(@shift_starts), "ends_at" => iso(@shift_ends)},
          400
        )

      assert %{"error" => %{"code" => "bad_request"}} = missing
      refute missing == refused_shift(conn, person, venue, Ecto.UUID.generate())
    end
  end

  ## The venue's shifts

  describe "GET /api/employer/venues/:venue_id/shift-rooms" do
    test "answers the most recent page, and the page is not the oldest shifts", %{conn: conn} do
      # **KTD-E6 on the wire.** The count alone certifies nothing: this list is
      # displayed earliest first, and a limit applied to *that* returns the
      # venue's oldest rooms, satisfies the count, and hides the shift the
      # manager just created — F2's payoff. So the rooms are named.
      #
      # **The fixture is `bound + 2`.** At `bound + 1` the read's own probe
      # selects every row the venue has, so the descending scan and an ascending
      # one return the same set and the direction is unobservable — measured,
      # and the reason is written out in `HospitalityComs.RoomsTest`.
      %{person: person, venue: venue, employer: employer} = manager()
      shift_type = shift_type_fixture(employer)
      limit = Rooms.recent_shift_room_limit()
      ids = shift_rooms_fixture(employer, shift_type, limit + 2, @shift_starts)

      body = json_get(conn, person, "/api/employer/venues/#{venue.id}/shift-rooms")

      assert body |> Map.keys() |> Enum.sort() == Enum.sort(@shift_room_page_keys)
      assert %{"shift_rooms" => listed, "complete" => false} = body
      assert length(listed) == limit

      read = Enum.map(listed, & &1["shift_room_id"])
      refute List.first(ids) in read
      assert List.last(ids) in read
    end

    test "renders each shift with its type's name and a pinned key set", %{conn: conn} do
      %{person: person, venue: venue, employer: employer} = manager()
      shift_type = shift_type_fixture(employer, 45)
      shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)

      assert %{"shift_rooms" => [listed]} =
               json_get(conn, person, "/api/employer/venues/#{venue.id}/shift-rooms")

      assert listed |> Map.keys() |> Enum.sort() == Enum.sort(@shift_room_keys)
      assert listed["shift_type_name"] == shift_type.name
      assert listed["starts_at"] == iso(@shift_starts)
      assert listed["closes_at"] == iso(DateTime.add(@shift_ends, 45, :minute))
    end

    test "lifts the bound for extent=all, which is the control for it existing", %{conn: conn} do
      # A limit applied to `all` too would satisfy every assertion above and
      # make "load them all" a lie.
      %{person: person, venue: venue, employer: employer} = manager()
      shift_type = shift_type_fixture(employer)
      limit = Rooms.recent_shift_room_limit()
      ids = shift_rooms_fixture(employer, shift_type, limit + 2, @shift_starts)

      assert %{"shift_rooms" => listed, "complete" => true} =
               json_get(conn, person, "/api/employer/venues/#{venue.id}/shift-rooms?extent=all")

      assert Enum.map(listed, & &1["shift_room_id"]) == ids
    end

    test "calls a short list complete, which is the other direction of the flag", %{conn: conn} do
      # A `complete` hard-coded either way passes one of the two.
      %{person: person, venue: venue, employer: employer} = manager()
      shift_type = shift_type_fixture(employer)
      count = Rooms.recent_shift_room_limit() - 1
      shift_rooms_fixture(employer, shift_type, count, @shift_starts)

      assert %{"shift_rooms" => listed, "complete" => true} =
               json_get(conn, person, "/api/employer/venues/#{venue.id}/shift-rooms")

      assert length(listed) == count
    end

    test "answers an extent it does not know with bad_request, not a refusal", %{conn: conn} do
      # A silent fall back to `recent` would satisfy every other row in this
      # block. The inequality is what proves the two answers are different.
      %{person: person, venue: venue} = manager()
      path = "/api/employer/venues/#{venue.id}/shift-rooms"

      bad_extent = json_get(conn, person, path <> "?extent=nonsense", 400)
      assert %{"error" => %{"code" => "bad_request"}} = bad_extent

      unknown_venue =
        json_get(conn, person, "/api/employer/venues/#{Ecto.UUID.generate()}/shift-rooms", 404)

      refute bad_extent == unknown_venue
    end
  end

  ## The roster

  describe "the roster routes" do
    test "puts an engagement on a shift and then lists it, with its role label", %{conn: conn} do
      # R12 and R13. The list is asserted non-empty before anything is asserted
      # about it, because the environment failure this file's setup avoids
      # answers every employer list with `[]`.
      %{person: person, venue: venue, employer: employer, worker_engagement: held} = manager()
      room = shift_room(employer)

      created = add_to_roster(conn, person, venue, room, held.id)

      assert created |> Map.keys() |> Enum.sort() == ["roster_entry"]
      assert %{"roster_entry" => entry} = created
      assert entry |> Map.keys() |> Enum.sort() == Enum.sort(@roster_entry_keys)
      assert entry["engagement_id"] == held.id
      assert entry["role_label"] == held.role_label
      assert entry["joined_at"] == DateTime.to_iso8601(@now)

      assert %{"roster" => [listed]} = read_roster(conn, person, venue, room)
      assert listed |> Map.keys() |> Enum.sort() == Enum.sort(@roster_entry_keys)
      assert listed["engagement_id"] == held.id
      assert listed["role_label"] == held.role_label

      # Control: the engagement the label came off still carries the key this
      # render withholds, so an empty render cannot pass for a projected one.
      assert :person_id in Engagement.__schema__(:fields)
    end

    test "labels a starter whose term has not opened, which the people list cannot", %{conn: conn} do
      # **KTD-E10 end to end, and the second half is the control.** A hire whose
      # term opens tomorrow is rosterable today and is absent from the venue's
      # people list at this instant — so a client joining the roster against
      # that list would render this row as a bare id. The preload is what
      # answers R13 for every row the roster can hold.
      %{person: person, venue: venue, employer: employer} = manager()
      opens = DateTime.add(@now, 1, :day)

      starter =
        engagement_fixture(employer, person_scope(person_fixture(@now)), %{
          starts_at: opens,
          ends_at: @term_ends
        })

      room = shift_room(employer)

      assert %{"roster_entry" => entry} = add_to_roster(conn, person, venue, room, starter.id)
      assert entry["role_label"] == starter.role_label

      assert %{"roster" => [listed]} = read_roster(conn, person, venue, room)
      assert listed["engagement_id"] == starter.id
      assert listed["role_label"] == starter.role_label

      assert %{"engagements" => people} =
               json_get(conn, person, "/api/employer/venues/#{venue.id}/engagements")

      assert people != []
      refute starter.id in Enum.map(people, & &1["engagement_id"])
    end

    test "refuses a second rostering and leaves the roster holding one entry", %{conn: conn} do
      # AE8. The count is the requirement; the status and its flatness are the
      # test below.
      %{person: person, venue: venue, employer: employer, worker_engagement: held} = manager()
      room = shift_room(employer)

      assert %{"roster_entry" => _first} = add_to_roster(conn, person, venue, room, held.id)
      assert %{"error" => _refused} = add_to_roster(conn, person, venue, room, held.id, 404)

      assert %{"roster" => [_one]} = read_roster(conn, person, venue, room)
    end

    test "answers all four of R15's refusals identically", %{conn: conn} do
      # **R15 names four conditions and says the refusal does not disclose
      # which**, so four bodies are compared for equality rather than matched
      # separately. The plan's own scenario compares three and leaves
      # `:already_rostered` out; the requirement does not.
      %{person: person, venue: venue, employer: employer, worker_engagement: held} = manager()
      {other_employer, _other} = scoped_venue_fixture(@now)
      elsewhere = shift_room(other_employer)
      their_engagement = engagement_fixture(other_employer, person_scope(person_fixture(@now)))

      room = shift_room(employer)
      assert %{"roster_entry" => _first} = add_to_roster(conn, person, venue, room, held.id)

      already = add_to_roster(conn, person, venue, room, held.id, 404)
      their_room = add_to_roster(conn, person, venue, elsewhere, held.id, 404)
      their_worker = add_to_roster(conn, person, venue, room, their_engagement.id, 404)
      nobody = add_to_roster(conn, person, venue, room, Ecto.UUID.generate(), 404)
      malformed = add_to_roster(conn, person, venue, room, "not-a-uuid", 404)

      assert already == their_room
      assert already == their_worker
      assert already == nobody
      assert already == malformed
      assert %{"error" => %{"code" => "not_found"}} = already

      # Control: a rostering this session may make is accepted, so a route that
      # refused everything cannot pass the four above.
      %{engagement: mine} = manager_engagement(employer)
      assert %{"roster_entry" => _second} = add_to_roster(conn, person, venue, room, mine.id)
    end

    test "answers a body naming no engagement with bad_request, not a refusal", %{conn: conn} do
      %{person: person, venue: venue, employer: employer} = manager()
      room = shift_room(employer)
      path = "/api/employer/venues/#{venue.id}/shift-rooms/#{room.id}/roster"

      missing = json_post(conn, person, path, %{}, 400)

      assert %{"error" => %{"code" => "bad_request"}} = missing
      refute missing == add_to_roster(conn, person, venue, room, Ecto.UUID.generate(), 404)
    end

    test "removes an entry, and the row stays with an upper bound on it", %{conn: conn} do
      # **AE9, and the row assertion is the control on the status.** A route
      # that actually deleted answers `204` and empties the roster too; only the
      # surviving row with `left_at` set distinguishes closed from deleted,
      # which is the whole of KTD6b.
      %{person: person, venue: venue, employer: employer, worker_engagement: held} = manager()
      room = shift_room(employer)

      assert %{"roster_entry" => _entry} = add_to_roster(conn, person, venue, room, held.id)
      assert %{"roster" => [_one]} = read_roster(conn, person, venue, room)

      assert "" ==
               conn
               |> with_session(person)
               |> delete(roster_path(venue, room, held.id))
               |> response(204)

      assert %{"roster" => []} = read_roster(conn, person, venue, room)

      stored = Repo.get_by!(RosterEntry, shift_room_id: room.id, engagement_id: held.id)
      assert %DateTime{} = stored.left_at
    end

    test "answers an unrostered engagement and an unknown shift room identically", %{conn: conn} do
      # `remove_from_roster/3` answers `:not_rostered` for both, and the
      # transport keeps them one answer.
      %{person: person, venue: venue, employer: employer, worker_engagement: held} = manager()
      room = shift_room(employer)

      never = remove_from_roster(conn, person, venue, room.id, held.id, 404)
      no_room = remove_from_roster(conn, person, venue, Ecto.UUID.generate(), held.id, 404)
      malformed = remove_from_roster(conn, person, venue, room.id, "not-a-uuid", 404)

      assert never == no_room
      assert never == malformed
      assert %{"error" => %{"code" => "not_found"}} = never

      # Control: an entry that is there is removed, so a route refusing
      # everything cannot pass the two above.
      assert %{"roster_entry" => _entry} = add_to_roster(conn, person, venue, room, held.id)
      assert "" == remove_from_roster(conn, person, venue, room.id, held.id, 204)
    end

    test "refuses a roster read for a shift room at another venue", %{conn: conn} do
      %{person: person, venue: venue} = manager()
      {other_employer, _other} = scoped_venue_fixture(@now)
      elsewhere = shift_room(other_employer)

      assert %{"error" => %{"code" => "not_found"}} =
               read_roster(conn, person, venue, elsewhere, 404)
    end
  end

  ## Every route, twice over

  describe "the six shift and roster routes" do
    test "refuse without a bearer token, and answer with one", %{conn: conn} do
      # The second half is the control: a pipeline that refused everything would
      # satisfy the first alone.
      manager = manager()

      for {method, path, params, status} <- shift_and_roster_calls(manager) do
        assert %{"error" => %{"code" => "unauthorized"}} =
                 conn |> call(method, path, params) |> json_response(401)

        assert conn
               |> with_session(manager.person)
               |> call(method, path, params)
               |> response(status)
      end
    end

    test "refuse a session engaged at the venue but holding no grant there", %{conn: conn} do
      # R17 on all six. The control is the last line: the *same session*, at the
      # venue it does manage, is answered — so the refusal is about the grant
      # rather than about the session or the route.
      manager = manager()

      for {method, path, params, _status} <- shift_and_roster_calls(manager) do
        assert %{"error" => %{"code" => "not_found"}} =
                 conn
                 |> with_session(manager.worker)
                 |> call(method, path, params)
                 |> json_response(404)
      end

      elsewhere = manager_for(manager.worker)

      assert %{"shift_types" => []} =
               json_get(conn, manager.worker, "/api/employer/venues/#{elsewhere.id}/shift-types")
    end
  end

  ## The resolver itself

  describe "the acting grant is resolved on every call" do
    test "builds a scope carrying the venue, the grant and the person scope's instant" do
      # The instant is KTD-E1 and it is asserted behaviourally rather than by
      # reading `.credo.exs`: the clock is moved *away* from the scope's
      # instant, both still inside the term, so a resolver that read
      # `Clock.now/0` for itself would stamp the scope with a moment this
      # request never happened at — and every period comparison downstream
      # would then be answered against it.
      %{person: person, venue: venue, grant: grant} = manager()
      scope = person_scope(person)
      elsewhere_in_the_term = DateTime.add(@now, 1, :day)

      :ok = Clock.Offset.set(elsewhere_in_the_term)

      assert {:ok, %EmployerScope{} = employer} = EmployerAuth.employer_scope(scope, venue.id)
      assert employer.venue_id == venue.id
      assert employer.grant_id == grant.id
      assert employer.now == scope.now
      refute employer.now == elsewhere_in_the_term
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

  defp iso(%DateTime{} = instant), do: DateTime.to_iso8601(DateTime.truncate(instant, :second))

  defp shift_room(employer) do
    shift_type = shift_type_fixture(employer, 30)
    shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)
  end

  defp create_shift(conn, person, venue, params, status \\ 201) do
    json_post(conn, person, "/api/employer/venues/#{venue.id}/shift-rooms", params, status)
  end

  defp create_shift_of(conn, person, venue, shift_type) do
    create_shift(conn, person, venue, %{
      "shift_type_id" => shift_type.id,
      "starts_at" => iso(@shift_starts),
      "ends_at" => iso(@shift_ends)
    })
  end

  defp refused_shift(conn, person, venue, shift_type_id) do
    create_shift(
      conn,
      person,
      venue,
      %{
        "shift_type_id" => shift_type_id,
        "starts_at" => iso(@shift_starts),
        "ends_at" => iso(@shift_ends)
      },
      404
    )
  end

  defp roster_path(venue, room, engagement_id) do
    "#{roster_path(venue, room)}/#{engagement_id}"
  end

  defp roster_path(venue, room) do
    "/api/employer/venues/#{venue.id}/shift-rooms/#{room.id}/roster"
  end

  defp add_to_roster(conn, person, venue, room, engagement_id, status \\ 201) do
    json_post(conn, person, roster_path(venue, room), %{"engagement_id" => engagement_id}, status)
  end

  defp read_roster(conn, person, venue, room, status \\ 200) do
    json_get(conn, person, roster_path(venue, room), status)
  end

  defp remove_from_roster(conn, person, venue, room_id, engagement_id, status) do
    conn
    |> with_session(person)
    |> delete("/api/employer/venues/#{venue.id}/shift-rooms/#{room_id}/roster/#{engagement_id}")
    |> response(status)
    |> decoded()
  end

  defp decoded(""), do: ""
  defp decoded(body), do: Jason.decode!(body)

  # One call per route, each carrying whatever it needs to reach its action
  # rather than its guard clause, and each with the status a manager gets.
  # Written out rather than derived from the router: a table read from the
  # thing under test asserts only that it equals itself.
  defp shift_and_roster_calls(%{venue: venue, employer: employer, worker_engagement: held}) do
    room = shift_room(employer)
    shift_type = shift_type_fixture(employer)
    base = "/api/employer/venues/#{venue.id}"

    [
      {:get, "#{base}/shift-types", nil, 200},
      {:get, "#{base}/shift-rooms", nil, 200},
      {:post, "#{base}/shift-rooms",
       %{
         "shift_type_id" => shift_type.id,
         "starts_at" => iso(@shift_starts),
         "ends_at" => iso(@shift_ends)
       }, 201},
      {:get, "#{base}/shift-rooms/#{room.id}/roster", nil, 200},
      {:post, "#{base}/shift-rooms/#{room.id}/roster", %{"engagement_id" => held.id}, 201},
      {:delete, "#{base}/shift-rooms/#{room.id}/roster/#{held.id}", nil, 204}
    ]
  end

  defp call(conn, :get, path, _params), do: get(conn, path)
  defp call(conn, :delete, path, _params), do: delete(conn, path)
  defp call(conn, :post, path, params), do: post(conn, path, params)

  defp json_get(conn, person, path, status \\ 200) do
    conn |> with_session(person) |> get(path) |> json_response(status)
  end

  defp json_post(conn, person, path, params, status) do
    conn |> with_session(person) |> post(path, params) |> json_response(status)
  end

  defp issue(conn, person, venue, offer) do
    json_post(conn, person, "/api/employer/venues/#{venue.id}/invitations", offer, 201)
  end

  defp refused_offer(conn, person, venue, offer, status \\ 422) do
    json_post(conn, person, "/api/employer/venues/#{venue.id}/invitations", offer, status)
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

  # A second engagement at this venue, for a test that needs one the roster does
  # not already hold.
  defp manager_engagement(employer) do
    %{
      engagement:
        engagement_fixture(employer, person_scope(person_fixture(@now)), %{
          starts_at: @now,
          ends_at: @term_ends
        })
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
