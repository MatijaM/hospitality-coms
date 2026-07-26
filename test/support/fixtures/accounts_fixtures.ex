defmodule HospitalityComs.AccountsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `HospitalityComs.Accounts`
  context.

  Every fixture takes the instant explicitly, for the same reason the context
  does: a test that wants to assert on an expiry boundary has to be able to
  place the token on one side of it, and a test that does not care should not
  have to move global state to say so.
  """

  import Ecto.Query

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Accounts.Scope
  alias HospitalityComs.Repo

  @doc """
  An instant to hang a test off, far enough from any real one that a wall-clock
  read shows up as an obviously wrong answer rather than an off-by-a-second.
  """
  @spec fixed_instant() :: DateTime.t()
  def fixed_instant, do: ~U[2026-03-01 12:00:00.000000Z]

  @spec unique_person_email() :: String.t()
  def unique_person_email, do: "person#{System.unique_integer([:positive])}@example.com"

  @spec valid_person_attributes(map()) :: map()
  def valid_person_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{email: unique_person_email()})
  end

  @spec unconfirmed_person_fixture(map()) :: Person.t()
  def unconfirmed_person_fixture(attrs \\ %{}) do
    {:ok, person} =
      attrs
      |> valid_person_attributes()
      |> Accounts.register_person()

    person
  end

  @spec person_fixture(map(), DateTime.t()) :: Person.t()
  def person_fixture(attrs \\ %{}, now \\ fixed_instant()) do
    person = unconfirmed_person_fixture(attrs)

    token =
      extract_person_token(fn url ->
        Accounts.deliver_login_instructions(person, url, now)
      end)

    {:ok, {person, _expired_tokens}} = Accounts.login_person_by_magic_link(token, now)

    person
  end

  @spec person_scope_fixture(Person.t(), DateTime.t()) :: Scope.t()
  def person_scope_fixture(person \\ person_fixture(), now \\ fixed_instant()) do
    Scope.for_person(person, now)
  end

  @doc """
  Runs `fun` with a URL builder that brackets the token, then pulls the token
  back out of the delivered email.
  """
  @spec extract_person_token((Accounts.url_fun() -> Swoosh.Email.t())) :: String.t()
  def extract_person_token(fun) do
    captured_email = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_before, token | _rest] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  @doc """
  Issues a magic-link token without delivering it, returning the encoded token
  and its hashed database counterpart.
  """
  @spec generate_person_magic_link_token(Person.t(), DateTime.t()) :: {String.t(), binary()}
  def generate_person_magic_link_token(person, now \\ fixed_instant()) do
    {encoded_token, person_token} = PersonToken.build_email_token(person, "login", now)
    Repo.insert!(person_token)
    {encoded_token, person_token.token}
  end

  @doc """
  Backdates a token's stamps, for tests that need a token to already be old
  rather than to wait for it.

  Takes the raw credential and finds the row by its digest, because that is
  what the column holds.
  """
  @spec override_token_authenticated_at(binary(), DateTime.t()) :: :ok
  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    digest = PersonToken.hash_token(token)

    Repo.update_all(from(t in PersonToken, where: t.token == ^digest),
      set: [authenticated_at: DateTime.truncate(authenticated_at, :second)]
    )

    :ok
  end
end
