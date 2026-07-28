defmodule HospitalityComs.Lifecycle.RetentionRun do
  @moduledoc """
  One pass of the retention sweeper, and what it did.

  An unattended deleter driven by an injectable input needs both a limit and a
  trace; this is the trace. It records the **instant the sweep used** rather than
  the instant the row was written, because those differ whenever the clock is
  injected — which is every run in the suite and every run of U11's demo control
  — and the first is the one that explains which rows went.

  Four counts rather than a total, because the four triggers fail for unrelated
  reasons and a sum reports none of them. A run that deleted four hundred roster
  entries and no messages is a different event from one that deleted four
  hundred messages.

  ## A refused run writes one of these too

  `:refused` is the blast-radius ceiling firing: the counts are what the run
  *would* have deleted, and nothing was. That is the case a record matters most
  for, so it is written outside the transaction the sweep rolled back rather
  than inside it — see `HospitalityComs.Lifecycle.sweep/1`.

  ## No person, no venue, no engagement

  There is nothing here to scope. The sweeper is the application acting for
  itself across every venue in the installation, which is exactly what no
  employer session may do, and a per-venue breakdown would turn this log into a
  report on other venues' activity.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @outcomes [:completed, :refused]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "retention_runs" do
    field :ran_at, :utc_datetime
    field :outcome, Ecto.Enum, values: @outcomes
    field :ceiling, :integer

    field :own_message_copies, :integer
    field :shift_messages, :integer
    field :roster_entries, :integer
    field :venue_room_messages, :integer

    timestamps(type: :utc_datetime)
  end

  @type outcome() :: :completed | :refused

  @typedoc "What one pass deleted, or would have, by trigger."
  @type counts() :: %{
          own_message_copies: non_neg_integer(),
          shift_messages: non_neg_integer(),
          roster_entries: non_neg_integer(),
          venue_room_messages: non_neg_integer()
        }

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          ran_at: DateTime.t() | nil,
          outcome: outcome() | nil,
          ceiling: pos_integer() | nil,
          own_message_copies: non_neg_integer() | nil,
          shift_messages: non_neg_integer() | nil,
          roster_entries: non_neg_integer() | nil,
          venue_room_messages: non_neg_integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Every outcome a run can have.
  """
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc """
  A run record, stamped from the instant the sweep used.

  Nothing is cast from attributes: every value here is produced by
  `HospitalityComs.Lifecycle.sweep/1` from its own counters.
  """
  @spec changeset(DateTime.t(), outcome(), pos_integer(), counts()) :: Ecto.Changeset.t(t())
  def changeset(%DateTime{} = ran_at, outcome, ceiling, counts)
      when outcome in @outcomes and is_integer(ceiling) and ceiling > 0 do
    stamped_at = DateTime.truncate(ran_at, :second)

    %__MODULE__{}
    |> change(Map.to_list(counts))
    |> change(
      ran_at: stamped_at,
      outcome: outcome,
      ceiling: ceiling,
      inserted_at: stamped_at,
      updated_at: stamped_at
    )
    |> check_constraint(:outcome, name: :retention_runs_outcome_known)
    |> check_constraint(:ceiling, name: :retention_runs_ceiling_positive)
  end
end
