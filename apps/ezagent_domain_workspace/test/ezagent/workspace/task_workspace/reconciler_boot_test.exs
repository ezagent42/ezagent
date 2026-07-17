defmodule Ezagent.Workspace.TaskWorkspace.ReconcilerBootTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace.TaskWorkspace.ReconcilerBoot
  alias Ezagent.Workspace.TaskWorkspace.{Provision, Store}
  alias EzagentCore.Repo

  test "boot recovery is a temporary bounded one-shot child" do
    assert %{restart: :temporary} = ReconcilerBoot.child_spec([])
    assert {:ok, pid} = ReconcilerBoot.start_link(limit: 1)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "production application declares the one-shot recovery child" do
    source =
      File.read!(Path.expand("../../../../lib/ezagent_domain_workspace/application.ex", __DIR__))

    assert source =~ "Ezagent.Workspace.TaskWorkspace.ReconcilerBoot"
  end

  test "one-shot boot waits once for an active orphan lease and recovers it" do
    {:ok, row} = Store.create_planned(attrs())
    {:ok, _claimed} = Store.claim_provision(row.id, now: at(0), lease_seconds: 30)
    Process.put(:recovery_times, [at(0), at(31)])

    result =
      ReconcilerBoot.run(
        limit: 1,
        now_fun: fn ->
          [now | rest] = Process.get(:recovery_times)
          Process.put(:recovery_times, rest)
          now
        end,
        wait_fun: fn milliseconds ->
          send(self(), {:waited_once, milliseconds})
          :ok
        end
      )

    assert_receive {:waited_once, milliseconds}
    assert milliseconds == 30_001
    assert result.second.cleaned == 1
    assert Repo.get!(Provision, row.id).status == :cleaned
  end

  defp attrs do
    %{
      provision_id: "boot-orphan",
      workspace_uri: "workspace://boot-recovery-team",
      task_uri: "resource://boot-recovery-team/kanban-task/task-one",
      generation: 1,
      task_access_uri: "resource://boot-recovery-team/git-task-access/access-one",
      repository_uri: "resource://boot-recovery-team/git-repository/repository-one",
      checkout_fingerprint: "fingerprint-one",
      base_ref: "main",
      allowed_head_ref: "task/one",
      visibility: :public
    }
  end

  defp at(seconds), do: DateTime.add(~U[2026-07-17 00:00:00.000000Z], seconds, :second)
end
