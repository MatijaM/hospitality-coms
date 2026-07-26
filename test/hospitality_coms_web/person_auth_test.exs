defmodule HospitalityComsWeb.PersonAuthTest do
  @moduledoc """
  The HTTP unit-of-work boundary: one instant per request, and a bearer token
  that is only as good as its row.

  These tests move the offsettable clock, because this is the one module that
  reads it. Global state means `async: false`, and the clock is reset around
  every test so a failure here cannot leak into another file.
  """

  use HospitalityComsWeb.ConnCase, async: false

  import HospitalityComs.AccountsFixtures

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.Scope
  alias HospitalityComs.Clock
  alias HospitalityComsWeb.PersonAuth

  @now ~U[2026-03-01 12:00:00.000000Z]

  setup %{conn: conn} do
    Clock.Offset.set(@now)
    on_exit(&Clock.Offset.reset/0)

    person = person_fixture(%{}, @now)

    %{conn: Plug.Conn.put_private(conn, :phoenix_endpoint, @endpoint), person: person}
  end

  describe "fetch_person_scope/2" do
    test "assigns an anonymous scope carrying the instant", %{conn: conn} do
      conn = PersonAuth.fetch_person_scope(conn, [])

      assert %Scope{person: nil, now: @now} = conn.assigns.current_scope
      assert is_nil(conn.assigns.person_token)
    end

    test "assigns the person for a live bearer token", %{conn: conn, person: person} do
      token = Accounts.generate_person_session_token(person, @now)

      conn =
        conn
        |> put_bearer_token(PersonAuth.encode_token(token))
        |> PersonAuth.fetch_person_scope([])

      assert %Scope{person: %Person{id: id}, now: @now} = conn.assigns.current_scope
      assert id == person.id
      assert conn.assigns.person_token == token
    end

    test "reads the clock rather than the wall", %{conn: conn} do
      Clock.Offset.advance(day: 30)

      conn = PersonAuth.fetch_person_scope(conn, [])

      assert conn.assigns.current_scope.now == ~U[2026-03-31 12:00:00.000000Z]
    end

    test "carries one instant, not one per read", %{conn: conn, person: person} do
      token = Accounts.generate_person_session_token(person, @now)

      first =
        conn
        |> put_bearer_token(PersonAuth.encode_token(token))
        |> PersonAuth.fetch_person_scope([])

      Clock.Offset.advance(hour: 1)

      second =
        conn
        |> put_bearer_token(PersonAuth.encode_token(token))
        |> PersonAuth.fetch_person_scope([])

      # Two requests, two instants; within one request the scope holds exactly
      # one, which is what every derived query downstream reads.
      assert first.assigns.current_scope.now == @now
      assert second.assigns.current_scope.now == DateTime.add(@now, 1, :hour)
    end

    test "is anonymous when the header is not a bearer credential", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Basic abc")
        |> PersonAuth.fetch_person_scope([])

      assert %Scope{person: nil} = conn.assigns.current_scope
    end

    test "is anonymous when the token is not base64url", %{conn: conn} do
      conn =
        conn
        |> put_bearer_token("not a token")
        |> PersonAuth.fetch_person_scope([])

      assert %Scope{person: nil} = conn.assigns.current_scope
      assert is_nil(conn.assigns.person_token)
    end

    test "is anonymous when the token decodes but matches no row", %{conn: conn} do
      encoded = PersonAuth.encode_token(:crypto.strong_rand_bytes(32))

      conn =
        conn
        |> put_bearer_token(encoded)
        |> PersonAuth.fetch_person_scope([])

      assert %Scope{person: nil} = conn.assigns.current_scope
    end

    test "is anonymous the moment the token row is deleted", %{conn: conn, person: person} do
      token = Accounts.generate_person_session_token(person, @now)
      encoded = PersonAuth.encode_token(token)

      assert %Scope{person: %Person{}} =
               conn
               |> put_bearer_token(encoded)
               |> PersonAuth.fetch_person_scope([])
               |> Map.fetch!(:assigns)
               |> Map.fetch!(:current_scope)

      :ok = Accounts.delete_person_session_token(token)

      assert %Scope{person: nil} =
               conn
               |> put_bearer_token(encoded)
               |> PersonAuth.fetch_person_scope([])
               |> Map.fetch!(:assigns)
               |> Map.fetch!(:current_scope)
    end

    test "is anonymous once the token is fourteen days old", %{conn: conn, person: person} do
      token = Accounts.generate_person_session_token(person, @now)
      Clock.Offset.advance(day: 14)

      conn =
        conn
        |> put_bearer_token(PersonAuth.encode_token(token))
        |> PersonAuth.fetch_person_scope([])

      assert %Scope{person: nil} = conn.assigns.current_scope
    end
  end

  describe "require_authenticated_person/2" do
    test "lets an authenticated request through", %{conn: conn, person: person} do
      token = Accounts.generate_person_session_token(person, @now)

      conn =
        conn
        |> put_bearer_token(PersonAuth.encode_token(token))
        |> PersonAuth.fetch_person_scope([])
        |> PersonAuth.require_authenticated_person([])

      refute conn.halted
      refute conn.status
    end

    test "halts an anonymous request with a JSON 401", %{conn: conn} do
      conn =
        conn
        |> PersonAuth.fetch_person_scope([])
        |> PersonAuth.require_authenticated_person([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
      assert ["application/json" <> _rest] = Plug.Conn.get_resp_header(conn, "content-type")
    end
  end

  describe "encode_token/1" do
    test "round-trips through the header the plug reads" do
      token = :crypto.strong_rand_bytes(32)
      encoded = PersonAuth.encode_token(token)

      assert {:ok, ^token} = Base.url_decode64(encoded, padding: false)
      refute encoded =~ "="
    end
  end
end
