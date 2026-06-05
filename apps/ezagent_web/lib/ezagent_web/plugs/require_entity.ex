defmodule EzagentWeb.Plugs.RequireEntity do
  @moduledoc """
  Plug that bounces unauthenticated requests to `/login` (PR #142
  rename of the prior `RequireUser` plug).

  The session cookie now carries `current_entity_uri` — any
  `entity://user/*` OR `entity://agent/*` URI is accepted, so a
  future agent-driven `/admin` flow (an AI agent logged in with a
  bearer token) lands in the same `assigns.current_entity_uri`
  slot a human user uses.

  Public scopes (e.g. `/`) skip this plug entirely.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :current_entity_uri) do
      nil ->
        bounce(conn)

      uri_str when is_binary(uri_str) ->
        # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
        # with try/rescue; stale or malformed cookie URIs bounce to login
        # (Invariant #9 — graceful surface, not silent crash).
        try do
          case Ezagent.URI.new!(uri_str) do
            %URI{} = uri ->
              if Ezagent.URI.scheme?(uri, :entity) and
                   match?({:ok, kind} when kind in ["user", "agent"], Ezagent.URI.type(uri)) do
                assign(conn, :current_entity_uri, uri)
              else
                bounce(conn)
              end

            _ ->
              bounce(conn)
          end
        rescue
          ArgumentError -> bounce(conn)
        end
    end
  end

  defp bounce(conn) do
    conn
    |> redirect(to: "/login")
    |> halt()
  end
end
