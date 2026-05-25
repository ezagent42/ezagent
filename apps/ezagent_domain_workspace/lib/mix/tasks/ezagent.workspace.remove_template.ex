defmodule Mix.Tasks.Ezagent.Workspace.RemoveTemplate do
  @shortdoc "Remove a session template from a workspace — same path as the LV admin form"
  @moduledoc """
  Remove a session template from a workspace via
  `Ezagent.Workspace.remove_template/2` — the SAME function
  `EzagentPluginLiveview.WorkspaceDetailLive`'s `remove_template`
  event handler calls. CLI and LV share one code path per Allen
  2026-05-25 (`CLI/LV 同源派生`).

  ## Usage

      mix ezagent.workspace.remove_template <workspace_name> <template_name>

  Exits non-zero on error.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [workspace_name, tmpl_name | _]
      when is_binary(workspace_name) and workspace_name != "" and
             is_binary(tmpl_name) and tmpl_name != "" ->
        case Ezagent.Workspace.remove_template(workspace_name, tmpl_name) do
          :ok ->
            Mix.shell().info(
              "✓ removed template #{inspect(tmpl_name)} from workspace://#{workspace_name}"
            )

          {:error, reason} ->
            Mix.raise("remove_template failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("""
        Missing arguments.

        Usage:
          mix ezagent.workspace.remove_template <workspace_name> <template_name>
        """)
    end
  end
end
