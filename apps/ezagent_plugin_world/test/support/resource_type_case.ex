defmodule Ezagent.World.ResourceTypeCase do
  @moduledoc """
  Test helper that makes a suite self-contained w.r.t. the world plugin's
  `world-layouts` resource type, instead of depending on the boot-time
  registration surviving an entire umbrella `mix test` sweep.

  ## Why this exists

  `world-layouts` IS registered at boot by `EzagentPluginWorld.Application`'s
  `Ezagent.Plugin.boot/2` Phase 2 (`Registry.register_all/1`) — verified directly
  (the production flow works). But the umbrella `mix test` runs every app's suite
  in ONE shared BEAM, and `ezagent_core`'s restart-resilience tests RESTART the
  `Ezagent.Resource.FsResolver.Registry` GenServer. Its `init/1` re-applies ONLY
  the core `boot_registrations/0` (`cc-agents`, `codex-agents`, `uploads`) — plugin
  types are NOT replayed (see the Registry moduledoc). So by the time the world
  test phase runs in a full sweep, `world-layouts` has been wiped, even though the
  app stayed `started`.

  > NOTE: that non-replay is a latent PRODUCTION bug class (a Registry crash drops
  > every plugin's resource types until those plugins re-boot). It is tracked
  > separately in `docs/futures/todo.md` and is out of scope for this PR. This
  > helper does NOT mask it — it only makes the affected SUITES deterministic by
  > ensuring the same real production spec is present for their fixtures.

  ## Behaviour

  `ensure_world_layouts!/0` registers the EXACT production spec
  (`EzagentPluginWorld.Application.resource_types/0`, so the helper can never drift
  from production) ONLY when absent, and registers an `on_exit/1` that removes it
  ONLY when this helper was the one that added it. When the boot registration is
  still live (isolated runs, pre-restart sweeps) it is a no-op and the real
  production type is left untouched.
  """

  @table :ezagent_resource_fs_types
  @type_name "world-layouts"

  @doc """
  Ensure `world-layouts` is registered for the duration of the calling test,
  idempotently. Safe whether or not the boot registration is currently live.
  """
  @spec ensure_world_layouts!() :: :ok
  def ensure_world_layouts! do
    if registered?() do
      :ok
    else
      {@type_name, spec} =
        Enum.find(
          EzagentPluginWorld.Application.resource_types(),
          fn {type, _spec} -> type == @type_name end
        )

      :ok = Ezagent.Resource.FsResolver.register_type(@type_name, spec)
      ExUnit.Callbacks.on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type(@type_name) end)
      :ok
    end
  end

  defp registered?, do: :ets.lookup(@table, @type_name) != []
end
