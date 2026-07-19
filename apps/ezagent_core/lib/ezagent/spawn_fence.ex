defmodule Ezagent.SpawnFence do
  @moduledoc """
  Core-owned spawn-fence registry — the behavior-set-independent principal
  gate every Kind start and registry return must pass (task #180,
  delete = atomic revocation, codex finding F1).

  ## Why this exists (the two fence holes)

  The C2 tombstone fence lives in `Ezagent.ActionSet.Identity`'s Lifecycle
  callbacks (`create/1` / `activate/2`). Codex review found that placement
  is bypassable on two paths:

    1. **The no-Identity path** — a Kind spawned with an explicit behavior
       set that excludes Identity (e.g. `behaviors: []`) never runs those
       callbacks, so a tombstoned principal's Kind starts unfenced.
    2. **The already-running path** — `SpawnRegistry`'s `KindRegistry`
       lookup hit returns the live pid BEFORE any spawn happens, so the
       fence never fires for a tombstoned principal whose process is
       (still) alive.

  This registry is the core chokepoint that closes both holes at the two
  places every start/return MUST pass:

    * `Ezagent.Kind.Server.init/1` — refuses to start ANY Kind (any
      behavior set) at a fenced URI.
    * `Ezagent.SpawnRegistry` — refuses the already-running return (and
      tears the stale process down) and refuses the spawn-fn invocation
      for a fenced URI.

  ## The tier problem

  The tombstone truth lives downstream (`Ezagent.Users` /
  `Ezagent.Identity.AgentTombstone` in `ezagent_domain_identity`), and
  `ezagent_core` must NOT reference domain modules (the no-core→domain
  layering invariant — the same constraint that keeps
  `Ezagent.Socialware.ConfigStore` out of core's EtsOwner list). So core
  owns only this REGISTRY: downstream apps register 1-arity predicate
  functions at boot (`ezagent_domain_identity` registers
  `Ezagent.Identity.Offboarding.refute_tombstoned/1`), and core callers
  run every registered predicate without knowing what they check. Same
  pattern as `SpawnRegistry.register/2` (core ETS table, domain fns).

  ## Semantics

    * `register(name, fun)` — idempotent; re-registering the same `name`
      overwrites. `fun` is `(URI.t() -> :ok | {:error, term()})`.
    * `unregister(name)` — removes a predicate (test teardown).
    * `check(uri)` — runs every registered predicate; `:ok` iff ALL
      pass, else the FIRST `{:error, reason}`. A predicate that raises /
      exits is caught and reported as `{:error, {:spawn_fence_error, ...}}`
      (FAIL-CLOSED: a broken fence predicate blocks spawns rather than
      silently admitting a possibly-tombstoned principal).
    * An EMPTY registry (no predicate registered yet — early boot, or a
      minimal app stack without the identity domain) is `:ok` (fail-open
      by design: absence of the checker ≠ a tombstone, mirroring
      `Users.deleted?/1`'s "absence is not deletion"). The Identity
      Lifecycle fence remains the independent backstop for stacks that
      load identity.

  ## ETS layout

  `:ezagent_spawn_fence` set table owned by `EzagentCore.EtsOwner`. Keys
  are predicate names (atoms), values are 1-arity functions. Owned by
  EtsOwner (like `SpawnRegistry`) so the table has the same crash-
  recovery + boot-order discipline as every other registry — an owner
  restart recreates it EMPTY and the domain app re-registers on ITS
  restart (same accepted trade-off as the spawn-fn registry).
  """

  @table :ezagent_spawn_fence

  @doc "The ETS table name. `EzagentCore.EtsOwner` creates it."
  def table, do: @table

  @doc """
  Register (or overwrite) a spawn-fence predicate under `name`.

  `fun` takes the candidate `%URI{}` and returns `:ok` (admit) or
  `{:error, reason}` (refuse). Domain apps call this in their
  `Application.start/2`; re-registration on app restart is intentional
  (late-binding wins, mirroring `SpawnRegistry.register/2`).
  """
  @spec register(atom(), (URI.t() -> :ok | {:error, term()})) :: :ok
  def register(name, fun) when is_atom(name) and is_function(fun, 1) do
    :ets.insert(@table, {name, fun})
    :ok
  end

  @doc "Remove the predicate registered under `name` (test teardown)."
  @spec unregister(atom()) :: :ok
  def unregister(name) when is_atom(name) do
    :ets.delete(@table, name)
    :ok
  end

  @doc """
  Run every registered fence predicate against `uri`.

  Returns `:ok` when all admit (or none are registered / the table is
  not up); the FIRST predicate's `{:error, reason}` otherwise. Predicate
  crashes are caught and surface as
  `{:error, {:spawn_fence_error, name, detail}}` — fail-closed.
  """
  @spec check(URI.t()) :: :ok | {:error, term()}
  def check(%URI{} = uri) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        @table
        |> :ets.tab2list()
        |> Enum.reduce_while(:ok, fn {name, fun}, :ok ->
          case safe_check(name, fun, uri) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  defp safe_check(name, fun, uri) do
    case fun.(uri) do
      :ok -> :ok
      {:error, _} = error -> error
      # A misbehaving predicate (non-contract return) fails CLOSED —
      # a fence that cannot say "admit" must never admit.
      other -> {:error, {:spawn_fence_error, name, {:bad_return, other}}}
    end
  rescue
    error -> {:error, {:spawn_fence_error, name, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:spawn_fence_error, name, {:exit, reason}}}
  end
end
