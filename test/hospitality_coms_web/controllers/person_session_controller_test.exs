defmodule HospitalityComsWeb.PersonSessionControllerTest do
  use HospitalityComsWeb.ConnCase, async: true

  import HospitalityComs.AccountsFixtures
  alias HospitalityComs.Accounts

  setup do
    %{unconfirmed_person: unconfirmed_person_fixture(), person: person_fixture()}
  end

  describe "POST /people/log-in - email and password" do
    test "logs the person in", %{conn: conn, person: person} do
      person = set_password(person)

      conn =
        post(conn, ~p"/people/log-in", %{
          "person" => %{"email" => person.email, "password" => valid_person_password()}
        })

      assert get_session(conn, :person_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ person.email
      assert response =~ ~p"/people/settings"
      assert response =~ ~p"/people/log-out"
    end

    test "logs the person in with remember me", %{conn: conn, person: person} do
      person = set_password(person)

      conn =
        post(conn, ~p"/people/log-in", %{
          "person" => %{
            "email" => person.email,
            "password" => valid_person_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_hospitality_coms_web_person_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the person in with return to", %{conn: conn, person: person} do
      person = set_password(person)

      conn =
        conn
        |> init_test_session(person_return_to: "/foo/bar")
        |> post(~p"/people/log-in", %{
          "person" => %{
            "email" => person.email,
            "password" => valid_person_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, person: person} do
      conn =
        post(conn, ~p"/people/log-in?mode=password", %{
          "person" => %{"email" => person.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/people/log-in"
    end
  end

  describe "POST /people/log-in - magic link" do
    test "logs the person in", %{conn: conn, person: person} do
      {token, _hashed_token} = generate_person_magic_link_token(person)

      conn =
        post(conn, ~p"/people/log-in", %{
          "person" => %{"token" => token}
        })

      assert get_session(conn, :person_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ person.email
      assert response =~ ~p"/people/settings"
      assert response =~ ~p"/people/log-out"
    end

    test "confirms unconfirmed person", %{conn: conn, unconfirmed_person: person} do
      {token, _hashed_token} = generate_person_magic_link_token(person)
      refute person.confirmed_at

      conn =
        post(conn, ~p"/people/log-in", %{
          "person" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :person_token)
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Person confirmed successfully."

      assert Accounts.get_person!(person.id).confirmed_at

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ person.email
      assert response =~ ~p"/people/settings"
      assert response =~ ~p"/people/log-out"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/people/log-in", %{
          "person" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The link is invalid or it has expired."

      assert redirected_to(conn) == ~p"/people/log-in"
    end
  end

  describe "DELETE /people/log-out" do
    test "logs the person out", %{conn: conn, person: person} do
      conn = conn |> log_in_person(person) |> delete(~p"/people/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :person_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the person is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/people/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :person_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
