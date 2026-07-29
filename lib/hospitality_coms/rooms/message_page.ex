defmodule HospitalityComs.Rooms.MessagePage do
  @moduledoc """
  A room's messages as a reader receives them: at most a page of them, and
  whether that page is the lot.

  **This is not an Ecto schema and there is no table behind it**, exactly as
  `HospitalityComs.Rooms.VenueRoom` is not and has none. It is derived on every
  read and cached nowhere.

  ## Why the answer is a page rather than a list

  `HospitalityComs.Rooms.list_venue_room_messages/2` used to be `Repo.all/1`
  over every message the room had ever held. A venue room is the venue's
  standing conversation and KTD14 gives it full history for every current
  member, so it is the one list in this application that grows without bound for
  a single reader — which is what `AGENTS.md` means by "paginate every list that
  grows with tenant data".

  The bound is `HospitalityComs.Rooms.recent_message_limit/0`, it lives in the
  context, and a caller **cannot pass a number**. It chooses an extent:
  `:recent`, which is the default arity, or `:all`. That is the whole of the
  design decision — a route passing `limit: 50` would leave the unbounded
  function one forgetful caller away from production, which is how the
  unbounded read came to be the only one there was.

  ## `complete` is not decoration, and it is not derivable by the caller

  There are two honest ways to know whether more messages exist: count them, or
  ask for one more than you will return and notice. The read does the second, so
  `complete` costs one row rather than a second query, and it is exact at the
  boundary — a room holding exactly `recent_message_limit/0` messages is
  `complete`, and one holding one more is not.

  A caller cannot recompute it from `messages` alone: a full page and a full
  history of the same length are the same list. That is also what makes the
  bound *observable* in a test, which is the property this unit is graded on —
  see `HospitalityComs.RoomsTest`'s "the message bound".

  ## The page is ordered oldest first

  Which is not the order it was selected in. "The most recent fifty" is a
  descending scan with a limit; the page is re-ordered ascending in SQL around
  it, so a room reads the way it is spoken and the way the live stream that
  follows it arrives. A page in selection order would satisfy every count
  assertion and render the room backwards.
  """

  alias HospitalityComs.Rooms.RoomMessage

  @typedoc """
  How much of a room's history a caller is asking for.

  Named rather than numbered on purpose. See the moduledoc.
  """
  @type extent() :: :recent | :all

  @enforce_keys [:messages, :complete]
  defstruct [:messages, :complete]

  @type t() :: %__MODULE__{messages: [RoomMessage.t()], complete: boolean()}

  @doc """
  A page from the rows a bounded read returned, which is one more than it will
  hand back.

  The extra row is the probe: its presence *is* the answer to "is there more",
  and it never reaches the caller.

  **`Enum.take(rows, -limit)`, from the end.** The rows arrive ordered oldest
  first, because that is the order they are read in — so the probe is the
  *oldest* of them, and taking from the front would hand back the oldest fifty
  while satisfying every assertion about how many came back. That is the one
  mistake this function can make silently, and it is why
  `HospitalityComs.RoomsTest` names the first and last bodies rather than
  counting.
  """
  @spec bounded([RoomMessage.t()], pos_integer()) :: t()
  def bounded(rows, limit) when is_list(rows) and is_integer(limit) and limit > 0 do
    %__MODULE__{messages: Enum.take(rows, -limit), complete: length(rows) <= limit}
  end

  @doc """
  A page that is the whole history, because that is what was asked for.
  """
  @spec whole([RoomMessage.t()]) :: t()
  def whole(rows) when is_list(rows), do: %__MODULE__{messages: rows, complete: true}
end
