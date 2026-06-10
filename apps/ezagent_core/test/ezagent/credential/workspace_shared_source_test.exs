defmodule Ezagent.Credential.WorkspaceSharedSourceTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Credential.WorkspaceSharedSource
  alias EzagentCore.Repo

  @workspace "workspace://team-a"
  @source "entity://team-a/agent/ws-service"

  test "resolve/2 returns nil when no workspace-shared pointer exists" do
    assert WorkspaceSharedSource.resolve(@workspace, "cc") == nil
  end

  test "changeset persists one shared source per workspace/flavor" do
    attrs = %{
      workspace_uri: @workspace,
      flavor: "cc",
      source_uri: @source,
      set_by: "entity://team-a/user/admin"
    }

    assert {:ok, _row} =
             attrs
             |> WorkspaceSharedSource.changeset()
             |> Repo.insert()

    assert WorkspaceSharedSource.resolve(@workspace, "cc") == @source
  end
end
