defmodule HospitalityComsWeb.Router do
  use HospitalityComsWeb, :router

  import HospitalityComsWeb.PersonAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HospitalityComsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_person
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HospitalityComsWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", HospitalityComsWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:hospitality_coms, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HospitalityComsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", HospitalityComsWeb do
    pipe_through [:browser, :require_authenticated_person]

    live_session :require_authenticated_person,
      on_mount: [{HospitalityComsWeb.PersonAuth, :require_authenticated}] do
      live "/people/settings", PersonLive.Settings, :edit
      live "/people/settings/confirm-email/:token", PersonLive.Settings, :confirm_email
    end

    post "/people/update-password", PersonSessionController, :update_password
  end

  scope "/", HospitalityComsWeb do
    pipe_through [:browser]

    live_session :current_person,
      on_mount: [{HospitalityComsWeb.PersonAuth, :mount_current_scope}] do
      live "/people/register", PersonLive.Registration, :new
      live "/people/log-in", PersonLive.Login, :new
      live "/people/log-in/:token", PersonLive.Confirmation, :new
    end

    post "/people/log-in", PersonSessionController, :create
    delete "/people/log-out", PersonSessionController, :delete
  end
end
