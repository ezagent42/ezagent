defmodule Mix.Tasks.Ezagent.Workspace.AddMember do
  @shortdoc "Add an entity URI to a workspace's member list — same path as the LV admin form"
  @moduledoc """
  Add an entity URI to a workspace's member list via
  `Ezagent.Workspace.add_member/2` — the SAME function
  `EzagentPluginLiveview.WorkspaceDetailLive`'s `add_member` event
  handler calls. CLI and LV share one code path; this task exists
  for parity per Allen 2026-05-25 directive (`CLI/LV 同源派生`).

  ## Usage

      mix ezagent.workspace.add_member <workspace_name> <entity_uri>

  ## Examples

      mix ezagent.workspace.add_member system entity://user/system/linyilun
      mix ezagent.workspace.add_member h2oslabs.com entity://agent/system/cc_main

  ## Caller authority

  The LV path performs a UI-side validation
  (`EzagentDomainUi.UriOptions.valid_for?/4`) that limits the URI
  picker to entities the caller can see. CLI operators already have
  shell access (per memory `feedback_let_it_crash_no_workarounds`'s
  in-VM-is-trusted v1 stance, SPEC `caps-cleanup-v1.md` §10.5), so
  this task does not re-impose the UI's pick-from-list constraint —
  it directly calls `Ezagent.Workspace.add_member/2` which performs
  the structural (entity URI in known workspace) checks. If your
  workflow requires a non-shell operator to drive this, use the LV.

  Exits non-zero on error so it composes with shell pipelines.
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

        case Ezagent.Workspace.add_member(workspace_name, member_uri) do
          :ok ->
            Mix.shell().info(
              "✓ added #{URI.to_string(member_uri)} to workspace #{workspace_name}"
            )

          {:ok, _} ->
            Mix.shell().info(
              "✓ added #{URI.to_string(member_uri)} to workspace #{workspace_name}"
            )

          {:error, reason} ->
            Mix.raise("add_member failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("""
        Missing arguments.

        Usage:
          mix ezagent.workspace.add_member <workspace_name> <entity_uri>

        Examples:
          mix ezagent.workspace.add_member system <user-uri>
          mix ezagent.workspace.add_member h2oslabs.com <agent-uri>
        """)
    end
  end

  defp parse_entity_uri(s) do
    try do
      {:ok, Ezagent.URI.new!(s)}
    rescue
      e in ArgumentError -> {:error, Exception.message(e)}
    end
  end
end
