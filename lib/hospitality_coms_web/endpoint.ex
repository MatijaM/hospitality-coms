defmodule HospitalityComsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hospitality_coms

  # There is no LiveView socket, no static file serving, and no live reload:
  # the HTML layer is gone.
  #
  # Two socket modules, deliberately, so that an employer session cannot even be
  # routed to a peer conversation (KTD9): the refusal is the absence of an entry
  # in `HospitalityComsWeb.EmployerSocket`'s channel table, which Phoenix's own
  # dispatch enforces before any application code runs.
  #
  # `auth_token: true` on both puts the session token on the
  # `Sec-WebSocket-Protocol` header rather than in a query parameter, which is
  # what keeps a live credential out of access logs and out of the `Referer` of
  # anything the page loads next. It reaches `connect/3` as
  # `connect_info[:auth_token]`.
  #
  # `max_channels_per_transport` is left at its default of 100. KTD10 is what
  # makes that enough: peer conversations multiplex through one channel rather
  # than taking one each, so a worker's channel count is bounded by the number
  # of rooms they are in rather than by the number of people they talk to.
  socket "/socket/person", HospitalityComsWeb.PersonSocket,
    auth_token: true,
    websocket: true,
    longpoll: false

  socket "/socket/employer", HospitalityComsWeb.EmployerSocket,
    auth_token: true,
    websocket: true,
    longpoll: false

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
