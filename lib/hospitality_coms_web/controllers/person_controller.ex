defmodule HospitalityComsWeb.PersonController do
  @moduledoc """
  The session's own person: read it, and change the one thing about it a person
  may change.

      GET   /api/me    who this token belongs to
      PATCH /api/me    the name they are shown under

  ## Why `/api/me` moved here from `HospitalityComsWeb.SessionController`

  `SessionController` is about the session — asking for a link, redeeming it,
  ending it — and `/api/me` answers with a *person*. Once there is a write on
  the same resource, leaving the read behind would put one resource under two
  controllers on one path, which is worse than a module boundary that reads
  correctly. The route, the pipeline and the response shape are unchanged;
  `rendered/1` gained a key.

  `rendered/1` is **public** and `SessionController` calls it for the person it
  puts in the redemption reply. That is `HospitalityComsWeb.RoomChannel.rendered/1`'s
  and `HospitalityComsWeb.RoomController.rendered_shift_room/1`'s precedent: one
  entity gets one shape on this API, called rather than copied, because a second
  spelling is the defect class this tree has fixed three times.

  ## Why the display name is changed *here*, over HTTP

  `/profile` is the surface a name most obviously belongs on and **it cannot
  connect**: U9 shipped no transport for it, `client/src/features/profile/contract.ts`
  exists precisely to write down events no channel answers, and nothing since
  has changed that. #48 established HTTP for person-side reads and #61 gave the
  client a write verb whose `WriteMethod` already includes `PATCH`. So the
  control goes on a surface that works today.

  It is not a channel event for a second reason: a display name is not a room's
  business and not a conversation's. It is a property of the session's own
  person, which is what this route already names.

  ## The two mistakes a body can make are two statuses

  A request carrying no `display_name` at all is `400` — "you did not name the
  thing" — and one carrying a name the schema refuses is `422` with `fields`.
  That is `HospitalityComsWeb.EmployerController`'s split for `shift_type_id`
  and `engagement_id`, and `HospitalityComsWeb.ClaimController`'s for a missing
  `claim_code`.

  There is no `404` here and no enumeration to resist: the resource is the
  caller's own session, so it either authenticates or it does not.

  ## `display_name` is deliberately absent from `filter_parameters`

  `config :phoenix, :filter_parameters` has been an **allowlist** since issue
  #53, so a parameter nobody named prints as `[FILTERED]`. `AGENTS.md` names
  `first_name`, `last_name` and `full_name` as values not to log, and a chosen
  display name is one of those. Adding it to the allowlist would be the bug;
  `test/hospitality_coms_web/parameter_filter_test.exs` pins the list so a
  widening cannot pass unreviewed.

  ## The rate limiter is not extended here

  `HospitalityComsWeb.LoginRateLimit` sits in front of `POST /api/log-in` alone,
  because that is the only endpoint an anonymous caller can use to write a row
  and send an email. Both routes here need a live session, the write touches one
  row the caller already owns, and neither sends mail.
  """

  use HospitalityComsWeb, :controller

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComsWeb.ErrorEnvelope

  @missing_name "display_name is required"
  @erased "this account has been erased"
  @rejected "the name was not accepted"

  @typedoc """
  What a person looks like on the wire, wherever this API renders one.

  `id` rather than `person_id`, which is the spelling `GET /api/me` and the
  redemption reply have carried since U2 and which the client's `decodePerson`
  is written against. It is the *envelope's own subject* rather than an entity
  named inside a larger shape, which is the case `<entity>_id` exists for.
  """
  @type rendered() :: %{
          id: Ecto.UUID.t(),
          email: String.t() | nil,
          display_name: String.t()
        }

  @doc """
  Returns the person the request's API token belongs to.
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    %PersonScope{person: person} = conn.assigns.current_scope
    json(conn, %{person: rendered(person)})
  end

  @doc """
  Changes the name this person is shown under, and answers the person.
  """
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"display_name" => name}) when is_binary(name) do
    %PersonScope{} = scope = conn.assigns.current_scope

    renamed(conn, Accounts.update_display_name(scope, name))
  end

  def update(conn, _params), do: refuse(conn, :bad_request, @missing_name)

  @doc """
  A person on the wire, for whichever surface is answering.

  Public because there are two callers and one entity:
  `HospitalityComsWeb.SessionController` puts a person in the redemption reply,
  and a second spelling there is how `id` and `person_id` — or `email` and no
  `display_name` — come to describe the same row two ways.
  """
  @spec rendered(Person.t()) :: rendered()
  def rendered(%Person{display_name: name} = person) when is_binary(name) do
    %{id: person.id, email: person.email, display_name: name}
  end

  @spec renamed(
          Plug.Conn.t(),
          {:ok, Person.t()} | {:error, :erased | Ecto.Changeset.t(Person.t())}
        ) ::
          Plug.Conn.t()
  defp renamed(conn, {:ok, %Person{} = person}), do: json(conn, %{person: rendered(person)})

  # Unreachable through this route — erasure deletes every token the person
  # holds, so no request can carry a scope naming an erased person — and handled
  # rather than left to crash, for `HospitalityComsWeb.EmployerController`'s
  # reason about `:grant_not_live`. `409` because the row is in a state that
  # refuses the write, not because the request was malformed.
  defp renamed(conn, {:error, :erased}), do: refuse(conn, :conflict, @erased)

  defp renamed(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorEnvelope.for_changeset(:unprocessable_entity, @rejected, changeset))
  end

  # The status atom is the envelope's code, so the two cannot drift apart.
  @spec refuse(Plug.Conn.t(), atom(), String.t()) :: Plug.Conn.t()
  defp refuse(conn, status, message) do
    conn
    |> put_status(status)
    |> json(ErrorEnvelope.new(status, message))
  end
end
