defmodule HospitalityComsWeb.PersonLive.ConfirmationTest do
  use HospitalityComsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HospitalityComs.AccountsFixtures

  alias HospitalityComs.Accounts

  setup do
    %{unconfirmed_person: unconfirmed_person_fixture(), confirmed_person: person_fixture()}
  end

  describe "Confirm person" do
    test "renders confirmation page for unconfirmed person", %{conn: conn, unconfirmed_person: person} do
      token =
        extract_person_token(fn url ->
          Accounts.deliver_login_instructions(person, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/people/log-in/#{token}")
      assert html =~ "Confirm and stay logged in"
    end

    test "renders login page for confirmed person", %{conn: conn, confirmed_person: person} do
      token =
        extract_person_token(fn url ->
          Accounts.deliver_login_instructions(person, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/people/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Keep me logged in on this device"
    end

    test "renders login page for already logged in person", %{conn: conn, confirmed_person: person} do
      conn = log_in_person(conn, person)

      token =
        extract_person_token(fn url ->
          Accounts.deliver_login_instructions(person, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/people/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Log in"
    end

    test "confirms the given token once", %{conn: conn, unconfirmed_person: person} do
      token =
        extract_person_token(fn url ->
          Accounts.deliver_login_instructions(person, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/people/log-in/#{token}")

      form = form(lv, "#confirmation_form", %{"person" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Person confirmed successfully"

      assert Accounts.get_person!(person.id).confirmed_at
      # we are logged in now
      assert get_session(conn, :person_token)
      assert redirected_to(conn) == ~p"/"

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/people/log-in/#{token}")
        |> follow_redirect(conn, ~p"/people/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "logs confirmed person in without changing confirmed_at", %{
      conn: conn,
      confirmed_person: person
    } do
      token =
        extract_person_token(fn url ->
          Accounts.deliver_login_instructions(person, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/people/log-in/#{token}")

      form = form(lv, "#login_form", %{"person" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Welcome back!"

      assert Accounts.get_person!(person.id).confirmed_at == person.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/people/log-in/#{token}")
        |> follow_redirect(conn, ~p"/people/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/people/log-in/invalid-token")
        |> follow_redirect(conn, ~p"/people/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end
  end
end
