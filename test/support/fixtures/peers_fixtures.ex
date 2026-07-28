defmodule HospitalityComs.PeersFixtures do
  @moduledoc """
  Test helpers for the peer graph, and the one thing they exist to make short.

  Every question this unit asks needs **two people who worked at one venue at
  the same time**, which is a venue, a grant, an employer scope, two invitations
  and two claims before a single assertion. `co_rostered/2` is that, in one
  line, returning both person scopes and both engagements.

  Built on `HospitalityComs.EngagementsFixtures` for the reason
  `HospitalityComs.RoomsFixtures` is: visibility is derived from engagements, an
  engagement needs an invitation written through `HospitalityComs.EmployerRepo`,
  and under the sandbox those are two transactions that cannot see each other's
  rows. So everything commits for real and `EngagementsFixtures.purge/0` — which
  U8 extended with the three peer tables, ahead of the people they all reference
  — removes it before and after each test.

  Every fixture takes the instant explicitly. A test asserting on the
  thirty-day tail has to be able to place a question on either side of it, and
  moving global state to say so is exactly what the injected clock exists to
  avoid.
  """

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.EngagementsFixtures
  alias HospitalityComs.Peers
  alias HospitalityComs.Peers.Connection
  alias HospitalityComs.Peers.ConnectionRequest

  @typedoc "Two people engaged at one venue, and the venue they share."
  @type co_rostering() :: %{
          employer: EmployerScope.t(),
          venue_id: Ecto.UUID.t(),
          first: PersonScope.t(),
          second: PersonScope.t(),
          first_engagement: Engagement.t(),
          second_engagement: Engagement.t()
        }

  @doc """
  The instant these fixtures hang off, shared with every other zone's fixtures.
  """
  @spec fixed_instant() :: DateTime.t()
  def fixed_instant, do: EngagementsFixtures.fixed_instant()

  @doc """
  A person scope for the same person, at another instant.

  What makes "advance the clock and ask again" one line rather than four, and
  what keeps every such advance explicit in the test that makes it.
  """
  @spec person_at(PersonScope.t(), DateTime.t()) :: PersonScope.t()
  def person_at(%PersonScope{person: %Person{} = person}, %DateTime{} = instant) do
    PersonScope.for_person(person, instant)
  end

  @doc """
  Two people engaged at one venue over the given terms, at `now`.

  `attrs` may carry `:first` and `:second`, each a map of engagement attributes
  — `:starts_at`, `:ends_at`, `:role_label` — so a test can make the two terms
  overlap, abut, or miss each other entirely. The default is the same
  month-long term for both, which is the ordinary co-rostering.
  """
  @spec co_rostered(DateTime.t(), map()) :: co_rostering()
  def co_rostered(now \\ fixed_instant(), attrs \\ %{}) do
    {employer, _creation} = EngagementsFixtures.scoped_venue_fixture(now)

    first = EngagementsFixtures.person_scope_fixture(now)
    second = EngagementsFixtures.person_scope_fixture(now)

    first_engagement = engage(employer, first, Map.get(attrs, :first, %{}), now)
    second_engagement = engage(employer, second, Map.get(attrs, :second, %{}), now)

    %{
      employer: employer,
      venue_id: employer.venue_id,
      first: first,
      second: second,
      first_engagement: first_engagement,
      second_engagement: second_engagement
    }
  end

  @doc """
  Engages `person` at the employer's venue over the term in `attrs`.

  Used on its own to add a third person to a venue, or to give an existing
  person a second stint.
  """
  @spec engage(EmployerScope.t(), PersonScope.t(), map(), DateTime.t()) :: Engagement.t()
  def engage(%EmployerScope{} = employer, %PersonScope{} = person, attrs \\ %{}, now \\ nil) do
    instant = now || employer.now

    EngagementsFixtures.engagement_fixture(
      employer,
      person,
      Enum.into(attrs, %{
        role_label: "Bartender",
        starts_at: instant,
        ends_at: DateTime.add(instant, 30, :day),
        code_expires_at: DateTime.add(instant, 7, :day)
      })
    )
  end

  @doc """
  A pending request from `requester` to `addressee`.
  """
  @spec request_fixture(PersonScope.t(), PersonScope.t()) :: ConnectionRequest.t()
  def request_fixture(%PersonScope{} = requester, %PersonScope{person: %Person{id: id}}) do
    {:ok, request} = Peers.request_connection(requester, id)
    request
  end

  @doc """
  A request sent and accepted, returning the connection it made.
  """
  @spec connection_fixture(PersonScope.t(), PersonScope.t()) :: Connection.t()
  def connection_fixture(%PersonScope{} = requester, %PersonScope{} = addressee) do
    request = request_fixture(requester, addressee)
    {:ok, connection} = Peers.accept_request(addressee, request.id)
    connection
  end
end
