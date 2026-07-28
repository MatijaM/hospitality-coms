defmodule HospitalityComsWeb.Router do
  use HospitalityComsWeb, :router

  import HospitalityComsWeb.LoginRateLimit
  import HospitalityComsWeb.PersonAuth

  # There is no browser pipeline. This application serves JSON and, from U7, two
  # sockets declared on `HospitalityComsWeb.Endpoint`; the HTML layer existed
  # only because `mix phx.gen.auth` refuses to run without it.
  pipeline :api do
    plug :accepts, ["json"]
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

    get "/me", SessionController, :show
    delete "/log-out", SessionController, :delete
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
