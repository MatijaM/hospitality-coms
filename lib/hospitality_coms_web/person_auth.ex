defmodule HospitalityComsWeb.PersonAuth do
  @moduledoc """
  The HTTP unit of work: where the instant is captured and where a bearer token
  becomes a person.

  This is the first unit-of-work boundary in the application, and therefore the
  first module listed in the `:boundary_modules` parameter of
  `HospitalityComs.Credo.Check.ClockAuthority`. It calls `Clock.now/0` exactly
  once per request and puts the result on the scope; everything downstream
  receives that instant as an argument. Nothing else in `lib/` may call the
  clock, and the check fails the build if it does.

  Authentication is a bearer token, and the bearer token is the database-backed
  session token from `HospitalityComs.Accounts.PersonToken` — base64url on the
  wire, raw bytes in the column. There is no cookie and no server-side session:
  a request either carries a live token row or it is anonymous. That is what
  makes revocation immediate, and it is why the generated cookie, remember-me,
  and token-reissue machinery is gone rather than adapted. Reissue in
  particular has no meaning here — an API client cannot be handed a new token
  mid-request the way a browser can be handed a new cookie.
  """

  import Plug.Conn

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.Scope
  alias HospitalityComs.Clock
  alias HospitalityComsWeb.Endpoint
  alias Phoenix.Controller

  @doc """
  Captures the request's instant and resolves its bearer token, assigning
  `:current_scope` and `:person_token`.

  The scope is assigned for every request, authenticated or not: the log-in
  endpoint has no person and still needs the instant to stamp a token with.
  """
  @spec fetch_person_scope(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_person_scope(conn, _opts) do
    now = Clock.now()
    token = bearer_token(conn)

    conn
    |> assign(:person_token, token)
    |> assign(:current_scope, Scope.for_person(authenticate(token, now), now))
  end

  @doc """
  Refuses the request unless it carries a live session token.
  """
  @spec require_authenticated_person(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_authenticated_person(conn, _opts) do
    %Scope{person: person} = conn.assigns.current_scope
    allow_or_refuse(conn, person)
  end

  @doc """
  Disconnects the sockets belonging to the given tokens.

  The socket id is per session rather than per person (KTD7): ending one
  session must not take down the same worker's other sessions. Teardown is best
  effort — the client reconnects, and the refused rejoin is the revocation.
  """
  @spec disconnect_sessions([%{token: binary()}]) :: :ok
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      Endpoint.broadcast(session_topic(token), "disconnect", %{})
    end)
  end

  @doc """
  Encodes a raw session token for transport.
  """
  @spec encode_token(binary()) :: String.t()
  def encode_token(token) when is_binary(token), do: Base.url_encode64(token, padding: false)

  @spec session_topic(binary()) :: String.t()
  defp session_topic(token), do: "session:#{encode_token(token)}"

  @spec authenticate(binary() | nil, DateTime.t()) :: Person.t() | nil
  defp authenticate(nil, _now), do: nil

  defp authenticate(token, now) do
    token |> Accounts.get_person_by_session_token(now) |> person_from_lookup()
  end

  @spec person_from_lookup({Person.t(), DateTime.t()} | nil) :: Person.t() | nil
  defp person_from_lookup({%Person{} = person, _inserted_at}), do: person
  defp person_from_lookup(nil), do: nil

  @spec bearer_token(Plug.Conn.t()) :: binary() | nil
  defp bearer_token(conn) do
    conn |> get_req_header("authorization") |> decode_authorization()
  end

  @spec decode_authorization([String.t()]) :: binary() | nil
  defp decode_authorization(["Bearer " <> encoded | _rest]), do: decode_token(encoded)
  defp decode_authorization(_headers), do: nil

  @spec decode_token(String.t()) :: binary() | nil
  defp decode_token(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, token} -> token
      :error -> nil
    end
  end

  @spec allow_or_refuse(Plug.Conn.t(), Person.t() | nil) :: Plug.Conn.t()
  defp allow_or_refuse(conn, %Person{}), do: conn

  defp allow_or_refuse(conn, nil) do
    conn
    |> put_status(:unauthorized)
    |> Controller.json(%{error: "unauthorized"})
    |> halt()
  end
end
