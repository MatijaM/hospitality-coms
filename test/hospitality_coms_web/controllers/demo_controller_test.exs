defmodule HospitalityComsWeb.DemoControllerTest do
  @moduledoc """
  The demo controls over HTTP, through the router rather than the controller.

  Through the router deliberately: the routes exist only where
  `Application.compile_env(:hospitality_coms, :demo_routes)` is set, and calling
  the controller's functions directly would assert the actions work while saying
  nothing about whether they are reachable — which is the half that matters,
  because the whole design here is that in a production build they are not.

  ## Why it is not sandboxed

  `EngagementsFixtures.real_connections/0`, for U5's reason: the manifest the
  seed action writes spans both repos. It also moves the global
  `HospitalityComs.Clock.Offset`, so it is `async: false`.

  ## Three refusals are deliberately unreached, and this is the record of it

  Every branch of `refused/3` is exercised here except these, and each is
  unreachable without a second caller committing between
  `HospitalityComs.Demo`'s pre-flight and its close:

    * `:stale`, and a changeset, from `Engagements.end_engagement/2`. They are
      also the only two that can carry a non-empty `ended` list, so the residue
      half of `{:error, reason, closed}` is asserted for its shape and not for
      a real interleaving. Reproducing one needs a parked row lock and a third
      process, which is `engagements_concurrency_test.exs`'s apparatus for a
      case nothing depends on.
    * `:no_grant`, from `Demo.permitted/1`. It wants a venue holding an active
      engagement and no live grant at the same instant, and `Venues` refuses to
      revoke a venue's last live grant, so no sequence of context calls
      produces one. It is a defensive clause and stays one.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ConnTest

  alias HospitalityComs.Clock
  alias HospitalityComs.Demo
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.EngagementsFixtures
  alias HospitalityComs.Repo
  alias HospitalityComs.Venues.Venue
  alias HospitalityComsWeb.Router

  @endpoint HospitalityComsWeb.Endpoint

  @instant ~U[2026-06-01 09:00:00.000000Z]

  # Read with `compile_env/2` because that is how the router reads it. The
  # router's value is fixed into the compiled module and cannot be read back at
  # run time, so `Application.get_env/2` here asserted a *different* read of the
  # same key and said nothing about the gate. Neither is the real proof: that is
  # CI's `MIX_ENV=prod mix compile --warnings-as-errors`, which fails naming all
  # six route lines when the key is set in a production config, and which also
  # catches the compile-time struct expansion `demo_test.exs`'s imports-chunk
  # sweep cannot see.
  @demo_routes Application.compile_env(:hospitality_coms, :demo_routes)

  setup do
    EngagementsFixtures.real_connections()
    :ok = Clock.Offset.set(@instant)
    ExUnit.Callbacks.on_exit(fn -> Clock.Offset.reset() end)
    {:ok, conn: build_conn()}
  end

  describe "the routes" do
    test "exist wherever the compile-time demo key was set" do
      paths = Enum.map(Router.__routes__(), & &1.path)

      assert "/api/demo/seed" in paths
      assert "/api/demo/clock" in paths
      assert "/api/demo/run-due-work" in paths
      assert "/api/demo/people/:person_id/end-engagements" in paths

      assert @demo_routes
    end
  end

  describe "the header a forged cross-origin request cannot carry" do
    test "refuses a state-changing control that arrives without it", %{conn: conn} do
      # A CORS-simple `fetch(…, {method: "POST", mode: "no-cors"})` from any page
      # a developer has open reaches this surface: no preflight, and
      # `Plug.Parsers` passes `*/*` so an unparseable body is no obstacle
      # either. A custom header is not simple, so asking for one forces a
      # preflight this application answers with no CORS headers at all.
      body = conn |> post("/api/demo/run-due-work") |> json_response(403)

      assert %{"error" => %{"code" => "forbidden", "message" => message}} = body
      assert message =~ "x-demo-control"
    end

    test "and refuses the clock, which Plug.MethodOverride would otherwise reach", %{conn: conn} do
      assert conn |> post("/api/demo/clock", %{"advance" => %{"day" => 1}}) |> json_response(403)
      assert conn |> delete("/api/demo/clock") |> json_response(403)
      assert DateTime.compare(Clock.now(), @instant) == :eq
    end

    test "and leaves the read alone, which is the control", %{conn: conn} do
      assert conn |> get("/api/demo/clock") |> json_response(200)
    end
  end

  describe "POST /api/demo/seed" do
    test "writes the manifest and answers with it", %{conn: conn} do
      body = conn |> control() |> post("/api/demo/seed") |> json_response(200)

      assert %{"manifest" => manifest} = body
      assert manifest["status"] == "created"
      assert map_size(manifest["people"]) == 4
      assert map_size(manifest["venues"]) == 2
      assert map_size(manifest["shift_rooms"]) == 3
      assert is_binary(manifest["declared_entry_id"])
      assert is_binary(manifest["correction_request_id"])
      assert is_binary(manifest["disclosure_id"])
    end

    test "and reports a manifest that is already there rather than writing a second", %{
      conn: conn
    } do
      {:ok, _manifest} = Demo.seed()

      body = conn |> control() |> post("/api/demo/seed") |> json_response(200)

      assert body["manifest"]["status"] == "present"
    end

    test "and refuses a half-seeded database with an envelope", %{conn: conn} do
      {:ok, manifest} = Demo.seed()

      {1, _} =
        Repo.update_all(
          from(venue in Venue, where: venue.id == ^manifest.venues.kolektiv),
          set: [name: "Kolektiv Coffee interrupted (demo)"]
        )

      body = conn |> control() |> post("/api/demo/seed") |> json_response(409)

      assert %{"error" => %{"code" => "conflict", "message" => message}} = body
      assert message =~ "did not finish"
    end
  end

  describe "the clock" do
    test "GET reports where it is", %{conn: conn} do
      body = conn |> get("/api/demo/clock") |> json_response(200)

      assert {:ok, instant, _offset} = DateTime.from_iso8601(body["clock"]["instant"])
      assert DateTime.compare(instant, @instant) == :eq
      assert body["clock"]["implementation"] == "HospitalityComs.Clock.Offset"
    end

    test "POST advances it and answers with where it landed", %{conn: conn} do
      body =
        conn
        |> control()
        |> post("/api/demo/clock", %{"advance" => %{"day" => 31}})
        |> json_response(200)

      {:ok, instant, _offset} = DateTime.from_iso8601(body["clock"]["instant"])

      assert DateTime.compare(instant, DateTime.add(@instant, 31, :day)) == :eq
      assert DateTime.compare(Clock.now(), instant) == :eq
    end

    test "POST pins it to a named instant", %{conn: conn} do
      pinned = ~U[2027-01-15 08:30:00.000000Z]

      body =
        conn
        |> control()
        |> post("/api/demo/clock", %{"instant" => DateTime.to_iso8601(pinned)})
        |> json_response(200)

      {:ok, instant, _offset} = DateTime.from_iso8601(body["clock"]["instant"])

      assert DateTime.compare(instant, pinned) == :eq
    end

    test "DELETE returns it to the system instant", %{conn: conn} do
      {:ok, _instant} = Demo.advance_clock(day: 31)

      pinned = conn |> get("/api/demo/clock") |> json_response(200)
      body = conn |> control() |> delete("/api/demo/clock") |> json_response(200)

      # Asserted as the control state rather than against a wall-clock value:
      # after a reset the clock reads whatever the machine says, and comparing
      # against that would be a test whose meaning depends on today's date.
      assert pinned["clock"]["fixed"]
      assert pinned["clock"]["shift"]["day"] == 31

      assert body["clock"]["fixed"] == nil
      assert Map.values(body["clock"]["shift"]) |> Enum.uniq() == [0]
    end

    test "refuses a malformed duration with an envelope", %{conn: conn} do
      body =
        conn
        |> control()
        |> post("/api/demo/clock", %{"advance" => %{"fortnight" => 1}})
        |> json_response(400)

      assert %{"error" => %{"code" => "bad_request", "message" => message}} = body
      assert message =~ "advance"
      assert DateTime.compare(Clock.now(), @instant) == :eq
    end

    test "refuses a count that is not a whole number", %{conn: conn} do
      # `is_integer/1` in `unit_pair/1` is load-bearing twice over: it keeps
      # `Duration.new!/1` from raising, and it is what a forged cross-origin
      # request cannot satisfy, because urlencoded bodies yield strings and JSON
      # is not a simple content type. Relaxing it to accept `"31"` would hand
      # the clock back to the forgery the header now refuses.
      body =
        conn
        |> control()
        |> post("/api/demo/clock", %{"advance" => %{"day" => "31"}})
        |> json_response(400)

      assert body["error"]["code"] == "bad_request"
      assert DateTime.compare(Clock.now(), @instant) == :eq
    end

    test "refuses an advance that names no unit at all", %{conn: conn} do
      body =
        conn |> control() |> post("/api/demo/clock", %{"advance" => %{}}) |> json_response(400)

      assert body["error"]["message"] =~ "at least one unit"
    end

    test "refuses an advance that is not an object", %{conn: conn} do
      body =
        conn
        |> control()
        |> post("/api/demo/clock", %{"advance" => "day"})
        |> json_response(400)

      assert body["error"]["message"] =~ "must be an object"
    end

    test "refuses an instant that is not a string", %{conn: conn} do
      body = conn |> control() |> post("/api/demo/clock", %{"instant" => 5}) |> json_response(400)

      assert body["error"]["message"] =~ "must be a string"
    end

    test "refuses an instant that is not ISO 8601", %{conn: conn} do
      body =
        conn
        |> control()
        |> post("/api/demo/clock", %{"instant" => "nonsense"})
        |> json_response(400)

      assert body["error"]["message"] =~ "ISO 8601"
      assert DateTime.compare(Clock.now(), @instant) == :eq
    end

    test "refuses a body naming both an instant and an advance", %{conn: conn} do
      body =
        conn
        |> control()
        |> post("/api/demo/clock", %{
          "instant" => DateTime.to_iso8601(@instant),
          "advance" => %{"day" => 1}
        })
        |> json_response(400)

      assert body["error"]["code"] == "bad_request"
    end

    test "refuses a body naming neither", %{conn: conn} do
      assert conn |> control() |> post("/api/demo/clock", %{}) |> json_response(400)
    end
  end

  describe "POST /api/demo/run-due-work" do
    test "reports the sweep and the retention run", %{conn: conn} do
      {:ok, _manifest} = Demo.seed()
      {:ok, _instant} = Demo.advance_clock(day: 11)

      body = conn |> control() |> post("/api/demo/run-due-work") |> json_response(200)

      assert %{"due_work" => work} = body
      assert work["swept"] >= 1
      assert work["retention"]["outcome"] == "completed"
      assert work["retention"]["shift_messages"] >= 1
      assert is_binary(work["retention"]["retention_run_id"])
    end
  end

  describe "POST /api/demo/people/:person_id/end-engagements" do
    test "ends every engagement the person holds", %{conn: conn} do
      {:ok, manifest} = Demo.seed()

      body =
        conn
        |> control()
        |> post("/api/demo/people/#{manifest.people.tomo}/end-engagements")
        |> json_response(200)

      assert length(body["ended"]) == 2
      assert Enum.all?(body["ended"], &is_binary(&1["engagement_id"]))
    end

    test "refuses a venue's last grant-holding engagement with an envelope", %{conn: conn} do
      # **The wording is not the property.** With `Demo.permitted/1`'s pre-flight
      # removed this endpoint closes Ana's Harbour engagement, meets
      # `end_engagement/2`'s own refusal at the Kolektiv, and answers with the
      # same 409 and the same sentence — so the assertions below say nothing
      # about anything having been left alone. The count around the call is what
      # does, and `ended` is now rendered rather than claimed in prose.
      {:ok, manifest} = Demo.seed()

      before = open_engagements(manifest.people.ana)

      body =
        conn
        |> control()
        |> post("/api/demo/people/#{manifest.people.ana}/end-engagements")
        |> json_response(409)

      assert %{"error" => %{"code" => "conflict", "message" => message}} = body
      assert message =~ "grant-holding"
      assert message =~ "Nothing was ended"
      assert body["ended"] == []

      assert open_engagements(manifest.people.ana) == before
      assert before == 2
    end

    test "answers not_found for an id naming nobody", %{conn: conn} do
      body =
        conn
        |> control()
        |> post("/api/demo/people/#{Ecto.UUID.generate()}/end-engagements")
        |> json_response(404)

      assert body["error"]["code"] == "not_found"
      assert body["ended"] == []
    end
  end

  ## Helpers

  defp control(conn), do: Plug.Conn.put_req_header(conn, "x-demo-control", "1")

  defp open_engagements(person_id) do
    Repo.aggregate(
      from(engagement in Engagement,
        where: engagement.person_id == ^person_id and engagement.ends_at > ^Clock.now()
      ),
      :count
    )
  end
end
