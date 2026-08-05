defmodule HospitalityComsWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, channels, and so on.

  This can be used in your application as:

      use HospitalityComsWeb, :controller

  The definitions below will be executed for every controller,
  channel, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.

  The `:html`, `:live_view`, and `:live_component` entrypoints the generator
  produced are gone with the HTML layer. This application answers JSON and,
  from U7, two sockets.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      # The backend lives in the context layer, because two of the three things
      # translated on the server are owned by contexts and a backend under this
      # namespace would invert that dependency. See `HospitalityComs.Gettext`.
      use Gettext, backend: HospitalityComs.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: HospitalityComsWeb.Endpoint,
        router: HospitalityComsWeb.Router,
        statics: []
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/channel/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
