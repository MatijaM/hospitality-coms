defmodule HospitalityComsWeb.ParameterFilterTest do
  @moduledoc """
  What `Phoenix.Logger` is allowed to print out of a parameter map.

  Every parameter map Phoenix logs — the HTTP dispatch line, a socket connect,
  a channel join, a channel `handle_in` — goes through
  `Phoenix.Logger.filter_values/1`, which reads
  `Application.get_env(:phoenix, :filter_parameters)`. This file is the only
  thing that pins what that value is and what it does.

  **Read the control discipline before adding to this file.** Every assertion
  here is an absence, and an absence assertion passes against a log that
  captured nothing at all — which is the default outcome, because
  `config/test.exs` sets `config :logger, level: :warning` and the dispatch line
  is `:debug`. `ExUnit.CaptureLog`'s `:level` option does *not* lower the
  primary level, and neither does `Logger.put_process_level/2`; both were
  measured against this exact request and both captured `""`. So every capture
  in this file goes through `with_debug_log/1`, and every absence assertion is
  paired with a **value read out of the same log line** — see
  `docs/solutions/test-failures/tests-that-certify-nothing.md`, whose generative
  rule this file is a direct instance of.

  `filter_values/1` is `@doc false` and is called here on purpose: it is the
  exact function the four log sites call, so testing it against the live
  configured value is testing the mechanism rather than a restatement of it.
  The two HTTP tests are what prove the configuration is actually wired to a
  log site; the direct calls then cover the parameters that have no route yet.
  """

  use HospitalityComsWeb.ConnCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]
  import HospitalityComs.AccountsFixtures

  alias HospitalityComs.Clock

  # The test-side copy of the allowlist. `config/config.exs` holds the
  # production-side one, and the first test asserts the two agree — that is the
  # point of the pair, and it is why this is written out rather than read back
  # from `Application.get_env/2`.
  @kept ~w(connection_id extent person_id request_id shift_room_id venue_id vsn)

  # Parameters that must never print. Five of them exist in the tree today
  # (`email`, `token`, `body`, and `password` and `code` as spellings a future
  # unit would reach for); `claim_code` is the one the employer view's plan
  # adds, and the whole argument for the allowlist shape is that it is covered
  # here without anybody having added a rule for it.
  @filtered ~w(email token claim_code code body password secret authorization otp)

  @now ~U[2026-03-01 12:00:00.000000Z]
  @venue_id "0195a1d2-4c3b-7f19-9a2e-6b8d4e1f0c77"

  setup do
    Clock.Offset.set(@now)
    on_exit(&Clock.Offset.reset/0)
    :ok
  end

  describe "the configured filter" do
    test "is an allowlist naming exactly the parameters this API needs to read" do
      assert Application.get_env(:phoenix, :filter_parameters) == {:keep, @kept}
    end

    test "filters every parameter it does not name" do
      params = Map.new(@filtered, &{&1, "secret-value-of-#{&1}"})

      redacted = Phoenix.Logger.filter_values(params)

      for {key, value} <- params do
        assert redacted[key] == "[FILTERED]", "#{key} was not filtered"
        refute redacted[key] == value
      end
    end

    # The control for the test above, and it is the one that matters: `{:keep,
    # []}`, or any bug that redacted unconditionally, passes every assertion up
    # there and fails every assertion down here.
    test "keeps every parameter it does name, verbatim" do
      params = Map.new(@kept, &{&1, "value-of-#{&1}"})

      assert Phoenix.Logger.filter_values(params) == params
    end

    # `keep_values/2` tests membership at every depth rather than only at the
    # top, so a kept name is kept wherever it appears. The demo route's
    # `%{"advance" => %{"day" => 31}}` is the only nested body in the tree.
    test "filters a nested value under a parameter it does not name" do
      assert Phoenix.Logger.filter_values(%{"advance" => %{"day" => 31}}) ==
               %{"advance" => %{"day" => "[FILTERED]"}}
    end
  end

  describe "over a real request" do
    test "the magic-link token is filtered out of the dispatch line", %{conn: conn} do
      email = unique_person_email()
      post(conn, ~p"/api/log-in", %{"email" => email})
      token = magic_link_token()

      {redeemed, log} =
        with_debug_log(fn ->
          post(build_conn(), ~p"/api/log-in/token?venue_id=#{@venue_id}", %{"token" => token})
        end)

      # The credential was live: this is the redemption succeeding, so the value
      # asserted absent below is a working bearer credential rather than a
      # rejected string.
      assert %{"token" => _api_token} = json_response(redeemed, 201)

      # Control: the request logged at all, and this is its parameter line.
      assert log =~ "Processing with HospitalityComsWeb.SessionController.confirm/2"
      assert is_binary(parameters(log))

      # Control: the filter is not blanket redaction. A kept parameter comes
      # back verbatim, in the same log line as the filtered one.
      assert parameters(log) =~ ~s("venue_id" => "#{@venue_id}")

      assert parameters(log) =~ ~s("token" => "[FILTERED]")
      refute log =~ token
    end

    test "an email address is filtered out of the dispatch line", %{conn: conn} do
      email = unique_person_email()

      {requested, log} =
        with_debug_log(fn ->
          post(conn, ~p"/api/log-in?venue_id=#{@venue_id}", %{"email" => email})
        end)

      assert response(requested, 202)

      # Controls, as above.
      assert log =~ "Processing with HospitalityComsWeb.SessionController.create/2"
      assert is_binary(parameters(log))
      assert parameters(log) =~ ~s("venue_id" => "#{@venue_id}")

      assert parameters(log) =~ ~s("email" => "[FILTERED]")
      refute parameters(log) =~ email
    end

    # The meta-control. It asserts the vacuous outcome explicitly, so the trap
    # is a passing test rather than a comment: without `with_debug_log/1` the
    # capture holds no parameter line at all, and `refute log =~ token` above
    # would be satisfied by the empty string.
    test "captures no parameter line at all at the suite's own log level", %{conn: conn} do
      assert Logger.compare_levels(Logger.level(), :debug) == :gt

      {_requested, log} =
        with_log(fn ->
          post(conn, ~p"/api/log-in?venue_id=#{@venue_id}", %{"email" => unique_person_email()})
        end)

      assert parameters(log) == nil
      refute log =~ "Processing with"
    end
  end

  # `config/test.exs` keeps the suite at `:warning`. Lowering it is the only way
  # to see a `:debug` dispatch line, and it has to be the primary level: both
  # `with_log(level: :debug)` and `Logger.put_process_level/2` were measured
  # against this request and captured nothing.
  @spec with_debug_log((-> result)) :: {result, String.t()} when result: term()
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
  @spec parameters(String.t()) :: String.t() | nil
  defp parameters(log) do
    log |> String.split("\n") |> Enum.find(&String.contains?(&1, "Parameters:"))
  end

  @spec magic_link_token() :: String.t()
  defp magic_link_token do
    assert_received {:email, %Swoosh.Email{} = delivered}

    base =
      :hospitality_coms
      |> Application.fetch_env!(:magic_link_base_urls)
      |> Map.fetch!("en")

    [_before, rest] = String.split(delivered.text_body, base, parts: 2)

    rest |> String.split("\n", parts: 2) |> hd() |> String.trim()
  end
end
