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
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
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
    {:ok, conn: with_own_remote_ip(Phoenix.ConnTest.build_conn())}
  end

  @doc """
  Gives a conn a remote address no other test in the suite will use.

  Issue #15 put a per-address rate limiter in front of `POST /api/log-in`, and
  its counter is one ETS table for the whole node that nothing resets. **The key
  space is what isolates the tests**: every test is a different client of the
  same live counter, so no test can spend another's budget, and none of them has
  to know the limiter is there.

  A reset hook was the alternative and is worse — it is a second mechanism to
  forget, and forgetting it fails in whichever file happens to run next rather
  than in the one that forgot. It would also put a test-only export in `lib/`.

  This matters immediately rather than hypothetically:
  `session_controller_test.exs` makes ten `POST /api/log-in` calls at one pinned
  instant, so on one shared address the file would go red at whichever call
  crossed the limit.
  """
  @spec with_own_remote_ip(Plug.Conn.t()) :: Plug.Conn.t()
  def with_own_remote_ip(%Plug.Conn{} = conn) do
    %{conn | remote_ip: unique_remote_ip()}
  end

  # A documentation-range address per test, from the same counter every unique
  # fixture value in this suite comes from.
  @spec unique_remote_ip() :: :inet.ip4_address()
  defp unique_remote_ip do
    n = System.unique_integer([:positive])

    {198, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end

  @doc """
  Setup helper that registers and logs in people.

      setup :register_and_log_in_person

  It stores an updated connection and a registered person in the test context.

  The instant defaults to the clock's, not to a constant. A conn test runs
  against the real request path, and the plug reading that clock is what
  decides whether the token it was handed has expired — so a helper minting
  from a hardcoded date and a plug validating against a pinned one disagree by
  however far the test moved the clock, and silently, until the gap crosses
  fourteen days. A test that wants a different instant says so with `:now`.
  """
  @spec register_and_log_in_person(map()) :: map()
  def register_and_log_in_person(%{conn: conn} = context) do
    now = Map.get_lazy(context, :now, &Clock.now/0)
    person = HospitalityComs.AccountsFixtures.person_fixture(%{}, now)

    %{
      conn: log_in_person(conn, person, now),
      person: person,
      scope: PersonScope.for_person(person, now)
    }
  end

  @doc """
  Puts an API token for `person` on the `conn` as a bearer credential.

  This is the same token any client gets: an actual row in `people_tokens`, so
  a test that deletes the row is exercising the real revocation path. It is
  stamped from the clock for the same reason the setup helper is.
  """
  @spec log_in_person(Plug.Conn.t(), Person.t(), DateTime.t()) :: Plug.Conn.t()
  def log_in_person(conn, person, now \\ Clock.now()) do
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
