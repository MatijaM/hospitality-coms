defmodule HospitalityComsWeb.ClaimControllerTest do
  @moduledoc """
  The worker's half of the handshake: one route, six ways it can be refused, and
  three fixtures that need two claimants.

  ## Two claimants, and it is the substance of this file rather than a detail

  Three of the tests below take two claimants, for one reason: every offer this
  file issues carries the same venue and the same defaulted term, so a second
  engagement *for the same person* collides on `engagements_no_overlap` before
  anything under test is reached. The one-person versions go wrong in two
  different ways, both measured — AE2's is **red against a correct tree**, and
  AE3's and AE4's are **green for a reason they do not name**.

    * **AE3 — one code, two claimants.** The guard is `claim_invitation/2`'s
      conditional `UPDATE`, the first step of its `Ecto.Multi`. With one person
      claiming twice, *three* mechanisms refuse the second call — the consume,
      the unique index on `engagements.invitation_id`, and
      `engagements_no_overlap` — and the test cannot say which one it exercised.
      Two claimants take the exclusion constraint out of the picture, so a green
      test attributes the refusal to at most two things rather than three.

      **The count is not what carries this, and the measurement says so.** With
      the consume's `claimed_at IS NULL` clause deleted, the second claim is
      still refused and the count is still **1**, with two claimants as much as
      with one, because one invitation can produce at most one engagement:
      `engagements.invitation_id` is uniquely indexed, which is the backstop
      `HospitalityComs.Engagements`'s own moduledoc names. What kills the
      mutation is the **status** — `409` becomes `422`, naming `invitation_id`.
      AE3 asks for the count so the count is asserted; the status is the
      assertion that means something.
    * **AE2 — two offers, two claimants.** Both carry `starts_at = now` and a
      ninety-day term, so one person claiming both is a `422` naming `period`
      and the failure reads as a bug in the route.
    * **AE4 — expiry from both sides.** Accepting at `expiry - 1s` consumes an
      engagement for that person, so the refusal at `expiry` has to come from a
      second person. It would still be `410` — `:consume` is the first step, so
      the expiry answer arrives before the engagement is built — which is
      exactly what makes the one-claimant version dangerous: it passes, and it
      passes for a reason the test does not name.

  The collision itself is asserted, once, in its own test, so the reason those
  three fixtures look the way they do is in the tree rather than only here.

  ## The refusals are deliberately not flat, unlike every other refusal here

  R6: an unknown code, a claimed code and an expired code are distinguishable,
  because none of them tells the holder of a code anything they do not already
  have. `HospitalityComsWeb.ErrorEnvelope`'s `code` **is** the response's status
  atom, so on this API "machine-distinguishable" and "distinct status" are the
  same sentence: `404`, `409`, `410`. The argument is in
  `HospitalityComsWeb.ClaimController`'s moduledoc, where a later reviewer
  sweeping for consistency with `HospitalityComsWeb.EmployerController`'s one
  flat `404` will meet it.

  ## Why this file is not sandboxed

  `HospitalityComsWeb.EmployerControllerTest`'s reason, and here it is sharper.
  A claim reads an invitation written through `HospitalityComs.EmployerRepo`,
  writes an engagement through `HospitalityComs.Repo`, and the two are separate
  pools; under the sandbox they are two transactions that cannot see each
  other's rows, so every claim in this file would fail on a foreign key and
  every refusal assertion would pass for the wrong reason.
  `HospitalityComsWeb.ConnCase` is the sandboxed alternative and must not be
  used here.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog, only: [with_log: 1]
  import HospitalityComs.EngagementsFixtures
  import Phoenix.ConnTest

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Repo
  alias HospitalityComs.Venues
  alias HospitalityComsWeb.PersonAuth

  @endpoint HospitalityComsWeb.Endpoint

  @now HospitalityComs.EngagementsFixtures.fixed_instant()
  @issued_at DateTime.truncate(@now, :second)
  @term_ends DateTime.add(@now, 90, :day)

  @claims "/api/claims"

  # A kept parameter, for the log test's control. `config/config.exs`'s
  # allowlist names `venue_id`; this route has none of its own, so it is carried
  # in the query string exactly as `parameter_filter_test.exs` carries it.
  @venue_id "0195a1d2-4c3b-7f19-9a2e-6b8d4e1f0c77"

  # The literal R18 pins against, written out here rather than derived from the
  # controller. `Engagement` also carries `person_id`, `invitation_id`,
  # `grant_id` and `lock_version`, and none of them is here.
  @engagement_keys ~w(engagement_id venue_id role_label starts_at ends_at accepted_at)

  setup do
    real_connections()
    :ok = Clock.Offset.set(@now)
    on_exit(&Clock.Offset.reset/0)

    {:ok, conn: build_conn()}
  end

  describe "POST /api/claims" do
    test "redeems a code and answers the engagement it produced", %{conn: conn} do
      # R5, and the key set is pinned even though this response goes to the
      # *person* rather than to an employer: it is the one response in this
      # surface whose source is a whole schema, and U4's client is written
      # against its shape.
      %{employer: employer, venue: venue} = venue()
      %{claim_code: code} = invitation_fixture(employer, %{role_label: "Runner"})

      body = claim(conn, person_fixture(@now), code)

      assert Map.keys(body) == ["engagement"]
      assert %{"engagement" => engagement} = body
      assert engagement |> Map.keys() |> Enum.sort() == Enum.sort(@engagement_keys)
      assert engagement["venue_id"] == venue.id
      assert engagement["role_label"] == "Runner"
      assert engagement["starts_at"] == DateTime.to_iso8601(@issued_at)
      assert engagement["accepted_at"] == DateTime.to_iso8601(@issued_at)

      # Control: an empty render cannot pass for a redacted one.
      assert :person_id in Engagement.__schema__(:fields)
    end

    test "F1: the issuing manager's people list gains the claimed row", %{conn: conn} do
      # The whole gesture, over HTTP, in two sessions. **This is the test that
      # fails if `starts_at` defaulted to tomorrow**: `list_engagements/1` is
      # active-at-instant, so the manager's own list would not contain what the
      # claimant just accepted, and in a demo that reads as the claim having
      # failed.
      %{person: manager, venue: venue} = manager()
      claimant = person_fixture(@now)

      %{"claim_code" => code} =
        json_post(
          conn,
          manager,
          "/api/employer/venues/#{venue.id}/invitations",
          %{"role_label" => "Runner"},
          201
        )

      %{"engagement" => claimed} = claim(conn, claimant, code)

      %{"engagements" => listed} =
        conn
        |> with_session(manager)
        |> get("/api/employer/venues/#{venue.id}/engagements")
        |> json_response(200)

      assert listed != []
      assert claimed["engagement_id"] in Enum.map(listed, & &1["engagement_id"])
      assert Enum.any?(listed, &(&1["role_label"] == "Runner"))
    end

    test "AE2: two offers for one role produce two codes and both are claimed", %{conn: conn} do
      # An invitation is an offer and nothing deduplicates offers.
      #
      # **Two claimants, and see the moduledoc.** One person claiming both is a
      # `422` on `engagements_no_overlap`, and the test would read as a bug in
      # the route rather than as the fixture being wrong. The test below asserts
      # that collision on purpose.
      %{employer: employer} = venue()

      %{claim_code: first} = invitation_fixture(employer, %{role_label: "Runner"})
      %{claim_code: second} = invitation_fixture(employer, %{role_label: "Runner"})

      refute first == second

      assert %{"engagement" => _one} = claim(conn, person_fixture(@now), first)
      assert %{"engagement" => _two} = claim(conn, person_fixture(@now), second)
    end

    test "refuses a second overlapping offer to one person, naming the period", %{conn: conn} do
      # The reachable `{:error, :engagement, changeset, _}` arm, and the reason
      # the test above needs two claimants.
      %{employer: employer} = venue()
      %{claim_code: first} = invitation_fixture(employer, %{role_label: "Runner"})
      %{claim_code: second} = invitation_fixture(employer, %{role_label: "Runner"})
      claimant = person_fixture(@now)

      assert %{"engagement" => _one} = claim(conn, claimant, first)

      refused = refused_claim(conn, claimant, second, 422)

      assert %{"error" => %{"code" => "unprocessable_entity", "fields" => fields}} = refused
      assert [message] = fields["period"]
      assert message =~ "overlaps"
    end

    test "AE3: one code and two claimants — the second is refused, one engagement exists",
         %{conn: conn} do
      # The race `claim_invitation/2`'s own doc names, driven sequentially.
      #
      # **The status is what carries this and the count is not** — see the
      # moduledoc. Measured: deleting the consume's `claimed_at IS NULL` clause
      # leaves the count at 1 with two claimants as much as with one, because
      # `engagements.invitation_id` is uniquely indexed. What changes is the
      # refusal: `409 conflict` becomes `422` naming `invitation_id`. The count
      # is asserted because AE3 asks for it, and because it is the control that
      # would catch a `409` returned over a row that *was* written.
      %{employer: employer} = venue()
      %{invitation: invitation, claim_code: code} = invitation_fixture(employer)

      assert %{"engagement" => _first} = claim(conn, person_fixture(@now), code)

      refused = refused_claim(conn, person_fixture(@now), code, 409)
      assert %{"error" => %{"code" => "conflict", "message" => message}} = refused
      assert message =~ "already"

      assert engagements_of(invitation.id) == 1
    end

    test "AE4: a code is good a second before expiry and gone at it", %{conn: conn} do
      # Both directions, and half-open: the instant a code expires already
      # belongs to the expired side, exactly as every other period in this
      # application. Two claimants, for the reason in the moduledoc.
      %{employer: employer} = venue()
      expires_at = DateTime.add(@issued_at, 1, :hour)

      %{claim_code: good} = invitation_fixture(employer, %{code_expires_at: expires_at})
      %{claim_code: late} = invitation_fixture(employer, %{code_expires_at: expires_at})

      early = person_fixture(@now)
      latecomer = person_fixture(@now)

      :ok = Clock.Offset.set(DateTime.add(expires_at, -1, :second))
      assert %{"engagement" => _accepted} = claim(conn, early, good)

      :ok = Clock.Offset.set(expires_at)
      refused = refused_claim(conn, latecomer, late, 410)

      assert %{"error" => %{"code" => "gone", "message" => message}} = refused
      assert message =~ "expired"
    end

    test "refuses a code that names nothing, and writes no engagement", %{conn: conn} do
      # The count before and after is the control. A `404` on its own is
      # satisfied by a route that refuses everything.
      claimant = person_fixture(@now)
      before = Repo.aggregate(Engagement, :count)

      refused = refused_claim(conn, claimant, "not-a-code", 404)

      assert %{"error" => %{"code" => "not_found"}} = refused
      assert Repo.aggregate(Engagement, :count) == before
    end

    test "refuses a claim whose conferred authority was revoked since the offer", %{conn: conn} do
      # The `{:error, :conferrable, :grant_not_live, _}` arm, **reachable from
      # this transport** — the plan says it is not. The offer need not have been
      # issued over HTTP for the claim to be; the crude form declining to confer
      # bounds what an employer *request* can produce, not what a code in
      # somebody's hand can name.
      %{employer: employer, grant: founding} = venue()
      {:ok, conferred} = Venues.issue_grant(employer)
      %{claim_code: code} = invitation_fixture(employer, %{grant_id: conferred.id})

      {:ok, _revoked} = Venues.revoke_grant(employer, conferred.id)

      refused = refused_claim(conn, person_fixture(@now), code, 409)

      assert %{"error" => %{"code" => "conflict", "message" => message}} = refused
      assert message =~ "authority"

      # Control: the same shape of offer with its authority still live is
      # claimed, so the refusal is about the revocation rather than about
      # conferring at all. A second claimant, because the first now holds a term
      # at this venue.
      %{claim_code: live} = invitation_fixture(employer, %{grant_id: founding.id})

      assert %{"engagement" => _held} = claim(conn, person_fixture(@now), live)
    end

    test "refuses a request carrying no code, distinctly from one carrying a bad code",
         %{conn: conn} do
      # Inequality is the assertion. A client bug and a code that failed are two
      # different things, and this is the mirror of the employer routes' flat
      # refusal, where equality is what is asserted.
      claimant = person_fixture(@now)

      missing = json_post(conn, claimant, @claims, %{}, 400)
      unknown = refused_claim(conn, claimant, "not-a-code", 404)

      assert %{"error" => %{"code" => "bad_request"}} = missing
      refute missing == unknown
    end

    test "refuses without a bearer token, and answers with one", %{conn: conn} do
      %{employer: employer} = venue()
      %{claim_code: code} = invitation_fixture(employer)

      assert %{"error" => %{"code" => "unauthorized"}} =
               conn |> post(@claims, %{"claim_code" => code}) |> json_response(401)

      assert %{"engagement" => _claimed} = claim(conn, person_fixture(@now), code)
    end
  end

  ## R20

  describe "the claim code and the request log" do
    test "a live code is filtered out of the dispatch line", %{conn: conn} do
      # `config/config.exs`'s `filter_parameters` is a `{:keep, [...]}`
      # **allowlist** since issue #53, so `claim_code` is redacted because it is
      # *not named* — there is nothing to add and adding it to the keep list
      # would be the bug. `parameter_filter_test.exs` pins the mechanism against
      # `filter_values/1`; this pins it against the route this unit ships, with
      # a code that demonstrably worked.
      #
      # **Two controls, and neither is optional.** Every assertion here is an
      # absence, and an absence assertion passes against a log that captured
      # nothing — which is the default outcome, since `config/test.exs` pins the
      # suite at `:warning` and the dispatch line is `:debug`. So the line is
      # asserted present, and a kept parameter is asserted verbatim *in the same
      # line*, which a blanket redaction would fail.
      %{employer: employer} = venue()
      %{claim_code: code} = invitation_fixture(employer)
      claimant = person_fixture(@now)

      {claimed, log} =
        with_debug_log(fn ->
          conn
          |> with_session(claimant)
          |> post("#{@claims}?venue_id=#{@venue_id}", %{"claim_code" => code})
        end)

      # The credential was live: the value asserted absent below is a code that
      # redeemed an offer, not a rejected string.
      assert %{"engagement" => _held} = json_response(claimed, 201)

      assert log =~ "Processing with HospitalityComsWeb.ClaimController.create/2"
      assert is_binary(parameters(log))
      assert parameters(log) =~ ~s("venue_id" => "#{@venue_id}")

      assert parameters(log) =~ ~s("claim_code" => "[FILTERED]")
      refute log =~ code
    end
  end

  ## Helpers

  defp claim(conn, person, code) do
    json_post(conn, person, @claims, %{"claim_code" => code}, 201)
  end

  defp refused_claim(conn, person, code, status) do
    json_post(conn, person, @claims, %{"claim_code" => code}, status)
  end

  defp json_post(conn, person, path, params, status) do
    conn |> with_session(person) |> post(path, params) |> json_response(status)
  end

  defp with_session(conn, person) do
    token =
      person
      |> PersonScope.for_person(@now)
      |> Accounts.generate_person_session_token()
      |> PersonAuth.encode_token()

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp engagements_of(invitation_id) do
    Repo.aggregate(from(e in Engagement, where: e.invitation_id == ^invitation_id), :count)
  end

  defp person_scope(person), do: PersonScope.for_person(person, @now)

  defp venue do
    {employer, creation} = scoped_venue_fixture(@now)
    %{employer: employer, venue: creation.venue, grant: creation.grant}
  end

  # `employer_controller_test.exs`'s shape: a venue with two live grants, and a
  # manager holding the second, so the people list has an authority behind it.
  defp manager do
    {employer, creation} = scoped_venue_fixture(@now)
    manager = person_fixture(@now)

    {:ok, held} = Venues.issue_grant(employer)

    engagement_fixture(employer, person_scope(manager), %{
      starts_at: DateTime.add(@now, -1, :hour),
      ends_at: @term_ends,
      grant_id: held.id
    })

    %{employer: employer, venue: creation.venue, person: manager, grant: held}
  end

  # `parameter_filter_test.exs`'s helper, duplicated rather than shared: that
  # file is sandboxed and this one cannot be, and the two live in different
  # `use` blocks. Lowering the **primary** level is the only thing that works —
  # both `with_log(level: :debug)` and `Logger.put_process_level/2` were
  # measured against a request of this shape and captured nothing.
  defp with_debug_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      with_log(fun)
    after
      Logger.configure(level: previous)
    end
  end

  # The dispatch line is one Logger message spanning three lines; the parameter
  # map is the middle one. Asserting against that line rather than the whole
  # capture is deliberate: `HospitalityComs.Repo` logs its own statements and
  # their bind parameters at `:debug` too, and `filter_parameters` governs
  # neither.
  defp parameters(log) do
    log |> String.split("\n") |> Enum.find(&String.contains?(&1, "Parameters:"))
  end
end
