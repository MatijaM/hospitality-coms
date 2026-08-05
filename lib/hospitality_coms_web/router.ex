defmodule HospitalityComsWeb.Router do
  use HospitalityComsWeb, :router

  import HospitalityComsWeb.Locale
  import HospitalityComsWeb.LoginRateLimit
  import HospitalityComsWeb.PersonAuth

  # There is no browser pipeline. This application serves JSON and, from U7, two
  # sockets declared on `HospitalityComsWeb.Endpoint`; the HTML layer existed
  # only because `mix phx.gen.auth` refuses to run without it.
  pipeline :api do
    plug :accepts, ["json"]
    # Which language this request is answered in, resolved from `Origin` before
    # anything can render text. It belongs in `:api` rather than in a pipeline
    # of its own — unlike the limiter below, every route can produce a
    # changeset error, and a route that answered in the wrong language would do
    # so silently.
    plug :put_locale
    plug :fetch_person_scope
  end

  pipeline :authenticated_person do
    plug :require_authenticated_person
  end

  # Issue #15's limiter, and it is a pipeline of its own rather than a line in
  # `:api` because exactly one route may have it: `POST /api/log-in` is the only
  # endpoint an anonymous caller can use to write a row and send an email.
  # Redemption is bounded by holding a link, and everything else needs a
  # session. It must come *after* `:fetch_person_scope`, which is where the
  # instant it derives its window from is captured.
  pipeline :rate_limited_log_in do
    plug :limit_login
  end

  scope "/api", HospitalityComsWeb do
    pipe_through [:api, :rate_limited_log_in]

    post "/log-in", SessionController, :create
  end

  scope "/api", HospitalityComsWeb do
    pipe_through :api

    post "/log-in/token", SessionController, :confirm
  end

  scope "/api", HospitalityComsWeb do
    pipe_through [:api, :authenticated_person]

    # The session's own person. `PATCH` is the only write in this API that
    # changes a `people` row, and `HospitalityComsWeb.PersonController` says why
    # it is here rather than on `/profile`, which has no transport at all.
    get "/me", PersonController, :show
    patch "/me", PersonController, :update

    delete "/log-out", SessionController, :delete

    # U12's person-side reads. Fetch-once lists, not streams: two of them are
    # lists you need *before* you have a room to ask through, so they cannot
    # live on a room topic, and the third is a room's past rather than its
    # present. `HospitalityComsWeb.RoomController` carries the argument for each
    # path, including why the shift-room list hangs off the venue rather than
    # off the venue room (KTD18).
    #
    # The limiter above is deliberately not extended to them: they need a live
    # session, they write nothing, and their cost is bounded in
    # `HospitalityComs.Rooms` rather than at the door.
    get "/venue-rooms", RoomController, :venue_rooms
    get "/venue-rooms/:venue_id/messages", RoomController, :venue_room_messages
    get "/venues/:venue_id/shift-rooms", RoomController, :shift_rooms
    get "/shift-rooms/:shift_room_id/messages", RoomController, :shift_room_messages

    # The employer's half, and it is on this same pipeline rather than one of
    # its own. There is no employer credential: a session is a person session
    # plus a venue, and the venue is a path parameter, so a pipeline would have
    # to know which venue before the router had parsed one.
    # `HospitalityComsWeb.EmployerAuth` resolves the acting grant inside the
    # action instead, against the database, on every request.
    #
    # `/employer/venues` is not `/venues`: the person side has no venue
    # collection (`HospitalityComsWeb.RoomController` says why), and these are
    # the venues this session may *act for*, which is a different set from the
    # venues it is engaged at.
    get "/employer/venues", EmployerController, :venues
    get "/employer/venues/:venue_id/engagements", EmployerController, :engagements
    post "/employer/venues/:venue_id/invitations", EmployerController, :create_invitation

    # The shift and roster half. A shift room *is* the shift — there is no
    # `shifts` table and never was one — so `shift-rooms` is the collection a
    # manager creates into, and the roster hangs off one.
    #
    # These nest under the venue like everything else on this half, and unlike
    # the person side's `/api/shift-rooms/:id/messages`, which does not: there
    # a room id is authorised by a roster overlap the caller already holds,
    # while here every request is authorised by a grant at a *venue*, resolved
    # from the path before the room id is looked at.
    get "/employer/venues/:venue_id/shift-types", EmployerController, :shift_types
    post "/employer/venues/:venue_id/shift-rooms", EmployerController, :create_shift_room
    get "/employer/venues/:venue_id/shift-rooms", EmployerController, :shift_rooms

    post "/employer/venues/:venue_id/shift-rooms/:shift_room_id/roster",
         EmployerController,
         :create_roster_entry

    get "/employer/venues/:venue_id/shift-rooms/:shift_room_id/roster",
        EmployerController,
        :roster

    delete "/employer/venues/:venue_id/shift-rooms/:shift_room_id/roster/:engagement_id",
           EmployerController,
           :delete_roster_entry

    # The other half of the handshake, and it is **not** under `/employer`. A
    # claimant needs no prior relationship to the venue — no grant, no
    # engagement, nothing but the code somebody handed them out of band — so
    # nesting it under a venue would name an authority the caller does not have
    # and cannot be asked for. `HospitalityComsWeb.ClaimController` casts the
    # code and nothing else: accepting an offer is accepting *the* offer.
    post "/claims", ClaimController, :create
  end

  # The mailbox preview is how the magic link is read during development, since
  # there is no browser surface that renders it.
  if Application.compile_env(:hospitality_coms, :dev_routes) do
    scope "/dev" do
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # U11's demo controls, and the gate is the same mechanism one block up rather
  # than a similar one. `HospitalityComsWeb.DemoController` compiles from
  # `dev_support/` alongside `HospitalityComs.Clock.Offset`, so under `:prod`
  # the module does not exist — `Application.compile_env/2` answers `nil` there,
  # this block's body never runs when the router's module body is evaluated, and
  # no route is registered that could name it.
  #
  # That absence is KTD5b and not tidiness: these controls move a clock that
  # reaches irreversible retention deletion and end engagements across venues,
  # which is the one thing no employer session may do. They authenticate nobody
  # on purpose; what makes them safe is that they are not compiled.
  if Application.compile_env(:hospitality_coms, :demo_routes) do
    scope "/api/demo", HospitalityComsWeb do
      pipe_through :api

      post "/seed", DemoController, :seed
      get "/clock", DemoController, :show_clock
      post "/clock", DemoController, :update_clock
      delete "/clock", DemoController, :reset_clock
      post "/run-due-work", DemoController, :run_due_work
      post "/people/:person_id/end-engagements", DemoController, :end_engagements
    end
  end
end
