defmodule HospitalityComsWeb.Router do
  use HospitalityComsWeb, :router

  import HospitalityComsWeb.PersonAuth

  # There is no browser pipeline. This application serves JSON and, from U7, a
  # socket; the HTML layer existed only because `mix phx.gen.auth` refuses to
  # run without it.
  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_person_scope
  end

  pipeline :authenticated_person do
    plug :require_authenticated_person
  end

  scope "/api", HospitalityComsWeb do
    pipe_through :api

    post "/log-in", SessionController, :create
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
end
