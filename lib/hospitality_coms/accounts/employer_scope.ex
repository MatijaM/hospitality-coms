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
  belongs here when U4 creates the table — not the human behind it.

  ## `employer_id` and the instant

  Both are written into the transaction as `app.employer_id` and `app.now` by
  `HospitalityComs.EmployerRepo.scoped_transaction/2`, transaction-locally,
  where the employer-visible view reads them. The instant arrives here from the
  unit-of-work boundary that captured it; `EmployerRepo` never reads the clock,
  because a repo is not a unit of work and a second read of the clock inside
  one is the disagreement `Clock` exists to prevent.
  """

  @enforce_keys [:employer_id, :now]
  defstruct [:employer_id, :now]

  @type t() :: %__MODULE__{employer_id: Ecto.UUID.t(), now: DateTime.t()}

  @doc """
  Creates a scope for the given employer at the given instant.

  Unlike a person scope there is no anonymous form. An employer session with no
  employer is not a caller with less authority; it is a caller with no meaning,
  and the settings the transaction wrapper writes would have nothing to say.
  """
  @spec for_employer(Ecto.UUID.t(), DateTime.t()) :: t()
  def for_employer(employer_id, %DateTime{} = now) when is_binary(employer_id) do
    %__MODULE__{employer_id: employer_id, now: now}
  end
end
