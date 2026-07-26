defmodule HospitalityComs.Accounts.PersonToken do
  @moduledoc """
  Database-backed tokens: the magic link that authenticates, and the API token
  a session runs on.

  The API token is deliberately the generated session token rather than a
  second, signed, stateless mechanism. A row can be deleted, and deleting it
  ends the session on the next request; a signed token stays valid until it
  expires, which makes revocation — the thing this product is about — a promise
  the transport cannot keep.

  Every expiry here is derived against an instant passed in by the caller
  (KTD5). The generated code used `Ecto.Query.ago/2`, which expands to
  `DateTime.utc_now/0` inside the query macro: invisible to the clock-authority
  Credo check, immune to the offsettable clock, and free to disagree with the
  rest of the unit of work. `inserted_at` is stamped from the same instant for
  the same reason — a token whose write and whose expiry read different clocks
  has an expiry nobody can predict.
  """

  use Ecto.Schema

  import Ecto.Query

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonToken

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  @change_email_validity_in_days 7
  @session_validity_in_days 14

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "people_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    belongs_to :person, Person

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          token: binary() | nil,
          context: String.t() | nil,
          sent_to: String.t() | nil,
          authenticated_at: DateTime.t() | nil,
          person_id: Ecto.UUID.t() | nil,
          person: Person.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil
        }

  @doc """
  Returns the number of days a session token stays valid for.
  """
  @spec session_validity_in_days() :: pos_integer()
  def session_validity_in_days, do: @session_validity_in_days

  @doc """
  Returns the number of minutes a magic link stays valid for.
  """
  @spec magic_link_validity_in_minutes() :: pos_integer()
  def magic_link_validity_in_minutes, do: @magic_link_validity_in_minutes

  @doc """
  Builds the token a session runs on, along with the row that makes it
  revocable.

  The token is returned as raw bytes. It is the caller's job to encode it for
  whatever transport it leaves on; `HospitalityComsWeb.PersonAuth` does that
  for HTTP.
  """
  @spec build_session_token(Person.t(), DateTime.t()) :: {binary(), t()}
  def build_session_token(%Person{} = person, %DateTime{} = now) do
    token = :crypto.strong_rand_bytes(@rand_size)
    stamped_at = DateTime.truncate(now, :second)

    {token,
     %PersonToken{
       token: token,
       context: "session",
       person_id: person.id,
       authenticated_at: person.authenticated_at || stamped_at,
       inserted_at: stamped_at
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the person found by the token, if any, along with the
  token's creation time. The token is valid if it matches the value in the
  database and it has not expired as of `now`.
  """
  @spec verify_session_token_query(binary(), DateTime.t()) :: {:ok, Ecto.Query.t()}
  def verify_session_token_query(token, %DateTime{} = now) when is_binary(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: person in assoc(token, :person),
        where: token.inserted_at > ^horizon(now, @session_validity_in_days, :day),
        select: {%{person | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Builds a token and its hash to be delivered to the person's email.

  The non-hashed token is sent to the person's email while the hashed part is
  stored in the database. The original token cannot be reconstructed, which
  means anyone with read-only access to the database cannot directly use the
  token in the application to gain access. Furthermore, if the person changes
  their email in the system, the tokens sent to the previous email are no
  longer valid.
  """
  @spec build_email_token(Person.t(), String.t(), DateTime.t()) :: {String.t(), t()}
  def build_email_token(%Person{} = person, context, %DateTime{} = now) do
    build_hashed_token(person, context, person.email, now)
  end

  @spec build_hashed_token(Person.t(), String.t(), String.t() | nil, DateTime.t()) ::
          {String.t(), t()}
  defp build_hashed_token(person, context, sent_to, now) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %PersonToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       person_id: person.id,
       inserted_at: DateTime.truncate(now, :second)
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  If found, the query returns a tuple of the form `{person, token}`.

  The given token is valid if it matches its hashed counterpart in the
  database, if it has not expired as of `now`, and if it was sent to the
  address the person still holds. The context of a magic link token is always
  "login".
  """
  @spec verify_magic_link_token_query(String.t(), DateTime.t()) :: {:ok, Ecto.Query.t()} | :error
  def verify_magic_link_token_query(token, %DateTime{} = now) when is_binary(token) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false) do
      hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

      query =
        from token in by_token_and_context_query(hashed_token, "login"),
          join: person in assoc(token, :person),
          where: token.inserted_at > ^horizon(now, @magic_link_validity_in_minutes, :minute),
          where: token.sent_to == person.email,
          select: {person, token}

      {:ok, query}
    end
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the person_token found by the token, if any.

  This is used to validate requests to change the person's email. The given
  token is valid if it matches its hashed counterpart in the database and if it
  has not expired as of `now`. The context must always start with "change:".
  """
  @spec verify_change_email_token_query(String.t(), String.t(), DateTime.t()) ::
          {:ok, Ecto.Query.t()} | :error
  def verify_change_email_token_query(token, "change:" <> _rest = context, %DateTime{} = now)
      when is_binary(token) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false) do
      hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

      query =
        from token in by_token_and_context_query(hashed_token, context),
          where: token.inserted_at > ^horizon(now, @change_email_validity_in_days, :day)

      {:ok, query}
    end
  end

  # `inserted_at` is second-precision and Ecto refuses to dump a `:utc_datetime`
  # parameter carrying microseconds, so the horizon is truncated rather than
  # compared at a precision the column does not have.
  @spec horizon(DateTime.t(), pos_integer(), :day | :minute) :: DateTime.t()
  defp horizon(now, amount, unit) do
    now |> DateTime.add(-amount, unit) |> DateTime.truncate(:second)
  end

  @spec by_token_and_context_query(binary(), String.t()) :: Ecto.Query.t()
  defp by_token_and_context_query(token, context) do
    from PersonToken, where: [token: ^token, context: ^context]
  end
end
