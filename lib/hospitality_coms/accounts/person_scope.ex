defmodule HospitalityComs.Accounts.PersonScope do
  @moduledoc """
  What one unit of work knows about a person acting for themselves: who, and
  when.

  This and `HospitalityComs.Accounts.EmployerScope` are two structs rather than
  one with a discriminating field, and the reason is the whole point of the
  split. A person-zone context function heads with `%PersonScope{}` and an
  employer caller is refused by function clause — a `FunctionClauseError`
  raised before the body runs, at the top of a function nobody had to remember
  to guard. One struct with a `:kind` field would put that check in the body,
  where forgetting it is silent and where every new function has to remember it
  again.

  It carries the instant for the reason `Clock` exists (KTD5): the instant is
  captured once at a unit-of-work boundary — an HTTP request, one inbound
  channel message, one job attempt — and then travels with the call. Two
  queries in one request that each read the clock can disagree about which side
  of a period boundary the work fell on, one seeing an engagement as active
  while the next sees it expired, and the fix is not care, it is having one
  instant to carry.

  A scope therefore always has an instant, including for a caller who has not
  authenticated: the log-in request needs to stamp a token, and it has no
  person yet. `person` is nil in that case, and
  `HospitalityComsWeb.PersonAuth.require_authenticated_person/2` is what turns
  that into a refusal.
  """

  alias HospitalityComs.Accounts.Person

  @enforce_keys [:now]
  defstruct person: nil, now: nil

  @type t() :: %__MODULE__{person: Person.t() | nil, now: DateTime.t()}

  @doc """
  Creates a scope for the given person at the given instant.

  `person` may be nil, which is an anonymous caller rather than an absent one.
  """
  @spec for_person(Person.t() | nil, DateTime.t()) :: t()
  def for_person(person, %DateTime{} = now) when is_struct(person, Person) or is_nil(person) do
    %__MODULE__{person: person, now: now}
  end
end
