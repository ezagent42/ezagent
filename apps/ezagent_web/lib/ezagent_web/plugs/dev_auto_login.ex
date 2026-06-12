defmodule EzagentWeb.Plugs.DevAutoLogin do
  @moduledoc """
  Dev-only plug: `?as=<short_name>` auto-login for fast role switching.

  Reads `conn.params["as"]` and, if present in dev mode, calls
  `SessionPrincipal.put/3` with the bare handle + workspace "cinnox",
  then redirects to the same path without the query param.

  This lets developers open three incognito windows each logged in as a
  different role (customer / operator / admin) without manually going
  through the login form.

  ## Security

  - **`Mix.env() != :dev` gate** — compiled away in prod; the plug is a
    no-op pass-through when dev routes are disabled.
  - **GET only** — POST/PUT/DELETE requests pass through unchanged so
    the param can't be used to hijack a form submission.
  - **Redirect removes `?as=`** — the auto-login token never appears in
    the browser address bar after the first redirect, and it's never
    written to the session cookie (only the canonical entity URI is).

  ## Wiring

  Added to the `:browser` pipeline in `router.ex` right after
  `:fetch_session` so `put_session/3` works and before any auth plugs.
  """

  import Plug.Conn, only: [halt: 1]
  import Phoenix.Controller, only: [redirect: 2]

  @default_workspace "cinnox"
  @dev_routes Application.compile_env(:ezagent_web, :dev_routes, false)

  @doc false
  def init(opts), do: opts

  @doc false
  def call(%{method: "GET"} = conn, _opts) do
    if dev?() && conn.params["as"] do
      short = conn.params["as"]
      workspace = conn.params["workspace"] || @default_workspace

      conn
      |> EzagentWeb.SessionPrincipal.put(short, workspace: workspace)
      |> redirect_to_clean_path()
    else
      conn
    end
  end

  # Non-GET requests (POST login, etc.) pass through unchanged.
  def call(conn, _opts), do: conn

  # --- private ---

  defp dev?, do: @dev_routes

  defp redirect_to_clean_path(conn) do
    clean =
      conn.params
      |> Map.delete("as")
      |> Map.delete("workspace")

    query = if clean == %{}, do: "", else: "?" <> Plug.Conn.Query.encode(clean)
    to = conn.request_path <> query

    conn
    |> redirect(to: to)
    |> halt()
  end
end
