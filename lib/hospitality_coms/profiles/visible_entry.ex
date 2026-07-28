defmodule HospitalityComs.Profiles.VisibleEntry do
  @moduledoc """
  One attested entry, as it is rendered to somebody entitled to see it.

  **Not an Ecto schema.** It is what `HospitalityComs.Profiles.Records` selects
  out of `employer_visible_attested_entries` for an employer, and out of
  `attested_entries` joined to the bridge for a peer or for the worker
  themselves — three readers, one shape, so the unit's verification is a
  comparison of two lists of the same struct rather than of two different
  renderings.

  ## What it carries, and the one thing it does not

  The entry, the venue that asserted it, the employer-authored role label, and
  the term. **No `person_id`.**

  That absence is U9 acting on the disclosure CLAUDE.md records against
  `engagements.person_id`: the key is a globally stable UUID and `employer_role`
  can read it off the bridge, so two venues comparing ids out of band can
  determine that the same human works at both — which is precisely the
  concurrency the disclosure default exists to hide. The employer names a worker
  by *their own* engagement at *their own* venue, which is venue-local by
  construction, and the entries that come back name venues rather than people.

  It is also the shape `HospitalityComs.Rooms.list_venue_room_members/2`'s
  docstring asks for and the shape `HospitalityComs.Peers.list_visible_peers/1`
  already adopted: a field list rather than a struct off the table, so a surface
  that renders one wholesale ships only what was chosen.

  ## `entry_engagement_id` is here and it is venue-local

  It identifies the entry's engagement so a correction request can be attached
  to it and a disclosure decision can name it. It is not a person key: it names
  one person's term at one venue, and a venue that reads it holds no privilege
  to resolve it — row-level security on `engagements` confines every employer
  read to `app_current_employer_id()`.
  """

  @enforce_keys [
    :attested_entry_id,
    :entry_engagement_id,
    :venue_id,
    :venue_name,
    :role_label,
    :starts_at,
    :ends_at,
    :attested_at
  ]
  defstruct [
    :attested_entry_id,
    :entry_engagement_id,
    :venue_id,
    :venue_name,
    :role_label,
    :starts_at,
    :ends_at,
    :attested_at
  ]

  @type t() :: %__MODULE__{
          attested_entry_id: Ecto.UUID.t(),
          entry_engagement_id: Ecto.UUID.t(),
          venue_id: Ecto.UUID.t(),
          venue_name: String.t(),
          role_label: String.t(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          attested_at: DateTime.t()
        }

  @typedoc """
  The row a `Records` query selects, before it becomes a struct.
  """
  @type row() :: %{
          attested_entry_id: Ecto.UUID.t(),
          entry_engagement_id: Ecto.UUID.t(),
          venue_id: Ecto.UUID.t(),
          venue_name: String.t(),
          role_label: String.t(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          attested_at: DateTime.t()
        }

  @doc """
  The struct one selected row becomes.
  """
  @spec new(row()) :: t()
  def new(%{} = row) do
    %__MODULE__{
      attested_entry_id: row.attested_entry_id,
      entry_engagement_id: row.entry_engagement_id,
      venue_id: row.venue_id,
      venue_name: row.venue_name,
      role_label: row.role_label,
      starts_at: row.starts_at,
      ends_at: row.ends_at,
      attested_at: row.attested_at
    }
  end
end
