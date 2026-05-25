defmodule Mix.Tasks.Ezagent.Workspace.RemoveMember do
  @shortdoc "Remove an entity URI from a workspace's member list — same path as the LV admin form"
  @moduledoc """
  Remove an entity URI from a workspace's member list via
  `Ezagent.Workspace.remove_member/2` — the SAME function
  `EzagentPluginLiveview.{WorkspaceDetailLive, UsersLive}`'s
  `remove_member` event handlers call. CLI and LV share one code
  path per Allen 2026-05-25 (`CLI/LV 同源派生`).

  ## Usage

      mix ezagent.workspace.remove_member <workspace_name> <entity_uri>

  Inverse of `mix ezagent.workspace.add_member`. Exits non-zero on
  error.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [workspace_name, member_uri_str | _]
      when is_binary(workspace_name) and workspace_name != "" and
             is_binary(member_uri_str) and member_uri_str != "" ->
        member_uri =
          case parse_entity_uri(String.trim(member_uri_str)) do
            {:ok, uri} -> uri
            {:error, reason} -> Mix.raise("bad member URI: #{inspect(reason)}")
          end

        case Ezagent.Workspace.remove_member(workspace_name, member_uri) do
          :ok ->
            Mix.shell().info(
              "✓ removed #{URI.to_string(member_uri)} from workspace://#{workspace_name}"
            )

          {:ok, _} ->
            Mix.shell().info(
              "✓ removed #{URI.to_string(member_uri)} from workspace://#{workspace_name}"
            )

          {:error, reason} ->
            Mix.raise("remove_member failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("""
        Missing arguments.

        Usage:
          mix ezagent.workspace.remove_member <workspace_name> <entity_uri>
        """)
    end
  end

  defp parse_entity_uri(s) do
    try do
      {:ok, Ezagent.URI.parse!(s)}
    rescue
      e in ArgumentError -> {:error, Exception.message(e)}
    end
  end
end
