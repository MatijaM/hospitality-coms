defmodule HospitalityComsWeb.ErrorEnvelope do
  @moduledoc """
  One shape for every error this API returns.

  The generated stack answers in three: `%{errors: %{email: [...]}}` from a
  controller's changeset branch, `%{error: "unauthorized"}` from the
  authentication plug, and `%{errors: %{detail: "Not Found"}}` from the error
  renderer. Two of those collide on the `errors` key carrying incompatible
  values, so a client cannot tell a validation failure from a routing failure
  by looking at which keys are present — it has to guess from the status code
  and then guess again at the value's shape.

  There is exactly one envelope now:

      %{error: %{code: "unauthorized", message: "..."}}
      %{error: %{code: "unprocessable_entity", message: "...", fields: %{email: [...]}}}

  `code` is the machine-readable discriminator and is always the response's
  status atom, so it never drifts from the status line. `message` is for a
  human reading a log. `fields` appears only when the failure is per-field, and
  its absence is itself information: there is nothing to attach to an input.

  U12's React client is written against this, so the shape is a contract rather
  than a rendering detail. Every error surface — controllers, plugs, and
  `HospitalityComsWeb.ErrorJSON` — builds its body here and nowhere else.
  """

  alias Plug.Conn.Status

  @type fields() :: %{optional(atom()) => [String.t()]}
  @type t() :: %{error: %{code: String.t(), message: String.t()}}
  @type with_fields() :: %{
          error: %{code: String.t(), message: String.t(), fields: fields()}
        }

  @doc """
  Builds the envelope for a failure that has nothing to attach to an input.
  """
  @spec new(atom(), String.t()) :: t()
  def new(code, message) when is_atom(code) and is_binary(message) do
    %{error: %{code: Atom.to_string(code), message: message}}
  end

  @doc """
  Builds the envelope for a failure that names the inputs it rejected.
  """
  @spec new(atom(), String.t(), fields()) :: with_fields()
  def new(code, message, fields) when is_atom(code) and is_binary(message) and is_map(fields) do
    %{error: %{code: Atom.to_string(code), message: message, fields: fields}}
  end

  @doc """
  Builds the envelope for a changeset, with its errors interpolated.

  The traversal lives here rather than at each call site because there are now
  three of them — `HospitalityComsWeb.SessionController`,
  `HospitalityComsWeb.VenueRoomChannel` and `ShiftRoomChannel` — and the
  interpolation of Ecto's `%{count}` placeholders is exactly the kind of detail
  that drifts when it is written out more than once. The moduledoc's claim that
  every error body is built here is otherwise not true.
  """
  @spec for_changeset(atom(), String.t(), Ecto.Changeset.t()) :: with_fields()
  def for_changeset(code, message, %Ecto.Changeset{} = changeset)
      when is_atom(code) and is_binary(message) do
    new(code, message, changeset_errors(changeset))
  end

  @spec changeset_errors(Ecto.Changeset.t()) :: fields()
  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      message |> translate(opts) |> interpolate(opts)
    end)
  end

  # A changeset message is the msgid. This is the whole of how the API answers
  # in the reader's language, and it is here rather than in the schemas for two
  # reasons.
  #
  # Contexts under `lib/hospitality_coms/` reference the web namespace in prose
  # and in no line of code; making a schema call Gettext would not break that,
  # but it would put the same lookup at forty call sites instead of one. And
  # this traversal already exists and already visits every error the API
  # renders, so translation and interpolation stay adjacent rather than
  # separated by a layer.
  #
  # A message with no catalogue entry comes back unchanged, which is English —
  # so an untranslated validation is a sentence in the wrong language rather
  # than a raise or a blank.
  @spec translate(String.t(), keyword()) :: String.t()
  defp translate(message, opts) do
    case Keyword.fetch(opts, :count) do
      # `dngettext` picks the form; Serbian has three where English has two, and
      # which one a count takes is `HospitalityComs.Gettext.Plural`'s answer.
      {:ok, count} ->
        Gettext.dngettext(HospitalityComs.Gettext, "errors", message, message, count)

      :error ->
        Gettext.dgettext(HospitalityComs.Gettext, "errors", message)
    end
  end

  # Unchanged, and deliberately applied *after* translation rather than folded
  # into Gettext's own binding support: a translated string still carries the
  # `%{count}` the msgid had, and Gettext raises on a binding it was not given
  # while this falls back to the placeholder's name. The fallback is what keeps
  # an error whose options do not carry every placeholder from becoming a 500.
  @spec interpolate(String.t(), keyword()) :: String.t()
  defp interpolate(message, opts) do
    Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end

  @doc """
  Builds the envelope for a status nobody wrote a message for.

  The code and the message both come from the status itself, which is what
  keeps a response Phoenix rendered on its own — a 404 from the router, a 500
  from an unhandled exception — in the same shape as one a controller wrote.
  """
  @spec for_status(100..599) :: t()
  def for_status(status) when is_integer(status) do
    new(Status.reason_atom(status), Status.reason_phrase(status))
  end
end
