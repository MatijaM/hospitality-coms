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

  Two values and nothing else: the person's **id**, and the session token's
  **digest**. No `HospitalityComs.Accounts.Person` struct — a channel crash
  report is `inspect/1` of the socket, so anything in assigns is anything in the
  logs, and the transport needs an id rather than an address. No raw token
  either: U2 hashes session tokens at rest precisely so that a leak yields
  digests, and keeping the token in memory for the length of a connection would
  hand it back.

  Membership is not cached at all.

  ## The session is derived again at every join, and that is new

  It used to be derived once. `connect/3` authenticated and the socket then held
  the person for ever, so log-out worked only because
  `HospitalityComsWeb.PersonAuth.disconnect_sessions/1` broadcasts `"disconnect"`
  to the socket's id — the guarantee rested on a *nudge*, which is the one thing
  the rest of this unit is careful never to do. Token expiry broadcasts nothing
  at all, so a socket connected on day 1 kept joining channels on day 20, past
  the fourteen-day horizon; and any deletion skipping that broadcast did the
  same.

  `join_scope/1` closes it: every `join/3` in this unit asks
  `HospitalityComs.Accounts.get_person_by_session_token_digest/2` again, against
  the same row and the same horizon an HTTP request is checked against. The
  broadcast stays, as the thing that shuts a socket promptly rather than the
  thing that makes it powerless.

  ### Per join, not per event, and the residue that leaves

  `handle_in/3` still builds its scope from the socket's assigns without a
  lookup. Three reasons, and one thing they do not cover.

    * The join is already the enforcement point (KTD8). Deriving the session
      there means authentication and authorization are answered by the same
      call, at the same instant, against the same rows — and a client rejoins
      constantly, because Phoenix's JS client rejoins on every `phx_error`,
      every reconnect and every server restart.
    * Per event would change `person_scope/1` from returning a scope to
      returning a result, so every `handle_in/3` would branch on authentication
      before it could branch on authorization. That is a lookup in front of
      every inbound message for a question whose answer changed at most once.
    * What an expired-but-not-deleted session can do on a channel it already
      holds is what its own person could do by logging in again. It is the same
      person, on a live engagement, sending as their own author.

  **The residue**, stated plainly: a token deleted while a channel is open
  leaves that channel able to send until it next joins, unless
  `disconnect_sessions/1` reached it. Log-out, magic-link redemption and email
  change all go through `disconnect_sessions/1`, so the uncovered case is a
  deletion by some future path that does not — and U10's erasure is the one to
  watch, because it deletes the person rather than the session.

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
  What a connected socket carries.

  Three values, all of them safe to print: the id of the person it
  authenticated as, the digest of the token it authenticated with, and the topic
  Phoenix disconnects it on. No `Person` struct — a crash report is the
  inspected socket — and no raw token, because the digest is what this
  application is willing to keep at rest.
  """
  @type session() :: %{
          person_id: Ecto.UUID.t(),
          token_digest: binary(),
          socket_id: String.t()
        }

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
    |> session(Accounts.session_token_digest(token))
  end

  # The digest is computed once, here, and the raw token goes no further. It is
  # the value the socket keeps and the value `join_scope/1` re-derives from, and
  # it is also what the socket id is named after (KTD7), so nothing downstream
  # of this line holds a working credential.
  @spec session({Person.t(), DateTime.t()} | nil, binary()) :: {:ok, session()} | :error
  defp session(nil, _digest), do: :error

  defp session({%Person{id: person_id}, _inserted_at}, digest) do
    {:ok,
     %{
       person_id: person_id,
       token_digest: digest,
       socket_id: PersonAuth.session_topic(digest)
     }}
  end

  @doc """
  A person scope for a **join**, with the session derived again first.

  The one place the credential is re-checked after `connect/3`. It asks
  `HospitalityComs.Accounts.get_person_by_session_token_digest/2` about the same
  row and the same fourteen-day horizon an HTTP request is checked against, so a
  token that was deleted or has aged out refuses the join whether or not
  anything was broadcast to the socket.

  `:no_session` is a deleted row and an expired one alike. Every caller turns it
  into the same refusal it gives an id that names nothing, so the answer says
  only that this session cannot have this topic.

  The person comes back from that read rather than from the socket, so the scope
  a join hands its context is the row as it is now.
  """
  @spec join_scope(Socket.t()) :: {:ok, PersonScope.t()} | {:error, :no_session}
  def join_scope(%Socket{assigns: %{token_digest: digest}}) when is_binary(digest) do
    now = Clock.now()

    digest
    |> Accounts.get_person_by_session_token_digest(now)
    |> live_session(now)
  end

  @spec live_session({Person.t(), DateTime.t()} | nil, DateTime.t()) ::
          {:ok, PersonScope.t()} | {:error, :no_session}
  defp live_session(nil, _now), do: {:error, :no_session}

  defp live_session({%Person{} = person, _inserted_at}, now) do
    {:ok, PersonScope.for_person(person, now)}
  end

  @doc """
  The entity id a channel topic's suffix names, if it is one.

  A topic arrives from the client, so its suffix is user input in a place that
  does not look like one — `"venue_room:" <> venue_id` reads like a route
  parameter and is not validated like one. Handed to a context it reaches Ecto's
  query builder uncast and raises `Ecto.Query.CastError`, which the transport
  reports as a crash rather than a refusal. That is worse than untidy: a caller
  can then tell a *malformed* id from an unknown one by which answer they get,
  which is the not-found-rather-than-forbidden rule (AE1) lost at the one place
  the id comes from outside.

  The shape is `HospitalityComs.Accounts.EmployerScope`'s `uuid!/1`, and taking
  `byte_size(id) == 36` first is the load-bearing half rather than a cheap
  pre-filter: `Ecto.UUID.cast/1` on its own also accepts sixteen raw bytes and
  encodes them, so any sixteen-character string would come back a valid-looking
  id. That module raises, because a scope built from nonsense fails three layers
  away inside Postgres; this one returns, because a channel's answer to nonsense
  is the same refusal it gives an id that names nothing.
  """
  @spec topic_id(String.t()) :: {:ok, Ecto.UUID.t()} | :error
  def topic_id(id) when byte_size(id) == 36, do: Ecto.UUID.cast(id)
  def topic_id(_id), do: :error

  @doc """
  A person scope for this socket, at a freshly read instant and with no lookup.

  Called at the top of every `handle_in/3`, and from `handle_info(:after_join,
  …)`. It reads the clock each time, which is KTD5's unit of work being the
  inbound event rather than the connection.

  The person it carries is the id the socket holds and nothing else — every
  context this reaches destructures `%PersonScope{person: %Person{id: _}}` and
  uses the id, so the struct is the shape they expect rather than a record. A
  join wants `join_scope/1` instead, which derives the session again and hands
  back the row.
  """
  @spec person_scope(Socket.t()) :: PersonScope.t()
  def person_scope(%Socket{assigns: %{person_id: person_id}}) when is_binary(person_id) do
    PersonScope.for_person(%Person{id: person_id}, Clock.now())
  end

  @doc """
  An employer scope for this socket at `venue_id`, at a freshly read instant.

  Derives the session and then the grant-holding engagement, on every call,
  rather than believing anything the socket is carrying — so a grant revoked a
  second ago produces `{:error, :no_grant}` with no job having run, and a
  session ended a second ago produces `{:error, :no_session}`. The venue comes
  from the channel topic, never from the credential.

  Called from `join/3` only, which is why it takes the session's cost.
  """
  @spec employer_scope(Socket.t(), Ecto.UUID.t()) ::
          {:ok, EmployerScope.t()} | {:error, :no_grant | :no_session}
  def employer_scope(%Socket{} = socket, venue_id) when is_binary(venue_id) do
    with {:ok, scope} <- join_scope(socket) do
      scope
      |> Engagements.fetch_grant_holding_engagement(venue_id)
      |> acting_scope(venue_id, scope.now)
    end
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
