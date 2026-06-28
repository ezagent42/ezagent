defmodule EzagentWeb.PluginAssetController do
  @moduledoc """
  Serves a hot-loaded plugin's frontend island bundle from its unpacked
  `priv/` dir (plugin-package handoff piece 3 — assets hot-load).

  Route: `GET /plugin-assets/:slug/*path` → looks up
  `Ezagent.PluginAssetRegistry` for `(slug, route)` and streams the
  registered file. Returns 404 if the slug/route is not registered
  (e.g. after unload). This is the runtime asset-serving path that
  AUGMENTS the compile-time `assets.deploy` copy — a plugin hot-loaded
  after the host started is reachable immediately, no web rebuild.
  """

  use EzagentWeb, :controller

  alias Ezagent.PluginAssetRegistry

  def show(conn, %{"slug" => slug, "path" => path_parts}) do
    route = Enum.join(path_parts, "/")

    case PluginAssetRegistry.lookup(slug, route) do
      {:ok, %{abs_path: abs_path, content_type: content_type}} ->
        case File.read(abs_path) do
          {:ok, body} ->
            conn
            |> put_resp_content_type(content_type)
            |> put_resp_header("cache-control", "public, max-age=300")
            |> send_resp(200, body)

          {:error, _reason} ->
            # Registered but the file is gone on disk (package dir removed).
            send_resp(conn, 404, "asset file not found")
        end

      :error ->
        send_resp(conn, 404, "plugin asset not registered")
    end
  end
end
