defmodule Ezagent.Workspace.CapReissuePolicy do
  @moduledoc false

  @behaviour Ezagent.Cap.ReissuePolicy

  alias Ezagent.Capability

  @responsibility_behaviors [
    Ezagent.ActionSet.Session,
    Ezagent.ActionSet.Turn,
    Ezagent.ActionSet.Surface,
    Ezagent.ActionSet.SupervisorApproval
  ]

  @impl true
  def classify(%Capability{behavior: Ezagent.ActionSet.Manage, action: :any}),
    do: {:ok, :creator_manage}

  def classify(%Capability{
        behavior: behavior,
        instance: {:within_workspace, %URI{scheme: "workspace"}}
      })
      when behavior in @responsibility_behaviors,
      do: {:ok, :workspace_responsibility}

  def classify(_cap), do: :not_mine

  @impl true
  def reissue_action(
        %{__struct__: Capability, behavior: Ezagent.ActionSet.Manage, granted_by: %URI{} = issuer},
        %URI{} = receiver
      ) do
    if same_uri?(issuer, receiver),
      do: {:reissue, {:genesis, issuer}},
      else: {:quarantine, :creator_manage_receiver_mismatch}
  end

  def reissue_action(%{__struct__: Capability, granted_by: %URI{} = issuer}, _receiver),
    do: {:reissue, {:genesis, issuer}}

  def reissue_action(_cap, _receiver), do: {:quarantine, :missing_workspace_issuer}

  defp same_uri?(left, right),
    do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
end
