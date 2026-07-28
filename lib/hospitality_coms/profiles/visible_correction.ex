defmodule HospitalityComs.Profiles.VisibleCorrection do
  @moduledoc """
  One correction request, as it is rendered to somebody entitled to see the
  entry it contests.

  **Not an Ecto schema**, for the reason `HospitalityComs.Profiles.VisibleEntry`
  is not: it is selected out of `employer_visible_correction_requests` for a
  venue that was disclosed the entry, out of `correction_requests` for the venue
  that asserted it, and out of the same table for the worker and their peers.
  Four readers, one shape.

  **Six callers now, and the two outside that claim were the writers.**
  `HospitalityComs.Profiles.request_correction/3` and `resolve_correction/3` both
  answered the `HospitalityComs.Profiles.CorrectionRequest` schema, so one entity
  was `correction_request_id` carrying `resolution: :declined` when read and `id`
  carrying `resolution: "declined"` when written. That is the divergence the note
  at the bottom of this moduledoc records against `venue_corrections/1`,
  surviving on the write path because "four readers, one shape" was a claim about
  readers and the writers were never counted. `of_request/1` is what the two go
  through now.

  R16 makes a correction request visible to any viewer of the entry, so its
  visibility is not a rule of its own — it is the entry's rule, applied to a
  join. `*_create_employer_visible_view.exs` builds the second view on the first
  for exactly that reason, and `HospitalityComs.Profiles.Records`'
  `peer_disclosure/4` composes over both of the peer's reads for the same one.

  `resolution` is the atom rather than the column's string, so a caller matches
  on `:declined` rather than on `"declined"` and the enumerated set is
  `HospitalityComs.Profiles.CorrectionRequest.resolution/0`.

  **"Four readers, one shape" was a claim rather than a fact until U9's review.**
  `Records.venue_corrections/1` — the attesting venue's own inbox — had no
  `select:` and handed back `CorrectionRequest` structs, so `resolution` was
  `"declined"` on that path and `:declined` on the other three, and the id
  arrived under `id` rather than `correction_request_id`.
  `HospitalityComs.ProfilesTest` had asserted both spellings two lines apart.
  Both paths now select the field list this struct renders.
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

  Kept, unlike `HospitalityComs.Profiles.VisibleEntry`'s, because it is not a
  restatement of `t()`: `resolution` is the column's `String.t()` here and the
  atom there, which is the conversion `new/1` exists to make.
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

  @doc """
  The struct one stored request becomes.

  The writers' door. `new/1` takes a row a `Records` query selected and this
  takes the schema struct an `insert` or a `RETURNING` hands back — the same
  split `HospitalityComs.Peers` has between `Visibility.new/1` and
  `Conversation.of_connection/2`.

  It builds the row and delegates rather than mapping the fields a second time,
  so the string-to-atom conversion and the field list have one spelling each. A
  `select:` on `Records.resolvable_correction/3` was the alternative and would
  have rendered `resolve_correction/3` alone, leaving `request_correction/3` —
  which writes through `HospitalityComs.Repo` and has no query to put a `select:`
  on — as the one caller still handing back the schema.
  """
  @spec of_request(CorrectionRequest.t()) :: t()
  def of_request(%CorrectionRequest{} = request) do
    new(%{
      correction_request_id: request.id,
      entry_engagement_id: request.engagement_id,
      venue_id: request.venue_id,
      body: request.body,
      requested_at: request.requested_at,
      resolved_at: request.resolved_at,
      resolution: request.resolution
    })
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
