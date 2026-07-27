defmodule HospitalityComsWeb.EmployerVenueChannel do
  @moduledoc """
  One venue's employer surface: the only topic
  `HospitalityComsWeb.EmployerSocket` routes.

  ## Join is where the authority is checked (KTD8, from the employer's side)

  `connect/3` authenticates the human. This is where it is decided whether that
  human may act *for this venue*, and the decision is
  `HospitalityComs.Engagements.fetch_grant_holding_engagement/2`: an engagement
  of theirs at this venue, active at this instant, naming a grant the venue has
  not revoked. Every one of those three is derived and none is stored, so a
  grant revoked a second ago produces a refused join with no job having run —
  the same property the worker's side gets from an engagement's period.

  Re-derived per join, cached nowhere. A session that joined an hour ago and
  rejoins now is asked again.

  ## What it carries, and what it will never carry

  The join reply is the venue and the grant the session is acting under. No
  person id: `HospitalityComs.Accounts.EmployerScope` has no `person` field for
  the reason KTD2 gives, and putting one on the wire here would be the same
  crossing by another route.

  There is no presence on this topic and no room event, because
  `EmployerSocket` routes no room. See that module for why each absence is a
  decision rather than an omission.

  U9 hangs the per-employer view off this channel. It needs nothing from here
  but the scope the join already resolved.
  """

  use HospitalityComsWeb, :channel

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComsWeb.ChannelAuth
  alias HospitalityComsWeb.ErrorEnvelope
  alias Phoenix.Socket

  # One sentence for a venue that does not exist, an engagement that ended, an
  # engagement holding nothing, and a grant that was revoked. Telling them apart
  # would enumerate the venues this session does not manage.
  @refusal "this session holds no live grant at that venue"

  @unknown_event "this channel does not handle that event"

  @doc """
  Joins a venue's employer surface, if this session holds a live grant there.
  """
  @impl true
  @spec join(String.t(), map(), Socket.t()) ::
          {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  def join("employer_venue:" <> venue_id, _payload, socket) do
    socket
    |> ChannelAuth.employer_scope(venue_id)
    |> admit(socket)
  end

  @spec admit({:ok, EmployerScope.t()} | {:error, :no_grant}, Socket.t()) ::
          {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  defp admit({:ok, %EmployerScope{} = scope}, socket) do
    {:ok, %{venue_id: scope.venue_id, grant_id: scope.grant_id},
     assign(socket, venue_id: scope.venue_id, grant_id: scope.grant_id)}
  end

  defp admit({:error, :no_grant}, _socket) do
    {:error, ErrorEnvelope.new(:unauthorized, @refusal)}
  end

  @doc """
  Answers an event this channel does not carry.

  The only clause today, and the one U9 adds the per-employer view's events in
  front of. `Phoenix.Channel.Server` dispatches to `handle_in/3` unconditionally
  — a channel exporting none raises `UndefinedFunctionError` on every event it
  receives — so this is what stops an employer session crashing its own channel
  by sending a word nobody implemented.
  """
  @impl true
  @spec handle_in(String.t(), map(), Socket.t()) ::
          {:reply, {:error, ErrorEnvelope.t()}, Socket.t()}
  def handle_in(_event, _payload, socket) do
    {:reply, {:error, ErrorEnvelope.new(:bad_request, @unknown_event)}, socket}
  end
end
