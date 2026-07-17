defmodule EzagentDomainWorkspace.TestSupport.TaskWorkspaceProofRunner do
  @moduledoc false

  def verify(%{worktree_path: "/tmp/task-workspace-proof"}), do: :ok
end
