defmodule Ezagent.Kind do
  @moduledoc """
  Kind — contract for a Kind type module.

  Per DECISIONS P1-D2 / Decision #84: Phase 1 uses the
  `@behaviour Ezagent.Kind` + shared `Ezagent.Kind.Server` approach (path B
  in ARCHITECTURE.md §5.7.4), **not** a `use Ezagent.Kind` macro. The
  Kind module is a pure data declaration: which Behaviors it has,
  what its persistence policy is, etc. The `Ezagent.Kind.Server`
  GenServer instantiates one process per `{kind_module, args}` and
  delegates lifecycle (register → subscribe → announce_ready) so
  plugin authors cannot bypass it.

  ## Required callbacks

  - `type_name/0`: stable type atom (e.g. `:echo`, `:user`, `:agent`).
    Stored in snapshots — used to rehydrate, so renaming the module
    must not require a migration. Per Decision #62.
  - `behaviors/0`: list of `Ezagent.Behavior` modules this Kind composes.
  - `persistence/0`: snapshot strategy.

  ## Optional callbacks

  - `uri_from_args/1`: build the URI from instance args. Default
    implementation expects `args[:uri]` to be set by the caller.
  - `supervisor/0`: declare which `DynamicSupervisor` should host this
    Kind's processes. Defaults to `Ezagent.KindSupervisor` (a generic
    catch-all started by `EzagentCore.Application`). Per-Kind
    supervisors are encouraged when the Kind wants its own restart
    policy or domain-app ownership boundary.
  - `snapshot_version/0`: integer rev for snapshot schema migration.

  ## V1 structural prevention (Phase 9 follow-up, Allen 2026-05-21)

  All Kind processes must be spawned via `Ezagent.Kind.spawn/2` — the
  sole programmatic entry. Direct `DynamicSupervisor.start_child` for
  Kind modules is caught by the CI gate
  `Ezagent.Invariants.SingleSpawnEntryTest` plus the runtime invariant
  `Ezagent.Invariants.KindProvenanceTest`. Sidecars
  (`Ezagent.Domain.Pty.Server` and friends) are NOT Kinds and are
  exempt.
  """

  @type persistence_policy ::
          :ephemeral
          | {:snapshot, :on_change}
          | {:snapshot, :periodic, ms :: pos_integer()}
          | :on_terminate
          | :external

  @callback type_name() :: atom()
  @callback behaviors() :: [module()]
  @callback persistence() :: persistence_policy()
  @callback uri_from_args(args :: map()) :: URI.t()
  @callback snapshot_version() :: non_neg_integer()
  @callback supervisor() :: module()

  @typedoc """
  Spawn-strategy override for Kinds that need a non-standard
  supervision-tree shape. Returning `:standard` (or NOT exporting
  the callback) uses the default `Kind.spawn/2` flow:
  `DynamicSupervisor.start_child(supervisor, {Kind.Server,
  {kind_module, params}})`.

  Returning `{:custom, module, function}` delegates to
  `apply(module, function, [params])` — the Kind's domain owns
  the start-child shape (PerBindingSupervisor layering, registry
  registration, etc.). Used by `Ezagent.Entity.ExternalMirrorWorker`
  (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §6.3) — the two-tier RootSupervisor → PerBindingSupervisor →
  Kind.Server topology cannot be expressed via the default
  `DynamicSupervisor.start_child` shape because the supervisor
  doesn't wrap child specs.
  """
  @type spawn_strategy ::
          :standard
          | {:custom, module(), atom()}

  @doc """
  Optional callback declaring how `Kind.spawn/2` should start an
  instance of this Kind. Default (when not exported): `:standard`
  — `Kind.spawn/2` issues `DynamicSupervisor.start_child(supervisor,
  {Kind.Server, {kind_module, params}})`.

  Custom strategy `{:custom, mod, fun}` makes `Kind.spawn/2`
  delegate to `apply(mod, fun, [params])` — the Kind's domain
  owns the supervision-tree layering. The custom function MUST
  return the same shape as `DynamicSupervisor.start_child/2`
  (`{:ok, pid()} | {:error, term()}`) so callers can match on
  `{:error, {:already_started, pid}}` for idempotency.

  Domains using `{:custom, _, _}` should ALSO implement the
  `terminate_strategy/0` companion callback so
  `Ezagent.Kind.terminate/1` knows how to tear down — the
  standard `DynamicSupervisor.terminate_child(supervisor,
  kind_server_pid)` path only works when the Kind.Server pid is
  a direct child of `supervisor()`, which is NOT the case for
  custom multi-tier topologies (e.g. ExternalMirror's
  RootSupervisor → PerBindingSupervisor → Kind.Server — RootSupervisor
  owns the PerBindingSupervisor pid, not the Kind.Server pid).

  This is the extension point for the ExternalMirror two-tier
  supervisor topology (SPEC §6.3) — a Domain concern that does
  NOT belong in core, hence the indirection.
  """
  @callback spawn_strategy() :: spawn_strategy()

  @typedoc """
  Companion to `spawn_strategy/0` — declares the per-Kind
  termination path. `Ezagent.Kind.terminate/1` reads this via
  `function_exported?/3`; default (when not exported) is
  `:standard` — terminate via
  `DynamicSupervisor.terminate_child(supervisor, kind_server_pid)`
  which only works when the Kind.Server is a DIRECT child of
  `supervisor()`.

  `{:custom, mod, fun}` makes `Kind.terminate/1` delegate the
  teardown to `apply(mod, fun, [uri, kind_server_pid])`. The
  custom function returns `:ok` (idempotent — absent / already-
  terminated URI returns `:ok`, mirroring `Kind.terminate/1`'s
  best-effort contract).
  """
  @type terminate_strategy ::
          :standard
          | {:custom, module(), atom()}

  @doc """
  Optional companion to `spawn_strategy/0` — declares how
  `Ezagent.Kind.terminate/1` should tear down an instance.
  Required when `spawn_strategy/0` returns `{:custom, _, _}` AND
  the custom spawn does NOT place the Kind.Server directly under
  `supervisor()`. See `t:terminate_strategy/0`.

  PR-EM-2 codex round-1 HIGH-2 fix (2026-05-25) — added so
  `Ezagent.Entity.ExternalMirrorWorker`'s two-tier topology has a
  symmetric teardown path.
  """
  @callback terminate_strategy() :: terminate_strategy()

  @optional_callbacks [
    uri_from_args: 1,
    snapshot_version: 0,
    supervisor: 0,
    spawn_strategy: 0,
    terminate_strategy: 0
  ]

  @doc """
  The SOLE programmatic entry for spawning a Kind process.

  Determines the target `DynamicSupervisor` via `kind_module.supervisor/0`
  (each Kind declares its own; defaults to `Ezagent.KindSupervisor`
  when not defined). Calls `DynamicSupervisor.start_child/2` with the
  standard `Ezagent.Kind.Server` child spec wrapping
  `{kind_module, params}`.

  **Critical**: NO other lib code should call
  `DynamicSupervisor.start_child` for a Kind process. CI grep gate
  `Ezagent.Invariants.SingleSpawnEntryTest` enforces; runtime invariant
  `Ezagent.Invariants.KindProvenanceTest` enforces. Sidecars
  (PtyServer etc.) are NOT Kinds and live in their own exemption table.

  Returns the same as `DynamicSupervisor.start_child/2`:

      {:ok, pid()} | {:error, term()}

  Callers expecting idempotency typically match
  `{:error, {:already_started, pid}}` and treat it as success — the
  underlying `DynamicSupervisor` semantics are preserved.

  ## Examples

      Ezagent.Kind.spawn(Ezagent.Entity.User, %{
        uri: Ezagent.Entity.User.admin_uri(),
        initial_caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
      })

      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{uri: session_uri})
  """
  @spec spawn(module(), map()) :: DynamicSupervisor.on_start_child()
  def spawn(kind_module, params) when is_atom(kind_module) and is_map(params) do
    case spawn_strategy(kind_module) do
      :standard ->
        supervisor = resolve_supervisor(kind_module)
        DynamicSupervisor.start_child(supervisor, {Ezagent.Kind.Server, {kind_module, params}})

      {:custom, mod, fun} when is_atom(mod) and is_atom(fun) ->
        # Domain-owned supervision-tree layering (e.g. ExternalMirror's
        # two-tier RootSupervisor → PerBindingSupervisor → Kind.Server,
        # SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
        # §6.3). The custom function returns the same on_start_child
        # shape so idempotent reconcilers can match `{:error,
        # {:already_started, pid}}`.
        apply(mod, fun, [params])
    end
  end

  # Inlined to keep `spawn/2` flat. Defaults to `:standard` when the
  # Kind module hasn't exported `spawn_strategy/0` — backward-compat
  # with every pre-PR-EM-2 Kind.
  defp spawn_strategy(kind_module) do
    if function_exported?(kind_module, :spawn_strategy, 0) do
      kind_module.spawn_strategy()
    else
      :standard
    end
  end

  @doc """
  Terminate a live Kind process by its instance URI (codex round-10 HIGH).

  This is the tier-clean teardown primitive a plugin Template Class uses
  to undo its OWN partial spawn: when a Template Class freshly STARTED a
  Kind via `spawn/2` (or `SpawnRegistry.spawn_detailed/1`) and a LATER
  step of the same instantiate fails, it must terminate the Kind it just
  started before returning `{:error, _}` — so a per-slot instantiate
  either fully succeeds or leaves zero residue.

  A Tier-3 plugin cannot name a Tier-2 supervisor constant, so this
  helper resolves the owning `DynamicSupervisor` itself: it looks up the
  live pid in `Ezagent.KindRegistry`, asks the running `Ezagent.Kind.Server`
  for its Kind module (`:ezagent_kind_module` call), resolves the
  supervisor via `kind_module.supervisor/0`, and calls
  `DynamicSupervisor.terminate_child/2`. The `:permanent` `Kind.Server`
  child is only PERMANENTLY removed by `terminate_child` — a bare
  `Process.exit/2` would be restarted; that is the fallback only when
  the child is not under the resolved supervisor.

  **Idempotent** — an already-absent / already-terminated URI returns
  `:ok`. Best-effort: any error in the lookup / query / terminate path
  is swallowed and `:ok` is returned (the caller is on a failure exit
  and a teardown step must not mask the original error).

  This terminates ONLY the Kind process. Lineage (`AgentLineage`) and
  workspace binding (`WorkspaceRegistry`) are ESR-domain registries —
  a plugin Template Class must NOT touch them (3-tier rule); the
  ESR-layer caller (`Ezagent.Entity.Agent.spawn_from_template_content/4`)
  owns undoing those.
  """
  @spec terminate(URI.t()) :: :ok
  def terminate(%URI{} = uri) do
    with {:ok, pid} <- Ezagent.KindRegistry.lookup(uri),
         {:ok, kind_module} <- safe_kind_module(pid) do
      case terminate_strategy(kind_module) do
        :standard ->
          supervisor = resolve_supervisor(kind_module)

          case DynamicSupervisor.terminate_child(supervisor, pid) do
            :ok ->
              :ok

            {:error, :not_found} ->
              # Not under the resolved supervisor (or already gone) —
              # bring the process down directly so the worker still
              # terminates.
              _ = Process.exit(pid, :shutdown)
              :ok
          end

        {:custom, mod, fun} when is_atom(mod) and is_atom(fun) ->
          # PR-EM-2 codex round-1 HIGH-2 fix (2026-05-25): Kinds with
          # custom spawn topologies (e.g. ExternalMirror's two-tier
          # RootSupervisor → PerBindingSupervisor → Kind.Server) need
          # symmetric teardown — the Kind.Server pid is NOT a direct
          # child of `supervisor()`, so the standard
          # `terminate_child(supervisor, kind_server_pid)` returns
          # `{:error, :not_found}` and the fallback `Process.exit`
          # path just lets the permanent inner child restart.
          # `terminate_strategy/0` declares the domain-owned teardown.
          _ = apply(mod, fun, [uri, pid])
          :ok
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp terminate_strategy(kind_module) do
    if function_exported?(kind_module, :terminate_strategy, 0) do
      kind_module.terminate_strategy()
    else
      :standard
    end
  end

  @doc """
  Read a specific Behavior slice from a live Kind instance.

  Synchronous `GenServer.call` to the Kind.Server — returns the
  current value of `state.state[slice_key]`. Used by lookups like
  `Ezagent.Entity.Session.owner/1` (PR-OWN-2, caps-data-ownership
  SPEC #306 §7) where a Behavior's `data_owner/1` callback needs
  to read durable per-instance state without going through dispatch.

  Returns `{:ok, slice}` (the slice may be `nil` or `%{}` if not
  initialised), `{:error, :not_found}` if the URI has no live
  Kind, or `{:error, reason}` if the call times out.

  NOT a hot-path API — `Behavior.invoke/4` should read its own
  slice via the `slice` argument; this is for cross-process
  lookups during default-grant evaluation, admin LV display, etc.
  """
  @spec get_slice(URI.t() | String.t(), atom()) ::
          {:ok, term()} | {:error, term()}
  def get_slice(uri, slice_key) when is_atom(slice_key) do
    uri_str =
      case uri do
        %URI{} = u -> URI.to_string(u)
        s when is_binary(s) -> s
      end

    case Ezagent.KindRegistry.lookup(uri_str) do
      {:ok, pid} when is_pid(pid) ->
        try do
          {:ok, slice} = GenServer.call(pid, {:ezagent_get_slice, slice_key}, 5_000)
          {:ok, slice}
        catch
          :exit, reason -> {:error, {:get_slice_exit, reason}}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp safe_kind_module(pid) when is_pid(pid) do
    {:ok, _} = GenServer.call(pid, :ezagent_kind_module, 5_000)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp resolve_supervisor(kind_module) do
    if function_exported?(kind_module, :supervisor, 0) do
      kind_module.supervisor()
    else
      Ezagent.KindSupervisor
    end
  end
end
