defmodule HospitalityComsWeb.ErrorJSONTest do
  @moduledoc """
  The renderer Phoenix reaches for when nothing in the router or a controller
  answered. It is the only error surface a client meets that no controller
  wrote, so it has to speak the same envelope the controllers do.
  """

  use HospitalityComsWeb.ConnCase, async: true

  alias HospitalityComsWeb.ErrorJSON

  test "renders 404 in the one envelope" do
    assert ErrorJSON.render("404.json", %{}) == %{
             error: %{code: "not_found", message: "Not Found"}
           }
  end

  test "renders 500 in the one envelope" do
    assert ErrorJSON.render("500.json", %{}) == %{
             error: %{code: "internal_server_error", message: "Internal Server Error"}
           }
  end

  test "falls back to a server error for a template that names no status" do
    assert %{error: %{code: "internal_server_error"}} = ErrorJSON.render("oops.json", %{})
  end
end
