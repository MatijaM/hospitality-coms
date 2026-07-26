defmodule HospitalityComsWeb.ErrorJSON do
  @moduledoc """
  The renderer the endpoint reaches for when no controller answered — a route
  that does not exist, or an exception nothing caught.

  It is the only error surface a client meets that no controller wrote, which
  is exactly why it must not invent a shape of its own. Both the code and the
  message come from the status, through
  `HospitalityComsWeb.ErrorEnvelope.for_status/1`.
  """

  alias HospitalityComsWeb.ErrorEnvelope

  @doc """
  Renders the error envelope for a `"<status>.json"` template.
  """
  @spec render(String.t(), map()) :: ErrorEnvelope.t()
  def render(template, _assigns) do
    template |> status_from_template() |> ErrorEnvelope.for_status()
  end

  @spec status_from_template(String.t()) :: 100..599
  defp status_from_template(template) do
    template |> String.split(".") |> hd() |> Integer.parse() |> status_or_server_error()
  end

  # Phoenix always names these templates after a status. A template that is not
  # one is a bug in whatever rendered it, and a server error is the honest
  # answer to a bug we cannot describe.
  @spec status_or_server_error({integer(), String.t()} | :error) :: 100..599
  defp status_or_server_error({status, ""}) when status in 100..599, do: status
  defp status_or_server_error(_unparsed), do: 500
end
