defmodule EzagentWeb.CustomerSessionsRedirectController do
  @moduledoc """
  Redirects legacy `/admin/customer_sessions` to the new `/operator`
  entry point. Added in Phase 2.8 when the operator console moved from
  `/admin/customer_sessions` to `/operator/:tenant`.
  """

  use Phoenix.Controller, formats: [:html]

  def redirect(conn, _params) do
    conn |> Phoenix.Controller.redirect(to: "/operator") |> Plug.Conn.halt()
  end
end
