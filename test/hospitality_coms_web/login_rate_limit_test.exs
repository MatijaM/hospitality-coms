defmodule HospitalityComsWeb.LoginRateLimitTest do
  @moduledoc """
  The limiter in front of `POST /api/log-in`, and the property it must not
  destroy while it is there.

  ## The enumeration oracle it is standing next to

  The endpoint merges registration and log-in on purpose, so a known and an
  unknown address get the same `202` and the same email. A limiter that answered
  differently for the two — the obvious "one link per address per fifteen
  minutes" shape — would be a *better* oracle than the merged door closed: no
  timing analysis, no mailbox, just a status code. So the counter keys on
  `conn.remote_ip` and nothing else, and this file asserts identical answers for
  a known and an unknown address on **both** sides of the limit. One side alone
  is satisfied by a limiter that refuses everybody always.

  ## Three ways to pass while doing nothing, and a control for each

  A limit test that never reaches the limit; a limiter that refuses everything;
  a counter that never resets. The first is answered by asserting the requests
  below the limit are accepted, the second by a second IP being accepted while
  the first is refused, and the third by the same IP being accepted one window
  later — with "still refused a second before the window rolls" as the control
  for *that*, since a window that rolled on any advance satisfies it.

  ## ETS is node-local, and this suite runs files concurrently

  There is one table for the whole node and it is never reset. What isolates the
  tests is the **key space**: `HospitalityComsWeb.ConnCase` gives every test's
  `conn` its own `remote_ip`, so each test is a different client of the same
  live counter. A reset hook would be a second mechanism to forget, and
  forgetting it fails in whichever file happens to run next rather than in the
  one that forgot.

  The window comes from `conn.assigns.current_scope.now`, which
  `HospitalityComsWeb.PersonAuth.fetch_person_scope/2` read from the clock — so
  the window is rolled by advancing `HospitalityComs.Clock.Offset` rather than by
  sleeping, and this file is `async: false` for the reason every clock-moving
  file is.
  """

  use HospitalityComsWeb.ConnCase, async: false

  import HospitalityComs.AccountsFixtures

  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Clock
  alias HospitalityComsWeb.LoginRateLimit

  @now ~U[2026-06-01 12:00:00Z]

  # Past every instant any other file in this suite pins, so that "the newest
  # window in the table" is a value the reclamation test controls.
  @far ~U[2099-01-01 00:00:00Z]

  setup do
    Clock.Offset.set(@now)
    on_exit(&Clock.Offset.reset/0)
    :ok
  end

  describe "the limit" do
    test "admits a full window's worth of requests", %{conn: conn} do
      # The control for "the next one is refused": a limiter that refused
      # everything satisfies that test on its own.
      for _ <- 1..LoginRateLimit.limit() do
        assert conn |> post(~p"/api/log-in", %{}) |> json_response(400)
      end
    end

    test "refuses the one after that, in the standard envelope", %{conn: conn} do
      spend(conn)

      refused = post(conn, ~p"/api/log-in", %{"email" => unique_person_email()})

      assert %{"error" => %{"code" => "too_many_requests", "message" => message}} =
               json_response(refused, 429)

      assert is_binary(message)
    end

    test "and tells the caller when to come back", %{conn: conn} do
      spend(conn)

      refused = post(conn, ~p"/api/log-in", %{})

      assert Plug.Conn.get_resp_header(refused, "retry-after") == [
               Integer.to_string(LoginRateLimit.window_seconds())
             ]
    end

    test "leaves a different address from the same caller equally refused", %{conn: conn} do
      # The enumeration property at the limit: the refusal is a function of the
      # caller, so a registered address and one nobody has ever used come back
      # byte for byte the same.
      known = person_fixture(%{}, @now)
      spend(conn)

      for_known = post(conn, ~p"/api/log-in", %{"email" => known.email})
      for_unknown = post(conn, ~p"/api/log-in", %{"email" => unique_person_email()})

      assert json_response(for_known, 429) == json_response(for_unknown, 429)
    end

    test "and equally admitted below it, which is the other half", %{conn: conn} do
      known = person_fixture(%{}, @now)

      for_known = post(conn, ~p"/api/log-in", %{"email" => known.email})
      for_unknown = post(conn, ~p"/api/log-in", %{"email" => unique_person_email()})

      assert json_response(for_known, 202) == json_response(for_unknown, 202)
    end

    test "counts requests rather than successes", %{conn: conn} do
      # The plug sits in front of the controller, so a bodyless request and a
      # malformed address consume the same budget a valid one does. That is
      # abuse control doing its job, and it is also what keeps the count free of
      # any information about the body.
      for _ <- 1..LoginRateLimit.limit() do
        assert conn |> post(~p"/api/log-in", %{"email" => "not an address"}) |> json_response(422)
      end

      assert conn |> post(~p"/api/log-in", %{"email" => unique_person_email()}) |> response(429)
    end

    test "spends its budget over the lifetime of the link it hands out" do
      # Every other test in this file derives its loop from `limit/0` and its
      # advance from `window_seconds/0`, which is what stops the two drifting —
      # and leaves both *unpinned*: a limit of a million passes all of them
      # while limiting nothing.
      #
      # So the pair is asserted directly, in the form the moduledoc claims it
      # in. The window is the magic link's own validity, so "one caller can
      # cause at most `limit` outbound emails inside the lifetime of any single
      # link they caused" is a sentence about these two numbers together.
      assert LoginRateLimit.window_seconds() ==
               PersonToken.magic_link_validity_in_minutes() * 60

      assert LoginRateLimit.limit() in 1..100
    end
  end

  describe "what the key is" do
    test "another caller is unaffected at the same instant", %{conn: conn} do
      spend(conn)

      assert conn |> post(~p"/api/log-in", %{}) |> response(429)
      assert conn |> from_ip({10, 1, 1, 1}) |> post(~p"/api/log-in", %{}) |> response(400)
    end

    test "the same caller is admitted again one window later", %{conn: conn} do
      spend(conn)
      assert conn |> post(~p"/api/log-in", %{}) |> response(429)

      Clock.Offset.set(DateTime.add(@now, LoginRateLimit.window_seconds(), :second))

      assert conn |> post(~p"/api/log-in", %{}) |> response(400)
    end

    test "and is still refused a second short of it, which is the control", %{conn: conn} do
      spend(conn)

      Clock.Offset.set(DateTime.add(@now, LoginRateLimit.window_seconds() - 1, :second))

      assert conn |> post(~p"/api/log-in", %{}) |> response(429)
    end

    test "the instant comes off the scope rather than from the clock", %{conn: conn} do
      # Asserted against the plug directly, because the whole claim is that this
      # module never reads a clock: two conns one window apart, with the clock
      # standing still between them.
      ip = {10, 2, 2, 2}
      for _ <- 1..LoginRateLimit.limit(), do: spent(ip, @now)

      assert %Plug.Conn{halted: true, status: 429} = limited(ip, @now)

      later = DateTime.add(@now, LoginRateLimit.window_seconds(), :second)
      assert %Plug.Conn{halted: false} = limited(ip, later)

      # …and the wall clock has not moved, so nothing above could have been the
      # clock rather than the scope.
      assert Clock.now() == @now
      refute conn.halted
    end
  end

  describe "the counter" do
    test "reclaims the buckets a window has left behind, and keeps the current one" do
      # One test rather than two, because the two halves race each other for
      # the table's newest window if they are separate bodies and ExUnit
      # shuffles them. The base is far enough out that no other file in the
      # suite has written a later window, which is what makes "the newest
      # window in the table" a value this test controls.
      stale = {10, 3, 3, 3}
      current = {10, 4, 4, 4}
      later = DateTime.add(@far, LoginRateLimit.window_seconds(), :second)

      spent(stale, @far)
      spent(current, later)

      assert bucket(stale)
      assert bucket(current)

      assert LoginRateLimit.prune() >= 1

      refute bucket(stale)
      assert bucket(current)
    end

    test "counts one bucket per caller rather than one per caller and window" do
      # Which is what makes the table bounded by the callers seen rather than
      # by every pair of caller and window since boot. A stale bucket is reset
      # in place by the next request, so reclaiming it and leaving it are the
      # same thing to the count — and that is what lets the reclamation above
      # run on a plain interval without reading the clock.
      ip = {10, 5, 5, 5}
      later = DateTime.add(@now, LoginRateLimit.window_seconds(), :second)

      spent(ip, @now)
      spent(ip, later)

      assert length(buckets(ip)) == 1
    end
  end

  describe "what is not limited" do
    test "redeeming a link from a caller who has spent their log-in budget", %{conn: conn} do
      spend(conn)
      assert conn |> post(~p"/api/log-in", %{}) |> response(429)

      assert conn |> post(~p"/api/log-in/token", %{"token" => "made-up"}) |> json_response(401)
      assert conn |> get(~p"/api/me") |> json_response(401)
    end
  end

  describe "the suite's own isolation" do
    test "every test's conn arrives with a remote address of its own", %{conn: conn} do
      # The partition every other file in the suite depends on without saying
      # so: `session_controller_test.exs` makes ten `POST /api/log-in` calls at
      # one pinned instant, and without this they would share one budget and
      # that file would go red at whichever call crossed the limit.
      other = Phoenix.ConnTest.build_conn()

      # The setup applied it…
      refute conn.remote_ip == other.remote_ip

      # …and it answers something different every time it is asked.
      refute with_own_remote_ip(other).remote_ip == with_own_remote_ip(other).remote_ip
    end
  end

  ## Helpers

  # Uses up exactly the window's budget for this conn's caller, leaving the
  # next request as the first refusal.
  defp spend(conn) do
    for _ <- 1..LoginRateLimit.limit(), do: post(conn, ~p"/api/log-in", %{})
    :ok
  end

  defp from_ip(conn, ip), do: %{conn | remote_ip: ip}

  # One trip through the plug alone, with the scope the pipeline would have
  # assigned.
  defp limited(ip, instant) do
    %Plug.Conn{Phoenix.ConnTest.build_conn() | remote_ip: ip}
    |> Plug.Conn.assign(:current_scope, PersonScope.for_person(nil, instant))
    |> LoginRateLimit.limit_login([])
  end

  defp spent(ip, instant), do: limited(ip, instant)

  defp bucket(ip), do: buckets(ip) != []

  defp buckets(ip), do: :ets.lookup(LoginRateLimit.table(), ip)
end
