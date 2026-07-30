defmodule HospitalityComsWeb.PersonControllerTest do
  @moduledoc """
  The session's own person over HTTP: `GET /api/me` and `PATCH /api/me`.

  ## Why this file is sandboxed and almost nothing else here is

  Ten test files take real connections because the thing under test spans both
  repos — an engagement is written through `EmployerRepo` and claimed through
  `Repo`, so under the sandbox each would be invisible to the other. Nothing on
  this surface reaches an employer at all: `people` is person zone, `Repo` owns
  it, and there is one connection. So this is the first controller test in the
  tree that may be sandboxed, and it is, because a sandboxed test cannot leave
  residue for the next run to trip over.

  It is `async: false` for `HospitalityComsWeb.ConnCase`'s reason rather than
  for the database's: the request path reads `HospitalityComs.Clock`, and this
  file pins `Clock.Offset`, which is global.

  ## What the exact key set is doing here

  `rendered/1` is called by `HospitalityComsWeb.SessionController` too, so a
  person has one shape on this API whichever route produced it. The exact key
  set is what fails when a field is *added* — the direction an identifying
  column arrives from — and `session_controller_test.exs` has the assertion
  that the redemption reply's person matches this one.
  """

  use HospitalityComsWeb.ConnCase, async: false

  import HospitalityComs.AccountsFixtures

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.DisplayName
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Repo

  @now ~U[2026-03-01 12:00:00.000000Z]
  @person_keys ~w(id email display_name)

  setup do
    Clock.Offset.set(@now)
    on_exit(&Clock.Offset.reset/0)
    :ok
  end

  describe "GET /api/me" do
    setup :register_and_log_in_person

    test "carries the person's display name, and exactly these keys", %{
      conn: conn,
      person: person
    } do
      assert %{"person" => rendered} = conn |> get(~p"/api/me") |> json_response(200)

      assert Enum.sort(Map.keys(rendered)) == Enum.sort(@person_keys)
      assert rendered["id"] == person.id
      assert rendered["email"] == person.email
      assert rendered["display_name"] == person.display_name
      assert rendered["display_name"] in DisplayName.all()
    end

    test "refuses an unauthenticated request", %{conn: _conn} do
      assert %{"error" => %{"code" => "unauthorized"}} =
               build_conn() |> get(~p"/api/me") |> json_response(401)
    end
  end

  describe "PATCH /api/me" do
    setup :register_and_log_in_person

    test "changes the display name and answers the same shape", %{conn: conn} do
      assert %{"person" => rendered} =
               conn
               |> patch(~p"/api/me", %{"display_name" => "Wendy Darling"})
               |> json_response(200)

      assert Enum.sort(Map.keys(rendered)) == Enum.sort(@person_keys)
      assert rendered["display_name"] == "Wendy Darling"
    end

    test "…and a later read shows the new name", %{conn: conn, person: person} do
      # The control for the test above. A route that echoed the body it was
      # handed passes that one completely; this is what says the row moved.
      patch(conn, ~p"/api/me", %{"display_name" => "Prospero"})

      assert %{"person" => %{"display_name" => "Prospero"}} =
               build_conn()
               |> log_in_person(person, @now)
               |> get(~p"/api/me")
               |> json_response(200)
    end

    test "trims what it is given", %{conn: conn} do
      assert %{"person" => %{"display_name" => "Puck"}} =
               conn |> patch(~p"/api/me", %{"display_name" => "  Puck  "}) |> json_response(200)
    end

    test "refuses a body with no display_name at all with 400", %{conn: conn} do
      # "You did not name the thing" and "the thing you named is not acceptable"
      # are two different mistakes — #60's split, and the two bodies are
      # asserted **unequal** so that flattening them would fail here.
      missing = conn |> patch(~p"/api/me", %{}) |> json_response(400)

      assert %{"error" => %{"code" => "bad_request", "message" => message}} = missing
      assert message =~ "display_name"
      refute Map.has_key?(missing["error"], "fields")
    end

    test "refuses a blank name with 422 and a per-field body", %{conn: conn, person: person} do
      rejected = conn |> patch(~p"/api/me", %{"display_name" => "   "}) |> json_response(422)

      assert %{"error" => %{"code" => "unprocessable_entity", "fields" => fields}} = rejected
      assert %{"display_name" => ["can't be blank"]} = fields

      missing = build_conn() |> log_in_person(person, @now) |> patch(~p"/api/me", %{})
      assert json_response(missing, 400) != rejected
    end

    test "refuses a name past the bound with 422", %{conn: conn} do
      too_long = String.duplicate("a", DisplayName.max_length() + 1)

      assert %{"error" => %{"fields" => %{"display_name" => [message]}}} =
               conn |> patch(~p"/api/me", %{"display_name" => too_long}) |> json_response(422)

      assert message =~ "at most #{DisplayName.max_length()}"
    end

    test "accepts a name at exactly the bound", %{conn: conn} do
      # The control for the test above: a bound refusing everything satisfies it.
      at_bound = String.duplicate("a", DisplayName.max_length())

      assert %{"person" => %{"display_name" => ^at_bound}} =
               conn |> patch(~p"/api/me", %{"display_name" => at_bound}) |> json_response(200)
    end

    test "refuses a non-string display_name with 400", %{conn: conn} do
      assert %{"error" => %{"code" => "bad_request"}} =
               conn |> patch(~p"/api/me", %{"display_name" => 42}) |> json_response(400)
    end

    test "refuses an unauthenticated request", %{conn: _conn} do
      assert %{"error" => %{"code" => "unauthorized"}} =
               build_conn()
               |> patch(~p"/api/me", %{"display_name" => "Wendy Darling"})
               |> json_response(401)
    end

    test "leaves the name alone when it refuses", %{conn: conn, person: person} do
      # A refusal that had already written would pass every status assertion
      # above.
      conn |> patch(~p"/api/me", %{"display_name" => "   "}) |> json_response(422)

      assert Repo.get!(Person, person.id).display_name == person.display_name
    end
  end

  describe "the erased arm" do
    test "is unreachable from the route, because erasure ends every session" do
      # `PersonController.renamed/2` handles `{:error, :erased}` and no request
      # can produce it: erasure deletes every token the person holds, so the
      # authenticator answers `401` first. Asserted rather than assumed, because
      # "unreachable" is the kind of claim that stops being true quietly.
      person = person_fixture(%{}, @now)
      token = Accounts.generate_person_session_token(PersonScope.for_person(person, @now))
      conn = put_bearer_token(build_conn(), HospitalityComsWeb.PersonAuth.encode_token(token))

      assert {:ok, _erasure} =
               Lifecycle.erase_person(PersonScope.for_person(person, @now))

      assert %{"error" => %{"code" => "unauthorized"}} =
               conn
               |> patch(~p"/api/me", %{"display_name" => "Somebody Real"})
               |> json_response(401)

      assert Repo.get!(Person, person.id).display_name == Lifecycle.erased_display_name()
    end
  end
end
