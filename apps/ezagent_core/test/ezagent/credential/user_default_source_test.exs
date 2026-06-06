defmodule Ezagent.Credential.UserDefaultSourceTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Credential.UserDefaultSource, as: UDS

  @owner "entity://team-a/user/alice"
  @ws "team-a"

  # Seed a source agent so all four validation checks can pass/fail deterministically:
  #   - existence: a durable snapshot row (SnapshotStore)
  #   - owner: spawn lineage (AgentLineage) → owner user
  #   - flavor: AgentFlavorAttributes ETS
  defp seed_agent(uri_str, owner, flavor) do
    {:ok, _} = Ezagent.SnapshotStore.write(uri_str, %{}, kind_type: :agent)
    uri = Ezagent.URI.new!(uri_str)
    :ok = Ezagent.AgentLineage.record(uri, owner)
    :ok = Ezagent.AgentFlavorAttributes.put(uri, flavor)
    uri_str
  end

  setup do
    seed_agent("entity://team-a/agent/alice-base", @owner, "cc")
    seed_agent("entity://team-a/agent/alice-base2", @owner, "cc")
    seed_agent("entity://team-a/agent/bob-base", "entity://team-a/user/bob", "cc")
    seed_agent("entity://team-a/agent/alice-codex", @owner, "codex")
    :ok
  end

  test "valid source: sets + resolves; re-set upserts (unique per owner/ws/flavor)" do
    src = "entity://team-a/agent/alice-base"
    assert {:ok, _} = UDS.persist_validated(@owner, @ws, "cc", src)
    assert UDS.resolve(@owner, @ws, "cc") == src

    src2 = "entity://team-a/agent/alice-base2"
    assert {:ok, _} = UDS.persist_validated(@owner, @ws, "cc", src2)
    assert UDS.resolve(@owner, @ws, "cc") == src2
  end

  test "rejects a source owned by another user in the same workspace (codex H4)" do
    assert {:error, :source_owner_mismatch} =
             UDS.persist_validated(@owner, @ws, "cc", "entity://team-a/agent/bob-base")
  end

  test "rejects a source of the wrong flavor" do
    assert {:error, :source_flavor_mismatch} =
             UDS.persist_validated(@owner, @ws, "cc", "entity://team-a/agent/alice-codex")
  end

  test "rejects a cross-workspace source" do
    # team-b/agent/x doesn't exist → existence check fires first; seed one in team-b
    # owned by alice but in the wrong workspace to exercise the workspace check.
    seed_agent("entity://team-b/agent/x", @owner, "cc")

    assert {:error, :source_workspace_mismatch} =
             UDS.persist_validated(@owner, @ws, "cc", "entity://team-b/agent/x")
  end

  test "rejects a non-existent source" do
    assert {:error, :source_not_found} =
             UDS.persist_validated(@owner, @ws, "cc", "entity://team-a/agent/ghost")
  end

  test "absent pointer resolves to nil (caller falls through to workspace-shared, not crash)" do
    assert UDS.resolve(@owner, @ws, "codex") == nil
  end
end
