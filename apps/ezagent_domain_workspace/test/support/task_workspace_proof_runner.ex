defmodule EzagentDomainWorkspace.TestSupport.TaskWorkspaceProofRunner do
  @moduledoc false

  alias Ezagent.Workspace.TaskWorkspace.Store

  def verify(%{worktree_path: "/tmp/task-workspace-proof"} = proof) do
    if id = Application.get_env(:ezagent_domain_workspace, :sidecar_gate_proof_row_id) do
      row = Store.get(id)

      send(Application.fetch_env!(:ezagent_domain_workspace, :sidecar_gate_test_owner), {
        :proof_called,
        proof,
        row.status,
        row.start_claim_token
      })
    end

    :ok
  end
end
