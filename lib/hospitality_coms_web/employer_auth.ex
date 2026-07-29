defmodule HospitalityComsWeb.EmployerAuth do
  @moduledoc """
  Turning an authenticated person into an employer session at one venue.

  **`HospitalityComsWeb.PersonAuth` authenticates and this authorises.** Two
  conn-side modules whose names both end in `Auth` and which do different jobs
  is a trap for the next reader, so it is said here rather than left to be
  noticed: `PersonAuth` decides *who* is calling and puts a
  `HospitalityComs.Accounts.PersonScope` on `conn.assigns.current_scope`; this
  decides whether that person may act for a named venue, and turns the answer
  into a `HospitalityComs.Accounts.EmployerScope`. It never looks at a token, a
  header or a connection.

  ## One spelling, two transports

  `HospitalityComsWeb.ChannelAuth.employer_scope/2` asked this same question of a
  socket and answered it inline. The shared part is not transport-shaped at all —
  it is `(PersonScope, venue_id) -> {:ok, EmployerScope} | {:error, :no_grant}` —
  so it lives here and the channel delegates, keeping its own signature and its
  own `:no_session` arm. A conn has no `:no_session` arm to keep:
  `HospitalityComsWeb.PersonAuth.require_authenticated_person/2` has already
  refused before a controller action runs.

  `HospitalityComsWeb.EntityId` is the precedent, extracted from `ChannelAuth`
  for exactly this situation when a second caller appeared. Its moduledoc's
  sentence applies verbatim: there is still exactly one spelling.

  ## Nothing is cached, and that is the requirement rather than an optimisation

  `HospitalityComs.Engagements.fetch_grant_holding_engagement/2` runs on **every**
  call. It resolves the person's engagement at that venue, active at the scope's
  instant, carrying a grant the venue has not revoked by that instant — three
  facts about rows, none of them stored on the connection and none derived from
  anything a client sent beyond the venue id.

  So a grant revoked a second ago refuses the next request with no job having
  run, which is KTD8 on the employer's side. `EmployerVenueChannel`'s moduledoc
  states the rule for the socket and it applies here verbatim: build the scope
  from a fresh derivation on every request, and never read a stored `grant_id`.

  **The instant comes off the scope and is never read again** (KTD-E1).
  `PersonAuth.fetch_person_scope/2` read `HospitalityComs.Clock` once for this
  request; a second read here would let one request's authorisation and its
  answer fall on opposite sides of a period boundary. This module is therefore
  absent from `HospitalityComs.Credo.Check.ClockAuthority`'s `:boundary_modules`,
  and adding it there would be the tell that it started reading one.

  ## `:no_grant` is one answer for four causes, and the wire keeps it that way

  `fetch_grant_holding_engagement/2` answers `:no_grant` identically for an
  ended engagement, an engagement holding nothing, a revoked grant, and a venue
  that does not exist. R17 requires the transport to preserve that, so
  `HospitalityComsWeb.EmployerController` renders `404` with one sentence for all
  of them; a `403` would confirm the venue exists, which is the distinction the
  context declines to make.

  **`EmployerVenueChannel` answers the same condition `unauthorized`, and that
  divergence is deliberate.** A channel join has no resource to be not-found
  about, and that channel is internally consistent because it answers
  `unauthorized` for a nonexistent venue too. Two transports, one refusal
  boundary, two status vocabularies — recorded here so a later reviewer does not
  read it as drift and "fix" one of them.
  """

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement

  @doc """
  An employer scope for this person at `venue_id`, resolved against the database.

  The instant is the person scope's, so the authority and everything the
  resulting scope goes on to read agree about which side of every period
  boundary this unit of work fell on.
  """
  @spec employer_scope(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, EmployerScope.t()} | {:error, :no_grant}
  def employer_scope(%PersonScope{} = scope, venue_id) when is_binary(venue_id) do
    scope
    |> Engagements.fetch_grant_holding_engagement(venue_id)
    |> acting_scope(venue_id, scope.now)
  end

  @spec acting_scope(
          {:ok, Engagement.t()} | {:error, :no_grant},
          Ecto.UUID.t(),
          DateTime.t()
        ) :: {:ok, EmployerScope.t()} | {:error, :no_grant}
  defp acting_scope({:ok, %Engagement{grant_id: grant_id}}, venue_id, now) do
    {:ok, EmployerScope.for_grant(venue_id, grant_id, now)}
  end

  defp acting_scope({:error, :no_grant} = refusal, _venue_id, _now), do: refusal
end
