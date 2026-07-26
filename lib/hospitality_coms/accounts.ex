defmodule HospitalityComs.Accounts do
  @moduledoc """
  Person identity: registration, magic-link authentication, and the API tokens
  a session runs on.

  A person record is created by the person and by no one else (R1). There is no
  invitation-claims-a-record path here and no employer-side creation path: the
  only way a `people` row comes into existence is `request_login_instructions/3`
  with an address nobody has used yet, and the row is unconfirmed until whoever
  reads that mailbox redeems the link.

  Every function that depends on the current instant takes it as an argument.
  The instant is captured once, at the HTTP boundary, and carried on the scope
  (KTD5); nothing in this module reads a clock. That is also why the context is
  testable without touching the offsettable clock at all — expiry is asserted
  by passing an instant, not by moving global state.

  This context is person zone. It reads and writes through
  `HospitalityComs.Repo` only. `HospitalityComs.EmployerRepo` must never appear
  here; U3 turns that from a convention into a Postgres privilege.
  """

  import Ecto.Query, warn: false

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonNotifier
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Repo

  @type url_fun() :: (String.t() -> String.t())

  ## Database getters

  @doc """
  Gets a person by email.

  An erased person is unreachable by address: erasure nulls the column, so this
  returns nil and a later registration with the same address creates a new,
  unrelated person.

  ## Examples

      iex> get_person_by_email("foo@example.com")
      %Person{}

      iex> get_person_by_email("unknown@example.com")
      nil

  """
  @spec get_person_by_email(String.t()) :: Person.t() | nil
  def get_person_by_email(email) when is_binary(email) do
    Repo.get_by(Person, email: email)
  end

  @doc """
  Gets a single person.

  Raises `Ecto.NoResultsError` if the person does not exist.
  """
  @spec get_person!(Ecto.UUID.t()) :: Person.t()
  def get_person!(id), do: Repo.get!(Person, id)

  ## Person registration

  @doc """
  Registers a person.

  ## Examples

      iex> register_person(%{email: "foo@example.com"})
      {:ok, %Person{}}

      iex> register_person(%{email: "not an address"})
      {:error, %Ecto.Changeset{}}

  """
  @spec register_person(map()) :: {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  def register_person(attrs) do
    %Person{}
    |> Person.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Requests a magic link for `email`, registering the person if the address has
  not been seen before.

  Registration and log-in are the same request on purpose. Splitting them, as
  the generated stack does, means the log-in endpoint has to answer differently
  for a known and an unknown address, which is an enumeration oracle; and it
  means a worker signing up has to know which of two doors is theirs. Here both
  produce the same accepted response and the same email.

  Nothing about this path involves an employer. That is the requirement (R1),
  not an implementation detail.
  """
  @spec request_login_instructions(String.t(), url_fun(), DateTime.t()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  def request_login_instructions(email, magic_link_url_fun, %DateTime{} = now)
      when is_binary(email) and is_function(magic_link_url_fun, 1) do
    with {:ok, person} <- fetch_or_register_person(email) do
      _email = deliver_login_instructions(person, magic_link_url_fun, now)
      {:ok, person}
    end
  end

  @spec fetch_or_register_person(String.t()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  defp fetch_or_register_person(email) do
    email
    |> get_person_by_email()
    |> registered_or_register(email)
  end

  @spec registered_or_register(Person.t() | nil, String.t()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  defp registered_or_register(%Person{} = person, _email), do: {:ok, person}
  defp registered_or_register(nil, email), do: register_person(%{email: email})

  ## Settings

  @doc """
  Checks whether the person is in sudo mode as of `now`.

  The person is in sudo mode when the last authentication was done no further
  than 20 minutes before `now`. The limit can be given as third argument in
  minutes.
  """
  @spec sudo_mode?(Person.t() | nil, DateTime.t(), integer()) :: boolean()
  def sudo_mode?(person, now, minutes \\ -20)

  def sudo_mode?(%Person{authenticated_at: ts}, %DateTime{} = now, minutes)
      when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.add(now, minutes, :minute))
  end

  def sudo_mode?(_person, _now, _minutes), do: false

  @doc """
  Updates the person's email using the given token.

  If the token matches, the email is updated and **every** token the person
  holds is deleted, session tokens included. The generated implementation
  deleted only the change-email tokens, which left API tokens issued under the
  old address alive; an address is an authentication factor here, so changing
  it ends the sessions that were established against it.

  Returns the updated person and the tokens that were expired, so a caller can
  disconnect the sockets they belong to.
  """
  @spec update_person_email(Person.t(), String.t(), DateTime.t()) ::
          {:ok, {Person.t(), [PersonToken.t()]}} | {:error, :transaction_aborted}
  def update_person_email(%Person{} = person, token, %DateTime{} = now) when is_binary(token) do
    context = "change:#{person.email}"

    Repo.transact(fn ->
      with {:ok, query} <- PersonToken.verify_change_email_token_query(token, context, now),
           %PersonToken{sent_to: email} <- Repo.one(query),
           {:ok, result} <-
             update_person_and_delete_all_tokens(Person.email_changeset(person, %{email: email})) do
        {:ok, result}
      else
        _error -> {:error, :transaction_aborted}
      end
    end)
  end

  ## Session

  @doc """
  Generates the token a session runs on and returns it as raw bytes.
  """
  @spec generate_person_session_token(Person.t(), DateTime.t()) :: binary()
  def generate_person_session_token(%Person{} = person, %DateTime{} = now) do
    {token, person_token} = PersonToken.build_session_token(person, now)
    Repo.insert!(person_token)
    token
  end

  @doc """
  Gets the person the given session token belongs to, as of `now`.

  Returns `{person, token_inserted_at}` when the token is live, and nil when it
  has expired or its row is gone. There is no cache in front of this: deleting
  the row is the revocation.
  """
  @spec get_person_by_session_token(binary(), DateTime.t()) ::
          {Person.t(), DateTime.t()} | nil
  def get_person_by_session_token(token, %DateTime{} = now) when is_binary(token) do
    {:ok, query} = PersonToken.verify_session_token_query(token, now)
    Repo.one(query)
  end

  @doc """
  Gets the person the given magic-link token belongs to, without redeeming it.
  """
  @spec get_person_by_magic_link_token(String.t(), DateTime.t()) :: Person.t() | nil
  def get_person_by_magic_link_token(token, %DateTime{} = now) when is_binary(token) do
    with {:ok, query} <- PersonToken.verify_magic_link_token_query(token, now),
         {person, _token} <- Repo.one(query) do
      person
    else
      _error -> nil
    end
  end

  @doc """
  Logs the person in by magic link, consuming the link in the same transaction.

  Two cases remain of the generated three, because this application has no
  passwords:

  1. The person has already confirmed their email. They are logged in and the
     magic link is deleted.

  2. The person has not confirmed their email. They are confirmed, logged in,
     and every token they hold — session tokens included — is expired.

  Redemption is single use either way: the second attempt with the same token
  finds no row and returns `{:error, :not_found}`.
  """
  @spec login_person_by_magic_link(String.t(), DateTime.t()) ::
          {:ok, {Person.t(), [PersonToken.t()]}}
          | {:error, :not_found | Ecto.Changeset.t(Person.t())}
  def login_person_by_magic_link(token, %DateTime{} = now) when is_binary(token) do
    case PersonToken.verify_magic_link_token_query(token, now) do
      {:ok, query} -> query |> Repo.one() |> redeem_magic_link(now)
      :error -> {:error, :not_found}
    end
  end

  @spec redeem_magic_link({Person.t(), PersonToken.t()} | nil, DateTime.t()) ::
          {:ok, {Person.t(), [PersonToken.t()]}}
          | {:error, :not_found | Ecto.Changeset.t(Person.t())}
  defp redeem_magic_link({%Person{confirmed_at: nil} = person, _token}, now) do
    person
    |> Person.confirm_changeset(now)
    |> update_person_and_delete_all_tokens()
  end

  defp redeem_magic_link({%Person{} = person, %PersonToken{} = token}, _now) do
    Repo.delete!(token)
    {:ok, {person, []}}
  end

  defp redeem_magic_link(nil, _now), do: {:error, :not_found}

  @doc ~S"""
  Delivers the update-email instructions to the given person.

  ## Examples

      iex> deliver_person_update_email_instructions(person, current_email, &"https://example.com/confirm-email/#{&1}", now)
      %Swoosh.Email{}

  """
  @spec deliver_person_update_email_instructions(
          Person.t(),
          String.t(),
          url_fun(),
          DateTime.t()
        ) :: Swoosh.Email.t()
  def deliver_person_update_email_instructions(
        %Person{} = person,
        current_email,
        update_email_url_fun,
        %DateTime{} = now
      )
      when is_function(update_email_url_fun, 1) do
    {encoded_token, person_token} =
      PersonToken.build_email_token(person, "change:#{current_email}", now)

    Repo.insert!(person_token)
    PersonNotifier.deliver_update_email_instructions(person, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic-link log-in instructions to the given person.
  """
  @spec deliver_login_instructions(Person.t(), url_fun(), DateTime.t()) :: Swoosh.Email.t()
  def deliver_login_instructions(%Person{} = person, magic_link_url_fun, %DateTime{} = now)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, person_token} = PersonToken.build_email_token(person, "login", now)
    Repo.insert!(person_token)
    PersonNotifier.deliver_login_instructions(person, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the session token, ending the session it stands for.

  Returns the rows that were deleted, so the caller can disconnect the sockets
  they belong to. They carry the stored digest rather than the credential the
  request arrived with, which is the value a session's PubSub topic is named
  after; handing them back is what keeps the caller from having to hash
  anything itself.
  """
  @spec delete_person_session_token(binary()) :: {:ok, [PersonToken.t()]}
  def delete_person_session_token(token) when is_binary(token) do
    digest = PersonToken.hash_token(token)

    {_count, deleted} =
      Repo.delete_all(
        from(t in PersonToken, where: [token: ^digest, context: "session"], select: t)
      )

    {:ok, deleted}
  end

  ## Token helper

  @spec update_person_and_delete_all_tokens(Ecto.Changeset.t(Person.t())) ::
          {:ok, {Person.t(), [PersonToken.t()]}} | {:error, Ecto.Changeset.t(Person.t())}
  defp update_person_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, person} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(PersonToken, person_id: person.id)

        Repo.delete_all(
          from(t in PersonToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id))
        )

        {:ok, {person, tokens_to_expire}}
      end
    end)
  end
end
