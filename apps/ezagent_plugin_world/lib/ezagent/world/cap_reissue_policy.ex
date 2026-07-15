defmodule Ezagent.World.CapReissuePolicy do
  @moduledoc false

  @behaviour Ezagent.Cap.ReissuePolicy

  alias Ezagent.Capability

  @impl true
  def classify(%Capability{
        kind: :workspace,
        behavior: Ezagent.World.Behavior.Layout,
        action: :manage,
        instance: %URI{scheme: "workspace"}
      }),
      do: {:ok, :world_layout_manage}

  def classify(_cap), do: :not_mine

  @impl true
  def reissue_action(
        %{__struct__: Capability, granted_by: %URI{} = issuer},
        %URI{} = receiver
      ) do
    if Ezagent.URI.stable_key(issuer) == Ezagent.URI.stable_key(receiver),
      do: {:reissue, {:genesis, issuer}},
      else: {:quarantine, :world_layout_receiver_mismatch}
  end

  def reissue_action(_cap, _receiver), do: {:quarantine, :missing_world_layout_issuer}
end
