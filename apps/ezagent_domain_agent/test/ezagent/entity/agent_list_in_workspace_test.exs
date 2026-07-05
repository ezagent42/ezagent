defmodule Ezagent.Entity.AgentListInWorkspaceTest do
  @moduledoc """
  Spec test 26 (R1.4) — the concrete agent enumerator used by the membership-cap
  reconcile candidate scan (§4.4) and the migration. Sourced from the persisted
  `kind_snapshots` rows (like `AgentRecipeResolver`), so it covers LIVE **and**
  DORMANT agents (a dormant agent has a snapshot row but no live Kind / ETS) and
  survives a BEAM restart.

  Proves the three filter axes:
    * a DORMANT agent (snapshot-only, no live Kind) is enumerated;
    * users (kind_type != "agent") are excluded;
    * another workspace's agents are excluded (workspace-scoped read).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Agent

  defp uniq, do: System.unique_integer([:positive])

  # A DORMANT agent — a persisted `kind_snapshots` row with NO live Kind / ETS
  # entry, seeded through the sanctioned `SnapshotFixtures` helper (Gates #20)
  # so the agent enumerates from snapshots alone.
  defp create_agent_snapshot_only(ws_name) do
    uri = Ezagent.URI.agent(ws_name, "dormant-#{uniq()}")
    :ok = Ezagent.Test.SnapshotFixtures.save_kind_snapshot(uri, Ezagent.Entity.Agent, %{})
    uri
  end

  defp create_user_snapshot(ws_name) do
    uri = Ezagent.URI.user(ws_name, "u-#{uniq()}")
    :ok = Ezagent.Test.SnapshotFixtures.save_kind_snapshot(uri, Ezagent.Entity.User, %{})
    uri
  end

  defp user_uri?(%URI{} = u), do: Ezagent.URI.type?(u, :user)
  defp user_uri?(_), do: false

  test "list_in_workspace returns a DORMANT agent, excludes users and other workspaces" do
    ws_name = "lw-#{uniq()}"
    ws = URI.new!("workspace://#{ws_name}")

    dormant = create_agent_snapshot_only(ws_name)
    _user = create_user_snapshot(ws_name)
    _other = create_agent_snapshot_only("other-#{uniq()}")

    uris = Agent.list_in_workspace(ws)

    assert dormant in uris
    refute Enum.any?(uris, &user_uri?/1)
    refute Enum.any?(uris, fn u -> Ezagent.Capability.workspace_of(u) != ws end)
  end
end
