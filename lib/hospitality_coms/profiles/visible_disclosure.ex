defmodule HospitalityComs.Profiles.VisibleDisclosure do
  @moduledoc """
  One disclosure decision, as it is rendered to the only person who may read
  one.

  **Not an Ecto schema**, for `HospitalityComs.Profiles.VisibleEntry`'s reason:
  the shape a reader gets names its entity `disclosure_id` rather than `id`, and
  a surface rendering the schema wholesale would put `id` on the wire beside the
  `attested_entry_id` and `correction_request_id` of the two shapes it is
  rendered next to.

  **The `Visible` prefix is the family's name and not a claim that anybody else
  can see one.** There is exactly one reader — the worker themselves — and there
  must not be a second: an employer-facing ledger would tell a venue which of its
  workers is concealing something, which is strictly more than the concealed
  entries disclose. `HospitalityComs.Profiles.list_disclosures/1` is the only
  function that returns one.

  ## The audience is a kind and an id, not the table's two columns

  `attested_entry_disclosures` spells one audience as `audience_venue_id XOR
  audience_person_id`, held to exactly one by
  `attested_entry_disclosures_one_audience`. Neither that pair nor
  `HospitalityComs.Profiles.Disclosure.audience/0`'s tagged tuple is what a
  reader gets:

    * the two nullable columns put the XOR on the wire, where it becomes
      something every consumer has to re-derive and something a *request* would
      have to be validated for;
    * the tuple cannot survive a JSON encoder, so whoever put it on a transport
      would split it into two fields there — and the split done twice is two
      spellings of one entity, which is the defect this struct exists to close.

  So it is `audience_kind` (`:venue` or `:person`) plus `audience_id`, which
  cannot express "both" or "neither" at all. The atom rather than the string, for
  the reason `HospitalityComs.Profiles.VisibleCorrection`'s `resolution` is an
  atom: an Elixir caller matches on `:venue`, and an encoder renders it
  `"venue"`.

  ## `disclosed` is a boolean and never an absence

  Revoking a disclosure writes `false`; nothing is deleted (KTD21). A ledger that
  removed rows would lose the difference between "decided to hide" and "never
  decided", which for an employer audience is the difference between an override
  and the computed concurrency default.
  """

  alias HospitalityComs.Profiles.Disclosure

  @enforce_keys [
    :disclosure_id,
    :engagement_id,
    :audience_kind,
    :audience_id,
    :disclosed,
    :decided_at
  ]
  defstruct [
    :disclosure_id,
    :engagement_id,
    :audience_kind,
    :audience_id,
    :disclosed,
    :decided_at
  ]

  @typedoc """
  Which of the two audiences a decision is about.

  The tag of `HospitalityComs.Profiles.Disclosure.audience/0` on its own, so the
  two cannot come to mean different things.
  """
  @type audience_kind() :: :venue | :person

  @type t() :: %__MODULE__{
          disclosure_id: Ecto.UUID.t(),
          engagement_id: Ecto.UUID.t(),
          audience_kind: audience_kind(),
          audience_id: Ecto.UUID.t(),
          disclosed: boolean(),
          decided_at: DateTime.t()
        }

  @doc """
  The struct one stored decision becomes.

  Takes the schema rather than a selected row, for
  `HospitalityComs.Profiles.VisibleDeclaration.of_entry/1`'s reason: one query
  and one write both hand back a `Disclosure`, and rendering only the query
  would leave the write rendered a second way.
  """
  @spec of_decision(Disclosure.t()) :: t()
  def of_decision(%Disclosure{} = disclosure) do
    %__MODULE__{
      disclosure_id: disclosure.id,
      engagement_id: disclosure.engagement_id,
      audience_kind: audience_kind(disclosure),
      audience_id: audience_id(disclosure),
      disclosed: disclosure.disclosed,
      decided_at: disclosure.decided_at
    }
  end

  # `attested_entry_disclosures_one_audience` makes the pair total: exactly one
  # of the two columns is set on every row the database will hold, so there is no
  # third clause to write and no `nil` to render.
  @spec audience_kind(Disclosure.t()) :: audience_kind()
  defp audience_kind(%Disclosure{audience_venue_id: venue_id}) when is_binary(venue_id),
    do: :venue

  defp audience_kind(%Disclosure{audience_person_id: person_id}) when is_binary(person_id),
    do: :person

  @spec audience_id(Disclosure.t()) :: Ecto.UUID.t()
  defp audience_id(%Disclosure{audience_venue_id: venue_id}) when is_binary(venue_id),
    do: venue_id

  defp audience_id(%Disclosure{audience_person_id: person_id}) when is_binary(person_id),
    do: person_id
end
