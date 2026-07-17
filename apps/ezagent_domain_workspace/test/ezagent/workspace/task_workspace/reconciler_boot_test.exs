defmodule Ezagent.Workspace.TaskWorkspace.ReconcilerBootTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace.TaskWorkspace.ReconcilerBoot

  test "boot recovery is a temporary bounded one-shot child" do
    assert %{restart: :temporary} = ReconcilerBoot.child_spec([])
    assert {:ok, pid} = ReconcilerBoot.start_link(limit: 1)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
