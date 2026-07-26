defmodule HospitalityComsWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use HospitalityComsWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.Scope
  alias HospitalityComs.AccountsFixtures
  alias HospitalityComsWeb.PersonAuth

  using do
    quote do
      # The default endpoint for testing
      @endpoint HospitalityComsWeb.Endpoint

      use HospitalityComsWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import HospitalityComsWeb.ConnCase
    end
  end

  setup tags do
    HospitalityComs.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in people.

      setup :register_and_log_in_person

  It stores an updated connection and a registered person in the test context.
  """
  @spec register_and_log_in_person(map()) :: map()
  def register_and_log_in_person(%{conn: conn} = context) do
    now = Map.get(context, :now, AccountsFixtures.fixed_instant())
    person = AccountsFixtures.person_fixture(%{}, now)

    %{
      conn: log_in_person(conn, person, now),
      person: person,
      scope: Scope.for_person(person, now)
    }
  end

  @doc """
  Puts an API token for `person` on the `conn` as a bearer credential.

  This is the same token any client gets: an actual row in `people_tokens`, so
  a test that deletes the row is exercising the real revocation path.
  """
  @spec log_in_person(Plug.Conn.t(), Person.t(), DateTime.t()) :: Plug.Conn.t()
  def log_in_person(conn, person, now \\ AccountsFixtures.fixed_instant()) do
    token = Accounts.generate_person_session_token(person, now)
    put_bearer_token(conn, PersonAuth.encode_token(token))
  end

  @doc """
  Puts an already-encoded bearer token on the `conn`.
  """
  @spec put_bearer_token(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_bearer_token(conn, encoded_token) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> encoded_token)
  end
end
