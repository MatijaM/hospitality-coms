defmodule HospitalityComsWeb.SessionController do
  @moduledoc """
  The whole of authentication over JSON: ask for a magic link, redeem it for an
  API token, read the session back, end it.

  The shape is the generated session controller with the response layer swapped
  from redirects and flash to status codes and JSON. The token logic underneath
  is untouched — the same database-backed token table, so that ending a session
  is a delete rather than a wait.

  Two departures from the generated controller are behavioural rather than
  cosmetic.

  Requesting a link registers the person if the address is new, so there is one
  door instead of two. The response is `202 Accepted` whether or not the address
  was known, which is the same answer an enumeration attempt gets either way.

  Redemption answers `401` for an invalid, expired, or already-used link. The
  three are indistinguishable from outside on purpose; from inside they are the
  same fact, which is that no live row matches.
  """

  use HospitalityComsWeb, :controller

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComsWeb.ErrorEnvelope
  alias HospitalityComsWeb.PersonAuth

  @doc """
  Requests a magic link, registering the person if the address is new.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"email" => email}) when is_binary(email) do
    %PersonScope{now: now} = conn.assigns.current_scope

    conn
    |> deliver_or_reject(Accounts.request_login_instructions(email, &magic_link_url/1, now))
  end

  def create(conn, _params), do: reject(conn, :bad_request, "email is required")

  @doc """
  Redeems a magic link and issues the API token a session runs on.
  """
  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token}) when is_binary(token) do
    %PersonScope{now: now} = conn.assigns.current_scope

    conn
    |> issue_or_reject(Accounts.login_person_by_magic_link(token, now), now)
  end

  def confirm(conn, _params), do: reject(conn, :bad_request, "token is required")

  @doc """
  Returns the person the request's API token belongs to.
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    %PersonScope{person: person} = conn.assigns.current_scope
    json(conn, %{person: render_person(person)})
  end

  @doc """
  Ends the session the request's API token stands for.
  """
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    {:ok, ended} = Accounts.delete_person_session_token(conn.assigns.person_token)
    :ok = PersonAuth.disconnect_sessions(ended)

    send_resp(conn, :no_content, "")
  end

  @spec deliver_or_reject(
          Plug.Conn.t(),
          {:ok, Person.t()}
          | {:error, :delivery_failed | :transaction_aborted | Ecto.Changeset.t(Person.t())}
        ) :: Plug.Conn.t()
  defp deliver_or_reject(conn, {:ok, _person}) do
    conn
    |> put_status(:accepted)
    |> json(%{status: "sent"})
  end

  # A provider outage is the mail provider's status, not the client's, and it
  # says nothing about whether the address was known — so it is the same answer
  # either way and the endpoint stays free of an enumeration oracle.
  defp deliver_or_reject(conn, {:error, :delivery_failed}) do
    reject(conn, :bad_gateway, "the log-in email could not be delivered")
  end

  defp deliver_or_reject(conn, {:error, :transaction_aborted}) do
    reject(conn, :internal_server_error, "the log-in request could not be recorded")
  end

  defp deliver_or_reject(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(
      ErrorEnvelope.for_changeset(
        :unprocessable_entity,
        "the address was not accepted",
        changeset
      )
    )
  end

  @spec issue_or_reject(
          Plug.Conn.t(),
          {:ok, {Person.t(), [PersonToken.t()]}}
          | {:error, :not_found | Ecto.Changeset.t(Person.t())},
          DateTime.t()
        ) :: Plug.Conn.t()
  defp issue_or_reject(conn, {:ok, {person, tokens_to_disconnect}}, now) do
    :ok = PersonAuth.disconnect_sessions(tokens_to_disconnect)
    token = Accounts.generate_person_session_token(person, now)

    conn
    |> put_status(:created)
    |> json(%{token: PersonAuth.encode_token(token), person: render_person(person)})
  end

  defp issue_or_reject(conn, {:error, _reason}, _now) do
    reject(conn, :unauthorized, "the link is invalid or it has expired")
  end

  # The status atom is the envelope's code, so the two cannot drift apart.
  @spec reject(Plug.Conn.t(), atom(), String.t()) :: Plug.Conn.t()
  defp reject(conn, status, message) do
    conn
    |> put_status(status)
    |> json(ErrorEnvelope.new(status, message))
  end

  @spec render_person(Person.t()) :: %{id: Ecto.UUID.t(), email: String.t() | nil}
  defp render_person(%Person{} = person) do
    %{id: person.id, email: person.email}
  end

  # The link is followed by a human in a mail client, so it points at whatever
  # surface is going to redeem it — the React client in U12, and nothing at all
  # today. It is configuration rather than a route because this application no
  # longer serves a page for it.
  @spec magic_link_url(String.t()) :: String.t()
  defp magic_link_url(encoded_token) do
    Application.fetch_env!(:hospitality_coms, :magic_link_base_url) <> encoded_token
  end
end
