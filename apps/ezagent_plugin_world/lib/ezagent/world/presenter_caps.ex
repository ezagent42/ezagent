defmodule Ezagent.World.PresenterCaps do
  @moduledoc """
  Single source for capabilities carried by World-originated dispatches.

  `load/1` re-derives the presenter's caps FRESH from the live/durable Identity
  store on every action — it is exactly `EntityCaps.load(presenter)`, full stop.
  LiveView's `current_caps` assign is a mount-time bootstrap snapshot and is NO
  LONGER trusted: merging it let a bootstrap-only authority artifact survive a
  mid-session grant/revoke/demotion (a demoted admin kept publish/admin rights
  until re-login — docs/futures/todo.md 2026-07-22). Fresh derivation closes that
  staleness on the very next action.

  The one caller that legitimately carries EPHEMERAL caps minted at request time
  (a JIT-issued capability that is never written to the principal's durable
  Identity slice — e.g. `EzagentWeb.Socialware.KanbanPublishedReadAdapter`, whose
  cap comes from `Ezagent.Cap.issue/3`, not a durable grant) uses the explicit
  narrow `load_with_ephemeral/2` path: those caps are minted at mount and are not
  revocable mid-socket, so they are unioned over the fresh set on purpose. No
  other path may resurrect a mount snapshot.
  """

  alias Ezagent.Capability

  @doc """
  Load the presenter's current caps FRESH from the Identity store (§2.2). Never
  merges the mount-time `current_caps` snapshot — see the moduledoc.
  """
  @spec load(Phoenix.LiveView.Socket.t() | map()) :: MapSet.t(Capability.t())
  def load(%{assigns: assigns}) when is_map(assigns), do: load(assigns)

  def load(assigns) when is_map(assigns) do
    assigns
    |> fresh_caps()
    |> MapSet.new()
  end

  @doc """
  Fresh presenter caps UNIONED with an explicit set of EPHEMERAL caps (§C1
  carve-out). The narrow path for callers that hold a request-time JIT capability
  which is never persisted to the principal's durable Identity slice and is not
  revocable mid-socket; unioning it over the fresh set is deliberate, not a mount
  snapshot. All other callers use `load/1`.
  """
  @spec load_with_ephemeral(Phoenix.LiveView.Socket.t() | map(), Enumerable.t()) ::
          MapSet.t(Capability.t())
  def load_with_ephemeral(%{assigns: assigns}, ephemeral) when is_map(assigns),
    do: load_with_ephemeral(assigns, ephemeral)

  def load_with_ephemeral(assigns, ephemeral) when is_map(assigns) do
    merge(ephemeral, fresh_caps(assigns))
  end

  defp fresh_caps(assigns) do
    case Map.get(assigns, :current_entity_uri) do
      %URI{} = presenter -> Ezagent.EntityCaps.load(presenter)
      _ -> []
    end
  end

  @doc false
  @spec context(Phoenix.LiveView.Socket.t() | map()) :: map()
  def context(%{assigns: assigns} = socket) when is_map(assigns) do
    presenter = Map.fetch!(assigns, :current_entity_uri)

    %{
      caller: presenter,
      authenticated_principal: presenter,
      caps: load(socket)
    }
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
