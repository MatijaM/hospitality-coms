defmodule HospitalityComsWeb.PersonSocket do
  @moduledoc """
  The worker's transport: venue rooms, shift rooms, and one multiplexed peer
  channel.

  ## Two socket modules, and this is the one with peer topics (KTD9)

  `HospitalityComsWeb.EmployerSocket` is a separate module with a separate
  routing table, and the separation is the point. An employer session attempting
  to reach a peer conversation is refused by Phoenix's own dispatch, because
  `EmployerSocket.__channel__("peer")` is `nil` — before any `join/3` runs,
  before any scope is built, before any query is issued. One socket module with
  an authorization check inside `join/3` would put that refusal in a function
  body somebody has to remember to write; two modules put it in the routing
  table, where forgetting it means the feature does not exist rather than that
  the check is missing.

  ## One channel for every peer conversation (KTD10)

  `"peer"` is an exact topic, not a pattern, and it carries every one of this
  person's conversations. `max_channels_per_transport` defaults to 100 in
  Phoenix 1.8.9, and a worker holding engagements at three venues, with a venue
  room and several shift rooms at each, is already using a meaningful fraction
  of that before a single conversation is opened. Multiplexing also means there
  is no per-conversation topic to leak into an employer socket's routing table
  by a later copy-paste.

  ## The credential is a header, and the id is a session (KTD7)

  `auth_token: true` in `HospitalityComsWeb.Endpoint` puts the token on the
  `Sec-WebSocket-Protocol` header rather than in a query parameter, which is
  what keeps a live session token out of access logs and out of the `Referer`
  of anything the page later loads.

  `id/1` is the session, not the person. The documented Phoenix example returns
  a topic built from the user's id, which here would mean that ending an engagement at
  Venue B — which broadcasts nothing to a session topic, but which a later unit
  would be tempted to wire up that way — takes down the Venue A session too.
  Origin R7 and AE1 both say a worker's other employers are untouched, so the id
  is the session and `HospitalityComsWeb.PersonAuth.session_topic/1` is the one
  place its string is written.
  """

  use Phoenix.Socket

  alias HospitalityComsWeb.ChannelAuth
  alias Phoenix.Socket

  channel "venue_room:*", HospitalityComsWeb.VenueRoomChannel
  channel "shift_room:*", HospitalityComsWeb.ShiftRoomChannel
  channel "peer", HospitalityComsWeb.PeerChannel

  @doc """
  Authenticates the session token the transport carried.

  `:error` for a missing, malformed, unknown or expired token, indistinguishably
  — a socket that answered differently would be an oracle for which tokens
  exist. Authorization is not done here: `join/3` re-derives it per topic, per
  join, which is KTD8.
  """
  @impl true
  @spec connect(map(), Socket.t(), map()) :: {:ok, Socket.t()} | :error
  def connect(_params, socket, connect_info) do
    connect_info
    |> Map.get(:auth_token)
    |> ChannelAuth.authenticate()
    |> admit(socket)
  end

  @doc """
  The topic Phoenix disconnects this socket on: its session, never its person.
  """
  @impl true
  @spec id(Socket.t()) :: String.t()
  def id(%Socket{assigns: %{socket_id: socket_id}}), do: socket_id

  # The id and the digest, and nothing else. A `%Person{}` here would put the
  # address in every crash report; the raw token would undo U2's hashing at
  # rest. `HospitalityComsWeb.ChannelAuth.join_scope/1` re-derives the session
  # from the digest at every join.
  @spec admit({:ok, ChannelAuth.session()} | :error, Socket.t()) :: {:ok, Socket.t()} | :error
  defp admit({:ok, session}, socket) do
    {:ok,
     assign(socket,
       person_id: session.person_id,
       token_digest: session.token_digest,
       socket_id: session.socket_id
     )}
  end

  defp admit(:error, _socket), do: :error
end
