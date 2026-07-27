defmodule HospitalityComs.Accounts.EmployerScope do
  @moduledoc """
  What one unit of work knows about an employer session: which employer, and
  when.

  It is a distinct struct from `HospitalityComs.Accounts.PersonScope` rather
  than a variant of it, so that a person-zone context function refuses an
  employer caller by function clause instead of by a runtime check somebody has
  to remember to write. See that module for the argument.

  ## It does not name a human, and that is the design

  There is no `person` field here. The employer zone's rule is that no
  employer-zone row carries `person_id` — messages, roster entries, and
  attested entries reference `engagements(id, venue_id)`, and the engagement is
  the single bridge (KTD2). A scope that carried a person would be a way to
  reach one without crossing that bridge, and it would make every employer-zone
  query one destructuring away from a person id it has no business holding.

  A manager is a person, of course, and their authority derives from a grant
  they hold. That grant is an employer-zone row, so it is `grant_id` that
  belongs here — not the human behind it.

  ## `grant_id`, and why it is not enforced

  U4 added it, and it is the field that turns this struct from a tenancy label
  into a capability reference. `employer_id` says which venue the session is
  reading; `grant_id` says under whose authority it is acting.
  `HospitalityComs.Venues` heads every function on
  `%EmployerScope{grant_id: grant_id} when is_binary(grant_id)`, so a scope
  without one is refused by function clause rather than by a check somebody has
  to remember, and the grant is then resolved against the database on every
  call — it must be live at this instant and belong to this venue.

  It is nevertheless not in `@enforce_keys`, and the reason is that a scope
  with no grant is a real thing rather than an incomplete one. The transaction
  wrapper writes `app.employer_id` and `app.now`, and U9's employer-visible
  view filters on those two alone — a disclosure read is per employer, not per
  manager. `for_employer/2` builds that scope, and it can reach nothing in the
  `Venues` context, because none of those functions has a head that matches it.

  What `grant_id` does not do yet is prove anything about who is holding it.
  Deriving a grant from an authenticated person means reading the bridge, which
  U5 builds; until then the scope is constructed by its caller and the tier
  that keeps one employer out of another's data is the same one it has always
  been — the Postgres grants, and the venue filter on every query.

  ## `employer_id` and the instant

  Both are written into the transaction as `app.employer_id` and `app.now` by
  `HospitalityComs.EmployerRepo.scoped_transaction/2`, transaction-locally,
  where the employer-visible view reads them. The instant arrives here from the
  unit-of-work boundary that captured it; `EmployerRepo` never reads the clock,
  because a repo is not a unit of work and a second read of the clock inside
  one is the disagreement `Clock` exists to prevent.
  """

  @enforce_keys [:employer_id, :now]
  defstruct [:employer_id, :now, grant_id: nil]

  @type t() :: %__MODULE__{
          employer_id: Ecto.UUID.t(),
          grant_id: Ecto.UUID.t() | nil,
          now: DateTime.t()
        }

  @doc """
  Creates a scope for the given employer at the given instant, under no grant.

  Unlike a person scope there is no anonymous form. An employer session with no
  employer is not a caller with less authority; it is a caller with no meaning,
  and the settings the transaction wrapper writes would have nothing to say.

  Raises `ArgumentError` unless `employer_id` is a UUID in canonical form.
  """
  @spec for_employer(Ecto.UUID.t(), DateTime.t()) :: t()
  def for_employer(employer_id, %DateTime{} = now) when is_binary(employer_id) do
    %__MODULE__{employer_id: uuid!(employer_id), now: now}
  end

  @doc """
  Creates a scope acting under `grant_id` at the employer it belongs to.

  Both ids are checked here for the same reason: they are written into a
  transaction-local setting or compared against one in a query, and a
  malformed one fails inside Postgres rather than at the boundary that built
  it.

  Nothing here says the grant is live, or that it belongs to this employer, or
  that whoever built the scope holds it. Those are questions about rows, and
  `HospitalityComs.Venues` asks them of the database on every call rather than
  believing the struct.
  """
  @spec for_grant(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: t()
  def for_grant(employer_id, grant_id, %DateTime{} = now)
      when is_binary(employer_id) and is_binary(grant_id) do
    %__MODULE__{employer_id: uuid!(employer_id), grant_id: uuid!(grant_id), now: now}
  end

  # `""` and `"nope"` satisfy `is_binary/1` too, and a scope built from one is
  # a scope that fails at `raw::uuid` inside `app_current_employer_id()` —
  # three layers from the caller that built it, in the qualifier of the view
  # U9 will read the employer zone through. It fails here instead.
  #
  # `Ecto.UUID.cast/1` on its own is not the check: it also accepts sixteen raw
  # bytes and encodes them, so any sixteen-character string would come back a
  # valid-looking employer. The scope carries the hex form, because the hex
  # form is what goes into `app.employer_id`, so the hex form is what is taken.
  @spec uuid!(String.t()) :: Ecto.UUID.t()
  defp uuid!(id) when byte_size(id) == 36, do: id |> Ecto.UUID.cast() |> cast_or_refuse(id)
  defp uuid!(id), do: refuse(id)

  @spec cast_or_refuse({:ok, Ecto.UUID.t()} | :error, String.t()) :: Ecto.UUID.t()
  defp cast_or_refuse({:ok, id}, _given), do: id
  defp cast_or_refuse(:error, given), do: refuse(given)

  @spec refuse(String.t()) :: no_return()
  defp refuse(given) do
    raise ArgumentError, """
    #{inspect(given)} is not an employer id.

    An employer scope is written into the transaction as app.employer_id and \
    read back by app_current_employer_id(), which casts it to uuid; the grant \
    it acts under is compared against a uuid column. A scope built from \
    anything else is a scope that fails inside Postgres — inside the qualifier \
    of the employer-visible view, or inside a where clause — rather than at \
    the boundary that built it.
    """
  end
end
