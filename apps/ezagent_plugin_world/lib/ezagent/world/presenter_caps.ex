defmodule Ezagent.World.PresenterCaps do
  @moduledoc """
  Single source for capabilities carried by World-originated dispatches.

  LiveView's `current_caps` assign is a bootstrap snapshot. The principal's
  Identity slice is the current source after grants, revokes, or target-key
  reconciliation. Current artifacts replace bootstrap artifacts with the same
  capability identity; bootstrap-only artifacts remain available for ephemeral
  mount authority.
  """

  alias Ezagent.Capability

  @doc "Load the presenter's current caps, merged over the LiveView bootstrap snapshot."
  @spec load(Phoenix.LiveView.Socket.t() | map()) :: MapSet.t(Capability.t())
  def load(%{assigns: assigns}) when is_map(assigns), do: load(assigns)

  def load(assigns) when is_map(assigns) do
    mounted = Map.get(assigns, :current_caps, MapSet.new()) || MapSet.new()

    current =
      case Map.get(assigns, :current_entity_uri) do
        %URI{} = presenter -> Ezagent.EntityCaps.load(presenter)
        _ -> []
      end

    merge(mounted, current)
  end

  @doc false
  @spec merge(Enumerable.t(), Enumerable.t()) :: MapSet.t(Capability.t())
  def merge(mounted, current) do
    mounted
    |> Enum.concat(current)
    |> Enum.reduce(%{}, fn
      %Capability{} = cap, acc -> Map.put(acc, Capability.identity_key(cap), cap)
      _other, acc -> acc
    end)
    |> Map.values()
    |> MapSet.new()
  end
end
