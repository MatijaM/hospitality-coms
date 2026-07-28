defmodule HospitalityComsWeb.DemoController do
  @moduledoc """
  The demo controls, over HTTP, in the two environments that have them.

  This file compiles from `dev_support/` alongside `HospitalityComs.Demo` and
  `HospitalityComs.Clock.Offset`, and for the same reason: KTD5b. The router
  mounts it behind `Application.compile_env(:hospitality_coms, :demo_routes)`,
  which is set in `config/dev.exs` and `config/test.exs` and nowhere else, so
  under `:prod` the scope's body never runs and no route is registered — the
  mechanism that already gates the Swoosh mailbox preview.

  ## It authenticates nobody, deliberately

  Every other route in this application requires a bearer token, and this one
  requires nothing. That is not an oversight: the controls end engagements
  across venues and move a clock that reaches irreversible deletion, so there is
  no session that *ought* to be able to reach them, and inventing a demo
  credential would suggest the surface is safe to expose to whoever holds it.
  What makes it safe is that it does not exist outside `:dev` and `:test`.

  ## It holds no logic

  Every action turns a request into one `HospitalityComs.Demo` call and one JSON
  body. There is no `Repo` here, no `Ecto.Query`, and no instant: the clock is
  read inside `Demo`, which is the unit-of-work boundary
  `.credo.exs` names — a controller reading it too would be two instants for one
  request, which is exactly what KTD5 exists to stop.

  Every refusal is a `HospitalityComsWeb.ErrorEnvelope`.
  """

  use HospitalityComsWeb, :controller

  alias HospitalityComs.Demo
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Lifecycle.RetentionRun
  alias HospitalityComsWeb.ErrorEnvelope

  # The units `Duration.new!/1` accepts, as strings, so a JSON body naming one
  # can be turned into an atom without `String.to_atom/1` on user input.
  @units ~w(year month week day hour minute second)

  @doc """
  Writes the seed manifest, or reports that it is already there.
  """
  @spec seed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def seed(conn, _params), do: answer(conn, Demo.seed(), &manifest/1)

  @doc """
  Where the clock is.
  """
  @spec show_clock(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show_clock(conn, _params), do: json(conn, %{clock: clock(Demo.clock())})

  @doc """
  Pins the clock to `instant`, or advances it by `advance`.

  Exactly one of the two. Both, or neither, is a `bad_request`: an instant and a
  duration in one body have no unambiguous reading, and answering with whichever
  the implementation happened to check first is how a control silently does
  something other than what it was asked.
  """
  @spec update_clock(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_clock(conn, %{"instant" => instant} = params) when not is_map_key(params, "advance") do
    conn |> instant(instant) |> moved(conn)
  end

  def update_clock(conn, %{"advance" => advance} = params)
      when not is_map_key(params, "instant") do
    conn |> duration(advance) |> moved(conn)
  end

  def update_clock(conn, _params) do
    refuse(conn, :bad_request, "Name exactly one of instant or advance.")
  end

  @doc """
  Returns the clock to the system instant.
  """
  @spec reset_clock(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reset_clock(conn, _params), do: moved(Demo.reset_clock(), conn)

  @doc """
  Runs every scheduled mechanism as though the queue had caught up.
  """
  @spec run_due_work(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def run_due_work(conn, _params) do
    {:ok, work} = Demo.run_due_work()

    json(conn, %{
      due_work: %{
        instant: work.instant,
        swept: work.swept,
        announced: work.announced,
        retention: retention(work.retention)
      }
    })
  end

  @doc """
  Closes every engagement the named person holds.
  """
  @spec end_engagements(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def end_engagements(conn, %{"person_id" => person_id}) do
    answer(conn, Demo.end_all_engagements(person_id), &ended/1)
  end

  ## Rendering

  @spec manifest(Demo.manifest()) :: map()
  defp manifest(seeded), do: %{manifest: seeded}

  @spec ended([Engagement.t()]) :: map()
  defp ended(engagements) do
    %{
      ended:
        Enum.map(engagements, fn %Engagement{} = engagement ->
          %{
            engagement_id: engagement.id,
            venue_id: engagement.venue_id,
            role_label: engagement.role_label,
            ends_at: engagement.ends_at
          }
        end)
    }
  end

  # `Duration` implements neither `String.Chars` nor `Jason.Encoder`, and it is
  # the accumulated advance rather than a wall-clock value, so it is rendered as
  # the unit pairs it actually holds — which is also the shape `POST` accepts.
  @spec clock(Demo.clock_state()) :: map()
  defp clock(state) do
    %{
      instant: state.instant,
      implementation: inspect(state.implementation),
      fixed: state.fixed,
      shift: shift(state.shift)
    }
  end

  @spec shift(Duration.t()) :: %{atom() => integer()}
  defp shift(%Duration{} = duration) do
    Map.new(@units, fn unit -> {unit, Map.fetch!(duration, String.to_existing_atom(unit))} end)
  end

  @spec retention(RetentionRun.t()) :: map()
  defp retention(%RetentionRun{} = run) do
    %{
      retention_run_id: run.id,
      ran_at: run.ran_at,
      outcome: run.outcome,
      own_message_copies: run.own_message_copies,
      shift_messages: run.shift_messages,
      roster_entries: run.roster_entries,
      venue_room_messages: run.venue_room_messages
    }
  end

  ## Answering

  @spec answer(Plug.Conn.t(), {:ok, result} | {:error, term()}, (result -> map())) ::
          Plug.Conn.t()
        when result: var
  defp answer(conn, {:ok, result}, render), do: json(conn, render.(result))
  defp answer(conn, {:error, reason}, _render), do: refused(conn, reason)

  @spec moved({:ok, DateTime.t()} | Plug.Conn.t(), Plug.Conn.t()) :: Plug.Conn.t()
  defp moved({:ok, _instant}, conn), do: json(conn, %{clock: clock(Demo.clock())})
  defp moved(%Plug.Conn{} = refusal, _conn), do: refusal

  @spec instant(Plug.Conn.t(), String.t()) :: {:ok, DateTime.t()} | Plug.Conn.t()
  defp instant(conn, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, instant, _offset} -> Demo.set_clock(instant)
      {:error, _reason} -> refuse(conn, :bad_request, "instant must be an ISO 8601 instant.")
    end
  end

  defp instant(conn, _value), do: refuse(conn, :bad_request, "instant must be a string.")

  # `{"advance": {"day": 31}}`. The unit names are matched against a literal
  # list, so nothing here turns user input into an atom — this application never
  # ships an unbounded `String.to_atom/1`, and a control reachable without a
  # session is the last place to start.
  @spec duration(Plug.Conn.t(), map()) :: {:ok, DateTime.t()} | Plug.Conn.t()
  defp duration(conn, value) when is_map(value) do
    value |> Enum.map(&unit_pair/1) |> advanced(conn)
  end

  defp duration(conn, _value), do: refuse(conn, :bad_request, "advance must be an object.")

  @spec unit_pair({String.t(), term()}) :: {atom(), integer()} | :error
  defp unit_pair({unit, count}) when unit in @units and is_integer(count) do
    {String.to_existing_atom(unit), count}
  end

  defp unit_pair(_pair), do: :error

  @spec advanced([{atom(), integer()} | :error], Plug.Conn.t()) ::
          {:ok, DateTime.t()} | Plug.Conn.t()
  defp advanced([], conn), do: refuse(conn, :bad_request, "advance must name at least one unit.")

  defp advanced(pairs, conn) do
    pairs |> Enum.member?(:error) |> advance_or_refuse(pairs, conn)
  end

  @spec advance_or_refuse(boolean(), [{atom(), integer()} | :error], Plug.Conn.t()) ::
          {:ok, DateTime.t()} | Plug.Conn.t()
  defp advance_or_refuse(true, _pairs, conn) do
    refuse(conn, :bad_request, "advance takes whole counts of #{Enum.join(@units, ", ")}.")
  end

  defp advance_or_refuse(false, pairs, _conn), do: Demo.advance_clock(pairs)

  @spec refused(Plug.Conn.t(), atom() | Ecto.Changeset.t()) :: Plug.Conn.t()
  defp refused(conn, %Ecto.Changeset{} = changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(
      ErrorEnvelope.for_changeset(
        :unprocessable_entity,
        "the demo control was refused",
        changeset
      )
    )
  end

  defp refused(conn, :not_found), do: refuse(conn, :not_found, "No such person.")

  defp refused(conn, :partial_manifest) do
    refuse(
      conn,
      :conflict,
      "This database holds part of a seed run that did not finish. Reset it and seed again."
    )
  end

  defp refused(conn, :last_grant_holder) do
    refuse(
      conn,
      :conflict,
      "One of these engagements is its venue's last grant-holding engagement. Nothing was ended."
    )
  end

  defp refused(conn, :no_grant) do
    refuse(conn, :conflict, "One of these venues holds no live grant. Nothing was ended.")
  end

  defp refused(conn, :stale) do
    refuse(conn, :conflict, "One of these engagements changed while it was being ended.")
  end

  @spec refuse(Plug.Conn.t(), atom(), String.t()) :: Plug.Conn.t()
  defp refuse(conn, code, message) do
    conn |> put_status(code) |> json(ErrorEnvelope.new(code, message))
  end
end
