defmodule HospitalityComs.Accounts.PersonScope do
  @moduledoc """
  What one unit of work knows about a person acting for themselves: who, and
  when.

  This and `HospitalityComs.Accounts.EmployerScope` are two structs rather than
  one with a discriminating field, and the reason is the whole point of the
  split. A person-zone context function that heads with `%PersonScope{}`
  refuses an employer caller by function clause — a `FunctionClauseError`
  raised before the body runs, at the top of a function nobody had to remember
  to guard. One struct with a `:kind` field would put that check in the body,
  where forgetting it is silent and where every new function has to remember it
  again.

  That refusal is in force across the person zone as of #18: every
  `HospitalityComs.Accounts` function that reaches a repo heads on this struct,
  as `Peers`, `Profiles`, `Rooms`, `Engagements` and `Lifecycle` already did.
  For most of U3's life it was *available* rather than in force —
  `Accounts.sudo_mode?/2` was the only function taking a scope and it reads no
  data, so an employer caller reached the whole context by passing
  `employer_scope.now`.

  It is still not the boundary, and the sentence to keep in mind has not
  changed: `Accounts` reads and writes through `HospitalityComs.Repo`, which
  holds every privilege, so an employer caller who *constructs* one of these
  from their own instant reaches everything behind it. What stands between an
  employer session and person data is the grant on
  `HospitalityComs.EmployerRepo`'s role. What the struct buys is that reaching
  the person zone from an employer session is now a deliberate line somebody
  wrote rather than an argument that happened to typecheck —
  `boundary_test.exs` asserts both halves.

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

  ## The anonymous form is a requirement, not a concession

  It is what made #18 possible at all. A scope answers three questions — which
  zone, when, and sometimes who — and the refusal by function clause is about
  the first, which is answerable before the third is. So the person zone's
  anonymous half takes one of these too: registration, magic-link redemption
  and every credential lookup head on `%PersonScope{}` with the person
  unconstrained, and their subject arrives as an argument.

  `HospitalityComs.Accounts.get_person_by_session_token/2` is the sharp case —
  it is the call that *produces* the person a scope will carry, so an
  authenticated scope would be circular. `HospitalityComsWeb.PersonAuth`
  therefore builds an anonymous scope from the request's instant, authenticates
  with it, and builds the request's real scope from the answer.
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
