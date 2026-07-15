defmodule Ezagent.Identity.CapReissuePolicy do
  @moduledoc false

  @behaviour Ezagent.Cap.ReissuePolicy

  alias Ezagent.Capability

  @impl true
  def classify(%Capability{} = cap) do
    if Capability.identity_key(cap) == Capability.identity_key(Capability.admin_genesis_cap()),
      do: {:ok, :admin_genesis},
      else: classify_non_genesis(cap)
  end

  def classify(_cap), do: :not_mine

  defp classify_non_genesis(%Capability{
         kind: kind,
         behavior: Ezagent.ActionSet.Identity,
         action: :list_caps
       })
       when kind in [:user, :agent],
    do: {:ok, :identity_self}

  defp classify_non_genesis(%Capability{
         kind: :agent,
         behavior: Ezagent.ActionSet.Sandbox,
         action: :update_config
       }),
    do: {:ok, :agent_sandbox_self}

  defp classify_non_genesis(%Capability{
         kind: :agent,
         behavior: Ezagent.ActionSet.ConfigEvolve,
         action: :reconcile_cascade
       }),
    do: {:ok, :agent_config_evolve_self}

  defp classify_non_genesis(_cap), do: :not_mine

  @impl true
  def reissue_action(%Capability{} = cap, receiver_uri) do
    admin = Ezagent.Entity.User.admin_uri()

    case classify(cap) do
      {:ok, :admin_genesis} ->
        if same_uri?(receiver_uri, admin),
          do: {:reissue, {:genesis, admin}},
          else: {:quarantine, :genesis_receiver_mismatch}

      {:ok, class}
      when class in [:identity_self, :agent_sandbox_self, :agent_config_evolve_self] ->
        if self_cap?(cap, receiver_uri),
          do: {:reissue, {:admin, admin}},
          else: {:quarantine, :self_cap_receiver_mismatch}

      :not_mine ->
        {:quarantine, :not_identity_owned}
    end
  end

  defp same_uri?(%URI{} = left, %URI{} = right),
    do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)

  defp same_uri?(_left, _right), do: false

  defp self_cap?(%Capability{instance: %URI{} = instance}, %URI{} = receiver_uri),
    do: same_uri?(instance, receiver_uri)

  defp self_cap?(_cap, _receiver_uri), do: false
end
