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
  # `check_origin` is set explicitly for production in `config/runtime.exs`,
  # from `WEBSOCKET_ORIGINS`, and a production boot raises without it. These two
  # sockets are the first thing that setting has ever applied to here, and
  # Phoenix's default of `true` checks the request's `Origin` against the
  # endpoint's own `:url` host — so a browser client served from anywhere else
  # has its upgrade refused before `connect/3` runs, with nothing in this
  # application's logs to say why. `config/dev.exs` sets `false`; the test
  # environment never opens a real transport.
  #
  # `max_channels_per_transport` is left at Phoenix's default of 100, and the
  # bound it implies is **not** what KTD10 claimed. Multiplexing is a
  # worker-side argument, so state the real numbers:
  #
  #   * **Person socket.** One `peer` channel, whatever KTD10 says about
  #     conversations, plus one `venue_room` per venue the person is engaged at,
  #     plus one `shift_room` per shift room they have open. The first two are
  #     small. The third has **no bound at all**:
  #     `HospitalityComs.Rooms.list_readable_shift_rooms/1` grows with every
  #     shift the person was ever rostered on at a venue whose engagement is
  #     still active, and a client that joined its whole readable set would
  #     reach 100 within a few months of ordinary shift work. Clients must open
  #     shift rooms on demand and leave them, rather than joining the list.
  #   * **Employer socket.** One channel per venue, with no multiplexing at all
  #     — there is nothing to multiplex, because the venue is the topic. A
  #     manager holding grants at more than a hundred venues would be refused,
  #     which is remote but is not the argument KTD10 makes.
  #
  # **What a client sees at the limit is not an `ErrorEnvelope`.** Phoenix
  # answers the join with `%{reason: "too many channels joined"}` from inside
  # `Phoenix.Socket`, before any application code runs, and logs a warning
  # naming the socket id. A client cannot parse it as `error.code`.
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
