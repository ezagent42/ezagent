defmodule Ezagent.Credential.WorkspaceSharedCredentialSourceBehaviorTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.WorkspaceSharedCredentialSource
  alias Ezagent.Credential.WorkspaceSharedSource

  @workspace_uri URI.new!("workspace://team-a")
  @workspace_str URI.to_string(@workspace_uri)

  defp seed_agent(uri_str, flavor) do
    {:ok, _} = Ezagent.SnapshotStore.write(uri_str, %{}, kind_type: :agent)
    uri = Ezagent.URI.new!(uri_str)
    :ok = Ezagent.AgentFlavorAttributes.put(uri, flavor)
    uri_str
  end

  defp ctx do
    %{
      self_uri: @workspace_uri,
      caller: URI.new!("entity://team-a/user/admin"),
      read: fn :set_count, default -> default end
    }
  end

  test "sets the workspace-shared source after validating workspace and flavor" do
    source = seed_agent("entity://team-a/agent/ws-service", "cc")

    assert {:ok, %{flavor: "cc", source_uri: ^source}, effects} =
             WorkspaceSharedCredentialSource.handle_set_workspace_shared_credential_source(
               %{flavor: "cc", source_uri: source},
               ctx()
             )

    assert {:set, :set_count, 1} in effects
    assert WorkspaceSharedSource.resolve(@workspace_str, "cc") == source
  end

  test "rejects a source from another workspace" do
    source = seed_agent("entity://team-b/agent/ws-service", "cc")

    assert {:error, :source_workspace_mismatch} =
             WorkspaceSharedCredentialSource.handle_set_workspace_shared_credential_source(
               %{flavor: "cc", source_uri: source},
               ctx()
             )

    assert WorkspaceSharedSource.resolve(@workspace_str, "cc") == nil
  end

  test "rejects a source of the wrong flavor" do
    source = seed_agent("entity://team-a/agent/ws-codex", "codex")

    assert {:error, :source_flavor_mismatch} =
             WorkspaceSharedCredentialSource.handle_set_workspace_shared_credential_source(
               %{flavor: "cc", source_uri: source},
               ctx()
             )

    assert WorkspaceSharedSource.resolve(@workspace_str, "cc") == nil
  end
end
