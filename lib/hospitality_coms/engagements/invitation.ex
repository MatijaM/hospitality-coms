defmodule HospitalityComs.Engagements.Invitation do
  @moduledoc """
  An offer of a fixed-term engagement, addressed to nobody.

  ## It names no human, and R1 is the reason

  A person record is created by the person and by nobody else. An employer
  action produces at most an invitation, and an unclaimed invitation creates no
  record — so there is no email column here, no phone column, and no
  `person_id`. What the row carries is a digest of a single-use opaque claim
  code; how the code reaches a human is outside the database, and that is the
  point. Two people who both hold the code produce one engagement, not two, and
  the loser is refused by the consume rather than by anything this row knows
  about who was supposed to have it.

  The code itself is never stored, only `:crypto.hash(:sha256, code)`, exactly
  as `HospitalityComs.Accounts.PersonToken` stores a magic link. `issue/4`
  returns the code once; nothing can recover it from the row afterwards.

  ## Two grants, and they answer different questions

  `issued_by_grant_id` is the authority that issued the invitation. It is
  required: an administrative act with no author is not one the employer zone
  can hold, and a grant is the only attribution available — naming the human
  would be a person key in the employer zone (KTD2).

  `grant_id` is the authority the resulting engagement will *hold*, and it is
  usually null. U4 shipped `employer_grants` with no holder column on purpose
  and left "who holds this" for the bridge to answer; an invitation that carries
  a grant is an invitation to manage rather than to work, and it is what makes
  KTD17 — a manager's authority derives from an engagement — true of a real row.

  ## Claimability is derived, like everything else

  There is no `status`. An invitation is claimable at instant `t` when
  `claimed_at` is null and `t < code_expires_at`, which is the same half-open
  discipline every period in this application follows, and it is evaluated
  inside the conditional `UPDATE` that consumes it rather than read first and
  acted on afterwards. See `HospitalityComs.Engagements.claim_invitation/2`.

  The proposed term is copied onto the engagement rather than joined to. An
  invitation is an offer and the engagement is the record; editing the offer
  afterwards must not move somebody's employment dates.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Venues.Venue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "invitations" do
    field :role_label, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :claim_code_digest, :binary
    field :code_expires_at, :utc_datetime
    field :issued_at, :utc_datetime
    field :claimed_at, :utc_datetime

    belongs_to :venue, Venue
    belongs_to :issued_by, EmployerGrant, foreign_key: :issued_by_grant_id
    belongs_to :grant, EmployerGrant

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          venue_id: Ecto.UUID.t() | nil,
          venue: Venue.t() | Ecto.Association.NotLoaded.t() | nil,
          issued_by_grant_id: Ecto.UUID.t() | nil,
          issued_by: EmployerGrant.t() | Ecto.Association.NotLoaded.t() | nil,
          grant_id: Ecto.UUID.t() | nil,
          grant: EmployerGrant.t() | Ecto.Association.NotLoaded.t() | nil,
          role_label: String.t() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          claim_code_digest: binary() | nil,
          code_expires_at: DateTime.t() | nil,
          issued_at: DateTime.t() | nil,
          claimed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @hash_algorithm :sha256
  @rand_size 32
  @max_label_length 160
  @max_code_validity_in_days 14

  @doc """
  The longest role label an invitation or an engagement may carry.
  """
  @spec max_label_length() :: pos_integer()
  def max_label_length, do: @max_label_length

  @doc """
  The longest a claim code may stay redeemable after it is issued.

  The same fourteen days `HospitalityComs.Accounts.PersonToken.session_validity_in_days/0`
  gives a session, and for the same reason: both are bearer credentials that
  grant something to whoever presents them first. The lifetime used to be
  whatever the caller asked for and there is still no way to withdraw a code
  early, so an unbounded one was a credential that could outlive the venue's
  interest in it by years.
  """
  @spec max_code_validity_in_days() :: pos_integer()
  def max_code_validity_in_days, do: @max_code_validity_in_days

  @doc """
  The digest a claim code is looked up by.

  Exposed so the context can hash a presented code without this module having to
  know what a request looks like, and so a test can assert that the row holds
  the digest rather than the credential.
  """
  @spec digest(String.t()) :: binary()
  def digest(code) when is_binary(code), do: :crypto.hash(@hash_algorithm, code)

  @doc """
  Builds an invitation at `venue_id` under `issuing_grant_id`, and the one-time
  claim code that redeems it.

  Returns `{changeset, code}`. The code is 32 bytes of `:crypto.strong_rand_bytes/1`
  in URL-safe base64 — the same construction and the same size as a magic-link
  token, because it is the same kind of secret: a bearer credential that grants
  a state change to whoever presents it first.

  `venue_id` and `issued_by_grant_id` are arguments rather than castable fields.
  It is the caller's scope that decides which venue a write lands on and under
  whose authority; a `venue_id` arriving in user attributes is a cross-tenant
  write waiting for somebody to forget to strip it.

  `grant_id` *is* castable, because it is a decision the caller is making —
  whether this invitation confers authority — rather than a fact about the
  session. `HospitalityComs.Engagements.issue_invitation/2` resolves it against
  the venue's live grants before the write, and the composite foreign key
  refuses one belonging to another venue regardless.
  """
  @spec issue(Ecto.UUID.t(), Ecto.UUID.t(), map(), DateTime.t()) ::
          {Ecto.Changeset.t(t()), String.t()}
  def issue(venue_id, issuing_grant_id, attrs, %DateTime{} = now)
      when is_binary(venue_id) and is_binary(issuing_grant_id) and is_map(attrs) do
    code = @rand_size |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    stamped_at = DateTime.truncate(now, :second)

    changeset =
      %__MODULE__{}
      |> cast(attrs, [:role_label, :starts_at, :ends_at, :code_expires_at, :grant_id])
      |> put_change(:venue_id, venue_id)
      |> put_change(:issued_by_grant_id, issuing_grant_id)
      |> put_change(:claim_code_digest, digest(code))
      |> put_change(:issued_at, stamped_at)
      |> put_change(:inserted_at, stamped_at)
      |> put_change(:updated_at, stamped_at)
      |> validate_required([:role_label, :starts_at, :ends_at, :code_expires_at])
      |> update_change(:role_label, &String.trim/1)
      |> validate_required([:role_label])
      |> validate_length(:role_label, max: @max_label_length)
      |> validate_uuid(:grant_id)
      |> truncate(:starts_at)
      |> truncate(:ends_at)
      |> truncate(:code_expires_at)
      |> validate_term()
      |> validate_code_expiry(stamped_at)
      |> declare_constraints()

    {changeset, code}
  end

  # The changeset half of every check constraint the table carries, so a caller
  # gets a field error rather than a raised `Postgrex.Error`, and the constraint
  # half so that a write which never passed through here cannot get around it.
  @spec declare_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_constraints(changeset) do
    changeset
    |> check_constraint(:role_label,
      name: :invitations_role_label_present,
      message: "can't be blank"
    )
    |> check_constraint(:role_label,
      name: :invitations_role_label_within_bound,
      message: "should be at most #{@max_label_length} character(s)"
    )
    |> check_constraint(:ends_at,
      name: :invitations_term_ordered,
      message: "must be after the start"
    )
    |> check_constraint(:code_expires_at,
      name: :invitations_code_expiry_after_issue,
      message: "must be after the invitation is issued"
    )
    |> check_constraint(:code_expires_at,
      name: :invitations_code_expiry_within_bound,
      message: "must be within #{@max_code_validity_in_days} day(s) of issue"
    )
    |> unique_constraint(:claim_code_digest)
    |> unique_constraint([:id, :venue_id])
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:issued_by_grant_id, name: :invitations_issued_by_grant_fkey)
    |> foreign_key_constraint(:grant_id, name: :invitations_grant_fkey)
  end

  # `:binary_id` accepts any binary at cast time — Ecto defers the check to
  # dump time, where a malformed id raises `Ecto.Query.CastError` out of
  # whichever query happened to reference it next. `grant_id` is the one field
  # here a caller chooses, and `HospitalityComs.Engagements.issue_invitation/2`
  # resolves it against the database before the insert, so without this the
  # promise of a changeset became a raise from inside a `where`.
  @spec validate_uuid(Ecto.Changeset.t(t()), atom()) :: Ecto.Changeset.t(t())
  defp validate_uuid(changeset, field) do
    changeset |> get_change(field) |> uuid?() |> refuse_uuid(changeset, field)
  end

  @spec uuid?(term()) :: boolean()
  defp uuid?(nil), do: true
  defp uuid?(value), do: match?({:ok, _cast}, Ecto.UUID.cast(value))

  @spec refuse_uuid(boolean(), Ecto.Changeset.t(t()), atom()) :: Ecto.Changeset.t(t())
  defp refuse_uuid(true, changeset, _field), do: changeset
  defp refuse_uuid(false, changeset, field), do: add_error(changeset, field, "is invalid")

  @spec validate_term(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp validate_term(changeset) do
    changeset
    |> get_field(:starts_at)
    |> ordered?(get_field(changeset, :ends_at))
    |> refuse_term(changeset)
  end

  @spec ordered?(DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  defp ordered?(%DateTime{} = starts_at, %DateTime{} = ends_at) do
    DateTime.compare(ends_at, starts_at) == :gt
  end

  defp ordered?(_starts_at, _ends_at), do: true

  @spec refuse_term(boolean(), Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp refuse_term(true, changeset), do: changeset

  defp refuse_term(false, changeset),
    do: add_error(changeset, :ends_at, "must be after the start")

  @spec validate_code_expiry(Ecto.Changeset.t(t()), DateTime.t()) :: Ecto.Changeset.t(t())
  defp validate_code_expiry(changeset, issued_at) do
    issued_at
    |> ordered?(get_field(changeset, :code_expires_at))
    |> refuse_expiry(changeset)
    |> validate_code_validity(issued_at)
  end

  @spec refuse_expiry(boolean(), Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp refuse_expiry(true, changeset), do: changeset

  defp refuse_expiry(false, changeset) do
    add_error(changeset, :code_expires_at, "must be after the invitation is issued")
  end

  # The upper bound on the same column the check above puts a lower bound on.
  # Half-*closed* here, unlike every period in the application: expiring at
  # exactly the limit is a code good for the full fourteen days rather than one
  # that is a second over.
  @spec validate_code_validity(Ecto.Changeset.t(t()), DateTime.t()) :: Ecto.Changeset.t(t())
  defp validate_code_validity(changeset, issued_at) do
    issued_at
    |> DateTime.add(@max_code_validity_in_days, :day)
    |> within_bound?(get_field(changeset, :code_expires_at))
    |> refuse_validity(changeset)
  end

  @spec within_bound?(DateTime.t(), DateTime.t() | nil) :: boolean()
  defp within_bound?(%DateTime{} = limit, %DateTime{} = code_expires_at) do
    DateTime.compare(code_expires_at, limit) != :gt
  end

  defp within_bound?(_limit, _code_expires_at), do: true

  @spec refuse_validity(boolean(), Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp refuse_validity(true, changeset), do: changeset

  defp refuse_validity(false, changeset) do
    add_error(
      changeset,
      :code_expires_at,
      "must be within #{@max_code_validity_in_days} day(s) of issue"
    )
  end

  # Every instant column in this schema is second-precision, matching the rest
  # of the application. Truncating in the changeset rather than at the database
  # means a boundary test comparing what it wrote against what it reads back
  # gets the same value.
  @spec truncate(Ecto.Changeset.t(t()), atom()) :: Ecto.Changeset.t(t())
  defp truncate(changeset, field) do
    changeset |> get_change(field) |> truncated(changeset, field)
  end

  @spec truncated(DateTime.t() | nil, Ecto.Changeset.t(t()), atom()) :: Ecto.Changeset.t(t())
  defp truncated(%DateTime{} = instant, changeset, field) do
    put_change(changeset, field, DateTime.truncate(instant, :second))
  end

  defp truncated(_instant, changeset, _field), do: changeset
end
