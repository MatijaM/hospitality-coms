defmodule HospitalityComs.AccountsDeliveryTest do
  @moduledoc """
  What a log-in request does when the mail provider is down.

  A magic link is the whole of authentication here, so a delivery failure is
  not an edge case — it is the one dependency the log-in path cannot route
  around. The generated stack delivered with `Mailer.deliver!/1` from inside
  the same function that had already committed a person row and a token row,
  which turns a provider outage into an unhandled exception, a raw 500 outside
  the API's error envelope, and two rows written for an email nobody received.

  Swapping the adapter is global state, so this file is `async: false` and puts
  the mailer configuration back on the way out.
  """

  use HospitalityComs.DataCase, async: false

  # Every test here provokes the delivery error the notifier logs.
  @moduletag capture_log: true

  import HospitalityComs.AccountsFixtures

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Mailer
  alias HospitalityComs.UnreachableMailerAdapter

  @now ~U[2026-03-01 12:00:00.000000Z]

  defp url_builder, do: &"http://localhost/log-in/#{&1}"

  # Called after any fixture the test needs, because building a confirmed
  # person means delivering a magic link to them first.
  defp take_the_provider_down do
    original = Application.get_env(:hospitality_coms, Mailer)
    Application.put_env(:hospitality_coms, Mailer, adapter: UnreachableMailerAdapter)
    on_exit(fn -> Application.put_env(:hospitality_coms, Mailer, original) end)
  end

  describe "request_login_instructions/3 when the provider is unreachable" do
    test "returns an enumerated atom rather than raising" do
      take_the_provider_down()

      assert {:error, :delivery_failed} =
               Accounts.request_login_instructions(unique_person_email(), url_builder(), @now)
    end

    test "answers the same way for an address that already exists" do
      person = person_fixture(%{}, @now)
      take_the_provider_down()

      assert {:error, :delivery_failed} =
               Accounts.request_login_instructions(person.email, url_builder(), @now)
    end
  end

  describe "deliver_person_update_email_instructions/4 when the provider is unreachable" do
    test "returns an enumerated atom rather than raising" do
      person = person_fixture(%{}, @now)
      take_the_provider_down()

      assert {:error, :delivery_failed} =
               Accounts.deliver_person_update_email_instructions(
                 %{person | email: unique_person_email()},
                 person.email,
                 url_builder(),
                 @now
               )
    end
  end

  describe "the writes a failed request leaves behind" do
    test "are consistent: a person with their unredeemed token, or neither" do
      email = unique_person_email()
      take_the_provider_down()

      assert {:error, :delivery_failed} =
               Accounts.request_login_instructions(email, url_builder(), @now)

      # The mail is delivered after the transaction commits, so the rows are
      # still here. What must never happen is half of them: a person nobody can
      # log in as, or a token belonging to nobody.
      assert %Person{id: person_id} = Accounts.get_person_by_email(email)
      assert [%PersonToken{context: "login"}] = Repo.all_by(PersonToken, person_id: person_id)
    end

    test "are nothing at all when the address is not an address" do
      take_the_provider_down()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.request_login_instructions("not an address", url_builder(), @now)

      assert Repo.aggregate(Person, :count) == 0
      assert Repo.aggregate(PersonToken, :count) == 0
    end
  end
end
