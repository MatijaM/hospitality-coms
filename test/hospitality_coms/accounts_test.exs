defmodule HospitalityComs.AccountsTest do
  @moduledoc """
  Registration and magic-link authentication, with no employer anywhere in
  sight — that absence is the requirement (R1), not a consequence of the unit
  being early.

  Every expiry here is asserted on both sides of its boundary, and none of it
  moves the clock. The context takes its instant as an argument, so a test that
  wants a token to be fifteen minutes old says so by passing an instant fifteen
  minutes later. That is what keeps this file `async: true` while the plug and
  controller tests, which go through the real clock, cannot be.
  """

  use HospitalityComs.DataCase, async: true

  import HospitalityComs.AccountsFixtures

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonToken

  @now ~U[2026-03-01 12:00:00.000000Z]

  defp url_builder, do: &"http://localhost/log-in/#{&1}"

  defp login_tokens(person), do: Repo.all_by(PersonToken, person_id: person.id, context: "login")

  describe "get_person_by_email/1" do
    test "does not return the person if the email does not exist" do
      refute Accounts.get_person_by_email("unknown@example.com")
    end

    test "returns the person if the email exists" do
      %Person{id: id} = person = person_fixture()

      assert %Person{id: ^id} = Accounts.get_person_by_email(person.email)
    end

    test "matches an address case-insensitively" do
      person = person_fixture(%{email: "Casing#{System.unique_integer([:positive])}@Example.com"})

      assert %Person{id: id} = Accounts.get_person_by_email(String.downcase(person.email))
      assert id == person.id
    end
  end

  describe "register_person/1" do
    test "requires an email" do
      {:error, changeset} = Accounts.register_person(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates the email's shape and length" do
      {:error, changeset} = Accounts.register_person(%{email: "not valid"})
      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)

      too_long = String.duplicate("a", 160) <> "@example.com"
      {:error, changeset} = Accounts.register_person(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "refuses an address a live person already holds" do
      %{email: email} = person_fixture()

      {:error, changeset} = Accounts.register_person(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      {:error, changeset} = Accounts.register_person(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers people without a password and unconfirmed" do
      email = unique_person_email()
      {:ok, person} = Accounts.register_person(valid_person_attributes(%{email: email}))

      assert person.email == email
      assert is_nil(person.confirmed_at)
      assert is_nil(person.erased_at)
      refute Map.has_key?(person, :hashed_password)
    end
  end

  describe "request_login_instructions/3" do
    test "creates a person and a login token for an address nobody holds" do
      email = unique_person_email()
      refute Accounts.get_person_by_email(email)

      assert {:ok, %Person{} = person} =
               Accounts.request_login_instructions(email, url_builder(), @now)

      assert person.email == email
      assert is_nil(person.confirmed_at)

      assert [%PersonToken{context: "login", sent_to: sent_to, inserted_at: inserted_at}] =
               login_tokens(person)

      assert sent_to == email
      assert inserted_at == DateTime.truncate(@now, :second)
    end

    test "delivers a confirmation email carrying the link" do
      email = unique_person_email()

      {:ok, _person} = Accounts.request_login_instructions(email, url_builder(), @now)

      assert_received {:email, %Swoosh.Email{subject: "Confirmation instructions"} = delivered}
      assert delivered.text_body =~ "http://localhost/log-in/"
    end

    test "issues a further token for a known address without creating a second person" do
      person = person_fixture()

      assert {:ok, returned} =
               Accounts.request_login_instructions(person.email, url_builder(), @now)

      assert returned.id == person.id
      assert Repo.aggregate(from(p in Person, where: p.email == ^person.email), :count) == 1
      assert length(login_tokens(person)) == 1
    end

    test "does not create a person for an address that is not an address" do
      assert {:error, changeset} =
               Accounts.request_login_instructions("not an address", url_builder(), @now)

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
      assert Repo.aggregate(PersonToken, :count) == 0
    end
  end

  describe "get_person_by_magic_link_token/2" do
    setup do
      person = unconfirmed_person_fixture()
      {encoded_token, hashed_token} = generate_person_magic_link_token(person, @now)

      %{person: person, token: encoded_token, hashed_token: hashed_token}
    end

    test "returns the person for a live token", %{person: person, token: token} do
      assert found = Accounts.get_person_by_magic_link_token(token, @now)
      assert found.id == person.id
    end

    test "does not return the person for a token that is not a token" do
      refute Accounts.get_person_by_magic_link_token("oops", @now)
    end

    test "does not return the person once the row is gone", %{token: token} do
      assert Accounts.get_person_by_magic_link_token(token, @now)
      assert {1, _returned} = Repo.delete_all(PersonToken)
      refute Accounts.get_person_by_magic_link_token(token, @now)
    end

    test "is still live one second short of fifteen minutes", %{token: token} do
      assert Accounts.get_person_by_magic_link_token(token, DateTime.add(@now, 899, :second))
    end

    test "is expired at fifteen minutes", %{token: token} do
      refute Accounts.get_person_by_magic_link_token(token, DateTime.add(@now, 15, :minute))
    end

    test "stops verifying once the person's address changes", %{person: person, token: token} do
      # Deliberately bypassing the context, which would delete every token in
      # the same transaction. The binding being asserted is the one in the
      # query — `sent_to == person.email` — not the deletion that usually makes
      # the point moot.
      person
      |> Ecto.Changeset.change(email: unique_person_email())
      |> Repo.update!()

      refute Accounts.get_person_by_magic_link_token(token, @now)
    end
  end

  describe "login_person_by_magic_link/2" do
    test "confirms an unconfirmed person and expires their tokens" do
      person = unconfirmed_person_fixture()
      {encoded_token, _hashed_token} = generate_person_magic_link_token(person, @now)

      assert {:ok, {confirmed, [_expired]}} =
               Accounts.login_person_by_magic_link(encoded_token, @now)

      assert confirmed.confirmed_at == DateTime.truncate(@now, :second)
      assert Repo.aggregate(PersonToken, :count) == 0
    end

    test "logs a confirmed person in and consumes only the link" do
      person = person_fixture()
      session_token = Accounts.generate_person_session_token(person, @now)
      {encoded_token, _hashed_token} = generate_person_magic_link_token(person, @now)

      assert {:ok, {returned, []}} = Accounts.login_person_by_magic_link(encoded_token, @now)
      assert returned.id == person.id
      assert login_tokens(person) == []
      assert Accounts.get_person_by_session_token(session_token, @now)
    end

    test "cannot redeem the same link twice" do
      person = person_fixture()
      {encoded_token, _hashed_token} = generate_person_magic_link_token(person, @now)

      assert {:ok, {_person, _expired}} = Accounts.login_person_by_magic_link(encoded_token, @now)
      assert {:error, :not_found} = Accounts.login_person_by_magic_link(encoded_token, @now)
    end

    test "cannot redeem an expired link" do
      person = person_fixture()
      {encoded_token, _hashed_token} = generate_person_magic_link_token(person, @now)

      assert {:error, :not_found} =
               Accounts.login_person_by_magic_link(encoded_token, DateTime.add(@now, 15, :minute))

      assert length(login_tokens(person)) == 1
    end

    test "cannot redeem a token that is not base64url" do
      assert {:error, :not_found} = Accounts.login_person_by_magic_link("not a token", @now)
    end
  end

  describe "generate_person_session_token/2" do
    setup do
      %{person: person_fixture()}
    end

    test "stores the token stamped with the unit of work's instant", %{person: person} do
      token = Accounts.generate_person_session_token(person, @now)

      assert %PersonToken{context: "session", inserted_at: inserted_at, person_id: person_id} =
               Repo.get_by(PersonToken, token: PersonToken.hash_token(token))

      assert person_id == person.id
      assert inserted_at == DateTime.truncate(@now, :second)
    end

    test "stores the digest and never the credential itself", %{person: person} do
      token = Accounts.generate_person_session_token(person, @now)

      assert %PersonToken{token: stored} =
               Repo.one(from(t in PersonToken, where: t.context == "session"))

      # A read of `people_tokens` must not hand the reader a working bearer
      # credential: the column holds a digest that cannot be replayed.
      refute stored == token
      assert stored == :crypto.hash(:sha256, token)
    end

    test "issues a distinct token every time", %{person: person} do
      first = Accounts.generate_person_session_token(person, @now)
      second = Accounts.generate_person_session_token(person, @now)

      refute first == second
    end
  end

  describe "get_person_by_session_token/2" do
    setup do
      person = person_fixture()
      %{person: person, token: Accounts.generate_person_session_token(person, @now)}
    end

    test "returns the person for a live token", %{person: person, token: token} do
      assert {found, inserted_at} = Accounts.get_person_by_session_token(token, @now)
      assert found.id == person.id
      assert inserted_at == DateTime.truncate(@now, :second)
    end

    test "does not return a person for a token nobody issued" do
      refute Accounts.get_person_by_session_token("nonsense", @now)
    end

    test "is still live one day short of fourteen", %{token: token} do
      assert Accounts.get_person_by_session_token(token, DateTime.add(@now, 13, :day))
    end

    test "is expired at fourteen days", %{token: token} do
      refute Accounts.get_person_by_session_token(token, DateTime.add(@now, 14, :day))
    end

    test "stops verifying the moment its row is deleted", %{token: token} do
      assert Accounts.get_person_by_session_token(token, @now)

      assert {:ok, [%PersonToken{context: "session", token: stored}]} =
               Accounts.delete_person_session_token(token)

      # The row handed back is the stored one, which is what names the PubSub
      # topic the session's sockets are torn down on.
      assert stored == PersonToken.hash_token(token)
      refute Accounts.get_person_by_session_token(token, @now)
    end

    test "deletes nothing when the credential matches no row", %{person: person} do
      assert {:ok, []} = Accounts.delete_person_session_token("nobody issued this")
      assert Repo.aggregate(from(t in PersonToken, where: t.person_id == ^person.id), :count) == 1
    end
  end

  describe "update_person_email/3" do
    setup do
      person = person_fixture()
      new_email = unique_person_email()

      change_token =
        extract_person_token(fn url ->
          Accounts.deliver_person_update_email_instructions(
            %{person | email: new_email},
            person.email,
            url,
            @now
          )
        end)

      %{person: person, new_email: new_email, change_token: change_token}
    end

    test "changes the address", context do
      %{person: person, new_email: new_email, change_token: change_token} = context

      assert {:ok, {updated, _expired}} = Accounts.update_person_email(person, change_token, @now)

      assert updated.email == new_email
      refute Accounts.get_person_by_email(person.email)
    end

    test "invalidates every API token the person held", context do
      %{person: person, change_token: change_token} = context
      session_token = Accounts.generate_person_session_token(person, @now)
      assert Accounts.get_person_by_session_token(session_token, @now)

      assert {:ok, {_updated, expired}} = Accounts.update_person_email(person, change_token, @now)

      assert Enum.any?(expired, &(&1.context == "session"))
      refute Accounts.get_person_by_session_token(session_token, @now)
    end

    test "refuses a token that is not the person's", %{person: person} do
      other = person_fixture()

      other_token =
        extract_person_token(fn url ->
          Accounts.deliver_person_update_email_instructions(
            %{other | email: unique_person_email()},
            other.email,
            url,
            @now
          )
        end)

      assert {:error, :transaction_aborted} =
               Accounts.update_person_email(person, other_token, @now)
    end

    test "refuses a token older than seven days", context do
      %{person: person, change_token: change_token} = context

      assert {:error, :transaction_aborted} =
               Accounts.update_person_email(person, change_token, DateTime.add(@now, 7, :day))
    end
  end

  describe "sudo_mode?/3" do
    test "is true inside the window and false outside it" do
      person = %Person{authenticated_at: DateTime.truncate(@now, :second)}

      assert Accounts.sudo_mode?(person, DateTime.add(@now, 19, :minute))
      refute Accounts.sudo_mode?(person, DateTime.add(@now, 21, :minute))
    end

    test "is false for a person who never authenticated" do
      refute Accounts.sudo_mode?(%Person{authenticated_at: nil}, @now)
      refute Accounts.sudo_mode?(nil, @now)
    end
  end
end
