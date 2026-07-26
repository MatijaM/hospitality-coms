defmodule HospitalityComs.Accounts.Scope do
  @moduledoc """
  What one unit of work knows about its caller: who, and when.

  The generated scope carried only the person. This one also carries `now`,
  because the instant is captured exactly once at a unit-of-work boundary and
  then travels with the call (KTD5). Two queries in one request that each read
  the clock can disagree about which side of a period boundary the work fell
  on — one seeing an engagement as active while the next sees it as expired —
  and the fix is not care, it is having one instant to carry.

  A scope therefore always has an instant, including for a caller who has not
  authenticated: the log-in request needs to stamp a token, and it has no
  person yet. `person` is nil in that case, and
  `HospitalityComsWeb.PersonAuth.require_authenticated_person/2` is what turns
  that into a refusal. This is a departure from the generated
  `for_person(nil) -> nil`, which had no instant to hand back.

  U3 splits this into a person scope and an employer scope, so that a
  person-zone context function refuses an employer caller by function clause
  rather than by runtime check. Fields added here should be ones both sides
  need; `now` is the canonical example.
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
