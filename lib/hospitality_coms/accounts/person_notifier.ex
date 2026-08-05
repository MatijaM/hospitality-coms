defmodule HospitalityComs.Accounts.PersonNotifier do
  @moduledoc """
  The emails that carry a magic link.

  A mail adapter's failure reason is adapter-specific and unbounded — a
  `Mint.TransportError`, a provider's JSON body, a bare `:timeout` — and this
  repository's specs enumerate their error atoms rather than falling back to
  `term()`. That was the argument for `Mailer.deliver!/1`, and it was the wrong
  conclusion: raising does not make the reason enumerable, it just moves the
  unbounded value into a stack trace and hands the client a 500 outside the
  API's error envelope.

  The reason is collapsed here instead. Every failure logs what actually
  happened and returns `{:error, :delivery_failed}`, which is one atom a caller
  can match on and a controller can turn into a response.
  """

  use Gettext, backend: HospitalityComs.Gettext

  import Swoosh.Email

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Mailer

  require Logger

  @type delivery() :: {:ok, Swoosh.Email.t()} | {:error, :delivery_failed}

  @doc """
  Deliver instructions to update a person's email.
  """
  @spec deliver_update_email_instructions(Person.t(), String.t()) :: delivery()
  def deliver_update_email_instructions(person, url) do
    deliver(
      person.email,
      dgettext("emails", "Update email instructions"),
      dgettext(
        "emails",
        """

        ==============================

        Hi %{email},

        You can change your email by visiting the URL below:

        %{url}

        If you didn't request this change, please ignore this.

        ==============================
        """,
        email: person.email,
        url: url
      )
    )
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  @spec deliver_login_instructions(Person.t(), String.t()) :: delivery()
  def deliver_login_instructions(%Person{confirmed_at: nil} = person, url) do
    deliver_confirmation_instructions(person, url)
  end

  def deliver_login_instructions(%Person{} = person, url) do
    deliver_magic_link_instructions(person, url)
  end

  @spec deliver_magic_link_instructions(Person.t(), String.t()) :: delivery()
  defp deliver_magic_link_instructions(person, url) do
    deliver(
      person.email,
      dgettext("emails", "Log in instructions"),
      dgettext(
        "emails",
        """

        ==============================

        Hi %{email},

        You can log into your account by visiting the URL below:

        %{url}

        If you didn't request this email, please ignore this.

        ==============================
        """,
        email: person.email,
        url: url
      )
    )
  end

  @spec deliver_confirmation_instructions(Person.t(), String.t()) :: delivery()
  defp deliver_confirmation_instructions(person, url) do
    deliver(
      person.email,
      dgettext("emails", "Confirmation instructions"),
      dgettext(
        "emails",
        """

        ==============================

        Hi %{email},

        You can confirm your account by visiting the URL below:

        %{url}

        If you didn't create an account with us, please ignore this.

        ==============================
        """,
        email: person.email,
        url: url
      )
    )
  end

  # Delivers the email using the application mailer.
  @spec deliver(String.t(), String.t(), String.t()) :: delivery()
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      # The sender's display name is the product's name, which is one of the
      # strings the client's own catalogue translates. A Serbian email arriving
      # from an English-named sender is the same discard the link's domain
      # would be, one line earlier in the mail client.
      |> from({dgettext("emails", "Hospitality Coms"), "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    email |> Mailer.deliver() |> delivered(email)
  end

  # The argument type is the adapter's, which is exactly the unbounded shape
  # this function exists to stop propagating. The recipient is deliberately not
  # logged: an address is person-zone data and log lines are not.
  @spec delivered({:ok, term()} | {:error, term()}, Swoosh.Email.t()) :: delivery()
  defp delivered({:ok, _metadata}, email), do: {:ok, email}

  defp delivered({:error, reason}, email) do
    Logger.error("mail delivery failed for #{email.subject}: #{inspect(reason)}")
    {:error, :delivery_failed}
  end
end
