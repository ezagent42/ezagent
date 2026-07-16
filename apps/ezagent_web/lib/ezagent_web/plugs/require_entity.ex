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
              cond do
                not entity_user_or_agent?(uri) ->
                  bounce(conn)

                # Active-session eviction (task #180 Change 3): a user
                # disabled/deleted AFTER login must be bounced on their next
                # authenticated request — `verify_password/2` only gates the
                # LOGIN, so without this recheck a live cookie survives until
                # expiry. Scoped to USER URIs: `Users.disabled?/1` fails closed
                # (unknown → disabled), and agent URIs are not in the `users`
                # table, so an agent bearer must NOT be run through it.
                user_offboarded?(uri) ->
                  bounce(conn)

                true ->
                  assign(conn, :current_entity_uri, uri)
              end

            _ ->
              bounce(conn)
          end
        rescue
          ArgumentError -> bounce(conn)
        end
    end
  end

  defp entity_user_or_agent?(%URI{} = uri) do
    Ezagent.URI.scheme?(uri, :entity) and
      match?({:ok, kind} when kind in ["user", "agent"], Ezagent.URI.type(uri))
  end

  # True only when `uri` is a USER that has been soft-disabled or tombstoned
  # (`disabled_at` is set on both). Agent URIs are exempt — they are not
  # `users` rows and `disabled?/1` fails closed on unknown, so an agent bearer
  # must NOT be run through it.
  defp user_offboarded?(%URI{} = uri) do
    match?({:ok, "user"}, Ezagent.URI.type(uri)) and Ezagent.Users.disabled?(uri)
  end

  defp bounce(conn) do
    conn
    |> redirect(to: "/login")
    |> halt()
  end
end
