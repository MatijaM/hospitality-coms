defmodule HospitalityComs.Rooms.ShiftRoomPage do
  @moduledoc """
  A venue's shift rooms as an employer session receives them: at most a page of
  them, and whether that page is the lot.

  Not an Ecto schema and no table behind it, exactly as
  `HospitalityComs.Rooms.MessagePage` and `HospitalityComs.Rooms.VenueRoom` are
  not and have none.

  ## The bound, and why the page is selected from the other end

  `HospitalityComs.Rooms.list_shift_rooms/1` returned every shift room the venue
  had ever had. It is one of two lists in this application that grow without
  bound for a single reader — `AGENTS.md`: *"paginate every list that grows with
  tenant data"* — and the other one, a room's history, is what #48 bounded.

  **The ordering is where the two differ, and getting it wrong is silent.**
  `HospitalityComs.Rooms.Records.earliest_first/1` is the order a rota is read
  in, and a `limit` in front of it returns the venue's **oldest** rooms: every
  count assertion passes and the shift the manager created a minute ago is
  missing. So selection is descending and the page is re-ordered ascending
  around it, which is `Records.most_recent_rooms/2` and is the shape
  `Records.most_recent/2` already had for messages.

  ## `complete` costs one row, not a second query

  The read asks for `limit + 1` and notices. The extra row is the probe, it
  never reaches the caller, and it makes the flag exact at the boundary: a venue
  holding exactly `HospitalityComs.Rooms.recent_shift_room_limit/0` rooms is
  `complete` and one holding one more is not.

  A caller cannot recompute it — a full page and a full history of the same
  length are the same list — which is why U5's "load all" control needs it and
  why the bound is observable in a test at all.

  ## The two bounds are independent constants

  Nothing here is derived from `HospitalityComs.Rooms.recent_message_limit/0`
  and no relationship between the two is asserted anywhere. Issue #42 is a live
  sweep of *"constant pairs held together by prose"*, and two lists that happen
  to share a number are exactly that.

  ## Why this is a second struct rather than a generalised one

  `@type t()` is what Dialyzer checks, and a page whose contents are
  `[RoomMessage.t()] | [ShiftRoom.t()]` checks nothing about either. The extent
  vocabulary *is* shared — `MessagePage.extent()` stays the single declaration
  of `:recent | :all`, because a second `@type extent()` would be one word
  declared twice.
  """

  alias HospitalityComs.Rooms.ShiftRoom

  @enforce_keys [:rooms, :complete]
  defstruct [:rooms, :complete]

  @type t() :: %__MODULE__{rooms: [ShiftRoom.t()], complete: boolean()}

  @doc """
  A page from the rows a bounded read returned, which is one more than it will
  hand back.

  **`Enum.take(rows, -limit)`, from the end.** The rows arrive ordered earliest
  first, because that is the order the page is displayed in — so the probe is
  the *earliest* of them, and taking from the front would hand back the venue's
  oldest rooms while satisfying every assertion about how many came back. That
  is the one mistake this function can make silently, and it is why
  `HospitalityComs.RoomsTest` names the first and last rooms rather than
  counting.
  """
  @spec bounded([ShiftRoom.t()], pos_integer()) :: t()
  def bounded(rows, limit) when is_list(rows) and is_integer(limit) and limit > 0 do
    %__MODULE__{rooms: Enum.take(rows, -limit), complete: length(rows) <= limit}
  end

  @doc """
  A page that is every room the venue has, because that is what was asked for.
  """
  @spec whole([ShiftRoom.t()]) :: t()
  def whole(rows) when is_list(rows), do: %__MODULE__{rooms: rows, complete: true}
end
