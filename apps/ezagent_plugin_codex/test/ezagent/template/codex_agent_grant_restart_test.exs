defmodule Ezagent.PluginCodex.Template.CodexAgentGrantRestartTest do
  @moduledoc """
  #17 cascade PR-2 (§5.1) — cold-restart credential-grant re-validation gate for codex.
  A (re)start is a cascade boundary: an agent whose grant was revoked must NOT respawn
  holding stale creds. No-grant / active-grant agents proceed.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCodex.Template.CodexAgent
  alias Ezagent.Credential.GrantRow

  defp uniq, do: System.unique_integer([:positive])

  test "ensure_subprocess_alive fails loud when the agent's grant is revoked" do
    agent_uri = URI.new!("entity://team-a/agent/codex_revoked-#{uniq()}")
    on_exit(fn -> File.rm_rf(CodexAgent.agent_config_dir(agent_uri)) end)

    source_uri = "entity://team-a/agent/svc-#{uniq()}"
    {:ok, _} = Ezagent.SnapshotStore.write(source_uri, %{}, kind_type: :agent)

    {:ok, _g} =
      GrantRow.insert(%{
        agent_uri: URI.to_string(agent_uri),
        credential_source_uri: source_uri,
        approved_by: "entity://team-a/user/bob",
        approved_scope: source_uri,
        version: 1
      })

    {:ok, _} = GrantRow.revoke(URI.to_string(agent_uri))

    assert {:error, {:credential_grant_revoked, _}} =
             CodexAgent.ensure_subprocess_alive(agent_uri, %{"cwd" => "/tmp"})
  end

  test "an agent with NO grant (pre-cascade) is not blocked by the gate" do
    agent_uri = URI.new!("entity://team-a/agent/codex_nogrant-#{uniq()}")
    on_exit(fn -> File.rm_rf(CodexAgent.agent_config_dir(agent_uri)) end)

    result = CodexAgent.ensure_subprocess_alive(agent_uri, %{"cwd" => "/nonexistent-cwd"})
    refute match?({:error, {:credential_grant_revoked, _}}, result)
  end
end
