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
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias HospitalityComs.Clock
  alias HospitalityComs.Demo
  alias HospitalityComs.EngagementsFixtures
  alias HospitalityComsWeb.Router

  @endpoint HospitalityComsWeb.Endpoint

  @instant ~U[2026-06-01 09:00:00.000000Z]

  setup do
    EngagementsFixtures.real_connections()
    :ok = Clock.Offset.set(@instant)
    ExUnit.Callbacks.on_exit(fn -> Clock.Offset.reset() end)
    {:ok, conn: build_conn()}
  end

  describe "the routes" do
    test "exist in this environment and are gated by a compile-time key" do
      paths = Enum.map(Router.__routes__(), & &1.path)

      assert "/api/demo/seed" in paths
      assert "/api/demo/clock" in paths
      assert "/api/demo/run-due-work" in paths
      assert "/api/demo/people/:person_id/end-engagements" in paths

      # The gate is compile-time, so it is not something a request can flip. The
      # value is read from the same key the router's `compile_env/2` names.
      assert Application.get_env(:hospitality_coms, :demo_routes)
    end
  end

  describe "POST /api/demo/seed" do
    test "writes the manifest and answers with it", %{conn: conn} do
      body = conn |> post("/api/demo/seed") |> json_response(200)

      assert %{"manifest" => manifest} = body
      assert manifest["status"] == "created"
      assert map_size(manifest["people"]) == 4
      assert map_size(manifest["venues"]) == 2
      assert map_size(manifest["shift_rooms"]) == 3
    end

    test "and reports a manifest that is already there rather than writing a second", %{
      conn: conn
    } do
      {:ok, _manifest} = Demo.seed()

      body = conn |> post("/api/demo/seed") |> json_response(200)

      assert body["manifest"]["status"] == "present"
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
        |> post("/api/demo/clock", %{"instant" => DateTime.to_iso8601(pinned)})
        |> json_response(200)

      {:ok, instant, _offset} = DateTime.from_iso8601(body["clock"]["instant"])

      assert DateTime.compare(instant, pinned) == :eq
    end

    test "DELETE returns it to the system instant", %{conn: conn} do
      {:ok, _instant} = Demo.advance_clock(day: 31)

      pinned = conn |> get("/api/demo/clock") |> json_response(200)
      body = conn |> delete("/api/demo/clock") |> json_response(200)

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
        |> post("/api/demo/clock", %{"advance" => %{"fortnight" => 1}})
        |> json_response(400)

      assert %{"error" => %{"code" => "bad_request", "message" => message}} = body
      assert message =~ "advance"
      assert DateTime.compare(Clock.now(), @instant) == :eq
    end

    test "refuses a body naming both an instant and an advance", %{conn: conn} do
      body =
        conn
        |> post("/api/demo/clock", %{
          "instant" => DateTime.to_iso8601(@instant),
          "advance" => %{"day" => 1}
        })
        |> json_response(400)

      assert body["error"]["code"] == "bad_request"
    end

    test "refuses a body naming neither", %{conn: conn} do
      assert conn |> post("/api/demo/clock", %{}) |> json_response(400)
    end
  end

  describe "POST /api/demo/run-due-work" do
    test "reports the sweep and the retention run", %{conn: conn} do
      {:ok, _manifest} = Demo.seed()
      {:ok, _instant} = Demo.advance_clock(day: 11)

      body = conn |> post("/api/demo/run-due-work") |> json_response(200)

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
        |> post("/api/demo/people/#{manifest.people.tomo}/end-engagements")
        |> json_response(200)

      assert length(body["ended"]) == 2
      assert Enum.all?(body["ended"], &is_binary(&1["engagement_id"]))
    end

    test "refuses a venue's last grant-holding engagement with an envelope", %{conn: conn} do
      {:ok, manifest} = Demo.seed()

      body =
        conn
        |> post("/api/demo/people/#{manifest.people.ana}/end-engagements")
        |> json_response(409)

      assert %{"error" => %{"code" => "conflict", "message" => message}} = body
      assert message =~ "grant-holding"
      assert message =~ "Nothing was ended"
    end

    test "answers not_found for an id naming nobody", %{conn: conn} do
      body =
        conn
        |> post("/api/demo/people/#{Ecto.UUID.generate()}/end-engagements")
        |> json_response(404)

      assert body["error"]["code"] == "not_found"
    end
  end
end
