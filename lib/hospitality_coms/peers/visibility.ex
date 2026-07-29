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
  **Any strictly positive overlap will do, and there is no minimum**: two people
  whose terms share one second are visible to each other for the whole thirty
  days after the earlier one ends, and can form a connection that outlives both.
  That is the rule as specified rather than an oversight — the origin asks for
  concurrent engagement at one venue and names no duration floor — and it is
  written down because "worked together" reads as more than it enforces. A floor
  would be a product decision and would need a number nothing supplies.
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
  intervals — and one at each of several venues. **The predicate keeps them
  separate**, because the union of two arbitrary intervals is not an interval
  and pretending otherwise would make a gap disappear.

  `merge_stints/1` folds them for one narrow case where that objection does not
  apply, and `HospitalityComs.Peers.list_visible_peers/1` is its only caller;
  see its docstring.

  ## Two spellings, and the test that keeps them together

  `HospitalityComs.Peers.Records.visible_between/3` asks this question in SQL and
  `visible_at?/2` asks it in Elixir, because the first has to run inside a query
  and the second has to produce something a client can render. Two spellings of
  one rule is one more than ideal, so `HospitalityComs.PeersTest` asserts they
  agree over a matrix of term pairs and instants — the same manoeuvre
  `HospitalityComs.RoomsTest` makes against the generated `open_period` column.

  **`visible_at?/2` is the whole predicate and `covers?/2` is half of it.** That
  distinction is load-bearing and was got wrong once: the SQL has six clauses in
  two groups — do the terms overlap at all, and does the interval they produce
  contain the instant — and `covers?/2` answers only the second. A test that
  compared SQL against `covers?/2` alone and restated the first group in the
  test file would be comparing SQL against itself as re-spelled by its own test,
  and it would report a gap **shorter than the thirty-day tail** as visible: two
  terms that miss each other by a day still produce endpoints whose derived
  interval contains today. `concurrent?/1` is that first group, exported so
  there is one spelling of it and the matrix can call it.

  What every spelling *shares* is `cutoff/1`, so the thirty days exist in one
  place. The SQL predicate compares each `ends_at` against it rather than adding
  an interval inside the query, which keeps the predicate in plain Ecto with no
  fragment and keeps the arithmetic on the Elixir side where the tail's length
  is defined.
  """

  @enforce_keys [
    :person_id,
    :display_name,
    :venue_id,
    :venue_name,
    :role_label,
    :visible_from,
    :visible_until
  ]
  defstruct [
    :person_id,
    :display_name,
    :venue_id,
    :venue_name,
    :role_label,
    :visible_from,
    :visible_until
  ]

  @typedoc """
  One counterpart, at one venue, over one interval.

  `person_id` is theirs, not the viewer's; `role_label` is the employer-authored
  label on *their* engagement at the shared venue, which is what the viewer can
  already read off the venue room's roll (KTD15b).

  `display_name` is theirs too, and it is on this list deliberately (#66): it is
  strictly **less** identifying than the `person_id` already beside it, it is
  what makes a list of counterparts readable at all, and its audience is exactly
  the audience the venue room's roll already discloses to.

  There is no email address here and there will not be one — it is the only
  other identifying column `people` has, `HospitalityComs.PeersTest` asserts its
  absence by value *and* by key name, and a new field beside it is precisely the
  change that would tempt somebody to relax that assertion.
  """
  @type t() :: %__MODULE__{
          person_id: Ecto.UUID.t(),
          display_name: String.t(),
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
          display_name: String.t(),
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
      display_name: endpoints.display_name,
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

  `visible_from <= instant < visible_until`, half-open. **Half of the rule, not
  all of it** — the endpoints it compares are `new/1`'s, and `new/1` is total on
  its inputs, so a pair of terms that never overlapped at all still produces an
  interval and this still answers about it. `visible_at?/2` is the whole
  predicate; use that unless you already know the terms are concurrent.
  """
  @spec covers?(t(), DateTime.t()) :: boolean()
  def covers?(%__MODULE__{} = visibility, %DateTime{} = instant) do
    DateTime.compare(visibility.visible_from, instant) != :gt and
      DateTime.compare(visibility.visible_until, instant) == :gt
  end

  @doc """
  Whether two engagement terms are concurrent at all.

  The four comparisons `HospitalityComs.Peers.Records.co_engagements/1` writes
  as its first two groups, in Elixir:

    * neither term is empty — `HospitalityComs.Engagements.end_engagement/2` can
      produce `ends_at == starts_at`, the empty range, which is active at no
      instant and overlaps nothing; and
    * each starts before the other ends.

  Exported so that the SQL predicate has exactly one Elixir counterpart and the
  matrix test in `HospitalityComs.PeersTest` can call it instead of restating
  it. A test that restates a rule cannot catch that rule drifting.
  """
  @spec concurrent?(endpoints()) :: boolean()
  def concurrent?(%{} = endpoints) do
    before?(endpoints.own_starts_at, endpoints.own_ends_at) and
      before?(endpoints.peer_starts_at, endpoints.peer_ends_at) and
      before?(endpoints.own_starts_at, endpoints.peer_ends_at) and
      before?(endpoints.peer_starts_at, endpoints.own_ends_at)
  end

  @doc """
  Whether two engagement terms make their people visible to each other at
  `instant`.

  `concurrent?/1` and then `covers?/2`, which together are every clause
  `HospitalityComs.Peers.Records.co_engagements/1` writes. The one function to
  compare the SQL against, because it is the only one that spells the same rule.
  """
  @spec visible_at?(endpoints(), DateTime.t()) :: boolean()
  def visible_at?(%{} = endpoints, %DateTime{} = instant) do
    concurrent?(endpoints) and endpoints |> new() |> covers?(instant)
  end

  @doc """
  Several intervals for one counterpart at one venue, folded into the one they
  cover between them.

  Every interval handed here contains the instant that produced the list, so
  their union is `[min(visible_from), max(visible_until))` with no gap in it —
  which is why this fold is available at all and why the module's warning about
  unions does not reach it. `HospitalityComs.Peers.list_visible_peers/1` is the
  caller and its docstring carries the argument.

  The surviving entry's `role_label` is the one on the interval that runs
  longest, which is the counterpart's most recent engagement at that venue and
  therefore the label a viewer would expect to see.

  Ordered by venue name and then by the counterpart, which is what
  `HospitalityComs.Peers.Records.visible_peers/2` already ordered by and what a
  client renders.
  """
  @spec merge_stints([t()]) :: [t()]
  def merge_stints(visibilities) when is_list(visibilities) do
    visibilities
    |> Enum.group_by(&{&1.venue_id, &1.person_id})
    |> Enum.map(fn {_venue_and_person, stints} -> merged(stints) end)
    |> Enum.sort_by(&{&1.venue_name, &1.person_id})
  end

  @spec merged([t(), ...]) :: t()
  defp merged(stints) do
    longest = Enum.max_by(stints, & &1.visible_until, DateTime)
    opened_at = stints |> Enum.min_by(& &1.visible_from, DateTime) |> Map.fetch!(:visible_from)

    %{longest | visible_from: opened_at}
  end

  @spec before?(DateTime.t(), DateTime.t()) :: boolean()
  defp before?(left, right), do: DateTime.compare(left, right) == :lt

  @spec later(DateTime.t(), DateTime.t()) :: DateTime.t()
  defp later(left, right), do: pick(DateTime.compare(left, right), :gt, left, right)

  @spec earlier(DateTime.t(), DateTime.t()) :: DateTime.t()
  defp earlier(left, right), do: pick(DateTime.compare(left, right), :lt, left, right)

  @spec pick(:lt | :eq | :gt, :lt | :gt, DateTime.t(), DateTime.t()) :: DateTime.t()
  defp pick(wanted, wanted, left, _right), do: left
  defp pick(_comparison, _wanted, _left, right), do: right
end
