defmodule Ezagent.LocalRuntime do
  @moduledoc """
  Owner-gated facade for plugin access to local Kind runtime (liveness + spawn).

  ## Why this module exists

  Plugins must NOT reach into `Ezagent.KindRegistry` / `Ezagent.SpawnRegistry`
  directly. Two reasons:

  1. **Decentralization (the fundamental assumption change).** A raw
     `KindRegistry.lookup/1` is a *local-only* read. Single-node it is correct,
     but the workspace-locality direction (`Ezagent.RuntimeIdentity` /
     `Ezagent.WorkspacePlacement` / `Ezagent.WorkspaceOwnerGate`) exists to allow
     a future multi-node deployment where a Kind owned by ANOTHER node is alive
     *there* and absent *here*. A plugin that reads the bare `:error` from a local
     lookup would make a wrong decision (e.g. a spurious respawn). `kind_alive?/1`
     routes the probe through the owner gate so the locality assumption is
     EXPLICIT: single-node it is a no-op; on a non-owner runtime it returns
     `false` (not alive HERE) WITHOUT implying "dead, respawn locally".
  2. **Plugin isolation (north-star).** One owner-gated chokepoint; plugin authors
     never depend on core registry internals. The
     `plugin_workspace_locality_contract_test` enforces that no `apps/ezagent_plugin_*`
     code calls `KindRegistry`/`SpawnRegistry` directly — this module is the single
     sanctioned caller (it lives in `ezagent_core`, outside the lint's scope).

  ## Gating split

  - `kind_alive?/1` adds the gate that `KindRegistry.lookup/1` lacks.
  - `ensure_started/1,2` + `ensure_started_detailed/1,2` DELEGATE to
    `SpawnRegistry.spawn[_detailed]/1,2`, which is ALREADY owner-gated (it calls
    `WorkspaceOwnerGate.assert_local_owner_for_uri/2` itself). No redundant gate —
    the facade's value for spawn is purely the plugin-isolation boundary, and a
    non-owner `ensure_*` returns SpawnRegistry's gate error rather than spawning a
    foreign agent locally. So the probe-then-ensure pattern is safe even though
    `kind_alive?/1` collapses "non-owner" and "locally dead" to the same `false`:
    the real safety net is the gate on `ensure_*`.
  """

  alias Ezagent.{KindRegistry, SpawnRegistry}

  @doc """
  Owner-gated liveness probe: is the Kind for `uri` alive on this (its owner)
  runtime? Returns `false` both when the Kind is locally absent AND when this
  runtime is not the workspace owner (see the module doc — callers must not treat
  `false` as an unconditional "respawn locally"; use `ensure_started/1`, which is
  itself gated, for that).
  """
  @spec kind_alive?(URI.t()) :: boolean()
  def kind_alive?(%URI{} = uri) do
    case dispatch_policy().assert_local_owner(uri, {:liveness, uri}) do
      :ok -> match?({:ok, _pid}, KindRegistry.lookup(uri))
      {:error, _violation} -> false
    end
  end

  @doc """
  Owner-gated ensure-started: spawn the Kind for `uri` if absent. Delegates to the
  already-owner-gated `SpawnRegistry.spawn/1,2`; the option-bearing form accepts
  only `:launch_context` and fails closed on unknown options.
  """
  @spec ensure_started(URI.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(%URI{} = uri, opts \\ []), do: SpawnRegistry.spawn(uri, opts)

  @doc """
  Like `ensure_started/1,2` but returns whether the Kind was freshly started or was
  already running. Delegates to the already-owner-gated
  `SpawnRegistry.spawn_detailed/1,2`. Runtime options are validated fail closed.
  """
  @spec ensure_started_detailed(URI.t(), keyword()) ::
          {:ok, :started | :already_started, pid()} | {:error, term()}
  # derivation-edge: recorded-by the scheme-specific SpawnRegistry handler
  def ensure_started_detailed(%URI{} = uri, opts \\ []),
    do: SpawnRegistry.spawn_detailed(uri, opts)

  @doc """
  Owner-gated ensure-live: return the live Kind for `uri`, rehydrating it from
  durable state if it is cold but was genuinely created before. Delegates to the
  already-owner-gated `SpawnRegistry.ensure_live/1` (whose `spawn/1` carries the
  gate), so a non-owner runtime returns the gate error instead of materialising a
  foreign Kind locally — and a never-created URI returns `{:error, :not_created}`
  rather than a spurious fresh spawn.

  This is the sanctioned facade for the LLM Protocol API plug's session-liveness
  check (#99): it previously called `SpawnRegistry.ensure_live/1` directly, which
  the `plugin_workspace_locality_contract_test` forbids for `apps/ezagent_plugin_*`.
  """
  @spec ensure_live(URI.t()) :: {:ok, :live | :rehydrated} | {:error, term()}
  def ensure_live(%URI{} = uri), do: SpawnRegistry.ensure_live(uri)

  # C5 §3.4 DispatchPolicyPort — the per-URI workspace owner gate goes
  # through the config-resolved port, never the literal
  # `Ezagent.WorkspaceOwnerGate` spine. Wired at core boot
  # (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.DispatchPolicyAdapter`.
  defp dispatch_policy, do: Application.fetch_env!(:ezagent_actor, :dispatch_policy)
end
