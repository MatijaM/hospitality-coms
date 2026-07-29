defmodule HospitalityComsWeb.ClaimController do
  @moduledoc """
  The worker's half of the handshake: one route, on which a person redeems a
  code somebody handed them and receives the engagement it produced.

      POST /api/claims    {claim_code: "..."} -> 201 {engagement: {...}}

  ## It takes a code and nothing else, and that is the design

  `HospitalityComs.Engagements.claim_invitation/2` casts nothing from the
  caller. Accepting an offer is accepting *the* offer — a claim that could move
  its own start date would be a claim that could grant itself a year at a venue
  that offered a fortnight — so the term, the role and the venue all come off
  the invitation.

  The route is therefore not nested under a venue and needs no employer scope.
  A claimant needs no prior relationship to the venue at all; the code is the
  whole of what they hold, which is the boundary the surface exists to show.

  ## Three refusals are deliberately distinguishable, and this is the only place

  Everywhere else in this API a refusal is flat, because distinguishing its
  causes would disclose something — `HospitalityComsWeb.EmployerController`'s
  one sentence for four causes is the neighbouring example. **R6 asks for the
  opposite here, and the reason is written down so a later reviewer does not
  sweep it into consistency:** an unknown code, a claimed code and an expired
  code tell the holder of a code nothing they do not already have. They hold
  it; that there is an offer behind it is not news, and whether it was taken or
  lapsed is a fact about their own offer.

  `HospitalityComsWeb.ErrorEnvelope`'s `code` **is** the response's status atom,
  which is what stops the two drifting. So on this API "distinguishable by a
  machine" and "a distinct status" are one sentence:

      :unknown_code    404  nothing matches the digest
      :already_claimed 409  it exists, and its state conflicts with the request
      :code_expired    410  it existed, and its validity has lapsed for good

  `:grant_not_live` shares `409` and carries its own sentence. It is a different
  family from R6's three — the code is fine, it is **not spent** (the refusal
  rolls the consume back with it), and re-issuing the grant makes the same code
  good again — so it gets no fourth status of its own, which would claim a
  precision the requirement does not ask for.

  A request carrying no `claim_code` at all is `400`. That is a client bug
  rather than a code that failed, and the two bodies are asserted *unequal* in
  `HospitalityComsWeb.ClaimControllerTest` for the same reason the employer
  routes' two refusals are asserted equal.

  ## The failure shape is `Ecto.Multi`'s four-tuple

  `claim_invitation/2` writes four rows in one transaction and answers
  `{:error, step, reason, changes_so_far}`. **A two-element `{:error, reason}`
  clause matches none of it** — it would compile, it would pass every test that
  never reaches a refusal, and the first refusal in front of an audience would
  be a `FunctionClauseError` rendered as `500`.

  The three changeset-carrying steps collapse into one clause keyed on the
  changeset rather than on the step name. Only `:engagement` is reachable —
  through `engagements_no_overlap`, when one person claims two overlapping
  offers — and the step name is not something a client can act on.

  ## Nothing rendered here names anybody but the reader

  The response carries `engagement_id`, `venue_id`, `role_label`, `starts_at`,
  `ends_at` and `accepted_at`. `Engagement` structs also carry `person_id`,
  `invitation_id`, `grant_id` and `lock_version`; the first is the claimant's
  own, so withholding it is not a boundary rule here, it is the same field-list
  discipline every other response in this API follows. R18 names employer-facing
  payloads and this one is the person's, but it is the one response whose source
  is a whole schema and the one U4's client is written against, so its key set
  is pinned too.

  `accepted_at` is when the code was redeemed and `starts_at` is when the term
  opens; KTD13 keeps both, so an engagement accepted before its start date is
  confirmed and not yet active. The client needs both to say so.

  ## The rate limiter is not extended to this route

  `HospitalityComsWeb.LoginRateLimit` sits in front of `POST /api/log-in` alone.
  This route needs a live session, and the credential it takes is 32 bytes of
  `:crypto.strong_rand_bytes/1` — guessing is not the threat model, and a
  throttle would bound the wrong thing. Whether a session-holder's write rate is
  bounded at all belongs with issue #15, which `CLAUDE.md` already files fan-out
  and abuse control under. Considered here, deliberately not added.
  """

  use HospitalityComsWeb, :controller

  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComsWeb.ErrorEnvelope

  @code_required "claim_code is required"
  @unknown_code "no offer matches that claim code"
  @already_claimed "that claim code has already been redeemed"
  @code_expired "that claim code has expired"
  @grant_not_live "the authority this offer confers is no longer live"
  @unclaimable "the offer could not be claimed"

  @doc """
  Redeems a claim code under the caller's own session.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"claim_code" => code}) when is_binary(code) do
    %PersonScope{} = scope = conn.assigns.current_scope

    scope
    |> Engagements.claim_invitation(code)
    |> claimed(conn)
  end

  def create(conn, _params), do: refuse(conn, :bad_request, @code_required)

  # `Ecto.Multi`'s four-tuple in every arm. See the moduledoc.
  @spec claimed({:ok, Engagements.claim()} | Engagements.claim_failure(), Plug.Conn.t()) ::
          Plug.Conn.t()
  defp claimed({:ok, %{engagement: %Engagement{} = engagement}}, conn) do
    conn
    |> put_status(:created)
    |> json(%{engagement: render_engagement(engagement)})
  end

  defp claimed({:error, :consume, :unknown_code, _changes}, conn) do
    refuse(conn, :not_found, @unknown_code)
  end

  defp claimed({:error, :consume, :already_claimed, _changes}, conn) do
    refuse(conn, :conflict, @already_claimed)
  end

  defp claimed({:error, :consume, :code_expired, _changes}, conn) do
    refuse(conn, :gone, @code_expired)
  end

  defp claimed({:error, :conferrable, :grant_not_live, _changes}, conn) do
    refuse(conn, :conflict, @grant_not_live)
  end

  defp claimed({:error, _step, %Ecto.Changeset{} = changeset, _changes}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorEnvelope.for_changeset(:unprocessable_entity, @unclaimable, changeset))
  end

  # `engagement_id` rather than `id`, because a roster entry, a room message and
  # the employer's own people list all already spell an engagement that way
  # (KTD15b's `author_engagement_id`), and one entity gets one key name across
  # this API.
  #
  # The instants ship as ISO-8601 and are formatted on the client, which is
  # where the reader's timezone is known.
  @spec render_engagement(Engagement.t()) :: %{
          engagement_id: Ecto.UUID.t(),
          venue_id: Ecto.UUID.t(),
          role_label: String.t(),
          starts_at: String.t(),
          ends_at: String.t(),
          accepted_at: String.t()
        }
  defp render_engagement(%Engagement{} = engagement) do
    %{
      engagement_id: engagement.id,
      venue_id: engagement.venue_id,
      role_label: engagement.role_label,
      starts_at: DateTime.to_iso8601(engagement.starts_at),
      ends_at: DateTime.to_iso8601(engagement.ends_at),
      accepted_at: DateTime.to_iso8601(engagement.accepted_at)
    }
  end

  # The status atom is the envelope's code, so the two cannot drift apart —
  # `HospitalityComsWeb.RoomController`'s shape, for the same reason.
  @spec refuse(Plug.Conn.t(), atom(), String.t()) :: Plug.Conn.t()
  defp refuse(conn, status, message) do
    conn
    |> put_status(status)
    |> json(ErrorEnvelope.new(status, message))
  end
end
