defmodule EzagentDomainWorkspace.TestSupport.FailingTaskWorkspaceProofRunner do
  @moduledoc false

  def verify(_proof), do: {:error, :workspace_checkout_mismatch}
end
