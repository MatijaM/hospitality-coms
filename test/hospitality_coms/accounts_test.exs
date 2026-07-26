defmodule HospitalityComs.AccountsTest do
  use HospitalityComs.DataCase

  alias HospitalityComs.Accounts

  import HospitalityComs.AccountsFixtures
  alias HospitalityComs.Accounts.{Person, PersonToken}

  describe "get_person_by_email/1" do
    test "does not return the person if the email does not exist" do
      refute Accounts.get_person_by_email("unknown@example.com")
    end

    test "returns the person if the email exists" do
      %{id: id} = person = person_fixture()
      assert %Person{id: ^id} = Accounts.get_person_by_email(person.email)
    end
  end

  describe "get_person_by_email_and_password/2" do
    test "does not return the person if the email does not exist" do
      refute Accounts.get_person_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the person if the password is not valid" do
      person = person_fixture() |> set_password()
      refute Accounts.get_person_by_email_and_password(person.email, "invalid")
    end

    test "returns the person if the email and password are valid" do
      %{id: id} = person = person_fixture() |> set_password()

      assert %Person{id: ^id} =
               Accounts.get_person_by_email_and_password(person.email, valid_person_password())
    end
  end

  describe "get_person!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_person!("11111111-1111-1111-1111-111111111111")
      end
    end

    test "returns the person with the given id" do
      %{id: id} = person = person_fixture()
      assert %Person{id: ^id} = Accounts.get_person!(person.id)
    end
  end

  describe "register_person/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_person(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_person(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_person(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = person_fixture()
      {:error, changeset} = Accounts.register_person(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_person(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers people without password" do
      email = unique_person_email()
      {:ok, person} = Accounts.register_person(valid_person_attributes(email: email))
      assert person.email == email
      assert is_nil(person.hashed_password)
      assert is_nil(person.confirmed_at)
      assert is_nil(person.password)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%Person{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%Person{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%Person{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %Person{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%Person{})
    end
  end

  describe "change_person_email/3" do
    test "returns a person changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_person_email(%Person{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_person_update_email_instructions/3" do
    setup do
      %{person: person_fixture()}
    end

    test "sends token through notification", %{person: person} do
      token =
        extract_person_token(fn url ->
          Accounts.deliver_person_update_email_instructions(person, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert person_token = Repo.get_by(PersonToken, token: :crypto.hash(:sha256, token))
      assert person_token.person_id == person.id
      assert person_token.sent_to == person.email
      assert person_token.context == "change:current@example.com"
    end
  end

  describe "update_person_email/2" do
    setup do
      person = unconfirmed_person_fixture()
      email = unique_person_email()

      token =
        extract_person_token(fn url ->
          Accounts.deliver_person_update_email_instructions(%{person | email: email}, person.email, url)
        end)

      %{person: person, token: token, email: email}
    end

    test "updates the email with a valid token", %{person: person, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_person_email(person, token)
      changed_person = Repo.get!(Person, person.id)
      assert changed_person.email != person.email
      assert changed_person.email == email
      refute Repo.get_by(PersonToken, person_id: person.id)
    end

    test "does not update email with invalid token", %{person: person} do
      assert Accounts.update_person_email(person, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(Person, person.id).email == person.email
      assert Repo.get_by(PersonToken, person_id: person.id)
    end

    test "does not update email if person email changed", %{person: person, token: token} do
      assert Accounts.update_person_email(%{person | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Person, person.id).email == person.email
      assert Repo.get_by(PersonToken, person_id: person.id)
    end

    test "does not update email if token expired", %{person: person, token: token} do
      {1, nil} = Repo.update_all(PersonToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_person_email(person, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Person, person.id).email == person.email
      assert Repo.get_by(PersonToken, person_id: person.id)
    end
  end

  describe "change_person_password/3" do
    test "returns a person changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_person_password(%Person{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_person_password(
          %Person{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_person_password/2" do
    setup do
      %{person: person_fixture()}
    end

    test "validates password", %{person: person} do
      {:error, changeset} =
        Accounts.update_person_password(person, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{person: person} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_person_password(person, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{person: person} do
      {:ok, {person, expired_tokens}} =
        Accounts.update_person_password(person, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(person.password)
      assert Accounts.get_person_by_email_and_password(person.email, "new valid password")
    end

    test "deletes all tokens for the given person", %{person: person} do
      _ = Accounts.generate_person_session_token(person)

      {:ok, {_, _}} =
        Accounts.update_person_password(person, %{
          password: "new valid password"
        })

      refute Repo.get_by(PersonToken, person_id: person.id)
    end
  end

  describe "generate_person_session_token/1" do
    setup do
      %{person: person_fixture()}
    end

    test "generates a token", %{person: person} do
      token = Accounts.generate_person_session_token(person)
      assert person_token = Repo.get_by(PersonToken, token: token)
      assert person_token.context == "session"
      assert person_token.authenticated_at != nil

      # Creating the same token for another person should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%PersonToken{
          token: person_token.token,
          person_id: person_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given person in new token", %{person: person} do
      person = %{person | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_person_session_token(person)
      assert person_token = Repo.get_by(PersonToken, token: token)
      assert person_token.authenticated_at == person.authenticated_at
      assert DateTime.compare(person_token.inserted_at, person.authenticated_at) == :gt
    end
  end

  describe "get_person_by_session_token/1" do
    setup do
      person = person_fixture()
      token = Accounts.generate_person_session_token(person)
      %{person: person, token: token}
    end

    test "returns person by token", %{person: person, token: token} do
      assert {session_person, token_inserted_at} = Accounts.get_person_by_session_token(token)
      assert session_person.id == person.id
      assert session_person.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return person for invalid token" do
      refute Accounts.get_person_by_session_token("oops")
    end

    test "does not return person for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(PersonToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_person_by_session_token(token)
    end
  end

  describe "get_person_by_magic_link_token/1" do
    setup do
      person = person_fixture()
      {encoded_token, _hashed_token} = generate_person_magic_link_token(person)
      %{person: person, token: encoded_token}
    end

    test "returns person by token", %{person: person, token: token} do
      assert session_person = Accounts.get_person_by_magic_link_token(token)
      assert session_person.id == person.id
    end

    test "does not return person for invalid token" do
      refute Accounts.get_person_by_magic_link_token("oops")
    end

    test "does not return person for expired token", %{token: token} do
      {1, nil} = Repo.update_all(PersonToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_person_by_magic_link_token(token)
    end
  end

  describe "login_person_by_magic_link/1" do
    test "confirms person and expires tokens" do
      person = unconfirmed_person_fixture()
      refute person.confirmed_at
      {encoded_token, hashed_token} = generate_person_magic_link_token(person)

      assert {:ok, {person, [%{token: ^hashed_token}]}} =
               Accounts.login_person_by_magic_link(encoded_token)

      assert person.confirmed_at
    end

    test "returns person and (deleted) token for confirmed person" do
      person = person_fixture()
      assert person.confirmed_at
      {encoded_token, _hashed_token} = generate_person_magic_link_token(person)
      assert {:ok, {^person, []}} = Accounts.login_person_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_person_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed person has password set" do
      person = unconfirmed_person_fixture()
      {1, nil} = Repo.update_all(Person, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_person_magic_link_token(person)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_person_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_person_session_token/1" do
    test "deletes the token" do
      person = person_fixture()
      token = Accounts.generate_person_session_token(person)
      assert Accounts.delete_person_session_token(token) == :ok
      refute Accounts.get_person_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{person: unconfirmed_person_fixture()}
    end

    test "sends token through notification", %{person: person} do
      token =
        extract_person_token(fn url ->
          Accounts.deliver_login_instructions(person, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert person_token = Repo.get_by(PersonToken, token: :crypto.hash(:sha256, token))
      assert person_token.person_id == person.id
      assert person_token.sent_to == person.email
      assert person_token.context == "login"
    end
  end

  describe "inspect/2 for the Person module" do
    test "does not include password" do
      refute inspect(%Person{password: "123456"}) =~ "password: \"123456\""
    end
  end
end
