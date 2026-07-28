defmodule HospitalityComs.Profiles.VisibleDeclaration do
  @moduledoc """
  One declared entry, as it is rendered to somebody entitled to see it.

  **Not an Ecto schema**, for the reason `HospitalityComs.Profiles.VisibleEntry`
  and `HospitalityComs.Profiles.VisibleCorrection` are not: it is the shape a
  reader gets, and the shape a reader gets names its entity `declared_entry_id`
  rather than `id`.

  Three readers, one shape — the worker's own record, a peer's view of it, and
  the reply to writing or amending one. That last is the half U9 could not have
  had: it shipped no transport, so `declare_entry/2` and
  `amend_declared_entry/3` answered the `HospitalityComs.Profiles.DeclaredEntry`
  schema and nothing noticed that its id was spelled differently from the two
  render structs beside it.

  ## `<entity>_id`, and why that is a rule rather than a preference

  U8 fixed a peer message reply saying `id` where the live push said
  `message_id`; U9 fixed the attesting venue's own correction inbox handing back
  a schema, so `resolution` was `"declined"` on one path and `:declined` on three
  others. Both were one entity with two names on one surface, and both were found
  by reading rather than by a failure — a client that accepts either spelling
  makes the divergence permanent, and a client that accepts one silently drops
  the other.

  ## What it carries, and the two things it does not

  The entry, the worker's own labels, the term, and when it was declared.

  **No `person_id`.** The worker's own read already knows whose record it is and
  a peer named the person to ask for it, so the key would be carried for nobody.
  That is `HospitalityComs.Peers.list_visible_peers/1`'s posture and
  `VisibleEntry`'s: a field list rather than a struct off the table, so a surface
  that renders one wholesale ships only what was chosen.

  **No `inserted_at`/`updated_at`.** They are bookkeeping; `declared_at` is the
  claim, and an amendment deliberately does not move it.
  """

  alias HospitalityComs.Profiles.DeclaredEntry

  @enforce_keys [
    :declared_entry_id,
    :role_label,
    :organisation_name,
    :starts_at,
    :ends_at,
    :declared_at
  ]
  defstruct [
    :declared_entry_id,
    :role_label,
    :organisation_name,
    :starts_at,
    :ends_at,
    :declared_at
  ]

  @type t() :: %__MODULE__{
          declared_entry_id: Ecto.UUID.t(),
          role_label: String.t(),
          organisation_name: String.t(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          declared_at: DateTime.t()
        }

  @doc """
  The struct one stored entry becomes.

  Takes the schema rather than a selected row, which is
  `HospitalityComs.Peers.Conversation.of_connection/2`'s shape and not
  `VisibleEntry.new/1`'s: there is one query behind a declared entry and two
  writes, and all three hand back a `DeclaredEntry`. A `select:` field list in
  `HospitalityComs.Profiles.Records` would render the read and leave the two
  writes to be rendered a second way, which is the drift this struct exists to
  close.
  """
  @spec of_entry(DeclaredEntry.t()) :: t()
  def of_entry(%DeclaredEntry{} = entry) do
    %__MODULE__{
      declared_entry_id: entry.id,
      role_label: entry.role_label,
      organisation_name: entry.organisation_name,
      starts_at: entry.starts_at,
      ends_at: entry.ends_at,
      declared_at: entry.declared_at
    }
  end
end
