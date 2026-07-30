defmodule HospitalityComs.Accounts do
  @moduledoc """
  Person identity: registration, magic-link authentication, and the API tokens
  a session runs on.

  A person record is created by the person and by no one else (R1). There is no
  invitation-claims-a-record path here and no employer-side creation path: the
  only way a `people` row comes into existence is `request_login_instructions/3`
  with an address nobody has used yet, and the row is unconfirmed until whoever
  reads that mailbox redeems the link.

  This context is person zone. It reads and writes through
  `HospitalityComs.Repo` only. `HospitalityComs.EmployerRepo` must never appear
  here; U3 turns that from a convention into a Postgres privilege.

  ## The scope-first shape, and what it covers

  Every function here that reaches a repo takes a
  `HospitalityComs.Accounts.PersonScope` first, so an employer caller holding
  an `EmployerScope` is refused by function clause — a `FunctionClauseError`
  raised before the body runs, at the top of a function nobody had to remember
  to guard. That is U3's mechanism, and until #18 it protected `sudo_mode?/2`
  alone, which reads nothing.

  `session_token_digest/1` is the only exception, and it is enumerated rather
  than incidental: it is a hash of its argument, reaching no repo, no row and
  no clock. `person_zone_test.exs` sweeps the module's export list and pins
  that exception as a literal.

  The instant arrives on the scope and nothing here reads a clock (KTD5), so
  the context is testable without touching the offsettable clock at all —
  expiry is asserted by passing an instant, not by moving global state.

  ## Two head shapes, because the person zone has an anonymous half

  Registration and log-in are anonymous. `request_login_instructions/3` may be
  the call that creates the row; `get_person_by_email/2` is asked about an
  address that may name nobody; and `get_person_by_session_token/2` is the call
  that *produces* the person a scope will carry, so it cannot be handed one
  that already has it. A scope answers three questions — which zone, when, and
  sometimes who — and only the first two are always answerable. The refusal is
  about the first, so the anonymous half is not an exception to it:
  `PersonScope.for_person(nil, now)` is what every unauthenticated request
  already carries.

  So the head says which of the two it is, per function:

    * **The scope's person is the subject.** `%PersonScope{person: %Person{}}`,
      and there is no person argument — `sudo_mode?/2`,
      `generate_person_session_token/1`, `update_person_email/2`,
      `deliver_login_instructions/2` and
      `deliver_person_update_email_instructions/3`.
    * **The subject is a credential, an address or an id handed in.**
      `%PersonScope{}`, and the scope's person is deliberately *not* read.
      Everything else.

  A head of the first shape on the log-in door would be a lie no caller could
  satisfy; a head of the second on `generate_person_session_token/1` would put
  a person argument beside a scope carrying a different one.

  The second shape does not require `person: nil`. `delete_person_session_token/2`
  is called from an authenticated request about that request's own credential,
  and `get_person_by_email/2` is called from inside
  `request_login_instructions/3` with whatever scope came down. The residue is
  worth stating: for those functions the scope's person is ignored, so the
  answer is about the credential and not about the caller.

  ## What this is not

  It is not the boundary, and nothing about it should be read as one. This
  module goes through `Repo`, which holds every privilege on every table, and
  an employer caller who constructs a `PersonScope` from their own instant
  reaches everything here. `boundary_test.exs` asserts exactly that, so the
  claim cannot quietly grow. What closes the person zone is the grant on
  `EmployerRepo`'s role plus U3's `REVOKE`; what the shape closes is reaching
  the zone by accident, and it makes the deliberate case a line a reviewer can
  see.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonNotifier
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Repo

  @type url_fun() :: (String.t() -> String.t())
  @type delivery() :: {:ok, Swoosh.Email.t()} | {:error, :delivery_failed}

  ## Database getters

  @doc """
  Gets a person by email.

  The scope carries no instant this needs — an address either names a live row
  or it does not, and there is no horizon on it. It is there for the zone: this
  is the read that turns an address into a person, and an employer session must
  not be one function call away from it.

  An erased person is unreachable by address: erasure nulls the column, so this
  returns nil and a later registration with the same address creates a new,
  unrelated person.

  ## Examples

      iex> get_person_by_email(scope, "foo@example.com")
      %Person{}

      iex> get_person_by_email(scope, "unknown@example.com")
      nil

  """
  @spec get_person_by_email(PersonScope.t(), String.t()) :: Person.t() | nil
  def get_person_by_email(%PersonScope{}, email) when is_binary(email) do
    Repo.get_by(Person, email: email)
  end

  @doc """
  Gets a single person.

  Raises `Ecto.NoResultsError` if the person does not exist.
  """
  @spec get_person!(PersonScope.t(), Ecto.UUID.t()) :: Person.t()
  def get_person!(%PersonScope{}, id) when is_binary(id), do: Repo.get!(Person, id)

  ## Person registration

  @doc """
  Registers a person.

  The insert takes a savepoint, so a unique-index collision comes back as a
  changeset error rather than poisoning an enclosing transaction. That is what
  lets `request_login_instructions/3` lose the registration race and carry on
  inside the same transaction; outside one it costs nothing.

  The scope is anonymous on the only path that matters: nobody holds a session
  for a person who does not exist yet.

  **The display name is given here and nowhere else** (#66). This is the one
  door a person row comes through, so putting the generator on this changeset is
  what makes "every person has a name" a property rather than a convention every
  fixture has to remember — `HospitalityComs.Demo.seed/0` and the five person
  fixtures all get one without naming it.

  ## Examples

      iex> register_person(scope, %{email: "foo@example.com"})
      {:ok, %Person{}}

      iex> register_person(scope, %{email: "not an address"})
      {:error, %Ecto.Changeset{}}

  """
  @spec register_person(PersonScope.t(), map()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  def register_person(%PersonScope{now: now}, attrs) when is_map(attrs) do
    %Person{}
    |> Person.registration_changeset(attrs, now)
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

  The scope is the request's own, and it is anonymous whenever this matters:
  the caller has no session, which is why they are asking for a link.
  """
  @spec request_login_instructions(PersonScope.t(), String.t(), url_fun()) ::
          {:ok, Person.t()}
          | {:error, :delivery_failed | :transaction_aborted | Ecto.Changeset.t(Person.t())}
  def request_login_instructions(%PersonScope{} = scope, email, magic_link_url_fun)
      when is_binary(email) and is_function(magic_link_url_fun, 1) do
    scope
    |> login_request_multi(email)
    |> Repo.transaction()
    |> deliver_requested_link(magic_link_url_fun)
  end

  @spec login_request_multi(PersonScope.t(), String.t()) :: Multi.t()
  defp login_request_multi(%PersonScope{now: now} = scope, email) do
    Multi.new()
    |> Multi.run(:person, fn _repo, _changes -> fetch_or_register_person(scope, email) end)
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

  @spec fetch_or_register_person(PersonScope.t(), String.t()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  defp fetch_or_register_person(scope, email) do
    scope
    |> get_person_by_email(email)
    |> registered_or_register(scope, email)
  end

  @spec registered_or_register(Person.t() | nil, PersonScope.t(), String.t()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  defp registered_or_register(%Person{} = person, _scope, _email), do: {:ok, person}

  defp registered_or_register(nil, scope, email) do
    scope
    |> register_person(%{email: email})
    |> or_whoever_won_the_race(scope, email)
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
          PersonScope.t(),
          String.t()
        ) :: {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  defp or_whoever_won_the_race({:ok, %Person{} = person}, _scope, _email), do: {:ok, person}

  defp or_whoever_won_the_race({:error, changeset}, scope, email) do
    scope |> get_person_by_email(email) |> registered_or_error(changeset)
  end

  # No row means the insert failed on its own merits — a malformed address, an
  # over-long one — and that is a real 422.
  @spec registered_or_error(Person.t() | nil, Ecto.Changeset.t(Person.t())) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  defp registered_or_error(%Person{} = person, _changeset), do: {:ok, person}
  defp registered_or_error(nil, changeset), do: {:error, changeset}

  ## Settings

  @doc """
  Checks whether the scope's person is in sudo mode as of the scope's instant.

  The person is in sudo mode when the last authentication was done no further
  than 20 minutes before the instant. The limit can be given as second argument
  in minutes.

  The head matches `PersonScope` and nothing else, so an employer caller raises
  `FunctionClauseError` before the body runs rather than being turned away by a
  check somebody has to remember to write. This was the only function in the
  module shaped that way until #18; the whole context is now, and it reads
  nothing, so it is the one place the shape is *all* there is.

  An anonymous person scope is a caller, not a mismatch, so it is answered
  `false` by the second clause rather than refused. That is deliberate and it
  is the reason this function is swept alongside the anonymous half in
  `person_zone_test.exs` rather than alongside the four that require a person:
  "was this session recently authenticated" has an answer for a session that
  never was.
  """
  @spec sudo_mode?(PersonScope.t(), integer()) :: boolean()
  def sudo_mode?(scope, minutes \\ -20)

  def sudo_mode?(%PersonScope{person: %Person{authenticated_at: ts}, now: now}, minutes)
      when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.add(now, minutes, :minute))
  end

  def sudo_mode?(%PersonScope{}, _minutes), do: false

  @doc """
  Changes the name the scope's person is shown under (#66).

  The person is the scope's own and there is no id argument: a session may
  rename itself and nothing else, which is the same head shape
  `generate_person_session_token/1` and `update_person_email/2` take —
  "where the scope's person *is* the subject, destructure it and take no person
  argument".

  Trimmed, required, and bounded by
  `HospitalityComs.Accounts.DisplayName.max_length/0`. Two check constraints say
  the same two things at the database, because the erasure write reaches this
  column with an `update_all` and meets no changeset.

  ## An erased person is refused, and that arm is unreachable from the API

  Erasure overwrites the name and deletes every token the person holds, so no
  authenticator can produce a scope carrying an erased person and no request can
  reach this arm. It is here anyway because the alternative is that KTD15's
  "nothing identifying is left" rests on the *absence of a caller* rather than
  on a rule — and a second clause is four lines. `{:error, :erased}` rather than
  a `FunctionClauseError`, so a future surface that acquires such a scope gets
  an answer it can render.
  """
  @spec update_display_name(PersonScope.t(), String.t()) ::
          {:ok, Person.t()} | {:error, :erased | Ecto.Changeset.t(Person.t())}
  def update_display_name(%PersonScope{person: %Person{erased_at: nil} = person, now: now}, name)
      when is_binary(name) do
    person
    |> Person.display_name_changeset(%{display_name: name}, now)
    |> Repo.update()
  end

  def update_display_name(%PersonScope{person: %Person{}}, name) when is_binary(name) do
    {:error, :erased}
  end

  @doc """
  Updates the person's email using the given token.

  If the token matches, the email is updated and **every** token the person
  holds is deleted, session tokens included. The generated implementation
  deleted only the change-email tokens, which left API tokens issued under the
  old address alive; an address is an authentication factor here, so changing
  it ends the sessions that were established against it.

  Returns the updated person and the tokens that were expired, so a caller can
  disconnect the sockets they belong to.

  The subject is the scope's own person: an address is changed by whoever holds
  it, and a session for somebody else has no business naming them here.
  """
  @spec update_person_email(PersonScope.t(), String.t()) ::
          {:ok, {Person.t(), [PersonToken.t()]}} | {:error, :transaction_aborted}
  def update_person_email(%PersonScope{person: %Person{} = person, now: now}, token)
      when is_binary(token) do
    context = "change:#{person.email}"

    Repo.transact(fn ->
      with {:ok, query} <- PersonToken.verify_change_email_token_query(token, context, now),
           %PersonToken{sent_to: email} <- Repo.one(query),
           {:ok, result} <-
             update_person_and_delete_all_tokens(
               Person.email_changeset(person, %{email: email}, now)
             ) do
        {:ok, result}
      else
        _error -> {:error, :transaction_aborted}
      end
    end)
  end

  ## Session

  @doc """
  Generates the token a session runs on and returns it as raw bytes.

  The scope is the session about to exist: whoever it names is who the token
  authenticates as, and its instant is what the row is stamped from. A caller
  redeeming a magic link holds an *anonymous* request scope and the person the
  redemption returned, so it builds one — `PersonScope.for_person(person,
  scope.now)` — rather than handing the person past the shape.
  """
  @spec generate_person_session_token(PersonScope.t()) :: binary()
  def generate_person_session_token(%PersonScope{person: %Person{} = person, now: now}) do
    {token, person_token} = PersonToken.build_session_token(person, now)
    Repo.insert!(person_token)
    token
  end

  @doc """
  The value a session token is stored under.

  The SHA-256 digest of the bytes the holder carries — the same one every
  lookup here hashes on its way to the column, exposed because a caller
  sometimes needs to *identify* a session without holding a credential for it.
  `HospitalityComsWeb.PersonSocket` is the caller: KTD7 makes a socket's id the
  session it belongs to, and a socket id is a PubSub topic that crosses
  distributed Erlang on every broadcast. Naming it after the digest rather than
  the token is what keeps a working session out of telemetry.

  One direction only. Nothing recovers the token from this.

  The one function in this module that takes no scope, and the reason is that
  it reaches no repo, no row and no clock: it is `:crypto.hash/2` of the bytes
  handed in. `person_zone_test.exs` names it as the sweep's single exception
  and asserts that justification rather than accepting it.
  """
  @spec session_token_digest(binary()) :: binary()
  def session_token_digest(token) when is_binary(token), do: PersonToken.hash_token(token)

  @doc """
  Gets the person the given session token belongs to, as of the scope's instant.

  Returns `{person, token_inserted_at}` when the token is live, and nil when it
  has expired or its row is gone. There is no cache in front of this: deleting
  the row is the revocation.

  **This is the call that produces the person a scope will carry**, so the
  scope it takes is necessarily anonymous — `HospitalityComsWeb.PersonAuth`
  builds one from the request's instant, authenticates, and then builds the
  request's real scope from the answer. Anything else would be circular, and it
  is why the anonymous form of a person scope is a requirement here rather than
  a concession.
  """
  @spec get_person_by_session_token(PersonScope.t(), binary()) ::
          {Person.t(), DateTime.t()} | nil
  def get_person_by_session_token(%PersonScope{now: now}, token) when is_binary(token) do
    {:ok, query} = PersonToken.verify_session_token_query(token, now)
    Repo.one(query)
  end

  @doc """
  The same lookup, for a caller holding the digest rather than the token.

  `HospitalityComsWeb.ChannelAuth` is the caller, and the reason it needs one is
  that a websocket outlives the request that opened it. An HTTP request carries
  its credential every time, so `get_person_by_session_token/2` re-derives the
  session on every call for free; a socket authenticates once and then lives for
  days, so if it is to ask the same question again it has to ask it about
  something it is willing to keep — and the digest is the value this application
  is willing to keep, because `people_tokens.token` holds exactly that and a
  leak of it must not yield a working session.

  Same row, same fourteen-day horizon: `PersonToken.verify_session_token_query/2`
  delegates to the query behind this one rather than repeating it. Same
  anonymous scope too, and for the same reason — a join derives the session
  before it has one.
  """
  @spec get_person_by_session_token_digest(PersonScope.t(), binary()) ::
          {Person.t(), DateTime.t()} | nil
  def get_person_by_session_token_digest(%PersonScope{now: now}, digest) when is_binary(digest) do
    {:ok, query} = PersonToken.verify_session_token_digest_query(digest, now)
    Repo.one(query)
  end

  @doc """
  Gets the person the given magic-link token belongs to, without redeeming it.
  """
  @spec get_person_by_magic_link_token(PersonScope.t(), String.t()) :: Person.t() | nil
  def get_person_by_magic_link_token(%PersonScope{now: now}, token) when is_binary(token) do
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

  The scope is the redeeming request's, which is anonymous: the link is the
  credential, and the person it names is this call's answer rather than its
  argument.
  """
  @spec login_person_by_magic_link(PersonScope.t(), String.t()) ::
          {:ok, {Person.t(), [PersonToken.t()]}}
          | {:error, :not_found | Ecto.Changeset.t(Person.t())}
  def login_person_by_magic_link(%PersonScope{now: now}, token) when is_binary(token) do
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

  It takes the **new** address and derives the rest from the scope, where it
  used to take a `Person` struct doctored to carry the new address plus the old
  address beside it. The freedom that removed was unusable: `update_person_email/2`
  verifies the token against `"change:\#{person.email}"`, so a caller who passed
  anything else minted a token nothing could ever redeem, and a caller who
  passed a person other than their own minted one against somebody else's
  address.

  ## Examples

      iex> deliver_person_update_email_instructions(scope, "new@example.com", &"https://example.com/confirm-email/#{&1}")
      {:ok, %Swoosh.Email{}}

  """
  @spec deliver_person_update_email_instructions(PersonScope.t(), String.t(), url_fun()) ::
          delivery()
  def deliver_person_update_email_instructions(
        %PersonScope{person: %Person{} = person, now: now},
        new_email,
        update_email_url_fun
      )
      when is_binary(new_email) and is_function(update_email_url_fun, 1) do
    addressee = %{person | email: new_email}

    {encoded_token, person_token} =
      PersonToken.build_email_token(addressee, "change:#{person.email}", now)

    Repo.insert!(person_token)

    PersonNotifier.deliver_update_email_instructions(
      addressee,
      update_email_url_fun.(encoded_token)
    )
  end

  @doc """
  Delivers the magic-link log-in instructions to the given person.

  This is the single-person form, and the person is the scope's own.
  `request_login_instructions/3` is the one the log-in endpoint uses, because
  it also has to register an address nobody holds — so it takes an address and
  an anonymous scope where this one takes neither.
  """
  @spec deliver_login_instructions(PersonScope.t(), url_fun()) :: delivery()
  def deliver_login_instructions(
        %PersonScope{person: %Person{} = person, now: now},
        magic_link_url_fun
      )
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

  The subject is the credential, not the scope's person: a session is ended by
  presenting it. The scope carries no instant this reads — a deletion is not
  answerable as of a moment — and is here so that the person zone's one
  deleting function is refused an employer scope like everything beside it.
  """
  @spec delete_person_session_token(PersonScope.t(), binary()) :: {:ok, [PersonToken.t()]}
  def delete_person_session_token(%PersonScope{}, token) when is_binary(token) do
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
