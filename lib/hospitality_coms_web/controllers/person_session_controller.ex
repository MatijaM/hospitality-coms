defmodule HospitalityComsWeb.PersonSessionController do
  use HospitalityComsWeb, :controller

  alias HospitalityComs.Accounts
  alias HospitalityComsWeb.PersonAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "Person confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"person" => %{"token" => token} = person_params}, info) do
    case Accounts.login_person_by_magic_link(token) do
      {:ok, {person, tokens_to_disconnect}} ->
        PersonAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> PersonAuth.log_in_person(person, person_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/people/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"person" => person_params}, info) do
    %{"email" => email, "password" => password} = person_params

    if person = Accounts.get_person_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> PersonAuth.log_in_person(person, person_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/people/log-in")
    end
  end

  def update_password(conn, %{"person" => person_params} = params) do
    person = conn.assigns.current_scope.person
    true = Accounts.sudo_mode?(person)
    {:ok, {_person, expired_tokens}} = Accounts.update_person_password(person, person_params)

    # disconnect all existing LiveViews with old sessions
    PersonAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:person_return_to, ~p"/people/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> PersonAuth.log_out_person()
  end
end
