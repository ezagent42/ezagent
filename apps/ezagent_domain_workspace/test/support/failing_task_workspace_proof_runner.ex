defmodule EzagentDomainWorkspace.TestSupport.FailingTaskWorkspaceProofRunner do
  @moduledoc false

  def verify(_proof), do: {:error, :worktree_verification_failed}
end
