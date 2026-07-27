defmodule HospitalityComsWeb.ChannelAuth do
  @moduledoc """
  The channel unit of work: where the instant is captured for a socket, and
  where a bearer token becomes a person.

  This is `HospitalityComsWeb.PersonAuth` for the transport, and it exists as
  one module for one reason. Six things in this unit need an instant — two
  sockets and four channels — and `HospitalityComs.Credo.Check.ClockAuthority`'s
  `:boundary_modules` list is only worth anything while it is short. Six entries
  would make it an inventory of everything that happens to call the clock; one
  entry makes it a statement about where units of work begin. Everything else in
  `HospitalityComsWeb.PersonSocket`, `EmployerSocket`, `VenueRoomChannel`,
  `ShiftRoomChannel`, `PeerChannel` and `EmployerVenueChannel` takes the instant
  off a scope this module built.

  ## The unit is the inbound event, not the connection and not the join

  KTD5 is explicit that a channel's unit of work is one inbound message. A
  channel process lives for hours; an instant stamped at join would authorise a
  send against a moment before the grace window opened, which is the demo's
  flagship beat and would be the one thing the transport got wrong. So
  `person_scope/1` reads the clock on **every** call, and every `join/3` and
  `handle_in/3` in this unit begins with one.

  ## What is cached on the socket, and what is not

  The `HospitalityComs.Accounts.Person` struct is resolved once, at connect, and
  carried in the socket's assigns. Membership never is. That split is the whole
  of KTD8: the session is torn down by Phoenix broadcasting `"disconnect"` to
  the socket's id when the token row is deleted
  (`HospitalityComsWeb.PersonAuth.disconnect_sessions/1`), so a dead session
  cannot outlive its token by more than that broadcast — while *authorization*
  is re-derived from the database on every join and every event, so an ended
  engagement is refused whether or not any broadcast arrived.

  ## Both sockets carry the same credential

  There is no separate employer credential. A manager's authority derives from
  a grant, `engagements.grant_id` is what records that they hold one, and
  `HospitalityComs.Engagements.fetch_grant_holding_engagement/2` is what
  resolves it — per venue, at join, against the database. So `connect/3`
  authenticates and `join/3` authorises, on both sockets, and one employer
  socket serves every venue the person manages without ever putting a venue on
  the transport's credential.
  """

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComsWeb.PersonAuth
  alias Phoenix.Socket

  @typedoc """
  What a connected socket carries: the person it authenticated as, and the id
  of the session it authenticated with.
  """
  @type session() :: %{person: Person.t(), socket_id: String.t()}

  @doc """
  Resolves the token a socket connected with into a person and a socket id.

  The token arrives base64url-encoded because `auth_token: true` puts it on the
  `Sec-WebSocket-Protocol` header verbatim, which is the point of declaring it:
  a query parameter lands in access logs and a header does not.

  `:error` covers a missing token, a token that is not base64url, a token naming
  no row, and a token whose row has expired — indistinguishably, because a
  socket that answered differently would be an oracle for which tokens exist.

  The socket id is `HospitalityComsWeb.PersonAuth.session_topic/1` of the
  token's *digest*, which is KTD7: per session, so ending a Venue B engagement
  cannot take down the Venue A session, and named after the digest, so the
  string that crosses distributed Erlang on every broadcast is not a working
  credential.
  """
  @spec authenticate(term()) :: {:ok, session()} | :error
  def authenticate(encoded) when is_binary(encoded) do
    encoded |> decode() |> resolve()
  end

  def authenticate(_absent), do: :error

  @spec decode(String.t()) :: binary() | nil
  defp decode(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, token} -> token
      :error -> nil
    end
  end

  @spec resolve(binary() | nil) :: {:ok, session()} | :error
  defp resolve(nil), do: :error

  defp resolve(token) do
    token
    |> Accounts.get_person_by_session_token(Clock.now())
    |> session(token)
  end

  @spec session({Person.t(), DateTime.t()} | nil, binary()) :: {:ok, session()} | :error
  defp session(nil, _token), do: :error

  defp session({%Person{} = person, _inserted_at}, token) do
    {:ok, %{person: person, socket_id: socket_id(token)}}
  end

  @spec socket_id(binary()) :: String.t()
  defp socket_id(token),
    do: token |> Accounts.session_token_digest() |> PersonAuth.session_topic()

  @doc """
  A person scope for this socket, at a freshly read instant.

  Called at the top of every `join/3` and every `handle_in/3` on a person
  socket. It reads the clock each time, which is KTD5's unit of work being the
  inbound event rather than the connection.
  """
  @spec person_scope(Socket.t()) :: PersonScope.t()
  def person_scope(%Socket{assigns: %{person: %Person{} = person}}) do
    PersonScope.for_person(person, Clock.now())
  end

  @doc """
  An employer scope for this socket at `venue_id`, at a freshly read instant.

  Re-derives the grant-holding engagement on every call rather than believing
  anything the socket is carrying, so a grant revoked a second ago produces
  `{:error, :no_grant}` with no job having run. The venue comes from the channel
  topic, never from the credential.
  """
  @spec employer_scope(Socket.t(), Ecto.UUID.t()) ::
          {:ok, EmployerScope.t()} | {:error, :no_grant}
  def employer_scope(%Socket{} = socket, venue_id) when is_binary(venue_id) do
    scope = person_scope(socket)

    scope
    |> Engagements.fetch_grant_holding_engagement(venue_id)
    |> acting_scope(venue_id, scope.now)
  end

  @spec acting_scope(
          {:ok, Engagement.t()} | {:error, :no_grant},
          Ecto.UUID.t(),
          DateTime.t()
        ) :: {:ok, EmployerScope.t()} | {:error, :no_grant}
  defp acting_scope({:ok, %Engagement{grant_id: grant_id}}, venue_id, now) do
    {:ok, EmployerScope.for_grant(venue_id, grant_id, now)}
  end

  defp acting_scope({:error, :no_grant} = refusal, _venue_id, _now), do: refusal
end
