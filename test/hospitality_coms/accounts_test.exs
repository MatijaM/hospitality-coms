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
  alias HospitalityComs.Accounts.DisplayName
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Lifecycle

  @now ~U[2026-03-01 12:00:00.000000Z]

  defp url_builder, do: &"http://localhost/log-in/#{&1}"

  defp login_tokens(person), do: Repo.all_by(PersonToken, person_id: person.id, context: "login")

  describe "get_person_by_email/1" do
    test "does not return the person if the email does not exist" do
      refute Accounts.get_person_by_email(anonymous_scope(@now), "unknown@example.com")
    end

    test "returns the person if the email exists" do
      %Person{id: id} = person = person_fixture()

      assert %Person{id: ^id} = Accounts.get_person_by_email(anonymous_scope(@now), person.email)
    end

    test "matches an address case-insensitively" do
      person = person_fixture(%{email: "Casing#{System.unique_integer([:positive])}@Example.com"})

      assert %Person{id: id} =
               Accounts.get_person_by_email(anonymous_scope(@now), String.downcase(person.email))

      assert id == person.id
    end
  end

  describe "register_person/1" do
    test "requires an email" do
      {:error, changeset} = Accounts.register_person(anonymous_scope(@now), %{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates the email's shape and length" do
      {:error, changeset} = Accounts.register_person(anonymous_scope(@now), %{email: "not valid"})
      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)

      too_long = String.duplicate("a", 160) <> "@example.com"
      {:error, changeset} = Accounts.register_person(anonymous_scope(@now), %{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "refuses an address a live person already holds" do
      %{email: email} = person_fixture()

      {:error, changeset} = Accounts.register_person(anonymous_scope(@now), %{email: email})
      assert "has already been taken" in errors_on(changeset).email

      {:error, changeset} =
        Accounts.register_person(anonymous_scope(@now), %{email: String.upcase(email)})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers people without a password and unconfirmed" do
      email = unique_person_email()

      {:ok, person} =
        Accounts.register_person(anonymous_scope(@now), valid_person_attributes(%{email: email}))

      assert person.email == email
      assert is_nil(person.confirmed_at)
      assert is_nil(person.erased_at)
      refute Map.has_key?(person, :hashed_password)
    end

    test "stamps the row from the unit of work's instant, not from the wall" do
      {:ok, person} = Accounts.register_person(anonymous_scope(@now), valid_person_attributes())
      stamped_at = DateTime.truncate(@now, :second)

      # Ecto's own `timestamps()` autogenerate calls `DateTime.utc_now/0`
      # inside Ecto, where neither the clock nor its Credo check can reach it —
      # so `people` would ignore the injected instant while `people_tokens`
      # honoured it, and the two tables would disagree about when a person
      # arrived.
      assert person.inserted_at == stamped_at
      assert person.updated_at == stamped_at
      assert %Person{inserted_at: ^stamped_at} = Repo.get!(Person, person.id)
    end

    test "gives them a display name drawn from the list" do
      # #66. The name is *given*, so every path that makes a person has one and
      # no fixture has to remember it — this is the door they all come through.
      {:ok, person} = Accounts.register_person(anonymous_scope(@now), valid_person_attributes())

      assert person.display_name in DisplayName.all()
      assert Repo.get!(Person, person.id).display_name == person.display_name
    end

    test "…and not the name erasure leaves behind" do
      # The control for the test above, and it protects a test one file over.
      # `lifecycle_test.exs` asserts that erasure *changes* `display_name`; a
      # generator that could produce the erased name would make that assertion
      # vacuous for whichever fixture drew it, at random, roughly never — which
      # is worse than never, because it is a flake nobody can reproduce.
      refute Lifecycle.erased_display_name() in DisplayName.all()
    end

    test "ignores a display name somebody tries to register with" do
      # It is given, not asked for. `registration_changeset/4` casts `:email`
      # alone and `put_change`s the name, so the door that creates a person
      # cannot be told what to call them.
      {:ok, person} =
        Accounts.register_person(
          anonymous_scope(@now),
          valid_person_attributes(%{display_name: "Somebody Real"})
        )

      refute person.display_name == "Somebody Real"
      assert person.display_name in DisplayName.all()
    end
  end

  describe "the names a person can be given" do
    test "are all non-blank and within the bound the database enforces" do
      # A registration that drew a name the CHECK refuses would raise
      # `Postgrex.Error` out of the log-in door for one person in sixty-four.
      for name <- DisplayName.all() do
        assert String.trim(name) != ""
        assert String.length(name) <= DisplayName.max_length()
      end
    end

    test "hold no duplicate" do
      assert Enum.uniq(DisplayName.all()) == DisplayName.all()
    end

    test "and generate/0 answers one of them" do
      # The control for both tests above: a list nothing draws from certifies
      # nothing about what a registration produces.
      for _attempt <- 1..50 do
        assert DisplayName.generate() in DisplayName.all()
      end
    end
  end

  describe "update_display_name/2" do
    test "changes the name the person is shown under" do
      scope = person_scope_fixture(person_fixture(), @now)

      assert {:ok, %Person{display_name: "Wendy Darling"}} =
               Accounts.update_display_name(scope, "Wendy Darling")

      assert Repo.get!(Person, scope.person.id).display_name == "Wendy Darling"
    end

    test "trims what it is given" do
      scope = person_scope_fixture(person_fixture(), @now)

      assert {:ok, %Person{display_name: "Puck"}} =
               Accounts.update_display_name(scope, "  Puck  ")
    end

    test "refuses a name that is only whitespace" do
      # The control for the trim: without it this is four characters and passes.
      scope = person_scope_fixture(person_fixture(), @now)

      assert {:error, changeset} = Accounts.update_display_name(scope, "    ")
      assert %{display_name: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts a name at exactly the bound and refuses one past it" do
      scope = person_scope_fixture(person_fixture(), @now)
      at_bound = String.duplicate("a", DisplayName.max_length())

      assert {:ok, %Person{}} = Accounts.update_display_name(scope, at_bound)

      assert {:error, changeset} = Accounts.update_display_name(scope, at_bound <> "a")
      assert %{display_name: [message]} = errors_on(changeset)
      assert message =~ "at most #{DisplayName.max_length()}"
    end

    test "stamps updated_at from the scope's instant" do
      scope = person_scope_fixture(person_fixture(), @now)
      later = DateTime.add(@now, 3, :hour)

      assert {:ok, person} =
               Accounts.update_display_name(%{scope | now: later}, "Prospero")

      assert person.updated_at == DateTime.truncate(later, :second)
    end

    test "refuses an erased person" do
      # Unreachable through the API — erasure deletes every token the person
      # holds, so no authenticator can produce this scope — and asserted because
      # KTD15's "nothing identifying is left" must rest on a rule rather than on
      # the absence of a caller. Without the second clause this succeeds and
      # undoes the overwrite `Lifecycle` just wrote.
      person = person_fixture()
      scope = person_scope_fixture(person, @now)

      assert {:ok, _erasure} = Lifecycle.erase_person(scope)
      erased = Repo.get!(Person, person.id)

      assert {:error, :erased} =
               Accounts.update_display_name(
                 person_scope_fixture(erased, @now),
                 "Somebody Real"
               )

      assert Repo.get!(Person, person.id).display_name == Lifecycle.erased_display_name()
    end
  end

  describe "request_login_instructions/3" do
    test "creates a person and a login token for an address nobody holds" do
      email = unique_person_email()
      refute Accounts.get_person_by_email(anonymous_scope(@now), email)

      assert {:ok, %Person{} = person} =
               Accounts.request_login_instructions(anonymous_scope(@now), email, url_builder())

      assert person.email == email
      assert is_nil(person.confirmed_at)

      assert [%PersonToken{context: "login", sent_to: sent_to, inserted_at: inserted_at}] =
               login_tokens(person)

      assert sent_to == email
      assert inserted_at == DateTime.truncate(@now, :second)
    end

    test "delivers a confirmation email carrying the link" do
      email = unique_person_email()

      {:ok, _person} =
        Accounts.request_login_instructions(anonymous_scope(@now), email, url_builder())

      assert_received {:email, %Swoosh.Email{subject: "Confirmation instructions"} = delivered}
      assert delivered.text_body =~ "http://localhost/log-in/"
    end

    test "delivers log-in instructions, not a confirmation, to a confirmed person" do
      person = person_fixture()

      {:ok, _person} =
        Accounts.request_login_instructions(anonymous_scope(@now), person.email, url_builder())

      # The everyday repeat log-in. Only the first-time branch was asserted, so
      # the notifier could have sent "Confirmation instructions" to somebody
      # who confirmed months ago and nothing would have failed.
      assert_received {:email, %Swoosh.Email{subject: "Log in instructions"} = delivered}
      assert delivered.text_body =~ "http://localhost/log-in/"
      assert delivered.text_body =~ "You can log into your account"
    end

    test "issues a further token for a known address without creating a second person" do
      person = person_fixture()

      assert {:ok, returned} =
               Accounts.request_login_instructions(
                 anonymous_scope(@now),
                 person.email,
                 url_builder()
               )

      assert returned.id == person.id
      assert Repo.aggregate(from(p in Person, where: p.email == ^person.email), :count) == 1
      assert length(login_tokens(person)) == 1
    end

    test "does not create a person for an address that is not an address" do
      assert {:error, changeset} =
               Accounts.request_login_instructions(
                 anonymous_scope(@now),
                 "not an address",
                 url_builder()
               )

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
      assert found = Accounts.get_person_by_magic_link_token(anonymous_scope(@now), token)
      assert found.id == person.id
    end

    test "does not return the person for a token that is not a token" do
      refute Accounts.get_person_by_magic_link_token(anonymous_scope(@now), "oops")
    end

    test "does not return the person once the row is gone", %{token: token} do
      assert Accounts.get_person_by_magic_link_token(anonymous_scope(@now), token)
      assert {1, _returned} = Repo.delete_all(PersonToken)
      refute Accounts.get_person_by_magic_link_token(anonymous_scope(@now), token)
    end

    test "is still live one second short of fifteen minutes", %{token: token} do
      assert Accounts.get_person_by_magic_link_token(
               anonymous_scope(DateTime.add(@now, 899, :second)),
               token
             )
    end

    test "is expired at fifteen minutes", %{token: token} do
      refute Accounts.get_person_by_magic_link_token(
               anonymous_scope(DateTime.add(@now, 15, :minute)),
               token
             )
    end

    test "stops verifying once the person's address changes", %{person: person, token: token} do
      # Deliberately bypassing the context, which would delete every token in
      # the same transaction. The binding being asserted is the one in the
      # query — `sent_to == person.email` — not the deletion that usually makes
      # the point moot.
      person
      |> Ecto.Changeset.change(email: unique_person_email())
      |> Repo.update!()

      refute Accounts.get_person_by_magic_link_token(anonymous_scope(@now), token)
    end
  end

  describe "login_person_by_magic_link/2" do
    test "confirms an unconfirmed person and expires their tokens" do
      person = unconfirmed_person_fixture()
      {encoded_token, _hashed_token} = generate_person_magic_link_token(person, @now)

      assert {:ok, {confirmed, [_expired]}} =
               Accounts.login_person_by_magic_link(anonymous_scope(@now), encoded_token)

      assert confirmed.confirmed_at == DateTime.truncate(@now, :second)
      assert Repo.aggregate(PersonToken, :count) == 0
    end

    test "logs a confirmed person in and consumes only the link" do
      person = person_fixture()
      session_token = Accounts.generate_person_session_token(person_scope_fixture(person, @now))
      {encoded_token, _hashed_token} = generate_person_magic_link_token(person, @now)

      assert {:ok, {returned, []}} =
               Accounts.login_person_by_magic_link(anonymous_scope(@now), encoded_token)

      assert returned.id == person.id
      assert login_tokens(person) == []
      assert Accounts.get_person_by_session_token(anonymous_scope(@now), session_token)
    end

    test "cannot redeem the same link twice" do
      person = person_fixture()
      {encoded_token, _hashed_token} = generate_person_magic_link_token(person, @now)

      assert {:ok, {_person, _expired}} =
               Accounts.login_person_by_magic_link(anonymous_scope(@now), encoded_token)

      assert {:error, :not_found} =
               Accounts.login_person_by_magic_link(anonymous_scope(@now), encoded_token)
    end

    test "cannot redeem an expired link" do
      person = person_fixture()
      {encoded_token, _hashed_token} = generate_person_magic_link_token(person, @now)

      assert {:error, :not_found} =
               Accounts.login_person_by_magic_link(
                 anonymous_scope(DateTime.add(@now, 15, :minute)),
                 encoded_token
               )

      assert length(login_tokens(person)) == 1
    end

    test "cannot redeem a token that is not base64url" do
      assert {:error, :not_found} =
               Accounts.login_person_by_magic_link(anonymous_scope(@now), "not a token")
    end
  end

  describe "generate_person_session_token/2" do
    setup do
      %{person: person_fixture()}
    end

    test "stores the token stamped with the unit of work's instant", %{person: person} do
      token = Accounts.generate_person_session_token(person_scope_fixture(person, @now))

      assert %PersonToken{context: "session", inserted_at: inserted_at, person_id: person_id} =
               Repo.get_by(PersonToken, token: PersonToken.hash_token(token))

      assert person_id == person.id
      assert inserted_at == DateTime.truncate(@now, :second)
    end

    test "stores the digest and never the credential itself", %{person: person} do
      token = Accounts.generate_person_session_token(person_scope_fixture(person, @now))

      assert %PersonToken{token: stored} =
               Repo.one(from(t in PersonToken, where: t.context == "session"))

      # A read of `people_tokens` must not hand the reader a working bearer
      # credential: the column holds a digest that cannot be replayed.
      refute stored == token
      assert stored == :crypto.hash(:sha256, token)
    end

    test "issues a distinct token every time", %{person: person} do
      first = Accounts.generate_person_session_token(person_scope_fixture(person, @now))
      second = Accounts.generate_person_session_token(person_scope_fixture(person, @now))

      refute first == second
    end
  end

  describe "get_person_by_session_token/2" do
    setup do
      person = person_fixture()

      %{
        person: person,
        token: Accounts.generate_person_session_token(person_scope_fixture(person, @now))
      }
    end

    test "returns the person for a live token", %{person: person, token: token} do
      assert {found, inserted_at} =
               Accounts.get_person_by_session_token(anonymous_scope(@now), token)

      assert found.id == person.id
      assert inserted_at == DateTime.truncate(@now, :second)
    end

    test "does not return a person for a token nobody issued" do
      refute Accounts.get_person_by_session_token(anonymous_scope(@now), "nonsense")
    end

    test "is still live one second short of fourteen days", %{token: token} do
      # The boundary the `ago/2` rewrite could have moved by a second without
      # anything noticing. A day either side of it proves nothing.
      assert Accounts.get_person_by_session_token(
               anonymous_scope(DateTime.add(@now, 14 * 86_400 - 1, :second)),
               token
             )
    end

    test "is expired at fourteen days", %{token: token} do
      refute Accounts.get_person_by_session_token(
               anonymous_scope(DateTime.add(@now, 14, :day)),
               token
             )
    end

    test "stops verifying the moment its row is deleted", %{token: token} do
      assert Accounts.get_person_by_session_token(anonymous_scope(@now), token)

      assert {:ok, [%PersonToken{context: "session", token: stored}]} =
               Accounts.delete_person_session_token(anonymous_scope(@now), token)

      # The row handed back is the stored one, which is what names the PubSub
      # topic the session's sockets are torn down on.
      assert stored == PersonToken.hash_token(token)
      refute Accounts.get_person_by_session_token(anonymous_scope(@now), token)
    end

    test "deletes nothing when the credential matches no row", %{person: person} do
      assert {:ok, []} =
               Accounts.delete_person_session_token(anonymous_scope(@now), "nobody issued this")

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
            person_scope_fixture(person, @now),
            new_email,
            url
          )
        end)

      %{person: person, new_email: new_email, change_token: change_token}
    end

    test "changes the address", context do
      %{person: person, new_email: new_email, change_token: change_token} = context

      assert {:ok, {updated, _expired}} =
               Accounts.update_person_email(person_scope_fixture(person, @now), change_token)

      assert updated.email == new_email
      refute Accounts.get_person_by_email(anonymous_scope(@now), person.email)
    end

    test "stamps the change from the unit of work's instant", context do
      %{person: person, change_token: change_token} = context
      later = DateTime.add(@now, 3, :day)

      assert {:ok, {updated, _expired}} =
               Accounts.update_person_email(person_scope_fixture(person, later), change_token)

      assert updated.updated_at == DateTime.truncate(later, :second)
      assert updated.inserted_at == person.inserted_at
    end

    test "invalidates every API token the person held", context do
      %{person: person, change_token: change_token} = context
      session_token = Accounts.generate_person_session_token(person_scope_fixture(person, @now))
      assert Accounts.get_person_by_session_token(anonymous_scope(@now), session_token)

      assert {:ok, {_updated, expired}} =
               Accounts.update_person_email(person_scope_fixture(person, @now), change_token)

      assert Enum.any?(expired, &(&1.context == "session"))
      refute Accounts.get_person_by_session_token(anonymous_scope(@now), session_token)
    end

    test "refuses a token that is not the person's", %{person: person} do
      other = person_fixture()

      other_token =
        extract_person_token(fn url ->
          Accounts.deliver_person_update_email_instructions(
            person_scope_fixture(other, @now),
            unique_person_email(),
            url
          )
        end)

      assert {:error, :transaction_aborted} =
               Accounts.update_person_email(person_scope_fixture(person, @now), other_token)
    end

    test "refuses a token older than seven days", context do
      %{person: person, change_token: change_token} = context

      assert {:error, :transaction_aborted} =
               Accounts.update_person_email(
                 person_scope_fixture(person, DateTime.add(@now, 7, :day)),
                 change_token
               )
    end
  end

  describe "sudo_mode?/2" do
    test "is true inside the window and false outside it" do
      person = %Person{authenticated_at: DateTime.truncate(@now, :second)}

      assert Accounts.sudo_mode?(PersonScope.for_person(person, DateTime.add(@now, 19, :minute)))
      refute Accounts.sudo_mode?(PersonScope.for_person(person, DateTime.add(@now, 21, :minute)))
    end

    test "is false for a person who never authenticated" do
      refute Accounts.sudo_mode?(PersonScope.for_person(%Person{authenticated_at: nil}, @now))
      refute Accounts.sudo_mode?(PersonScope.for_person(nil, @now))
    end
  end
end
