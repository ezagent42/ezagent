defmodule Ezagent.World.Navigation do
  @moduledoc """
  Partial navigation rules for the world React island.
  """

  @static_patch_paths MapSet.new([
                        "/",
                        "/sessions",
                        "/overview",
                        "/identities",
                        "/identities/users",
                        "/identities/agents",
                        "/identities/agents/new",
                        "/workspaces",
                        "/plugins",
                        "/plugins/feishu/bindings",
                        "/profile",
                        "/admin",
                        "/admin/logs",
                        "/admin/registry",
                        "/admin/snapshots",
                        "/admin/templates",
                        "/admin/caps",
                        "/admin/audit/authz",
                        "/admin/settings",
                        "/admin/routing"
                      ])

  @doc """
  Return a safe LiveView patch target for an in-app world path.
  """
  @spec patch_to(String.t()) :: {:ok, String.t()} | :error
  def patch_to(to) do
    case safe_destination(to) do
      {:ok, path, query} -> {:ok, path <> query_suffix(query)}
      :error -> :error
    end
  end

  @doc """
  Return a safe World destination together with the required LiveView transition.

  Admin-session targets must navigate so Phoenix can mount the separate
  `world_require_admin` live session and apply its router gate again.
  """
  @spec navigation_for(String.t()) :: {:ok, :patch | :navigate, String.t()} | :error
  def navigation_for(to) do
    case safe_destination(to) do
      {:ok, path, query} -> {:ok, navigation_mode(path), path <> query_suffix(query)}
      :error -> :error
    end
  end

  defp navigation_mode(path) do
    if admin_session_path?(path), do: :navigate, else: :patch
  end

  # Keep the cross-session seam here, next to the allowlist. This is deliberately
  # not an authorization decision: the router's LiveAuth :require_admin gate is
  # still the sole authority for each admin destination.
  defp admin_session_path?("/overview"), do: true
  defp admin_session_path?("/admin"), do: true
  defp admin_session_path?("/admin/" <> _rest), do: true
  defp admin_session_path?(_path), do: false

  defp safe_destination(to) when is_binary(to) do
    with {:ok, path, query} <- split_patch_to(to),
         true <- patch_path?(path) do
      {:ok, path, query}
    else
      _ -> :error
    end
  end

  defp safe_destination(_), do: :error

  defp split_patch_to(to) do
    cond do
      String.contains?(to, ["#", "://"]) -> :error
      String.starts_with?(to, "//") -> :error
      true -> split_query(to)
    end
  end

  defp split_query(to) do
    case String.split(to, "?", parts: 2) do
      [path] -> {:ok, path, nil}
      [path, query] -> {:ok, path, query}
    end
  end

  defp query_suffix(nil), do: ""
  defp query_suffix(""), do: ""
  defp query_suffix(query), do: "?" <> query

  defp patch_path?(path) when is_binary(path) do
    MapSet.member?(@static_patch_paths, path) or dynamic_patch_path?(path) or
      plugin_page_patch_path?(path)
  end

  defp patch_path?(_), do: false

  defp dynamic_patch_path?(path) do
    Regex.match?(~r{\A/identities/(?:users|agents)/[^/]+/caps\z}, path) or
      Regex.match?(
        ~r{\A/identities/agents/[^/]+(?:/api-keys|/config|/extensions|/terminal)?\z},
        path
      ) or
      Regex.match?(~r{\A/workspaces/[^/]+/templates/new\z}, path) or
      Regex.match?(~r{\A/workspaces/[^/]+\z}, path) or
      Regex.match?(~r{\A/plugins/auto/[^/]+(?:/[^/]+)?\z}, path) or
      Regex.match?(~r{\A/admin/sessions/[^/]+/external_mirror\z}, path)
  end

  # 插件页面（`Ezagent.World.PluginPageRegistry`）的列表/详情路由都是合法
  # patch 目标——由注册表派生，不再逐插件写静态项 + 正则（kanban 曾是硬编码）。
  defp plugin_page_patch_path?(path) do
    Ezagent.World.PluginPageRegistry.by_route(path) != nil
  end
end
