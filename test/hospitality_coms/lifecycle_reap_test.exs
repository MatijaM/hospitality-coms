defmodule HospitalityComs.LifecycleReapTest do
  @moduledoc """
  The two reapers issue #15 asks for, and the properties that keep them honest.

  Nothing reaped `people_tokens` past their validity horizons except
  consumption, and nothing reaped unconfirmed `people` at all, so both tables
  grew monotonically behind an endpoint any anonymous caller can drive. These
  are the sweeps that close that, and they live in `HospitalityComs.Lifecycle`
  because KTD21 says the module that deletes is that one.

  ## The token reaper is asserted as the authenticator's complement

  Three horizons — fifteen minutes, fourteen days, seven days — and each of them
  is already written down once, in the `verify_*_query` function that decides
  whether a token still authenticates. Asserting the reaper against a *repeated*
  constant would pass on the day the two drift, so the load-bearing test here
  puts six tokens either side of their own horizons at one instant, asks each
  verify query, and asserts the reap deleted exactly the ones the authenticator
  had already refused. **What it deletes could not have authenticated anything;
  what it keeps could.**

  ## Half-open points two different ways here, deliberately

  A token's own liveness rule is `inserted_at > instant - validity`, strictly —
  so a token whose validity elapses *exactly* at the instant asked about is
  already dead, and the reaper's complement is `<=`. An unconfirmed person has
  no authenticator to complement, so their horizon takes
  `HospitalityComs.Lifecycle.sweep/1`'s convention instead — `delete_after <
  instant`, a row whose deadline is exactly the instant survives — which in
  terms of a birth stamp is `inserted_at < instant - 30 days`. Both directions
  are asserted, on both sweeps.

  ## `async: false`, sandboxed, and the reason is the reach

  `Lifecycle.reap/1` is scoped to no person and no venue: it reaches every
  `people` and `people_tokens` row in the database. Ten files in this suite are
  not sandboxed and commit people for real, so this file must not run beside
  one. ExUnit finishes every async module before it starts a synchronous one,
  which is what makes that safe — the same reasoning
  `test_database_guard_test.exs` records for its `TRUNCATE`.
  """

  use HospitalityComs.DataCase, async: false
  use Oban.Testing, repo: HospitalityComs.Repo

  import HospitalityComs.AccountsFixtures

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Clock
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Workers.AccountReaper

  @now ~U[2026-06-01 12:00:00Z]

  describe "expired tokens" do
    test "reaps a login token at exactly its fifteen-minute horizon" do
      person = unconfirmed_person_fixture(%{}, @now)
      token = login_token(person, minutes_before(15))

      assert {:ok, %{expired_tokens: 1}} = Lifecycle.reap(@now)
      refute Repo.get(PersonToken, token.id)
    end

    test "and leaves one a second younger, which is the control" do
      person = unconfirmed_person_fixture(%{}, @now)
      token = login_token(person, seconds_before(15 * 60 - 1))

      assert {:ok, %{expired_tokens: 0}} = Lifecycle.reap(@now)
      assert %PersonToken{} = Repo.get(PersonToken, token.id)
    end

    test "reaps a session token at fourteen days and not a second earlier" do
      person = person_fixture(%{}, @now)
      dead = token_at(person, "session", days_before(14))
      live = token_at(person, "session", seconds_before(14 * 24 * 60 * 60 - 1))

      assert {:ok, %{expired_tokens: 1}} = Lifecycle.reap(@now)
      refute Repo.get(PersonToken, dead.id)
      assert %PersonToken{} = Repo.get(PersonToken, live.id)
    end

    test "reaps a change-email token at seven days and not a second earlier" do
      person = person_fixture(%{}, @now)
      context = "change:#{person.email}"
      dead = token_at(person, context, days_before(7))
      live = token_at(person, context, seconds_before(7 * 24 * 60 * 60 - 1))

      assert {:ok, %{expired_tokens: 1}} = Lifecycle.reap(@now)
      refute Repo.get(PersonToken, dead.id)
      assert %PersonToken{} = Repo.get(PersonToken, live.id)
    end

    test "reaps a context nobody enumerated at the longest horizon, and not before" do
      # The three contexts this application writes are enumerated, and an
      # enumeration is a hole the day somebody adds a fourth. The catch-all is
      # what makes "both tables stop growing" true rather than true of the
      # contexts that existed when it was written: an unrecognised context
      # cannot outlive the longest horizon this application honours anywhere.
      person = person_fixture(%{}, @now)
      dead = token_at(person, "some:later:unit", days_before(14))
      live = token_at(person, "some:later:unit", days_before(13))

      assert {:ok, %{expired_tokens: 1}} = Lifecycle.reap(@now)
      refute Repo.get(PersonToken, dead.id)
      assert %PersonToken{} = Repo.get(PersonToken, live.id)
    end

    test "deletes exactly the tokens the authenticator refuses, at one instant" do
      # The load-bearing one. Every horizon in the reaper is a second copy of a
      # number `PersonToken` already holds, and two copies of a number drift.
      # So this asks the *authenticator* which side of the line each token is
      # on, and then asserts the reap agreed with it — six tokens, three
      # horizons, one instant.
      person = person_fixture(%{}, @now)

      {live_link, dead_link} = magic_links(person)
      {live_session, dead_session} = session_tokens(person)
      {live_change, dead_change} = change_tokens(person)

      # What the authenticator says, before anything is deleted.
      assert Accounts.get_person_by_magic_link_token(live_link, @now)
      refute Accounts.get_person_by_magic_link_token(dead_link, @now)
      assert Accounts.get_person_by_session_token(live_session, @now)
      refute Accounts.get_person_by_session_token(dead_session, @now)
      assert change_email_row(live_change, person, @now)
      refute change_email_row(dead_change, person, @now)

      assert {:ok, %{expired_tokens: 3}} = Lifecycle.reap(@now)

      # And what survives is exactly the half it still honours.
      assert encoded_present?(live_link)
      refute encoded_present?(dead_link)
      assert raw_present?(live_session)
      refute raw_present?(dead_session)
      assert encoded_present?(live_change)
      refute encoded_present?(dead_change)
    end

    test "leaves a live session token of a confirmed person alone" do
      # The control for the whole sweep: a `delete_all` with no predicate
      # satisfies every assertion above.
      person = person_fixture(%{}, @now)
      token = Accounts.generate_person_session_token(person, @now)

      assert {:ok, %{expired_tokens: 0, unconfirmed_people: 0}} = Lifecycle.reap(@now)
      assert Accounts.get_person_by_session_token(token, @now)
    end
  end

  describe "unconfirmed people" do
    test "reaps one past the thirty-day horizon" do
      person = unconfirmed_person_fixture(%{}, days_before(31))

      assert {:ok, %{unconfirmed_people: 1}} = Lifecycle.reap(@now)
      refute Repo.get(Person, person.id)
    end

    test "and takes their login token with them" do
      person = unconfirmed_person_fixture(%{}, days_before(31))
      token = login_token(person, days_before(31))

      assert {:ok, %{unconfirmed_people: 1}} = Lifecycle.reap(@now)
      refute Repo.get(PersonToken, token.id)
    end

    test "leaves a confirmed person of the same age, which is the control" do
      person = person_fixture(%{}, days_before(31))

      assert {:ok, %{unconfirmed_people: 0}} = Lifecycle.reap(@now)
      assert %Person{} = Repo.get(Person, person.id)
    end

    test "leaves an erased person, whose row is the tombstone" do
      # An erased row carries no address and no confirmation this reap could
      # read as "never confirmed". Deleting it would undo the one thing erasure
      # promises to leave behind.
      person = unconfirmed_person_fixture(%{}, days_before(31))
      erase(person, days_before(31))

      assert {:ok, %{unconfirmed_people: 0}} = Lifecycle.reap(@now)
      assert %Person{erased_at: %DateTime{}} = Repo.get(Person, person.id)
    end

    test "survives at exactly thirty days and does not a second later" do
      at_horizon = unconfirmed_person_fixture(%{}, days_before(30))
      past_it = unconfirmed_person_fixture(%{}, seconds_before(30 * 24 * 60 * 60 + 1))

      assert {:ok, %{unconfirmed_people: 1}} = Lifecycle.reap(@now)
      assert %Person{} = Repo.get(Person, at_horizon.id)
      refute Repo.get(Person, past_it.id)
    end

    test "frees the address, which is the accepted consequence rather than a defect" do
      email = unique_person_email()
      first = unconfirmed_person_fixture(%{email: email}, days_before(31))

      assert {:ok, %{unconfirmed_people: 1}} = Lifecycle.reap(@now)

      assert {:ok, %Person{id: second_id}} = Accounts.register_person(%{email: email}, @now)
      assert second_id != first.id
    end

    test "the unconfirmed horizon outlives every token horizon" do
      # Not decoration. `people_tokens.person_id` is the only foreign key into
      # `people` that is not `ON DELETE RESTRICT`, so reaping a person takes
      # their tokens with them — and this ordering is what makes "it can never
      # take a *live* credential" true without appealing to the argument that
      # an unconfirmed person cannot hold a session token.
      #
      # `HospitalityComs.Lifecycle` now checks this ordering at **compile time**
      # against the same three functions, so a retention that breaks it does not
      # build and can never reach here. What these three assertions guard is the
      # check being the right check: drop a validity from the `Enum.max/1` it
      # ranges over and the module still compiles at a horizon that no longer
      # outlives that token, and this is the only thing that says so.
      assert Lifecycle.unconfirmed_retention_days() > PersonToken.session_validity_in_days()

      assert Lifecycle.unconfirmed_retention_days() * 24 * 60 >
               PersonToken.magic_link_validity_in_minutes()

      assert Lifecycle.unconfirmed_retention_days() > PersonToken.change_email_validity_in_days()
    end
  end

  describe "the bounds" do
    test "answers zeroes and deletes nothing when there is nothing due" do
      person = person_fixture(%{}, @now)
      Accounts.generate_person_session_token(person, @now)

      assert {:ok, %{expired_tokens: 0, unconfirmed_people: 0}} = Lifecycle.reap(@now)
      assert Repo.aggregate(Person, :count) == 1
      assert Repo.aggregate(PersonToken, :count) == 1
    end

    test "is bounded per run and the next run reaches what the first did not" do
      # The bound and the *absence of a lower bound* in one test.
      # `Engagements.list_expired/3` needs a floor because it does not consume
      # its rows; both statements here delete what they select, so the sweep
      # advances by construction and a floor would leave a backlog nothing ever
      # reaches — which is the monotonic growth this issue is about, arriving
      # through the fix.
      olds = for _ <- 1..2, do: unconfirmed_person_fixture(%{}, days_before(31))

      assert {:ok, %{unconfirmed_people: 1}} = with_limits([batch_size: 1], &reap_now/0)
      assert Repo.aggregate(Person, :count) == 1

      assert {:ok, %{unconfirmed_people: 1}} = with_limits([batch_size: 1], &reap_now/0)
      assert Repo.aggregate(Person, :count) == 0

      assert Enum.all?(olds, &is_nil(Repo.get(Person, &1.id)))
    end

    test "bounds the token statement the same way, and clears it over two runs" do
      # Measured: without this the token reap's `limit` could be removed and no
      # test noticed — the bound above exercised the people statement alone,
      # and two statements in one function are two bounds.
      person = person_fixture(%{}, @now)
      for _ <- 1..2, do: login_token(person, minutes_before(20))

      assert {:ok, %{expired_tokens: 1}} = with_limits([batch_size: 1], &reap_now/0)
      assert Repo.aggregate(PersonToken, :count) == 1

      assert {:ok, %{expired_tokens: 1}} = with_limits([batch_size: 1], &reap_now/0)
      assert Repo.aggregate(PersonToken, :count) == 0
    end
  end

  describe "the worker" do
    test "takes its instant from the clock, so moving the offset moves the reap" do
      person = unconfirmed_person_fixture(%{}, @now)

      Clock.Offset.set(DateTime.add(@now, 29, :day))
      on_exit(&Clock.Offset.reset/0)

      assert {:ok, %{unconfirmed_people: 0}} = perform_job(AccountReaper, %{})
      assert %Person{} = Repo.get(Person, person.id)

      Clock.Offset.set(DateTime.add(@now, 31, :day))

      assert {:ok, %{unconfirmed_people: 1}} = perform_job(AccountReaper, %{})
      refute Repo.get(Person, person.id)
    end
  end

  ## Helpers

  defp reap_now, do: Lifecycle.reap(@now)

  defp minutes_before(minutes), do: DateTime.add(@now, -minutes, :minute)
  defp seconds_before(seconds), do: DateTime.add(@now, -seconds, :second)
  defp days_before(days), do: DateTime.add(@now, -days, :day)

  defp login_token(person, instant), do: token_at(person, "login", instant)

  defp token_at(person, context, instant) do
    {_encoded, row} = PersonToken.build_email_token(person, context, instant)
    Repo.insert!(%{row | context: context})
  end

  # A magic link either side of its fifteen minutes, as the credential rather
  # than as a row, because that is what the authenticator takes.
  defp magic_links(person) do
    {live, _digest} = generate_person_magic_link_token(person, minutes_before(14))
    {dead, _digest} = generate_person_magic_link_token(person, minutes_before(15))
    {live, dead}
  end

  defp session_tokens(person) do
    live = Accounts.generate_person_session_token(person, days_before(13))
    dead = Accounts.generate_person_session_token(person, days_before(14))
    {live, dead}
  end

  defp change_tokens(person) do
    context = "change:#{person.email}"
    {live, _row} = insert_email_token(person, context, days_before(6))
    {dead, _row} = insert_email_token(person, context, days_before(7))
    {live, dead}
  end

  defp insert_email_token(person, context, instant) do
    {encoded, row} = PersonToken.build_email_token(person, context, instant)
    {encoded, Repo.insert!(row)}
  end

  defp change_email_row(encoded, person, instant) do
    {:ok, query} =
      PersonToken.verify_change_email_token_query(encoded, "change:#{person.email}", instant)

    Repo.one(query)
  end

  # The column holds the SHA-256 digest, so presence is asked about that.
  # Session tokens are raw bytes and email tokens are base64url of the same
  # thirty-two, which is why the two are not folded into one helper: a raw
  # credential that happened to be valid base64url would be hashed twice over.
  defp raw_present?(raw), do: digest_present?(PersonToken.hash_token(raw))

  defp encoded_present?(encoded) do
    {:ok, raw} = Base.url_decode64(encoded, padding: false)
    raw_present?(raw)
  end

  defp digest_present?(digest), do: Repo.get_by(PersonToken, token: digest) != nil

  defp erase(person, instant) do
    Repo.update_all(
      from(p in Person, where: p.id == ^person.id),
      set: [email: nil, erased_at: DateTime.truncate(instant, :second)]
    )
  end

  defp with_limits(opts, fun) do
    previous = Application.get_env(:hospitality_coms, Lifecycle, [])
    Application.put_env(:hospitality_coms, Lifecycle, Keyword.merge(previous, opts))

    try do
      fun.()
    after
      Application.put_env(:hospitality_coms, Lifecycle, previous)
    end
  end
end
