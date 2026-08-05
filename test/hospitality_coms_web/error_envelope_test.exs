defmodule HospitalityComsWeb.ErrorEnvelopeTest do
  @moduledoc """
  One shape for every error the API returns, asserted where it is built.

  `for_changeset/3` was extracted for three call sites — `SessionController`,
  `VenueRoomChannel` and `ShiftRoomChannel` — and had no test of its own; two of
  the three exercised it through a channel and the interpolation it exists to
  centralise was never asserted directly. That interpolation is the part that
  drifts: Ecto's messages carry `%{count}` placeholders and the options that
  fill them, and a call site that forgot to substitute would ship
  `"should be at most %{count} character(s)"` to a client.

  The envelope is U12's contract rather than a rendering detail, so `fields`
  being **absent** on a failure with nothing to attach is asserted as
  positively as its presence. A client cannot tell a validation failure from a
  routing failure by status code alone; the key is the discriminator.

  Nothing here touches the database.
  """

  use ExUnit.Case, async: true

  alias HospitalityComsWeb.ErrorEnvelope

  describe "new/2" do
    test "carries the status atom as a string, and no fields key" do
      # `code` is always the response's status atom, so it cannot drift from the
      # status line. The absence of `fields` is itself information: there is
      # nothing to attach to an input.
      envelope = ErrorEnvelope.new(:unauthorized, "the request carries no live session token")

      assert envelope == %{
               error: %{
                 code: "unauthorized",
                 message: "the request carries no live session token"
               }
             }

      refute Map.has_key?(envelope.error, :fields)
    end
  end

  describe "new/3" do
    test "carries the fields it was given" do
      envelope = ErrorEnvelope.new(:unprocessable_entity, "rejected", %{email: ["is invalid"]})

      assert envelope.error.fields == %{email: ["is invalid"]}
    end
  end

  describe "for_changeset/3" do
    test "interpolates Ecto's placeholders rather than shipping them" do
      # The whole reason the traversal lives in one module. `%{count}` is filled
      # from the error's own options, so a client sees a sentence rather than a
      # template.
      envelope =
        ErrorEnvelope.for_changeset(
          :unprocessable_entity,
          "the message was rejected",
          too_long(:body, "xxxx", 2)
        )

      assert envelope.error.code == "unprocessable_entity"
      assert envelope.error.message == "the message was rejected"
      assert envelope.error.fields == %{body: ["should be at most 2 character(s)"]}

      refute envelope |> inspect() |> String.contains?("%{count}")
    end

    test "names every field that failed, and only those" do
      changeset =
        {%{}, %{body: :string, subject: :string}}
        |> Ecto.Changeset.cast(%{body: "", subject: "fine"}, [:body, :subject])
        |> Ecto.Changeset.validate_required([:body])

      envelope = ErrorEnvelope.for_changeset(:unprocessable_entity, "rejected", changeset)

      assert Map.keys(envelope.error.fields) == [:body]
    end

    test "keeps a message with no placeholder in it intact" do
      # The substitution is a `Regex.replace/3` over every message, so a message
      # that has nothing to substitute has to come through untouched.
      changeset =
        {%{}, %{body: :string}}
        |> Ecto.Changeset.cast(%{body: ""}, [:body])
        |> Ecto.Changeset.validate_required([:body])

      envelope = ErrorEnvelope.for_changeset(:unprocessable_entity, "rejected", changeset)

      assert envelope.error.fields == %{body: ["can't be blank"]}
    end
  end

  describe "for_changeset/3 answers in the request's language" do
    setup do
      on_exit(fn -> Gettext.put_locale("en") end)
    end

    test "a validation message comes back translated" do
      Gettext.put_locale("sr-Latn")

      envelope = ErrorEnvelope.for_changeset(:unprocessable_entity, "rejected", blank(:body))

      assert envelope.error.fields == %{body: ["ne sme biti prazno"]}
    end

    # The control for the row above, and the one that would fail if this change
    # had altered English behaviour rather than added a language.
    test "and the same message in the default locale is what it always was" do
      Gettext.put_locale("en")

      envelope = ErrorEnvelope.for_changeset(:unprocessable_entity, "rejected", blank(:body))

      assert envelope.error.fields == %{body: ["can't be blank"]}
    end

    test "the code does not change with the language, so a client keyed on it still matches" do
      Gettext.put_locale("sr-Latn")
      serbian = ErrorEnvelope.for_changeset(:unprocessable_entity, "rejected", blank(:body))

      Gettext.put_locale("en")
      english = ErrorEnvelope.for_changeset(:unprocessable_entity, "rejected", blank(:body))

      assert serbian.error.code == english.error.code
      refute serbian.error.fields == english.error.fields
    end

    # Serbian has three plural forms where English has two, and which one a
    # count takes is `HospitalityComs.Gettext.Plural`'s answer. A wrong rule
    # here produces grammatical-looking output in the wrong form, so the three
    # boundaries are asserted rather than a single count.
    test "a bound renders the right plural form at each of Serbian's three boundaries" do
      Gettext.put_locale("sr-Latn")

      assert field_error(too_long(:body, "xx", 1)) == "sme imati najviše 1 znak"
      assert field_error(too_long(:body, "xxxx", 3)) == "sme imati najviše 3 znaka"
      assert field_error(too_long(:body, "xxxxxx", 5)) == "sme imati najviše 5 znakova"
    end

    test "English keeps its two forms for the same counts" do
      Gettext.put_locale("en")

      assert field_error(too_long(:body, "xx", 1)) == "should be at most 1 character(s)"
      assert field_error(too_long(:body, "xxxx", 3)) == "should be at most 3 character(s)"
    end

    test "a message with no catalogue entry comes back in English rather than blank" do
      Gettext.put_locale("sr-Latn")

      changeset =
        {%{}, %{body: :string}}
        |> Ecto.Changeset.cast(%{body: ""}, [:body])
        |> Ecto.Changeset.add_error(:body, "a message nobody has translated")

      assert field_error(changeset) == "a message nobody has translated"
    end

    test "one of this project's own validation messages is translated too" do
      # The Ecto built-ins ship in the scaffolded catalogue; these are the
      # fifteen this project wrote, which had to be added by hand because
      # extraction cannot see a runtime msgid.
      Gettext.put_locale("sr-Latn")

      changeset =
        {%{}, %{email: :string}}
        |> Ecto.Changeset.cast(%{email: "nope"}, [:email])
        |> Ecto.Changeset.add_error(:email, "must have the @ sign and no spaces")

      assert field_error(changeset) == "mora sadržati znak @ i biti bez razmaka"
    end
  end

  describe "for_status/1" do
    test "takes both the code and the message from the status itself" do
      # What keeps a response Phoenix rendered on its own — a 404 from the
      # router, a 500 from an unhandled exception — in the same shape as one a
      # controller wrote.
      assert ErrorEnvelope.for_status(404) == %{
               error: %{code: "not_found", message: "Not Found"}
             }
    end
  end

  defp too_long(field, value, max) do
    {%{}, %{field => :string}}
    |> Ecto.Changeset.cast(%{field => value}, [field])
    |> Ecto.Changeset.validate_length(field, max: max)
  end

  defp blank(field) do
    {%{}, %{field => :string}}
    |> Ecto.Changeset.cast(%{field => ""}, [field])
    |> Ecto.Changeset.validate_required([field])
  end

  # The single message a one-field changeset produced, so the plural rows read
  # as the sentence they are asserting rather than as a map of lists.
  defp field_error(changeset) do
    envelope = ErrorEnvelope.for_changeset(:unprocessable_entity, "rejected", changeset)

    envelope.error.fields |> Map.values() |> List.first() |> List.first()
  end
end
