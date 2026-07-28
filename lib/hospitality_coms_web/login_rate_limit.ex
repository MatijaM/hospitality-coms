defmodule HospitalityComsWeb.LoginRateLimit do
  @moduledoc """
  A fixed-window counter, keyed on the caller's address, in front of
  `POST /api/log-in`.

  That endpoint merges registration and log-in so that a known and an unknown
  address get the same answer (issue #2), and the cost of the merge is that
  **anonymous, unauthenticated row creation in the person zone's root table is a
  first-class path**: any caller can post an arbitrary address and get a
  committed `people` row plus an outbound email from our domain to somebody who
  never asked for it. Table growth and sender reputation were both load-bearing
  on an endpoint that limited neither.

  One ETS table, no dependency. `hammer` was the alternative and is not taken:
  this is a POC, the mechanism below is a counter and a comparison, and a
  dependency that owns a supervision tree and a backend abstraction buys nothing
  this file does not already do.

  ## The key is the remote address, and it is not the address in the body

  This limiter is standing next to an enumeration oracle that was deliberately
  closed, so it must not reopen it. The refusal is a function of
  `(remote IP, count, window)` and of nothing else: below the limit, a known and
  an unknown address both get `202`; at it, both get `429`. Nothing about the
  body reaches the counter.

  **The shape to refuse for ever is a per-address throttle** — "one link per
  address per window" — which answers `429` for an address that was just used
  and `202` for one that was not. That is a *better* oracle than the merged door
  closed: no timing analysis and no mailbox, just a status code. A future
  duplicate-suppression must suppress the *email* and leave the *response*
  alone.

  ## The window is not a setting, it is the link's own validity

  `@limit` and `@window_seconds` are a pair, and the sentence they exist to make
  true is **one caller can cause at most `limit/0` outbound emails inside the
  lifetime of any single link they caused.** That only holds while the window
  *is* the magic link's validity, so `@window_seconds` is derived from
  `HospitalityComs.Accounts.PersonToken.magic_link_validity_in_minutes/0` at
  compile time rather than declared beside it. Two literals agreeing is a
  property a test can only report *after* they have stopped agreeing; a
  derivation cannot stop.

  Two consequences of counting requests rather than successes, both deliberate.
  A malformed address and a bodyless request consume the same budget a valid one
  does — which is abuse control doing its job, and which also keeps the count
  free of any information about the body. And the plug runs before the
  controller, so a refused request costs no query and sends no mail.

  ## The instant is the scope's, so this module reads no clock

  `HospitalityComsWeb.PersonAuth.fetch_person_scope/2` captured the request's
  instant and put it on `:current_scope`; the window is derived from that. So
  this is not a unit-of-work boundary, it is not in `.credo.exs`'s
  `:boundary_modules`, and a test rolls the window by moving
  `HospitalityComs.Clock.Offset` rather than by sleeping.

  **Residue:** the window index is therefore derived from an injectable clock,
  so U11's `DELETE /api/demo/clock` can move a caller back into a window they
  have already spent or forward into an empty one. `Clock.Offset` is not
  compiled in `:prod`, so nothing in production reaches it, and in the demo it
  costs at most one window's budget.

  ## One bucket per caller, reset in place

  The row is `{ip, window, count}` keyed on the address alone, rather than a row
  per `{ip, window}` pair. Two things follow. The table is bounded by the
  callers seen rather than by every pair of caller and window since boot; and a
  stale bucket is *reset* by the next request from that caller rather than
  accumulating beside a new one — so reclaiming a stale row and leaving it are
  the same thing to the count, which is what lets `prune/0` run on a plain
  interval without reading a clock or agreeing with one.

  `:ets.update_counter/4` reads the stored window and increments the count in
  one atomic operation. The reset that follows a stale read is *not* atomic:
  several requests arriving in the same microsecond as a window rolls can each
  write `1` and lose a handful of increments. That is bounded by the number of
  requests in flight at a window boundary, it can only happen at the instant the
  budget resets anyway, and closing it means a lock or a serialising GenServer
  in front of every log-in attempt. Left as-is, on the record.

  ## What `conn.remote_ip` is, and what it is not

  It is the peer address. Behind a load balancer it is the balancer's, and this
  limit becomes global rather than per-caller. `x-forwarded-for` is deliberately
  **not** consulted: an unauthenticated caller sets it freely, so trusting it
  would let anybody mint a fresh bucket per request, which is strictly worse
  than one shared bucket. Closing it properly needs a trusted-proxy
  configuration — `Plug.RewriteOn` plus a peer allowlist — which is a deployment
  decision rather than an implementation one.
  """

  use GenServer

  import Plug.Conn

  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComsWeb.ErrorEnvelope
  alias Phoenix.Controller

  @table :login_rate_limit

  # Requests per address per window, and the window is not a number chosen here:
  # it is the magic link's own validity, read at compile time. The remote call
  # is what puts this module in `PersonToken`'s compile-time dependency set, so
  # changing the validity recompiles the limiter with it and the pair cannot
  # drift. See the moduledoc for the sentence the pair makes true.
  #
  # `@limit` is generous on purpose. A venue's staff behind one NAT address
  # share a bucket, and the cost of being refused is a wait rather than a
  # lockout.
  @limit 10
  @window_seconds PersonToken.magic_link_validity_in_minutes() * 60

  @doc """
  How many log-in attempts one address may make inside one window.
  """
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  How long a window lasts, in seconds.

  Derived from `HospitalityComs.Accounts.PersonToken.magic_link_validity_in_minutes/0`
  rather than declared, for the reason in the moduledoc. Public, like `limit/0`,
  so a caller asks for the bound the plug will actually apply rather than
  restating it — which is how the two would drift.
  """
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc """
  The ETS table the counters live in.

  Public for the same reason the two bounds are: a test that observes the
  counter should not have to write the table's name down a second time.
  """
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Refuses the request when this caller has spent the window's budget.

  A function plug, in the shape `HospitalityComsWeb.PersonAuth`'s two already
  have, so the router reads `plug :limit_login` and the ordering against
  `:fetch_person_scope` — which must come first, because the instant comes from
  the scope — is visible in the pipeline.
  """
  @spec limit_login(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def limit_login(%Plug.Conn{} = conn, _opts) do
    %PersonScope{now: now} = conn.assigns.current_scope

    admit_or_refuse(conn, spend(conn.remote_ip, window(now)))
  end

  @doc """
  Drops every bucket left behind by a window that has passed, and answers how
  many.

  Called on an interval by this module's own process. It is safe on any
  schedule and against any clock, including none: a bucket whose window is not
  the newest one in the table would be reset in place by the next request from
  that caller, so deleting it and leaving it are the same thing to the count.
  That is the whole reason the row is keyed on the address rather than on the
  pair.

  Public so a test drives the same statement the interval drives, rather than
  waiting a window for it.
  """
  @spec prune() :: non_neg_integer()
  def prune, do: prune_below(newest_window())

  @doc """
  Starts the process that owns the table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Creates the table and schedules the first reclamation.

  The table is `:public` with write concurrency, because every request process
  writes to it directly; this process exists only to own it, since an ETS table
  dies with its creator and a plug runs in a process that lives for one request.
  """
  @impl GenServer
  @spec init(keyword()) :: {:ok, reference()}
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, schedule_prune()}
  end

  @doc """
  Reclaims stale buckets and schedules the next pass.
  """
  @impl GenServer
  @spec handle_info(:prune, reference()) :: {:noreply, reference()}
  def handle_info(:prune, _timer) do
    prune()
    {:noreply, schedule_prune()}
  end

  @spec schedule_prune() :: reference()
  defp schedule_prune, do: Process.send_after(self(), :prune, @window_seconds * 1_000)

  @spec window(DateTime.t()) :: integer()
  defp window(%DateTime{} = instant), do: div(DateTime.to_unix(instant), @window_seconds)

  # `update_counter/4` answers `[stored_window, new_count]` — position two read
  # by incrementing it by zero — so one atomic operation both increments this
  # window's count and says which window the stored count belongs to.
  @spec spend(:inet.ip_address(), integer()) :: :admitted | :refused
  defp spend(ip, window) do
    @table
    |> :ets.update_counter(ip, [{2, 0}, {3, 1}], {ip, window, 0})
    |> reckon(ip, window)
  end

  # The repeated `window` is the whole dispatch: the first clause is a bucket in
  # the window being asked about, the second is one left over from an earlier
  # one, which is reset rather than added to.
  @spec reckon([integer()], :inet.ip_address(), integer()) :: :admitted | :refused
  defp reckon([window, count], _ip, window), do: verdict(count <= @limit)

  defp reckon([_stale, _count], ip, window) do
    :ets.insert(@table, {ip, window, 1})
    :admitted
  end

  @spec verdict(boolean()) :: :admitted | :refused
  defp verdict(true), do: :admitted
  defp verdict(false), do: :refused

  @spec admit_or_refuse(Plug.Conn.t(), :admitted | :refused) :: Plug.Conn.t()
  defp admit_or_refuse(conn, :admitted), do: conn

  # `retry-after` carries the window, not the caller's position in it, so every
  # caller refused inside one window is told the same thing.
  defp admit_or_refuse(conn, :refused) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@window_seconds))
    |> put_status(:too_many_requests)
    |> Controller.json(
      ErrorEnvelope.new(:too_many_requests, "too many log-in attempts from this address")
    )
    |> halt()
  end

  @spec newest_window() :: integer()
  defp newest_window do
    :ets.foldl(fn {_ip, window, _count}, newest -> max(window, newest) end, 0, @table)
  end

  @spec prune_below(integer()) :: non_neg_integer()
  defp prune_below(window) do
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", window}], [true]}])
  end
end
