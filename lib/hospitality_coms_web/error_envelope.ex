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
  Builds the envelope for a status nobody wrote a message for.

  The code and the message both come from the status itself, which is what
  keeps a response Phoenix rendered on its own — a 404 from the router, a 500
  from an unhandled exception — in the same shape as one a controller wrote.
  """
  @spec for_status(100..599) :: t()
  def for_status(status) when is_integer(status) do
    new(Plug.Conn.Status.reason_atom(status), Plug.Conn.Status.reason_phrase(status))
  end
end
