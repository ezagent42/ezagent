defmodule EzagentWeb.Plugs.WorldHostScope do
  @moduledoc """
  Runtime host-scope gate for the world/operator routes.

  `nil` allows the operator routes on every host (prod apex deployment). A
  binary scope preserves Phoenix's `"world."` prefix semantics for dev/test.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_view: 2, render: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:ezagent_web, :world_host_scope, "world.") do
      nil ->
        conn

      "" ->
        conn

      scope when is_binary(scope) ->
        if host_matches?(conn.host, scope), do: conn, else: not_found(conn)
    end
  end

  defp host_matches?(host, scope) when is_binary(host) and is_binary(scope) do
    if String.ends_with?(scope, ".") do
      String.starts_with?(host, scope)
    else
      host == scope
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(EzagentWeb.ErrorHTML)
    |> render(:"404")
    |> halt()
  end
end
