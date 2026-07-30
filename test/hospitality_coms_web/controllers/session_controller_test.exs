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

  import ExUnit.CaptureLog, only: [with_log: 1]
  import HospitalityComs.AccountsFixtures

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Clock
  alias HospitalityComs.Mailer
  alias HospitalityComs.Repo
  alias HospitalityComs.UnreachableMailerAdapter
  alias HospitalityComsWeb.Router

  @now ~U[2026-03-01 12:00:00.000000Z]
  @invalid_link "the link is invalid or it has expired"

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

  describe "where a magic link points" do
    # The link is redeemed by the React client, on its own origin. This
    # application must serve no page at that path — which is exactly what made
    # the wrong host survive four units: pointed at Phoenix, the link 404s, and
    # a 404 reads as a broken link rather than as a misconfigured one.
    #
    # Asserting the *path* is unrouted rather than the *host* is a literal is
    # what makes this survive a deployment: the host is a deploy-time value and
    # `MAGIC_LINK_BASE_URL` overrides it in production, while "this endpoint
    # cannot answer it" holds wherever the client is served from.
    test "at a path this application does not route" do
      %URI{path: path} =
        :hospitality_coms |> Application.fetch_env!(:magic_link_base_url) |> URI.parse()

      assert :error =
               Phoenix.Router.route_info(Router, "GET", path <> "any-token", "localhost")
    end

    test "and the check would notice a path this application does route" do
      assert %{route: _} = Phoenix.Router.route_info(Router, "GET", "/api/me", "localhost")
    end

    # The test above does not catch the wrong *host*, which is the way this
    # actually broke: `/log-in/:token` is unrouted here whether the link says
    # 4000 or 5173, so a link pointing at the API passed it.
    #
    # What must agree is this value and the client dev server's port, and until
    # now nothing linked them but a comment — the shape issue #42 catalogues.
    # Reading the port out of the client's own config is what makes the
    # agreement checkable across the two languages; the alternative is that the
    # coupling stays prose and drifts again the next time either side moves.
    test "at the port the client dev server actually listens on" do
      vite = File.read!(Path.join([__DIR__, "..", "..", "..", "client", "vite.config.ts"]))

      # The control: a regex that matched nothing would make the comparison
      # nil == nil and the test would pass having checked nothing.
      assert [_, client_port] = Regex.run(~r/^\s*port:\s*(\d+),/m, vite)

      %URI{port: link_port} =
        :hospitality_coms |> Application.fetch_env!(:magic_link_base_url) |> URI.parse()

      assert link_port == String.to_integer(client_port)
    end
  end

  describe "POST /api/log-in" do
    test "registers an unknown address and issues a login token", %{conn: conn} do
      email = unique_person_email()

      conn = post(conn, ~p"/api/log-in", %{"email" => email})

      assert json_response(conn, 202) == %{"status" => "sent"}
      assert %Person{} = person = Accounts.get_person_by_email(anonymous_scope(@now), email)
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

      assert %{
               "error" => %{
                 "code" => "unprocessable_entity",
                 "fields" => %{"email" => [_message | _rest]}
               }
             } =
               json_response(conn, 422)

      assert Repo.aggregate(Person, :count) == 0
    end

    test "rejects a request with no address at all", %{conn: conn} do
      conn = post(conn, ~p"/api/log-in", %{})

      assert %{"error" => %{"code" => "bad_request", "message" => "email is required"}} =
               json_response(conn, 400)
    end

    test "answers a mail provider outage in the envelope, not with a 500", %{conn: conn} do
      original = Application.get_env(:hospitality_coms, Mailer)
      Application.put_env(:hospitality_coms, Mailer, adapter: UnreachableMailerAdapter)
      on_exit(fn -> Application.put_env(:hospitality_coms, Mailer, original) end)

      {conn, _log} =
        with_log(fn -> post(conn, ~p"/api/log-in", %{"email" => unique_person_email()}) end)

      assert %{"error" => %{"code" => "bad_gateway", "message" => _message}} =
               json_response(conn, 502)
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

    test "renders the person exactly as GET /api/me does", %{conn: conn} do
      # One entity, one shape. `SessionController` calls
      # `PersonController.rendered/1` rather than spelling a person a second
      # time, and this is the assertion that fails if somebody re-spells it —
      # compared field for field rather than by key set, because a second
      # rendering that agreed on the keys and disagreed on a *value* is the
      # other half of the same defect (`resolution: "declined"` against
      # `:declined`, #36).
      email = unique_person_email()
      post(conn, ~p"/api/log-in", %{"email" => email})

      assert %{"token" => api_token, "person" => redeemed} =
               build_conn()
               |> post(~p"/api/log-in/token", %{"token" => magic_link_token()})
               |> json_response(201)

      assert %{"person" => read} =
               build_conn()
               |> put_bearer_token(api_token)
               |> get(~p"/api/me")
               |> json_response(200)

      assert redeemed == read
      assert is_binary(redeemed["display_name"])
    end

    test "confirms the person on first redemption", %{conn: conn} do
      email = unique_person_email()
      post(conn, ~p"/api/log-in", %{"email" => email})
      token = magic_link_token()

      post(build_conn(), ~p"/api/log-in/token", %{"token" => token})

      assert %Person{confirmed_at: %DateTime{}} =
               Accounts.get_person_by_email(anonymous_scope(@now), email)
    end

    test "refuses a second redemption of the same link", %{conn: conn} do
      post(conn, ~p"/api/log-in", %{"email" => unique_person_email()})
      token = magic_link_token()

      assert build_conn()
             |> post(~p"/api/log-in/token", %{"token" => token})
             |> json_response(201)

      replayed = post(build_conn(), ~p"/api/log-in/token", %{"token" => token})

      assert %{"error" => %{"code" => "unauthorized", "message" => @invalid_link}} =
               json_response(replayed, 401)
    end

    test "refuses a link that has expired", %{conn: conn} do
      post(conn, ~p"/api/log-in", %{"email" => unique_person_email()})
      token = magic_link_token()

      Clock.Offset.advance(minute: 16)

      conn = post(build_conn(), ~p"/api/log-in/token", %{"token" => token})

      assert %{"error" => %{"code" => "unauthorized", "message" => @invalid_link}} =
               json_response(conn, 401)
    end

    test "refuses a token nobody issued", %{conn: conn} do
      conn = post(conn, ~p"/api/log-in/token", %{"token" => "made-up"})

      assert json_response(conn, 401)
    end

    test "rejects a request with no token", %{conn: conn} do
      conn = post(conn, ~p"/api/log-in/token", %{})

      assert %{"error" => %{"code" => "bad_request", "message" => "token is required"}} =
               json_response(conn, 400)
    end
  end

  describe "GET /api/me" do
    test "refuses an unauthenticated request", %{conn: conn} do
      conn = get(conn, ~p"/api/me")

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
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

  describe "the log-in test helpers" do
    test "stamp their token from the pinned clock, not the wall", %{conn: conn} do
      Clock.Offset.advance(day: 3)
      now = Clock.now()
      person = person_fixture(%{}, now)

      conn = log_in_person(conn, person)

      # A helper that mints against a hardcoded instant and then validates
      # against the real clock is a fourteen-day accident waiting for a test
      # that pins the clock somewhere else.
      assert %PersonToken{inserted_at: inserted_at} = session_token_row(conn)
      assert inserted_at == DateTime.truncate(now, :second)
    end

    test "carry the pinned instant onto the scope they build", %{conn: conn} do
      Clock.Offset.advance(day: 3)

      %{scope: scope, conn: logged_in} = register_and_log_in_person(%{conn: conn})

      assert scope.now == Clock.now()
      assert %PersonToken{} = session_token_row(logged_in)
    end
  end

  describe "the error envelope" do
    test "a 404 and a 422 are the same shape", %{conn: conn} do
      not_found = conn |> get("/api/nothing-here") |> json_response(404)

      unprocessable =
        conn |> post(~p"/api/log-in", %{"email" => "not an address"}) |> json_response(422)

      # One top-level key, and it is the same key. A client discriminating on
      # key presence cannot be handed two incompatible value shapes under one
      # name, which is what `errors` was doing.
      assert Map.keys(not_found) == ["error"]
      assert Map.keys(unprocessable) == ["error"]

      assert %{"error" => %{"code" => "not_found", "message" => message}} = not_found
      assert is_binary(message)

      assert %{
               "error" => %{
                 "code" => "unprocessable_entity",
                 "message" => _message,
                 "fields" => %{"email" => [_first | _rest]}
               }
             } = unprocessable
    end

    test "a 401 from the plug is the same shape as one from the controller", %{conn: conn} do
      from_plug = conn |> get(~p"/api/me") |> json_response(401)

      from_controller =
        conn |> post(~p"/api/log-in/token", %{"token" => "made-up"}) |> json_response(401)

      assert %{"error" => %{"code" => "unauthorized", "message" => _plug}} = from_plug
      assert %{"error" => %{"code" => "unauthorized", "message" => _ctrl}} = from_controller
      assert Map.keys(from_plug) == Map.keys(from_controller)
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

  # Finds the stored row behind the bearer credential a conn is carrying.
  defp session_token_row(conn) do
    ["Bearer " <> encoded] = Plug.Conn.get_req_header(conn, "authorization")
    {:ok, raw} = Base.url_decode64(encoded, padding: false)

    Repo.get_by(PersonToken, token: PersonToken.hash_token(raw), context: "session")
  end

  # Table names come from the catalogue, not from input, so interpolating them
  # is the only way to ask the question and carries nothing to inject.
  #
  # `table_type = 'BASE TABLE'` restricts this to relations that *hold* rows,
  # which is what the assertion has always been about. It is not a narrowing:
  # `information_schema.tables` lists views too, and U9's two are the first in
  # the tree — one of them calls `app_current_instant()`, so selecting from it
  # on a connection outside `EmployerRepo.scoped_transaction/2` raises rather
  # than answering, which is precisely the guarantee U3 built that function to
  # give. The set of relations checked here is unchanged.
  defp populated_tables do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
        """,
        []
      )

    rows
    |> List.flatten()
    |> Enum.reject(&(&1 == "schema_migrations"))
    |> Enum.filter(&(Repo.query!("SELECT EXISTS (SELECT 1 FROM #{&1})", []).rows == [[true]]))
    |> Enum.sort()
  end
end
