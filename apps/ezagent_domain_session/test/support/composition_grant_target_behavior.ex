defmodule EzagentDomainInstanceMessage.CompositionGrantTargetBehavior do
  @moduledoc false
  # Test-only owner-resolvable target with TWO actions so a single
  # `mint_cap/4` call can mint a read-only key (`[:get_tree]`) or an operate
  # key (`[:add_node, ...]`) purely by the `actions` argument. Mirrors the
  # kanban board shape the runtime grant entry serves.

  use Ezagent.Lifecycle, state_slice: :composition_grant_target

  action(:get_tree,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:get_tree],
    modes: [:call],
    description: "read action"
  )

  action(:add_node,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:add_node],
    modes: [:call],
    description: "write action"
  )

  def required_caps do
    %{
      get_tree: Ezagent.Capability.cap(:agent, __MODULE__, :get_tree),
      add_node: Ezagent.Capability.cap(:agent, __MODULE__, :add_node)
    }
  end

  def data_owner(instance), do: Ezagent.ActionSet.ApiKeys.data_owner(instance)

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  def handle_get_tree(_args, _ctx), do: {:ok, %{ok: true}, []}
  def handle_add_node(_args, _ctx), do: {:ok, %{ok: true}, []}
end
