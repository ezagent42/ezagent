defmodule EzagentWeb.HealthController do
  @moduledoc """
  Liveness probe. Returns 200 + `{"status":"ok"}` if the BEAM node is up
  enough to serve HTTP. Does NOT exercise the Ezagent dispatch path — it is a
  plain controller action, not an Invocation (Phase 0 has no dispatch path).
  """
  use EzagentWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
