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

  alias Ecto.Multi
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonNotifier
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Repo

  @type url_fun() :: (String.t() -> String.t())
  @type delivery() :: {:ok, Swoosh.Email.t()} | {:error, :delivery_failed}

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

  The insert takes a savepoint, so a unique-index collision comes back as a
  changeset error rather than poisoning an enclosing transaction. That is what
  lets `request_login_instructions/3` lose the registration race and carry on
  inside the same transaction; outside one it costs nothing.

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
    |> Repo.insert(mode: :savepoint)
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

  The two writes — the person row and the token row — are one transaction, so
  there is no state in which a person exists with no link on the way to them.
  The mail goes out after that transaction commits, and deliberately not
  inside it: a database transaction held open across a call to a mail provider
  is a connection hostage to somebody else's latency.

  A provider that is down is therefore `{:error, :delivery_failed}` with the
  rows already written. That is the same thing an abandoned request leaves —
  an unconfirmed person holding a token that expires in fifteen minutes — and
  the person can ask again.
  """
  @spec request_login_instructions(String.t(), url_fun(), DateTime.t()) ::
          {:ok, Person.t()}
          | {:error, :delivery_failed | :transaction_aborted | Ecto.Changeset.t(Person.t())}
  def request_login_instructions(email, magic_link_url_fun, %DateTime{} = now)
      when is_binary(email) and is_function(magic_link_url_fun, 1) do
    email
    |> login_request_multi(now)
    |> Repo.transaction()
    |> deliver_requested_link(magic_link_url_fun)
  end

  @spec login_request_multi(String.t(), DateTime.t()) :: Multi.t()
  defp login_request_multi(email, now) do
    Multi.new()
    |> Multi.run(:person, fn _repo, _changes -> fetch_or_register_person(email) end)
    |> Multi.run(:login_token, fn repo, %{person: person} ->
      insert_login_token(repo, person, now)
    end)
  end

  @spec deliver_requested_link(
          {:ok, %{person: Person.t(), login_token: String.t()}}
          | {:error, atom(), Ecto.Changeset.t(Person.t()) | term(), map()},
          url_fun()
        ) ::
          {:ok, Person.t()}
          | {:error, :delivery_failed | :transaction_aborted | Ecto.Changeset.t(Person.t())}
  defp deliver_requested_link({:ok, %{person: person, login_token: encoded_token}}, url_fun) do
    person
    |> PersonNotifier.deliver_login_instructions(url_fun.(encoded_token))
    |> requested(person)
  end

  defp deliver_requested_link({:error, :person, %Ecto.Changeset{} = changeset, _changes}, _fun) do
    {:error, changeset}
  end

  defp deliver_requested_link({:error, _step, _reason, _changes}, _url_fun) do
    {:error, :transaction_aborted}
  end

  @spec requested(PersonNotifier.delivery(), Person.t()) ::
          {:ok, Person.t()} | {:error, :delivery_failed}
  defp requested({:ok, _email}, person), do: {:ok, person}
  defp requested({:error, :delivery_failed}, _person), do: {:error, :delivery_failed}

  @spec insert_login_token(Ecto.Repo.t(), Person.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, Ecto.Changeset.t(PersonToken.t())}
  defp insert_login_token(repo, person, now) do
    {encoded_token, person_token} = PersonToken.build_email_token(person, "login", now)

    with {:ok, _row} <- repo.insert(person_token), do: {:ok, encoded_token}
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

  defp registered_or_register(nil, email) do
    %{email: email}
    |> register_person()
    |> or_whoever_won_the_race(email)
  end

  # Two first-ever log-ins for the same address at the same time both see no
  # person and both insert; one of them loses on the unique index. Losing that
  # race is not the caller's problem and must not be reported as one — a 422
  # saying the address "has already been taken" would tell somebody who has
  # never used this application that the address is registered, which is the
  # enumeration oracle the single log-in door exists to close. So the loser
  # looks again, and the winner's person is the answer to both requests.
  @spec or_whoever_won_the_race(
          {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())},
          String.t()
        ) :: {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  defp or_whoever_won_the_race({:ok, %Person{} = person}, _email), do: {:ok, person}

  defp or_whoever_won_the_race({:error, changeset}, email) do
    email |> get_person_by_email() |> registered_or_error(changeset)
  end

  # No row means the insert failed on its own merits — a malformed address, an
  # over-long one — and that is a real 422.
  @spec registered_or_error(Person.t() | nil, Ecto.Changeset.t(Person.t())) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  defp registered_or_error(%Person{} = person, _changeset), do: {:ok, person}
  defp registered_or_error(nil, changeset), do: {:error, changeset}

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

  Redemption is single use either way, and single use under concurrency and
  not merely on a second request an hour later. The lookup and the write are
  one transaction, and the write that claims the link is
  `delete_all ... where id`, whose affected-row count is the claim: exactly one
  caller gets `{1, _}` and everybody else gets `{0, _}` and `{:error,
  :not_found}`, which the endpoint answers 401 to.

  That matters because both racing paths were wrong before. Deleting the struct
  raised `Ecto.StaleEntryError` on the loser — a 500 where a 401 was promised —
  and the unconfirmed path did not delete by identity at all, so two
  simultaneous redemptions of one link produced two sessions.
  """
  @spec login_person_by_magic_link(String.t(), DateTime.t()) ::
          {:ok, {Person.t(), [PersonToken.t()]}}
          | {:error, :not_found | Ecto.Changeset.t(Person.t())}
  def login_person_by_magic_link(token, %DateTime{} = now) when is_binary(token) do
    case PersonToken.verify_magic_link_token_query(token, now) do
      {:ok, query} -> Repo.transact(fn -> query |> Repo.one() |> redeem_magic_link(now) end)
      :error -> {:error, :not_found}
    end
  end

  @spec redeem_magic_link({Person.t(), PersonToken.t()} | nil, DateTime.t()) ::
          {:ok, {Person.t(), [PersonToken.t()]}}
          | {:error, :not_found | Ecto.Changeset.t(Person.t())}
  defp redeem_magic_link({%Person{} = person, %PersonToken{id: id}}, now) do
    PersonToken
    |> where([t], t.id == ^id)
    |> select([t], t)
    |> Repo.delete_all()
    |> log_in_claimant(person, now)
  end

  defp redeem_magic_link(nil, _now), do: {:error, :not_found}

  @spec log_in_claimant({non_neg_integer(), [PersonToken.t()]}, Person.t(), DateTime.t()) ::
          {:ok, {Person.t(), [PersonToken.t()]}}
          | {:error, :not_found | Ecto.Changeset.t(Person.t())}
  defp log_in_claimant({0, _deleted}, _person, _now), do: {:error, :not_found}

  defp log_in_claimant({1, [claimed]}, %Person{confirmed_at: nil} = person, now) do
    person
    |> Person.confirm_changeset(now)
    |> update_person_and_delete_all_tokens()
    |> including_claimed(claimed)
  end

  defp log_in_claimant({1, _deleted}, %Person{} = person, _now), do: {:ok, {person, []}}

  # The link this call claimed is expired along with the rest of the person's
  # tokens, so it belongs in the list the caller disconnects sockets for even
  # though it was deleted a statement earlier.
  @spec including_claimed(
          {:ok, {Person.t(), [PersonToken.t()]}} | {:error, Ecto.Changeset.t(Person.t())},
          PersonToken.t()
        ) :: {:ok, {Person.t(), [PersonToken.t()]}} | {:error, Ecto.Changeset.t(Person.t())}
  defp including_claimed({:ok, {person, expired}}, claimed),
    do: {:ok, {person, [claimed | expired]}}

  defp including_claimed({:error, changeset}, _claimed), do: {:error, changeset}

  @doc ~S"""
  Delivers the update-email instructions to the given person.

  The token row is written before the mail goes out, and stays written if the
  mail does not: a token nobody can reach expires on its own, whereas a
  transaction held open across a provider call does not.

  ## Examples

      iex> deliver_person_update_email_instructions(person, current_email, &"https://example.com/confirm-email/#{&1}", now)
      {:ok, %Swoosh.Email{}}

  """
  @spec deliver_person_update_email_instructions(
          Person.t(),
          String.t(),
          url_fun(),
          DateTime.t()
        ) :: delivery()
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

  This is the single-person form. `request_login_instructions/3` is the one the
  log-in endpoint uses, because it also has to register an address nobody
  holds, and that pair of writes belongs in one transaction.
  """
  @spec deliver_login_instructions(Person.t(), url_fun(), DateTime.t()) :: delivery()
  def deliver_login_instructions(%Person{} = person, magic_link_url_fun, %DateTime{} = now)
      when is_function(magic_link_url_fun, 1) do
    {:ok, encoded_token} = insert_login_token(Repo, person, now)
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
