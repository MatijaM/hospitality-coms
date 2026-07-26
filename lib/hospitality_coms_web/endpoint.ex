defmodule HospitalityComsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hospitality_coms

  # There is no LiveView socket, no static file serving, and no live reload:
  # the HTML layer is gone. U7 adds `PersonSocket` and `EmployerSocket` here,
  # deliberately as two socket modules so that an employer session cannot even
  # be routed to a peer conversation (KTD9).

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :hospitality_coms
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug HospitalityComsWeb.Router
end
