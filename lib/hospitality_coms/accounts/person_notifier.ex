defmodule HospitalityComs.Accounts.PersonNotifier do
  @moduledoc """
  The emails that carry a magic link.

  Delivery uses `Mailer.deliver!/1` rather than `deliver/1`: a mail adapter's
  failure reason is adapter-specific and unbounded, and this repository's specs
  enumerate their error atoms rather than falling back to `term()`. A delivery
  that fails is an infrastructure fault, so it raises and the request fails
  loudly instead of returning an error nobody can pattern match on.
  """

  import Swoosh.Email

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Mailer

  @doc """
  Deliver instructions to update a person's email.
  """
  @spec deliver_update_email_instructions(Person.t(), String.t()) :: Swoosh.Email.t()
  def deliver_update_email_instructions(person, url) do
    deliver(person.email, "Update email instructions", """

    ==============================

    Hi #{person.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  @spec deliver_login_instructions(Person.t(), String.t()) :: Swoosh.Email.t()
  def deliver_login_instructions(%Person{confirmed_at: nil} = person, url) do
    deliver_confirmation_instructions(person, url)
  end

  def deliver_login_instructions(%Person{} = person, url) do
    deliver_magic_link_instructions(person, url)
  end

  @spec deliver_magic_link_instructions(Person.t(), String.t()) :: Swoosh.Email.t()
  defp deliver_magic_link_instructions(person, url) do
    deliver(person.email, "Log in instructions", """

    ==============================

    Hi #{person.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  @spec deliver_confirmation_instructions(Person.t(), String.t()) :: Swoosh.Email.t()
  defp deliver_confirmation_instructions(person, url) do
    deliver(person.email, "Confirmation instructions", """

    ==============================

    Hi #{person.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  # Delivers the email using the application mailer.
  @spec deliver(String.t(), String.t(), String.t()) :: Swoosh.Email.t()
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"HospitalityComs", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    _metadata = Mailer.deliver!(email)
    email
  end
end
