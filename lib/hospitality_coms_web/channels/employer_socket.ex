defmodule HospitalityComsWeb.EmployerSocket do
  @moduledoc """
  The employer's transport, and the list of topics it cannot reach.

  ## What it routes, and what the absences mean (KTD9)

  One entry: `"employer_venue:*"`. Everything else in the application's topic
  space is missing from this table on purpose, and each absence is a decision
  somebody would otherwise have had to enforce inside a `join/3`:

    * **No `"peer:*"`.** This is the one the plan names. An employer session
      cannot resolve a peer conversation through this transport because there is
      no route to one — `__channel__("peer:" <> person_id)` is `nil` for every
      id, and the refusal happens in Phoenix's dispatch with no application code
      running. AE1's "the transport has no route to the topic", literally.
    * **No `"profile:*"`.** A profile is person-zone data: `attested_entries`,
      `declared_entries` and `attested_entry_disclosures` are person zone,
      `employer_role` holds nothing on any of them, and the *only* employer read
      of an attested entry is through `employer_visible_attested_entries`
      (KTD3), which resolves its venue from
      `app_current_employer_id()` and belongs on
      `HospitalityComsWeb.EmployerVenueChannel` if it is ever put on a
      transport. A worker's own record, and the ledger of what they have chosen
      to conceal, must not be reachable from a session scoped to a venue —
      `WHERE audience_venue_id = <me> AND disclosed = false` is the list of
      workers concealing something, which discloses strictly more than the
      entries do.
    * **No `"venue_room:*"` and no `"shift_room:*"`.** Room conversation is
      worker-facing. `employer_role` holds no privilege at all on
      `room_messages` (U6), a manager reads their venue's room through their own
      engagement on `HospitalityComsWeb.PersonSocket`, and an employer *session*
      that could read a venue's conversation in bulk has no reason to exist. It
      follows that no room's presence is observable from here either, which is
      what stops presence becoming the arithmetic that recovers a suspension
      (KTD18) — see `HospitalityComsWeb.Presence`.

  ## The credential is the same, and the venue is not on it

  There is no separate employer login. A manager's authority derives from a
  grant and `engagements.grant_id` is the column that records they hold one, so
  this socket authenticates the same person session token
  `HospitalityComsWeb.PersonSocket` does, and the venue arrives on the channel
  topic. `HospitalityComsWeb.EmployerVenueChannel` then re-derives the
  grant-holding engagement at join, per venue, against the database.

  That is KTD8 on the employer's side: connect authenticates, join authorises. A
  grant revoked a second ago produces a refused join with no job having run, and
  one socket serves every venue the person manages without a venue ever
  appearing in a credential.

  ## Same session, same id (KTD7)

  `id/1` returns the same `"session:<digest>"` string `PersonSocket` returns for
  the same token, so logging out disconnects both transports of that session and
  neither transport of any other. Ending an engagement does not broadcast to a
  session topic at all — it broadcasts per engagement — which is what keeps
  Venue A's session alive when Venue B's engagement ends.
  """

  use Phoenix.Socket

  alias HospitalityComsWeb.ChannelAuth
  alias Phoenix.Socket

  channel "employer_venue:*", HospitalityComsWeb.EmployerVenueChannel

  @doc """
  Authenticates the session token the transport carried.

  Holding no grant anywhere is not refused here, deliberately: it is a question
  about a venue, this socket has not been told one yet, and answering it at
  connect would mean a manager whose only grant is revoked while connected keeps
  a socket whose joins all fail — which is the correct behaviour, arrived at by
  the join rather than by the connection.
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
