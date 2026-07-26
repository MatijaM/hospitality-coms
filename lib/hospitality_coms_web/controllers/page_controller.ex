defmodule HospitalityComsWeb.PageController do
  use HospitalityComsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
