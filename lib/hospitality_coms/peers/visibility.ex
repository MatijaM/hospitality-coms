defmodule HospitalityComs.Peers.Visibility do
  @moduledoc """
  One interval during which two people can see each other, and the thirty days
  it outlives their employment by.

  **This is not an Ecto schema and there is no `peer_visibility` table.**
  Visibility is derived from the two engagements that produced it, on every
  read, at the instant the caller carries — which is R13 and KTD4 applied to the
  one relationship in the product that survives the employment it came out of.

  Storing it would be the cached authorization decision the plan's Problem Frame
  names as the failure the whole design exists to prevent. It would also be
  wrong within a day: `engagements.ends_at` moves under renewal and under
  ending, so a materialised tail is stale from the first renewal, and a job that
  refreshed it would inherit KTD6b's whole failure class — fire late and it
  captures the period *as corrected*, and its absence is indistinguishable from
  nobody being visible.

  ## What "co-rostered" means here, and why

  Two people are co-rostered at a venue when their engagements there overlap.
  Not when they shared a shift — the plan fixes this in two places and both
  point the same way: the interval is "per pair per **venue**", and its tail
  starts at "the first of the two **engagements** to end". A shift-level reading
  would make the interval per shift and would leave the engagement endpoints
  with nothing to do.

  It also lands where U6 already is. `HospitalityComs.Rooms.list_venue_room_members/2`
  hands a venue room's roll to everyone in it, and that roll is the venue's
  active engagements — so the people a worker can see here are the people they
  are already in a room with, and this adds the thirty days after the room
  closes to them. A shared-shift rule would be a strict subset of this one and
  remains available to a later unit that wants the narrower answer.

  ## The interval

      [ max(their two starts_at), min(their two ends_at) + 30 days )

  Half-open at both ends, like every other interval in the tree (KTD4). The
  lower bound is when they became concurrent; the upper is thirty days past
  **the first of the two engagements to end**, which is the plan's wording and
  is a real decision rather than a detail: a worker who left in January stops
  being visible to a colleague still employed there, in February, thirty days
  on. Keying on the *last* to end would keep somebody visible to a venue's whole
  staff for as long as any one of them stayed.

  A pair can hold several of these at one venue — two separate stints are two
  intervals — and one at each of several venues. They are not merged, because
  the union of two intervals is not an interval and pretending otherwise would
  make a gap disappear.

  ## Two spellings, and the test that keeps them together

  `HospitalityComs.Peers.Records.visible_between/2` asks this question in SQL and
  `covers?/2` asks it in Elixir, because the first has to run inside a query and
  the second has to produce something a client can render. Two spellings of one
  rule is one more than ideal, so `HospitalityComs.PeersTest` asserts they agree
  over a matrix of term pairs and instants — the same manoeuvre
  `HospitalityComs.RoomsTest` makes against the generated `open_period` column.

  What they *share* is `cutoff/1`, so the thirty days exist in one place. The
  SQL predicate compares each `ends_at` against it rather than adding an
  interval inside the query, which keeps the predicate in plain Ecto with no
  fragment and keeps the arithmetic on the Elixir side where the tail's length
  is defined.
  """

  @enforce_keys [:person_id, :venue_id, :venue_name, :role_label, :visible_from, :visible_until]
  defstruct [:person_id, :venue_id, :venue_name, :role_label, :visible_from, :visible_until]

  @typedoc """
  One counterpart, at one venue, over one interval.

  `person_id` is theirs, not the viewer's; `role_label` is the employer-authored
  label on *their* engagement at the shared venue, which is what the viewer can
  already read off the venue room's roll (KTD15b). There is no email address
  here and there will not be one — it is the only other identifying column
  `people` has, and a peer list is not the place to hand it out.
  """
  @type t() :: %__MODULE__{
          person_id: Ecto.UUID.t(),
          venue_id: Ecto.UUID.t(),
          venue_name: String.t(),
          role_label: String.t(),
          visible_from: DateTime.t(),
          visible_until: DateTime.t()
        }

  @typedoc """
  The four endpoints and two labels a visibility row is built from.

  What `HospitalityComs.Peers.Records.visible_peers/2` selects: the two
  engagements' bounds, and the counterpart's venue and role.
  """
  @type endpoints() :: %{
          person_id: Ecto.UUID.t(),
          venue_id: Ecto.UUID.t(),
          venue_name: String.t(),
          role_label: String.t(),
          own_starts_at: DateTime.t(),
          own_ends_at: DateTime.t(),
          peer_starts_at: DateTime.t(),
          peer_ends_at: DateTime.t()
        }

  # R13's thirty days. One number, one place, read by the SQL predicate and by
  # the rendered struct alike.
  @tail_days 30

  @doc """
  How long visibility outlives the first of the two engagements to end.
  """
  @spec tail_days() :: pos_integer()
  def tail_days, do: @tail_days

  @doc """
  The instant an engagement must still have been running after, for its pair to
  be visible at `instant`.

  `instant - 30 days`. An engagement that ended at or before this has run its
  tail out, so `ends_at > cutoff(instant)` is `ends_at + 30 days > instant` with
  the arithmetic on the side of the comparison that does not need an interval
  inside a query.

  Days are exactly 86400 seconds here, and correctly so: every instant this
  application produces is UTC by construction (`HospitalityComs.Clock`), so
  there is no zone in which a day is a different length.
  """
  @spec cutoff(DateTime.t()) :: DateTime.t()
  def cutoff(%DateTime{} = instant), do: DateTime.add(instant, -@tail_days, :day)

  @doc """
  The visibility one pair of overlapping engagements produces.

  `visible_from` is the later of the two starts and `visible_until` is thirty
  days past the earlier of the two ends. Total on its inputs — an overlap that
  is empty produces an interval that contains nothing, and
  `HospitalityComs.Peers.Records` is what declines to select one in the first
  place.
  """
  @spec new(endpoints()) :: t()
  def new(%{} = endpoints) do
    %__MODULE__{
      person_id: endpoints.person_id,
      venue_id: endpoints.venue_id,
      venue_name: endpoints.venue_name,
      role_label: endpoints.role_label,
      visible_from: later(endpoints.own_starts_at, endpoints.peer_starts_at),
      visible_until:
        endpoints.own_ends_at
        |> earlier(endpoints.peer_ends_at)
        |> DateTime.add(@tail_days, :day)
    }
  end

  @doc """
  Whether this interval contains `instant`.

  `visible_from <= instant < visible_until`, half-open. The Elixir spelling of
  `HospitalityComs.Peers.Records.visible_between/2`; `HospitalityComs.PeersTest`
  asserts the two agree rather than taking this sentence's word for it.
  """
  @spec covers?(t(), DateTime.t()) :: boolean()
  def covers?(%__MODULE__{} = visibility, %DateTime{} = instant) do
    DateTime.compare(visibility.visible_from, instant) != :gt and
      DateTime.compare(visibility.visible_until, instant) == :gt
  end

  @spec later(DateTime.t(), DateTime.t()) :: DateTime.t()
  defp later(left, right), do: pick(DateTime.compare(left, right), :gt, left, right)

  @spec earlier(DateTime.t(), DateTime.t()) :: DateTime.t()
  defp earlier(left, right), do: pick(DateTime.compare(left, right), :lt, left, right)

  @spec pick(:lt | :eq | :gt, :lt | :gt, DateTime.t(), DateTime.t()) :: DateTime.t()
  defp pick(wanted, wanted, left, _right), do: left
  defp pick(_comparison, _wanted, _left, right), do: right
end
