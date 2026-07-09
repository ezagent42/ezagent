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
                        "/plugins/kanban",
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
  def patch_to(to) when is_binary(to) do
    with {:ok, path, query} <- split_patch_to(to),
         true <- patch_path?(path) do
      {:ok, path <> query_suffix(query)}
    else
      _ -> :error
    end
  end

  def patch_to(_), do: :error

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
    MapSet.member?(@static_patch_paths, path) or dynamic_patch_path?(path)
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
      Regex.match?(~r{\A/plugins/kanban/[^/]+\z}, path) or
      Regex.match?(~r{\A/plugins/auto/[^/]+(?:/[^/]+)?\z}, path) or
      Regex.match?(~r{\A/admin/sessions/[^/]+/external_mirror\z}, path)
  end
end
