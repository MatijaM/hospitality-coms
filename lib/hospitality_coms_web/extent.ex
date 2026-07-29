defmodule HospitalityComsWeb.Extent do
  @moduledoc """
  The whole of this API's paging vocabulary, in one place: `recent` or `all`.

  Two lists in this application are bounded — a room's history and a venue's
  shift rooms — and both are bounded **in their context**, because a route that
  passes a number leaves the unbounded read one forgetful caller away from
  production. That is how both history functions came to be `Repo.all/1` over a
  room's entire life. So a caller names an *extent* rather than a limit, and
  this is where the word is turned into one.

  There is no `limit` parameter on any route and there must not be one.

  ## Anything else is a refusal, not a default

  A client sending a word this server does not know is a client bug, and
  swallowing it hides the bug at the only place that can see it. `:error`
  becomes `400`; the sentence is `refusal/0` so the two callers cannot answer
  the same mistake with two different strings.

  ## Why it is a module of its own

  `HospitalityComsWeb.RoomController` owned a private `extent/1` and the
  sentence beside it. `HospitalityComsWeb.EmployerController` needs both, and
  `HospitalityComsWeb.EntityId` already answered what this tree does when a
  second caller appears: the rule moves, the first caller delegates, and there
  is still exactly one spelling. Duplicating five clauses would be duplicating a
  user-visible string with them.
  """

  alias HospitalityComs.Rooms.MessagePage

  @refusal ~s(extent must be "recent" or "all")

  @doc """
  The extent a client-supplied `params` map asks for, if it asks for one this
  server knows.

  Absent is `:recent`, which is what every bounded read answers by default.

  The type is `HospitalityComs.Rooms.MessagePage`'s, which is the single
  declaration of `:recent | :all` in the tree. It is the page abstraction's
  vocabulary rather than the message page's alone, and a second
  `@type extent()` beside it would be one word declared twice (issue #42).
  """
  @spec cast(map()) :: {:ok, MessagePage.extent()} | :error
  def cast(%{"extent" => "all"}), do: {:ok, :all}
  def cast(%{"extent" => "recent"}), do: {:ok, :recent}
  def cast(%{"extent" => _other}), do: :error
  def cast(_params), do: {:ok, :recent}

  @doc """
  What a caller is told when they named an extent this server does not know.
  """
  @spec refusal() :: String.t()
  def refusal, do: @refusal
end
