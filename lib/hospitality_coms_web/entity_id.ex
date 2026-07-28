defmodule HospitalityComsWeb.EntityId do
  @moduledoc """
  The one rule this application applies to an id that arrived from outside.

  An id reaches the web layer three ways and they look nothing alike:

    * a **channel topic suffix** — `"venue_room:" <> venue_id`, which reads like
      a route parameter and was not validated like one;
    * an **event payload field**, which U8's `HospitalityComsWeb.PeerChannel`
      takes every one of through here;
    * a **path parameter**, which is what U12's room routes carry.

  All three are user input, and handed to a context uncast all three reach
  Ecto's query builder and raise `Ecto.Query.CastError`. On a channel that is
  reported as a crash; over HTTP it is a `500`. Either way a caller can tell a
  **malformed** id from an **unknown** one by which answer they get, which is
  the not-found-rather-than-forbidden rule (AE1) lost at the one place the id
  comes from outside.

  ## Why the byte size is load-bearing rather than a cheap pre-filter

  `Ecto.UUID.cast/1` on its own also accepts **sixteen raw bytes** and encodes
  them, so any sixteen-character string comes back as a valid-looking id
  naming a row nobody has. `byte_size(id) == 36` is what refuses that, and it
  has to come first.

  The shape is `HospitalityComs.Accounts.EmployerScope`'s `uuid!/1` without the
  raise. That module raises because a scope built from nonsense fails three
  layers away inside Postgres; this one returns, because the web layer's answer
  to nonsense is the same refusal it gives an id that names nothing.

  ## Why it is a module of its own

  `HospitalityComsWeb.ChannelAuth.topic_id/1` was the rule's only spelling, and
  its docstring already recorded that the name was historical and that payload
  ids went through it anyway. A controller calling `ChannelAuth` to parse a path
  parameter would be a fourth caller of a function named after the first, so the
  rule moved here and `topic_id/1` delegates. **The three channels keep the
  function they call**, which is the cost the note in `ChannelAuth` declined to
  pay for a rename; nothing about their behaviour changes, and there is still
  exactly one spelling.
  """

  @doc """
  The entity id a client-supplied string names, if it is one.
  """
  @spec cast(term()) :: {:ok, Ecto.UUID.t()} | :error
  def cast(id) when is_binary(id) and byte_size(id) == 36, do: Ecto.UUID.cast(id)
  def cast(_id), do: :error
end
