defmodule EzagentWeb.CustomerSessionsRedirectController do
  @moduledoc """
  Redirects legacy `/admin/customer_sessions` to the new `/operator`
  entry point. Added in Phase 2.8 when the operator console moved from
  `/admin/customer_sessions` to `/operator/:tenant`.
  """

  use Phoenix.Controller, formats: [:html]

  # Named `index` (not `redirect`) to avoid shadowing
  # `Phoenix.Controller.redirect/2`. Covers both the legacy list page
  # and old `/admin/customer_sessions/:id` deep links (the old `:id` was
  # an encoded session URI not derivable to the new tenant/conv shape, so
  # both land on the `/operator` picker).
  def index(conn, _params) do
    conn |> Phoenix.Controller.redirect(to: "/operator") |> Plug.Conn.halt()
  end
end
