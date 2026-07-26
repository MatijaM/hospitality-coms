defmodule HospitalityComs.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `HospitalityComs.Accounts` context.
  """

  import Ecto.Query

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Scope

  def unique_person_email, do: "person#{System.unique_integer()}@example.com"
  def valid_person_password, do: "hello world!"

  def valid_person_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_person_email()
    })
  end

  def unconfirmed_person_fixture(attrs \\ %{}) do
    {:ok, person} =
      attrs
      |> valid_person_attributes()
      |> Accounts.register_person()

    person
  end

  def person_fixture(attrs \\ %{}) do
    person = unconfirmed_person_fixture(attrs)

    token =
      extract_person_token(fn url ->
        Accounts.deliver_login_instructions(person, url)
      end)

    {:ok, {person, _expired_tokens}} =
      Accounts.login_person_by_magic_link(token)

    person
  end

  def person_scope_fixture do
    person = person_fixture()
    person_scope_fixture(person)
  end

  def person_scope_fixture(person) do
    Scope.for_person(person)
  end

  def set_password(person) do
    {:ok, {person, _expired_tokens}} =
      Accounts.update_person_password(person, %{password: valid_person_password()})

    person
  end

  def extract_person_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    HospitalityComs.Repo.update_all(
      from(t in Accounts.PersonToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_person_magic_link_token(person) do
    {encoded_token, person_token} = Accounts.PersonToken.build_email_token(person, "login")
    HospitalityComs.Repo.insert!(person_token)
    {encoded_token, person_token.token}
  end

  def offset_person_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    HospitalityComs.Repo.update_all(
      from(ut in Accounts.PersonToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
