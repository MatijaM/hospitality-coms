defmodule HospitalityComs.Rooms.VenueRoom do
  @moduledoc """
  The venue's own room, which has no row.

  **This is not an Ecto schema and there is no `venue_rooms` table.** A venue
  room is exactly one per venue; its membership is a query over active
  engagements minus the person's own suspension; and there is no state it could
  hold that `venues` and `engagements` do not already hold. Giving it a row
  would create a second place for the room to be — one that a venue could exist
  without, or that could exist for a venue that had been closed — which is the
  mistake KTD6b rejects at full size, in miniature.

  A message belonging to a venue room is a `room_messages` row whose
  `shift_room_id` is null. That is the whole of the storage.

  What this struct is for is the *answer*: `HospitalityComs.Rooms` returns it
  from the reads that say which venue rooms a person is in, so a caller has
  something with an identity to render and U7 has something to build a topic
  from. It is derived on every read and cached nowhere.

  ## Full history, and only here

  KTD14 resolves the origin document's contradiction between R14 and R16 in this
  room's favour. Venue-room history is readable in full by anyone currently in
  the room, including messages sent long before their engagement began —
  a venue room is the venue's standing conversation and a new hire joins it
  where it is. Taking R14 literally for *shift* rooms would let a day-one hire
  read every shift conversation the venue has ever held, which is why shift
  rooms are scoped to the people who were rostered on them.
  """

  alias HospitalityComs.Venues.Venue

  @enforce_keys [:venue_id, :name]
  defstruct [:venue_id, :name]

  @type t() :: %__MODULE__{venue_id: Ecto.UUID.t(), name: String.t()}

  @doc """
  The room of a venue.

  Total: every venue has one, always, and there is nothing to look up.
  """
  @spec of_venue(Venue.t()) :: t()
  def of_venue(%Venue{id: id, name: name}) when is_binary(id) do
    %__MODULE__{venue_id: id, name: name}
  end
end
