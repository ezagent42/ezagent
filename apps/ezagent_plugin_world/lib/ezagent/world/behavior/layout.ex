defmodule Ezagent.World.Behavior.Layout do
  @moduledoc """
  Workspace-scoped layout management behavior for the `world` plugin.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :world_layout

  action(:manage,
    args: %{layout: :map},
    returns: %{layout: :map},
    caps: [:manage],
    modes: [:call],
    description: "manage the world app layout for this workspace"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  @doc "Workspace layout is class-wide workspace data, matching Workspace.data_owner/1."
  def data_owner(_), do: :any

  @doc "The world layout manage cap is workspace-kind scoped."
  def required_caps do
    %{
      manage: Ezagent.Capability.cap(:workspace, __MODULE__, :manage)
    }
  end

  @doc """
  Persist a validated world layout for the target workspace.

  R-3 (codex HIGH-4): the caller's authenticated `scope` is built from
  `ctx.caller` (the authenticated dispatch caller) — INDEPENDENTLY of the target
  `workspace_uri` (`self_uri`) — and threaded SEPARATELY into
  `LayoutManager.write_layout/3`. The resolver's authority check then compares
  the target URI's `<ws>` against the caller's `scope.workspace`; the two come
  from independent sources, so the check is non-tautological.
  """
  def handle_manage(%{layout: layout}, %{
        self_uri: %URI{scheme: "workspace"} = workspace_uri,
        caller: %URI{} = caller_uri
      }) do
    scope = %{workspace: Ezagent.URI.workspace_name!(caller_uri)}

    case Ezagent.World.LayoutManager.write_layout(workspace_uri, layout, scope) do
      {:ok, saved_layout} -> {:ok, %{layout: saved_layout}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_manage(_args, _ctx), do: {:error, :invalid_workspace_scope}
end
