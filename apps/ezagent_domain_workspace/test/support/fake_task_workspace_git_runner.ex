defmodule EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceGitRunner do
  @moduledoc false

  def prepare(request) do
    owner = Application.fetch_env!(:ezagent_domain_workspace, :provisioner_test_owner)
    send(owner, {:git_prepare, request})
    Process.sleep(Application.get_env(:ezagent_domain_workspace, :provisioner_test_delay, 0))

    Application.get_env(
      :ezagent_domain_workspace,
      :provisioner_test_prepare_result,
      {:ok,
       %{
         cache_identity: "cache-fixture",
         worktree_identity: "worktree-fixture",
         worktree_path: "/tmp/ezagent-task-worktree-fixture"
       }}
    )
  end

  def verify(ready) do
    owner = Application.fetch_env!(:ezagent_domain_workspace, :provisioner_test_owner)
    send(owner, {:git_verify, ready})

    Application.get_env(:ezagent_domain_workspace, :provisioner_test_verify_hook, fn -> :ok end).()

    Application.get_env(:ezagent_domain_workspace, :provisioner_test_verify_result, :ok)
  end

  def remove(ready) do
    owner = Application.fetch_env!(:ezagent_domain_workspace, :provisioner_test_owner)
    send(owner, {:git_remove, ready})

    if Application.get_env(:ezagent_domain_workspace, :provisioner_test_remove_clears, false),
      do:
        Application.put_env(
          :ezagent_domain_workspace,
          :provisioner_test_verify_absent_result,
          :ok
        )

    Application.get_env(:ezagent_domain_workspace, :provisioner_test_remove_result, :ok)
  end

  def verify_absent(ready) do
    owner = Application.fetch_env!(:ezagent_domain_workspace, :provisioner_test_owner)
    send(owner, {:git_verify_absent, ready})

    Application.get_env(
      :ezagent_domain_workspace,
      :provisioner_test_verify_absent_result,
      :ok
    )
  end
end
