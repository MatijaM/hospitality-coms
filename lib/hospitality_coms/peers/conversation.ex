defmodule HospitalityComs.Peers.Conversation do
  @moduledoc """
  A connection seen from one side, which is the only thing the two parties do
  not agree about.

  **This is not an Ecto schema and there is no `conversations` table.** A
  conversation *is* a live connection; giving it a row would create a second
  place for one to be, which is the mistake `HospitalityComs.Rooms.VenueRoom`
  declines at venue-room scale and KTD6b declines at membership scale.

  What the struct is for is the *answer*. `HospitalityComs.Peers.Connection`
  stores its pair canonically — `person_a_id < person_b_id`, so that "one live
  connection per pair" is expressible as a unique index — and a caller does not
  want to know which of the two columns they happen to be in. A conversation
  names the counterpart and says whether it is open, which is what a client
  renders and what U12 builds its list from.

  ## Closed conversations are still conversations

  `open?` is false and the struct is still returned. R15's disconnect closes the
  conversation for both parties and leaves each of them their own messages, so a
  list that dropped closed ones would leave those messages unreachable — the
  person would have a retained copy and no way to find it.

  `disconnected_by_id` is carried rather than hidden. In a 1:1 conversation the
  party who did not disconnect knows they did not, so which of the two it was is
  disclosed by arithmetic whether or not this struct says so; carrying it means
  the client can render "you ended this" and "they ended this" differently
  without inferring anything.
  """

  alias HospitalityComs.Peers.Connection

  @enforce_keys [:connection_id, :peer_id, :connected_at, :open?]
  defstruct [
    :connection_id,
    :peer_id,
    :connected_at,
    :disconnected_at,
    :disconnected_by_id,
    :open?
  ]

  @type t() :: %__MODULE__{
          connection_id: Ecto.UUID.t(),
          peer_id: Ecto.UUID.t(),
          connected_at: DateTime.t(),
          disconnected_at: DateTime.t() | nil,
          disconnected_by_id: Ecto.UUID.t() | nil,
          open?: boolean()
        }

  @doc """
  The conversation `connection` is, as `viewer_id` sees it.

  Raises `FunctionClauseError` through `Connection.counterpart/2` for a viewer
  who is not a party — every caller resolves the connection from one side, so a
  non-party reaching here is a bug rather than an input.
  """
  @spec of_connection(Connection.t(), Ecto.UUID.t()) :: t()
  def of_connection(%Connection{} = connection, viewer_id) when is_binary(viewer_id) do
    %__MODULE__{
      connection_id: connection.id,
      peer_id: Connection.counterpart(connection, viewer_id),
      connected_at: connection.connected_at,
      disconnected_at: connection.disconnected_at,
      disconnected_by_id: connection.disconnected_by_id,
      open?: Connection.open?(connection)
    }
  end
end
