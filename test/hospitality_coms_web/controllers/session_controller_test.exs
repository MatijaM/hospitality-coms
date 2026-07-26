defmodule HospitalityComsWeb.SessionControllerTest do
  @moduledoc """
  Registration and authentication end to end over HTTP, with nothing in the
  database but people and their tokens.

  The unit's verification is that a person registers and authenticates with no
  venue existing — so the last test in this file counts the tables that hold
  rows, which is the strongest form that claim can take while the employer zone
  does not exist yet.
  """

  use HospitalityComsWeb.ConnCase, async: false

  import HospitalityComs.AccountsFixtures

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Clock
  alias HospitalityComs.Repo

  @now ~U[2026-03-01 12:00:00.000000Z]

  setup do
    Clock.Offset.set(@now)
    on_exit(&Clock.Offset.reset/0)
    :ok
  end

  defp magic_link_token do
    assert_received {:email, %Swoosh.Email{} = delivered}
    base = Application.fetch_env!(:hospitality_coms, :magic_link_base_url)
    [_before, rest] = String.split(delivered.text_body, base, parts: 2)

    rest |> String.split("\n", parts: 2) |> hd() |> String.trim()
  end

  describe "POST /api/log-in" do
    test "registers an unknown address and issues a login token", %{conn: conn} do
      email = unique_person_email()

      conn = post(conn, ~p"/api/log-in", %{"email" => email})

      assert json_response(conn, 202) == %{"status" => "sent"}
      assert %Person{} = person = Accounts.get_person_by_email(email)
      assert is_nil(person.confirmed_at)
      assert [%PersonToken{context: "login"}] = Repo.all_by(PersonToken, person_id: person.id)
    end

    test "answers the same way for a known address", %{conn: conn} do
      person = person_fixture(%{}, @now)

      conn = post(conn, ~p"/api/log-in", %{"email" => person.email})

      assert json_response(conn, 202) == %{"status" => "sent"}
      assert Repo.aggregate(Person, :count) == 1
    end

    test "rejects a malformed address without creating anything", %{conn: conn} do
      conn = post(conn, ~p"/api/log-in", %{"email" => "not an address"})

      assert %{"errors" => %{"email" => [_message | _rest]}} = json_response(conn, 422)
      assert Repo.aggregate(Person, :count) == 0
    end

    test "rejects a request with no address at all", %{conn: conn} do
      conn = post(conn, ~p"/api/log-in", %{})

      assert %{"error" => "email is required"} = json_response(conn, 400)
    end
  end

  describe "POST /api/log-in/token" do
    test "redeems a link and returns an API token that works", %{conn: conn} do
      email = unique_person_email()
      post(conn, ~p"/api/log-in", %{"email" => email})
      token = magic_link_token()

      conn = post(build_conn(), ~p"/api/log-in/token", %{"token" => token})

      assert %{"token" => api_token, "person" => %{"email" => ^email, "id" => id}} =
               json_response(conn, 201)

      authenticated =
        build_conn() |> put_bearer_token(api_token) |> get(~p"/api/me")

      assert %{"person" => %{"id" => ^id}} = json_response(authenticated, 200)
    end

    test "confirms the person on first redemption", %{conn: conn} do
      email = unique_person_email()
      post(conn, ~p"/api/log-in", %{"email" => email})
      token = magic_link_token()

      post(build_conn(), ~p"/api/log-in/token", %{"token" => token})

      assert %Person{confirmed_at: %DateTime{}} = Accounts.get_person_by_email(email)
    end

    test "refuses a second redemption of the same link", %{conn: conn} do
      post(conn, ~p"/api/log-in", %{"email" => unique_person_email()})
      token = magic_link_token()

      assert build_conn()
             |> post(~p"/api/log-in/token", %{"token" => token})
             |> json_response(201)

      replayed = post(build_conn(), ~p"/api/log-in/token", %{"token" => token})

      assert %{"error" => "the link is invalid or it has expired"} = json_response(replayed, 401)
    end

    test "refuses a link that has expired", %{conn: conn} do
      post(conn, ~p"/api/log-in", %{"email" => unique_person_email()})
      token = magic_link_token()

      Clock.Offset.advance(minute: 16)

      conn = post(build_conn(), ~p"/api/log-in/token", %{"token" => token})

      assert %{"error" => "the link is invalid or it has expired"} = json_response(conn, 401)
    end

    test "refuses a token nobody issued", %{conn: conn} do
      conn = post(conn, ~p"/api/log-in/token", %{"token" => "made-up"})

      assert json_response(conn, 401)
    end

    test "rejects a request with no token", %{conn: conn} do
      conn = post(conn, ~p"/api/log-in/token", %{})

      assert %{"error" => "token is required"} = json_response(conn, 400)
    end
  end

  describe "GET /api/me" do
    test "refuses an unauthenticated request", %{conn: conn} do
      conn = get(conn, ~p"/api/me")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "refuses a token that has expired", %{conn: conn} do
      person = person_fixture(%{}, @now)
      conn = log_in_person(conn, person, @now)

      Clock.Offset.advance(day: 14)

      assert conn |> get(~p"/api/me") |> json_response(401)
    end
  end

  describe "DELETE /api/log-out" do
    setup :register_and_log_in_person

    test "ends the session the token stands for", %{conn: conn} do
      ["Bearer " <> api_token] = Plug.Conn.get_req_header(conn, "authorization")

      assert conn |> delete(~p"/api/log-out") |> response(204)

      replayed = build_conn() |> put_bearer_token(api_token) |> get(~p"/api/me")

      assert json_response(replayed, 401)
    end

    test "deletes the row rather than marking it", %{conn: conn, person: person} do
      delete(conn, ~p"/api/log-out")

      assert Repo.all_by(PersonToken, person_id: person.id, context: "session") == []
    end
  end

  describe "the whole cycle" do
    test "a person registers and authenticates with no venue in the database", %{conn: conn} do
      email = unique_person_email()

      assert conn |> post(~p"/api/log-in", %{"email" => email}) |> json_response(202)

      assert %{"token" => api_token} =
               build_conn()
               |> post(~p"/api/log-in/token", %{"token" => magic_link_token()})
               |> json_response(201)

      assert %{"person" => %{"email" => ^email}} =
               build_conn()
               |> put_bearer_token(api_token)
               |> get(~p"/api/me")
               |> json_response(200)

      # Nothing outside the person zone was touched, and nothing outside it
      # exists to touch: the only populated tables are the two this unit added.
      assert populated_tables() == ["people", "people_tokens"]

      assert build_conn()
             |> put_bearer_token(api_token)
             |> delete(~p"/api/log-out")
             |> response(204)
    end
  end

  # Table names come from the catalogue, not from input, so interpolating them
  # is the only way to ask the question and carries nothing to inject.
  defp populated_tables do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'",
        []
      )

    rows
    |> List.flatten()
    |> Enum.reject(&(&1 == "schema_migrations"))
    |> Enum.filter(&(Repo.query!("SELECT EXISTS (SELECT 1 FROM #{&1})", []).rows == [[true]]))
    |> Enum.sort()
  end
end
