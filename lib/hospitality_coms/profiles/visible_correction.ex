defmodule HospitalityComs.Profiles.VisibleCorrection do
  @moduledoc """
  One correction request, as it is rendered to somebody entitled to see the
  entry it contests.

  **Not an Ecto schema**, for the reason `HospitalityComs.Profiles.VisibleEntry`
  is not: it is selected out of `employer_visible_correction_requests` for a
  venue that was disclosed the entry, out of `correction_requests` for the venue
  that asserted it, and out of the same table for the worker and their peers.
  Four readers, one shape.

  R16 makes a correction request visible to any viewer of the entry, so its
  visibility is not a rule of its own — it is the entry's rule, applied to a
  join. `*_create_employer_visible_view.exs` builds the second view on the first
  for exactly that reason.

  `resolution` is the atom rather than the column's string, so a caller matches
  on `:declined` rather than on `"declined"` and the enumerated set is the one
  `HospitalityComs.Profiles.CorrectionRequest.resolutions/0` names.
  """

  alias HospitalityComs.Profiles.CorrectionRequest

  @enforce_keys [
    :correction_request_id,
    :entry_engagement_id,
    :venue_id,
    :body,
    :requested_at,
    :resolved_at,
    :resolution
  ]
  defstruct [
    :correction_request_id,
    :entry_engagement_id,
    :venue_id,
    :body,
    :requested_at,
    :resolved_at,
    :resolution
  ]

  @type t() :: %__MODULE__{
          correction_request_id: Ecto.UUID.t(),
          entry_engagement_id: Ecto.UUID.t(),
          venue_id: Ecto.UUID.t(),
          body: String.t(),
          requested_at: DateTime.t(),
          resolved_at: DateTime.t() | nil,
          resolution: CorrectionRequest.resolution() | nil
        }

  @typedoc """
  The row a `Records` query selects, before it becomes a struct.
  """
  @type row() :: %{
          correction_request_id: Ecto.UUID.t(),
          entry_engagement_id: Ecto.UUID.t(),
          venue_id: Ecto.UUID.t(),
          body: String.t(),
          requested_at: DateTime.t(),
          resolved_at: DateTime.t() | nil,
          resolution: String.t() | nil
        }

  @doc """
  The struct one selected row becomes.
  """
  @spec new(row()) :: t()
  def new(%{} = row) do
    %__MODULE__{
      correction_request_id: row.correction_request_id,
      entry_engagement_id: row.entry_engagement_id,
      venue_id: row.venue_id,
      body: row.body,
      requested_at: row.requested_at,
      resolved_at: row.resolved_at,
      resolution: resolution(row.resolution)
    }
  end

  # The column is `NULL`, `'accepted'` or `'declined'` and a CHECK says so, so
  # the mapping is total over what the database can hold. Written as clauses
  # rather than as `String.to_existing_atom/1`, which would turn an unexpected
  # value into a raise from inside a list read.
  @spec resolution(String.t() | nil) :: CorrectionRequest.resolution() | nil
  defp resolution("accepted"), do: :accepted
  defp resolution("declined"), do: :declined
  defp resolution(nil), do: nil
end
