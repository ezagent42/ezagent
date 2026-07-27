defmodule Ezagent.Kind do
  import Kernel, except: [spawn: 3]

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
  - `behaviors/0`: list of `Ezagent.ActionSet` modules this Kind composes.
  - `persistence/0`: snapshot strategy.

  ## Optional callbacks

  - `uri_from_args/1`: build the URI from instance args. Default
    implementation expects `args[:uri]` to be set by the caller.
  - `supervisor/0`: declare which `DynamicSupervisor` should host this
    Kind's processes. Defaults to `Ezagent.KindSupervisor` (a generic
    catch-all started by `EzagentActor.Application`). Per-Kind
    supervisors are encouraged when the Kind wants its own restart
    policy or domain-app ownership boundary.
  - `snapshot_version/0`: integer rev for snapshot schema migration.
  - `before_start/1`: run a fallible hook before snapshot loading and live
    registration. Runtime-only launch context is available only to this hook.

  ## V1 structural prevention (Phase 9 follow-up, Allen 2026-05-21)

  All Kind processes must be spawned via `Ezagent.Kind.spawn/2,3` — the
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
  @callback before_start(args :: map()) :: :ok | {:error, term()}

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

  @doc """
  Does the entity (or principal) at `entity_uri` hold a cap that
  authorizes the `needed` capability?

  Called by `Ezagent.Kind.Runtime.handle_dispatch/4` step 5.5 (the
  dispatch authz chokepoint, post-PR-CC-2-v2). Returns `true` only when
  the entity's `:identity` slice contains at least one `%Capability{}`
  cap that matches `needed` per `Capability.matches?/2`.

  ## Default implementation

  When a Kind does not export `holds_cap?/2`, dispatch uses
  `Ezagent.Kind.default_holds_cap?/2` which:

  1. Reads the entity's `:identity` slice via the framework-internal
     `Kind.SliceAccess` live read (NOT
     `Invocation.dispatch/1` — breaks the self-list-caps recursion), through
     the classifying + bounded-retry read `SliceAccess.read_identity_caps/1`.
  2. Converts the `needed` `%Capability{}` into the 4-field map
     `Capability.matches?/2` consumes.
  3. Returns `true` iff any held cap matches (per #154 predicate A). A GENUINE
     absence denies (`false`); a TRANSIENT read failure of a KNOWN entity fails
     LOUD (raises `Ezagent.Kind.IdentityReadError`) — never a silent deny. See
     `default_holds_cap?/2`.

  ## Override semantics

  Kinds MAY override `holds_cap?/2` for Kind-specific bypass logic.
  The override MUST preserve the "any held cap matches needed"
  semantic. The two known overrides today:

  - `Ezagent.Entity.User` short-circuits when the user is the structural
    bootstrap admin (`User.admin_invariant?/1`).
  - `Ezagent.Kind.Template` reads its caps from `TemplateRegistry`
    directly to avoid re-entering dispatch during materialization.

  SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §3.
  """
  @callback holds_cap?(entity_uri :: URI.t() | String.t(), needed :: term()) ::
              boolean()

  # P5-0b — does this Kind REQUIRE a non-nil `:kind_base` on every instance?
  # Default `false` when absent (legacy static Kinds: omitted-`:behaviors` →
  # declared list, the intentional compat path). Session Kind(s) override to
  # `true` — see `requires_explicit_behavior_set?/1` + `effective_set/2`.
  @callback requires_explicit_behavior_set?() :: boolean()

  @optional_callbacks [
    uri_from_args: 1,
    snapshot_version: 0,
    supervisor: 0,
    spawn_strategy: 0,
    terminate_strategy: 0,
    holds_cap?: 2,
    requires_explicit_behavior_set?: 0,
    before_start: 1
  ]

  # C5 §3.4 — the `holds_cap?/default_holds_cap?` cap-policy block RELOCATED
  # OUT of this module into the core spine `Ezagent.Cap.HoldsCap` (it is cap
  # POLICY layered on the §2.2 public `read_classified/2` and struct-matches
  # `%Ezagent.Capability{}` — under the §3.4 opacity rule it can never live
  # in the actor app). These two delegates keep the established caller API;
  # the framework reaches the spine ONLY via the AuthzPort.
  @doc """
  Resolve `holds_cap?/2` for `kind_module`, defaulting to
  `default_holds_cap?/2` when the optional callback is not exported.

  This is the entry point dispatch step 5.5 uses — never call
  `kind_module.holds_cap?(...)` directly without going through this
  helper, or you skip the default impl for the (common) Kinds that
  haven't overridden it. Implementation: `Ezagent.Cap.HoldsCap.holds_cap?/3`
  (core spine, reached via the AuthzPort).
  """
  @spec holds_cap?(module(), URI.t() | String.t(), term()) :: boolean()
  def holds_cap?(kind_module, entity_uri, needed) when is_atom(kind_module),
    do: authz().holds_cap?(kind_module, entity_uri, needed)

  @doc """
  Default `holds_cap?/2` impl — used by `holds_cap?/3` when the target Kind
  module does not export the optional callback. Fail-LOUD on a transient
  identity read, never a silent deny. Implementation + the full
  fail-loud/not-deny contract: `Ezagent.Cap.HoldsCap.default_holds_cap?/2`
  (core spine, reached via the AuthzPort).
  """
  @spec default_holds_cap?(URI.t() | String.t() | :vm_internal | nil, term()) :: boolean()
  def default_holds_cap?(entity_uri, needed),
    do: authz().default_holds_cap?(entity_uri, needed)

  @doc """
  The SOLE programmatic entry for spawning a Kind process.

  `spawn/3` accepts only `launch_context: opaque_term`. Unknown options fail
  closed. The context is made available solely to `before_start/1` on the
  winning initial start; it is absent from behavior initialization, live state,
  snapshots, and permanent-child restarts.

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
        initial_caps: MapSet.new()
      })

      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{uri: session_uri})
  """
  @spec spawn(module(), map(), keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, [atom()]}
  def spawn(kind_module, params, opts \\ [])
      when is_atom(kind_module) and is_map(params) and is_list(opts) do
    with {:ok, validated_opts} <- Keyword.validate(opts, [:launch_context]) do
      strategy = spawn_strategy(kind_module)

      strategy =
        if strategy == :standard, do: {:standard, resolve_supervisor(kind_module)}, else: strategy

      Ezagent.Kind.Spawner.spawn(
        kind_module,
        params,
        validated_opts,
        strategy,
        &start_child/3,
        &await_ready_after_spawn/2
      )
    end
  end

  @doc """
  #201 PR-1 — like `spawn/3`, but surfaces BOTH ownership signals as a
  core-issued creation receipt:

      {:ok, :started, pid, %{created?: created?}}
      {:ok, :already_started, pid, %{created?: false}}
      {:error, term()}

  `:started` / `:already_started` is the atomic `DynamicSupervisor`
  winner verdict (exactly one concurrent caller wins `:started`).
  `created?` is the Lifecycle-owned logical-create verdict
  (`Ezagent.Lifecycle.fresh_create?/1`, durable `ever_created` marker),
  recorded by the fresh Kind's own `init/1` (before the marker write) and
  read back SYNCHRONOUSLY by the sole `:started` winner from this calling
  process — no message round-trip to the fresh Kind, no two-both-read
  race. The two signals are deliberately distinct: a cold rehydrate of a
  durably pre-existing Kind wins `:started` with `created?: false` (a
  duplicate-create attempt against it must NOT re-run create-only side
  effects like credential-grant minting).

  `created?` is meaningful only on `:started`; on `:already_started`
  this call did not create anything and `created?` is pinned `false`.

  The receipt is a plain synchronous return value — nothing is threaded
  through invocation/signal. Callers that only need the pid keep using
  `spawn/3`.
  """
  @spec spawn_receipt(module(), map(), keyword()) ::
          {:ok, :started | :already_started, pid(), %{created?: boolean()}}
          | {:error, term()}
  def spawn_receipt(kind_module, params, opts \\ [])
      when is_atom(kind_module) and is_map(params) and is_list(opts) do
    case spawn(kind_module, params, opts) do
      {:ok, pid} ->
        {:ok, :started, pid, %{created?: params_create_freshness(params) == :created}}

      {:error, {:already_started, pid}} ->
        {:ok, :already_started, pid, %{created?: false}}

      {:error, {:already_registered, _}} = err ->
        # Registry-dedup inside the loser's init (`ReadyTransition` /
        # `KindRegistry` collision): a live Kind already holds this URI, so
        # THIS call did not win the start. Resolve the live pid to report
        # the adoption; if the holder died in the race window, return the
        # original error (the caller retries).
        case existing_pid(params) do
          {:ok, pid} -> {:ok, :already_started, pid, %{created?: false}}
          :error -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp existing_pid(%{uri: %URI{} = uri}), do: Ezagent.KindRegistry.lookup(uri)
  defp existing_pid(_params), do: :error

  defp params_create_freshness(%{uri: %URI{} = uri}), do: create_freshness(uri)
  defp params_create_freshness(_params), do: :unknown

  @doc """
  #201 PR-1 — read the create-vs-activate verdict recorded by the CURRENT
  incarnation of the Kind at `uri` (`:created` = that incarnation's init saw
  no durable `ever_created` marker — a genuine logical create; `:existed` =
  rehydrate/activate of a durably pre-existing Kind; `:unknown` = never
  spawned this BEAM, or the verdict could not be read).

  This is an ETS read in the CALLING process, not a message to the Kind —
  see `Ezagent.Kind.CreateFreshness` for the happens-before argument. It is
  meaningful ONLY for the sole `:started` winner reading back its own spawn;
  any other reader may see a stale verdict from an earlier incarnation.

  Fail-CONSERVATIVE: an unknown/unreadable verdict is `:unknown` (never
  `:created`), so a caller gating create-only side effects on
  `create_freshness(uri) == :created` cannot be tricked into running them.
  """
  @spec create_freshness(URI.t() | String.t()) :: :created | :existed | :unknown
  def create_freshness(%URI{} = uri), do: Ezagent.Kind.CreateFreshness.lookup(URI.to_string(uri))

  def create_freshness(uri_str) when is_binary(uri_str),
    do: Ezagent.Kind.CreateFreshness.lookup(uri_str)

  defp start_child(kind_module, params, {:standard, supervisor}) do
    DynamicSupervisor.start_child(supervisor, {Ezagent.Kind.Server, {kind_module, params}})
  end

  defp start_child(_kind_module, params, {:custom, module, function}),
    do: apply(module, function, [params])

  # Only await when a process actually exists (fresh start OR idempotent
  # already-started). Other errors short-circuit. `params` without a `:uri`
  # (some custom-spawn shapes) is a no-op — those domains own their own
  # readiness sequencing.
  defp await_ready_after_spawn({:ok, _pid}, params), do: do_await_ready(params)

  defp await_ready_after_spawn({:error, {:already_started, _pid}}, params),
    do: do_await_ready(params)

  defp await_ready_after_spawn(_result, _params), do: :ok

  defp do_await_ready(%{uri: uri}) do
    timeout = Application.get_env(:ezagent_core, :spawn_await_ready_ms, 500)

    case Ezagent.ReadyGate.await(uri, timeout) do
      :ok ->
        :ok

      {:error, :timeout} ->
        require Logger

        Logger.warning(
          "Ezagent.Kind.spawn: #{inspect(uri)} not :ready within #{timeout}ms — " <>
            "returning anyway; the next synchronous dispatch may see :not_ready"
        )

        :ok
    end
  end

  defp do_await_ready(_params), do: :ok

  # Inlined to keep `spawn/2` flat. Defaults to `:standard` when the
  # Kind module hasn't exported `spawn_strategy/0` — backward-compat
  # with every pre-PR-EM-2 Kind.
  #
  # `Code.ensure_loaded?/1` BEFORE `function_exported?/3` (remediation SPEC
  # 2026-05-30): `function_exported?/3` returns `false` for a not-yet-loaded
  # module even when the callback IS defined. In a cold VM (or a test where
  # the Entity module hasn't been touched yet) the ExternalMirrorWorker
  # Entity's `{:custom, WorkerSpawn, :spawn_kind_server}` strategy was
  # silently missed → the Worker spawned via the `:standard` path under the
  # default KindSupervisor instead of the two-tier
  # RootSupervisor→PerBindingSupervisor, so `WorkerRegistry.lookup/1`
  # returned `:error` (the PerBindingSupervisor was never registered). The
  # ensure-loaded makes strategy resolution deterministic regardless of
  # module-load timing.
  defp spawn_strategy(kind_module) do
    if Code.ensure_loaded?(kind_module) and function_exported?(kind_module, :spawn_strategy, 0) do
      kind_module.spawn_strategy()
    else
      :standard
    end
  end

  # P5-0b accessors — extracted to `Ezagent.Kind.BehaviorSet` (oversized-module
  # arch gate, 2026-06-23). Kept as delegates so the public API + the in-module
  # callers (`effective_set/2`, `init_set/2`) are unchanged.
  @doc "Does `kind_module` require an explicit behavior set? (delegates to `Ezagent.Kind.BehaviorSet`.)"
  @spec requires_explicit_behavior_set?(module()) :: boolean()
  defdelegate requires_explicit_behavior_set?(kind_module), to: Ezagent.Kind.BehaviorSet

  @doc "Behavior set captured for a `nil` instance set (delegates to `Ezagent.Kind.BehaviorSet`)."
  @spec nil_capture_behavior_set(module()) :: [module()]
  defdelegate nil_capture_behavior_set(kind_module), to: Ezagent.Kind.BehaviorSet

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
  `:ok`. The return is honest: `:ok` means the resolved process is confirmed
  dead; a module-query, custom-teardown, fallback-exit, or liveness failure is
  returned as `{:error, reason}`. Callers that deliberately do not care about
  cleanup convergence must use `terminate!/1`.

  Standard `DynamicSupervisor.terminate_child/2` already blocks until the
  child is dead, so honesty adds no latency there. Only custom teardown and the
  direct-exit fallback use the short `:terminate_verify_ms` grace (default
  200ms); setting it to `0` performs one immediate liveness poll.

  Before process lookup, the URI is definitively marked failed and any
  `PendingDelivery` casts are dead-lettered. This prevents an authority-bearing
  absorb artifact queued for a failed incarnation from landing on a later entity
  recreated at the same URI.

  This terminates ONLY the Kind process. Lineage (`AgentLineage`) and
  workspace binding (`WorkspaceRegistry`) are Ezagent-domain registries —
  a plugin Template Class must NOT touch them (3-tier rule); the
  Ezagent-layer caller (`Ezagent.Entity.Agent.spawn_from_template_content/4`)
  owns undoing those.
  """
  @spec terminate(URI.t()) :: :ok | {:error, term()}
  def terminate(%URI{} = uri) do
    :ok = Ezagent.Kind.ReadyTransition.mark_failed(uri)

    with {:ok, pid} <- Ezagent.KindRegistry.lookup(uri),
         {:ok, kind_module} <- safe_kind_module(pid) do
      launch_context_relay = safe_launch_context_relay(pid)

      case terminate_strategy(kind_module) do
        :standard ->
          # #195 termination refactor: `Termination.standard/2` rolls the
          # not-found → `Process.exit` fallback inside and reports honest
          # `{:error, …}` on a still-alive process. main's launch-context
          # cleanup is preserved by discarding the relay once termination
          # succeeds; force_discard is idempotent.
          case Ezagent.Kind.Termination.standard(resolve_supervisor(kind_module), pid) do
            :ok ->
              discard_launch_context_relay(launch_context_relay)
              :ok

            {:error, _reason} = error ->
              error
          end

        {:custom, mod, fun} when is_atom(mod) and is_atom(fun) ->
          Ezagent.Kind.Termination.custom(mod, fun, uri, pid)
      end
    else
      :error -> :ok
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:terminate_crashed, error}}
  catch
    :exit, reason -> {:error, {:terminate_exit, reason}}
    kind, reason -> {:error, {:terminate_caught, kind, reason}}
  end

  @doc "Best-effort teardown for don't-care callers; always returns :ok."
  @spec terminate!(URI.t()) :: :ok
  def terminate!(%URI{} = uri) do
    _ = terminate(uri)
    :ok
  end

  defp safe_launch_context_relay(pid) do
    GenServer.call(pid, :ezagent_launch_context_relay)
  catch
    :exit, _reason -> nil
  end

  defp discard_launch_context_relay(nil), do: :ok

  defp discard_launch_context_relay(relay) do
    Ezagent.Kind.LaunchContextRelay.force_discard(relay)
  end

  defp terminate_strategy(kind_module) do
    if function_exported?(kind_module, :terminate_strategy, 0) do
      kind_module.terminate_strategy()
    else
      :standard
    end
  end

  @doc """
  RF-2 — MOUNT a Behavior onto a LIVE instance at runtime.

  Adds `behavior` to the instance's per-instance behavior set: materializes its
  slice (runs `create` + `activate` + `activated`, NOT just slice-init — codex
  HIGH-A), rewrites the persisted `:kind_base` capture so the change survives
  cold restart, and re-validates closure under required sibling reads. After a
  successful mount the behavior's actions dispatch on this instance (per RF-1's
  per-instance resolution) and its slice is non-empty.

  Synchronous `:call` — the single `Kind.Server` mailbox serializes mount with
  dispatch/detach. Validates BEFORE mutating; a rejected mount (not a real
  Behavior / would leave the set unclosed) returns `{:error, reason}` with the
  live instance unchanged. Idempotent (mounting a present behavior → `:ok`).

  `args` (default `%{}`) is merged with `%{uri: <instance uri>}` and passed to
  the behavior's create/activate, mirroring the spawn contract.
  """
  @spec mount(URI.t() | String.t(), module(), map()) :: :ok | {:error, term()}
  def mount(uri, behavior, args \\ %{})

  def mount(%URI{} = uri, behavior, args) when is_atom(behavior) and is_map(args) do
    with {:ok, pid} <- Ezagent.KindRegistry.lookup(uri) do
      GenServer.call(pid, {:ezagent_mount, behavior, args})
    end
  end

  def mount(uri_str, behavior, args) when is_binary(uri_str),
    do: mount(Ezagent.URI.new!(uri_str), behavior, args)

  @doc """
  RF-3 — DETACH a Behavior from a LIVE instance at runtime.

  Runs the behavior's optional `on_detach/2` per-behavior teardown (the seam
  designed for this — `deactivate`/`destroy` are WHOLE-ENTITY and cannot do
  per-behavior cleanup, codex HIGH-B), drops its slice, and rewrites the
  persisted `:kind_base` capture to exclude it. After a successful detach the
  behavior's actions no longer dispatch.

  REJECTS (reverse-closure) when a REMAINING behavior still REQUIRES the one
  being detached as a sibling read (`{:error, {:still_required, ...}}`), and
  refuses to detach a base behavior (`KindBase` / universal). Idempotent
  (detaching an absent behavior → `:ok`). Synchronous `:call` (serialized).
  """
  @spec detach(URI.t() | String.t(), module()) :: :ok | {:error, term()}
  def detach(%URI{} = uri, behavior) when is_atom(behavior) do
    with {:ok, pid} <- Ezagent.KindRegistry.lookup(uri) do
      GenServer.call(pid, {:ezagent_detach, behavior})
    end
  end

  def detach(uri_str, behavior) when is_binary(uri_str),
    do: detach(Ezagent.URI.new!(uri_str), behavior)

  # Slice cross-process reads + T3 normalization extracted to
  # `Ezagent.Kind.SliceAccess` (oversized-module arch gate, 2026-06-23).
  # `get_slice/2` + `get_raw_slice/2` retired from the public surface in C7
  # (chunks 4a/4b) — both live-slice accessors are framework-internal now;
  # callers use the §2.2 `read/3` surface below (`spawn: :never` mirrors the
  # old live-only `get_slice` contract).
  @doc "Normalize a two-container slice view to its state map (delegates to `Ezagent.Kind.SliceAccess`)."
  @spec normalize_slice_view(term()) :: term()
  defdelegate normalize_slice_view(slice), to: Ezagent.Kind.SliceAccess

  # ================================================================
  # SPEC 2026-07-23 §2.2 — actor-extraction PUBLIC READ SURFACE (C0)
  # ================================================================
  # Eight ADDITIVE entry points. Everything outside the future `ezagent_actor`
  # app must touch actor state ONLY through this surface; the boundary gate
  # (`test/invariants/actor_internals_boundary_test.exs`) enforces it. Each
  # wrapper COMPOSES existing internals with ZERO behavior change — existing
  # reach-in callers are NOT migrated here (later chunks C1–C6 do that).

  @doc """
  The authoritative read (§2.2). Returns a slice's consumer-facing value,
  spawning from durable state if the Kind is cold-but-created.

  1. Live process → the normalized live slice (exactly
     `Ezagent.Kind.SliceAccess.get_slice/2`).
  2. Cold but durably created → lazy-spawn via the framework's own rehydration
     path (`SpawnRegistry.ensure_live/1`, which refuses never-created URIs),
     await `ReadyGate`, then read live.
  3. Never durably created → `{:error, :not_created}`.
  4. Self-safe: when the caller IS the target's own process, a `GenServer.call`
     to self would deadlock, so the durable projection is served instead
     (correct for `{:snapshot, :on_change}` Kinds; the persisted view for others,
     same as today's `load_persisted` escape).
  5. `opts[:spawn]` — `:ensure` (default) lazy-spawns cold Kinds; `:never`
     returns `{:error, :not_live}` for probe-style callers that want only LIVE
     state (use `read_durable/3` for durable state without spawning).
  """
  @spec read(URI.t() | String.t(), atom(), keyword()) ::
          {:ok, term()} | {:error, :not_created | :not_live | term()}
  def read(uri, slice_key, opts \\ []) when is_atom(slice_key) and is_list(opts) do
    spawn_mode = Keyword.get(opts, :spawn, :ensure)

    cond do
      self?(uri) ->
        case read_durable(uri, slice_key) do
          {:ok, value, _meta} -> {:ok, value}
          {:error, reason} -> {:error, reason}
        end

      true ->
        case Ezagent.Kind.SliceAccess.get_slice(uri, slice_key) do
          {:ok, slice} -> {:ok, slice}
          {:error, :not_found} -> read_cold(uri, slice_key, spawn_mode)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read_cold(_uri, _slice_key, :never), do: {:error, :not_live}

  defp read_cold(uri, slice_key, :ensure) do
    case Ezagent.SpawnRegistry.ensure_live(to_uri(uri)) do
      {:ok, _live_or_rehydrated} ->
        # The actor MUST reach :ready before its slice is read — a rehydrated
        # actor whose post_init has not completed holds stale/empty state. A
        # readiness timeout is PROPAGATED, never papered over by reading a
        # non-ready actor (`ReadyGate.await/2` → `{:error, :timeout}`,
        # ready_gate.ex:134).
        case Ezagent.ReadyGate.await(uri) do
          :ok ->
            case Ezagent.Kind.SliceAccess.get_slice(uri, slice_key) do
              {:ok, slice} -> {:ok, slice}
              {:error, :not_found} -> {:error, :not_live}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, {:not_ready, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The authz-grade read (§2.2) — 3-way classification with bounded retry and
  `:not_found` durable-existence disambiguation. The generalization of
  `SliceAccess.read_identity_caps/1`; preserves the fail-LOUD-not-deny contract
  as a public primitive so the cap layer stops needing private slice/snapshot
  access. Does NOT spawn. Delegates to `Ezagent.Kind.SliceAccess`.
  """
  @spec read_classified(URI.t() | String.t(), atom()) ::
          {:ok, term()} | :absent | {:transient, term()}
  defdelegate read_classified(uri, slice_key), to: Ezagent.Kind.SliceAccess

  @doc """
  The durable projection for a single URI (§2.2). NEVER consults the live
  process — the answer is the snapshot row (decode + `normalize_slice_view/1`),
  deterministic and agreeing with `read_durable_many/3` by construction (same
  row, same decode). `{:ok, value, meta}` carries the row's `version` +
  `updated_at` so staleness is reasoned about explicitly at the call site.
  `{:error, :not_created}` when there is no durable row (including a live Kind
  whose policy has produced none yet — transients are absent by definition).
  """
  @spec read_durable(URI.t() | String.t(), atom(), keyword()) ::
          {:ok, term(), %{version: integer(), updated_at: DateTime.t()}}
          | {:error, :not_created | term()}
  def read_durable(uri, slice_key, opts \\ []) when is_atom(slice_key) and is_list(opts) do
    case Ezagent.Ecto.KindSnapshot.get(uri_to_string(uri)) do
      nil -> {:error, :not_created}
      row -> project_durable_row(row, slice_key)
    end
  end

  @doc """
  The batch durable projection — the list plane (§2.2). ONE store query over the
  snapshot rows (never per-URI spawns / GenServer calls / live overlay), a single
  consistent durable view. Per-URI results carry the same `meta` as `read_durable/3`;
  a URI with no durable row maps to `{:error, :not_created}`. Rendering N rows
  costs one query.
  """
  @spec read_durable_many([URI.t() | String.t()], atom(), keyword()) ::
          %{
            optional(URI.t() | String.t()) =>
              {:ok, term(), %{version: integer(), updated_at: DateTime.t()}}
              | {:error, :not_created | term()}
          }
  def read_durable_many(uris, slice_key, opts \\ [])
      when is_list(uris) and is_atom(slice_key) and is_list(opts) do
    rows_by_uri =
      uris
      |> Enum.map(&uri_to_string/1)
      |> Ezagent.Ecto.KindSnapshot.get_many()
      |> Map.new(&{&1.uri, &1})

    Map.new(uris, fn uri ->
      result =
        case Map.get(rows_by_uri, uri_to_string(uri)) do
          nil -> {:error, :not_created}
          row -> project_durable_row(row, slice_key)
        end

      {uri, result}
    end)
  end

  # Shared projection so single + batch durable reads agree by construction.
  defp project_durable_row(row, slice_key) do
    case Ezagent.Ecto.KindSnapshot.decode_state(row) do
      {:ok, state} ->
        value = normalize_slice_view(Map.get(state, slice_key))
        {:ok, value, %{version: row.version || 0, updated_at: row.updated_at}}

      :error ->
        {:error, :not_created}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolve which `{kind_module, behavior_module}` handles `action` on the live
  target (§2.2). Runs the behavior-set resolution INSIDE the actor and returns
  ONLY the two module atoms — never the slice map. The purpose-specific
  replacement for the raw `runtime_view` reach-through. Does NOT spawn;
  `{:error, :not_live}` when cold.
  """
  @spec resolve_action_subject(URI.t() | String.t() | pid(), atom()) ::
          {:ok, {module(), module()}} | {:error, :not_live | term()}
  def resolve_action_subject(pid, action) when is_pid(pid) and is_atom(action),
    do: GenServer.call(pid, {:ezagent_resolve_action_subject, action}, 5_000)

  def resolve_action_subject(uri, action) when is_atom(action) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} -> resolve_action_subject(pid, action)
      :error -> {:error, :not_live}
    end
  end

  @doc """
  Is the Kind for `uri` alive on this (its owner) runtime? (§2.2 — today
  `LocalRuntime.kind_alive?/1`, owner-gated.)
  """
  @spec alive?(URI.t()) :: boolean()
  def alive?(%URI{} = uri), do: Ezagent.LocalRuntime.kind_alive?(uri)

  @doc """
  Liveness-ONLY probe (§2.2): is a Kind process for `uri` registered
  locally? Unlike `alive?/1` this runs NO workspace owner gate — it is the
  public equivalent of the bare registry lookup for policy code that runs
  its OWN owner gate separately (e.g. `DispatchPolicyAdapter.before_delivery/1`,
  which owner-gates once after admin-cap materialization; routing its
  liveness probe through the owner-gated `alive?/1` would resolve
  ownership TWICE and open a placement-transition TOCTOU between the two
  reads). Never use this for respawn/placement decisions — those need the
  owner-gated `alive?/1`.
  """
  @spec alive_locally?(URI.t()) :: boolean()
  def alive_locally?(%URI{} = uri),
    do: match?({:ok, _pid}, Ezagent.KindRegistry.lookup(uri))

  @doc """
  Am I (the calling process) the target URI's own Kind process? (§2.2) — the
  self-detection the `EntityCaps` self-read case needs to avoid a self-call
  deadlock. `false` when no live process is registered for `uri`.
  """
  @spec self?(URI.t() | String.t()) :: boolean()
  def self?(uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} -> pid == self()
      :error -> false
    end
  end

  @doc """
  List every live Kind instance as `{uri_string, meta}` (§2.2 — the operator
  plane; the sole sanctioned `KindRegistry.list_all/0` wrapper). `meta` carries
  the registered `pid`.
  """
  @spec list_instances() :: [{String.t(), %{pid: pid()}}]
  def list_instances do
    Enum.map(Ezagent.KindRegistry.list_all(), fn {uri_str, pid} ->
      {uri_str, %{pid: pid}}
    end)
  end

  defp to_uri(%URI{} = uri), do: uri
  defp to_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_to_string(uri) when is_binary(uri), do: uri

  @doc "Return the live Kind metadata and slice map without private framework authority state."
  @spec runtime_view(pid() | URI.t() | String.t()) :: {:ok, map()} | {:error, term()}
  def runtime_view(pid) when is_pid(pid), do: GenServer.call(pid, :ezagent_runtime_view, 5_000)

  def runtime_view(uri) do
    with {:ok, pid} <- Ezagent.KindRegistry.lookup(uri) do
      runtime_view(pid)
    end
  end

  @doc false
  @spec recredential_generation(URI.t() | String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def recredential_generation(uri) do
    with {:ok, pid} <- Ezagent.KindRegistry.lookup(uri) do
      GenServer.call(pid, :ezagent_recredential_generation, 5_000)
    end
  end

  @doc "Return whether `observer` monitors a live process without exposing process state."
  @spec monitored_by?(pid(), pid()) :: boolean()
  def monitored_by?(pid, observer \\ self()) when is_pid(pid) and is_pid(observer) do
    case Process.info(pid, :monitored_by) do
      {:monitored_by, monitors} when is_list(monitors) -> observer in monitors
      _ -> false
    end
  end

  defp safe_kind_module(pid) when is_pid(pid) do
    {:ok, _} = GenServer.call(pid, :ezagent_kind_module, 5_000)
  rescue
    error -> {:error, {:module_query_crashed, error}}
  catch
    :exit, {:timeout, _} -> {:error, :module_query_timeout}
    :exit, reason -> {:error, {:module_query_exit, reason}}
    kind, reason -> {:error, {:module_query_caught, kind, reason}}
  end

  defp resolve_supervisor(kind_module) do
    if function_exported?(kind_module, :supervisor, 0) do
      kind_module.supervisor()
    else
      Ezagent.KindSupervisor
    end
  end

  # ---------------------------------------------------------------
  # SPEC 2026-05-28 Router/Behavior/Kind — new contract (additive)
  # ---------------------------------------------------------------
  #
  # `use Ezagent.Kind, pattern: ...` is the new declarative
  # entrypoint per SPEC §2.3. The legacy `@behaviour Ezagent.Kind`
  # callback shape (above) continues to work unmodified — the new
  # macro is purely additive.

  @typedoc """
  Composition pattern per SPEC §3.

  - `:session` — multi-participant, time-bounded context (`session://`)
  - `:entity` — named, authenticatable principal (`entity://`)
  - `:resource` — owned by an Entity; cold (default snapshot policy)
  - `{:resource, :hot}` — high-volume Resource; ephemeral by default
  - `{:resource, :hot, periodic: ms}` — opt-in periodic snapshot
  - `{:custom, hooks: [...], snapshot: policy}` — escape hatch (SPEC change required)
  """
  @type pattern ::
          :session
          | :entity
          | :resource
          | {:resource, :hot}
          | {:resource, :hot, [{:periodic, pos_integer()}]}
          | {:custom, keyword()}

  @doc """
  `use Ezagent.Kind, pattern: ..., supervisor: ...`
  — declarative Kind definition per SPEC §2.3.

  Required keyword options:

  - `pattern:` — one of `:session` / `:entity` / `:resource` /
    `{:resource, :hot, ...}` / `{:custom, ...}`. Compile-time
    pattern enforcement (OQ-2) lives in `attach_behavior`'s
    collision check.

  Optional keyword options:

  - `supervisor:` — module ref. Surfaced via the legacy `supervisor/0`
    callback. Default: `Ezagent.KindSupervisor`.
  - `type_name:` — atom for snapshots. Default: derived from module
    last segment (downcase + `_`).
  - `workspace_scoped?:` — boolean. Default `true`.

  ## Injects

  - `Module.register_attribute(__MODULE__, :ezagent_kind_attached, accumulate: true)`
  - `attach/2` macro for `attach Behavior, opts`
  - `@before_compile Ezagent.Kind` to:
    1. Run cross-Behavior action collision check (OQ-5)
    2. Enforce pattern → Behavior compatibility (OQ-2)
    3. Emit a `__pattern__/0`, `__attached__/0`
       set of introspection functions
  """
  defmacro __using__(opts) when is_list(opts) do
    pattern = Keyword.get(opts, :pattern)
    supervisor = Keyword.get(opts, :supervisor)
    type_name = Keyword.get(opts, :type_name)
    workspace_scoped = Keyword.get(opts, :workspace_scoped?, true)

    unless pattern do
      raise ArgumentError,
            "use Ezagent.Kind requires :pattern (got opts: #{inspect(opts)})"
    end

    validate_pattern!(pattern)

    quote do
      Module.register_attribute(__MODULE__, :ezagent_kind_attached, accumulate: true)
      Module.put_attribute(__MODULE__, :ezagent_kind_pattern, unquote(Macro.escape(pattern)))

      import Ezagent.Kind, only: [attach: 1, attach: 2]

      @before_compile Ezagent.Kind

      @doc false
      def __pattern__, do: unquote(Macro.escape(pattern))

      @doc false
      def __kind_workspace_scoped__?, do: unquote(workspace_scoped)

      # Pre-fill supervisor + type_name as overridable defaults so
      # the Kind author can still implement them by hand for full
      # control.
      unquote(maybe_inject_supervisor(supervisor))
      unquote(maybe_inject_type_name(type_name))

      @doc false
      def __kind__?, do: true
    end
  end

  defp validate_pattern!(:session), do: :ok
  defp validate_pattern!(:entity), do: :ok
  defp validate_pattern!(:resource), do: :ok
  defp validate_pattern!({:resource, :hot}), do: :ok
  defp validate_pattern!({:resource, :hot, opts}) when is_list(opts), do: :ok
  defp validate_pattern!({:custom, opts}) when is_list(opts), do: :ok

  defp validate_pattern!(other) do
    raise ArgumentError,
          "Ezagent.Kind: unknown :pattern value #{inspect(other)}. " <>
            "Expected :session / :entity / :resource / {:resource, :hot} / " <>
            "{:resource, :hot, [periodic: ms]} / {:custom, opts}"
  end

  defp maybe_inject_supervisor(nil), do: quote(do: nil)

  defp maybe_inject_supervisor(supervisor) do
    quote do
      def supervisor, do: unquote(supervisor)
      defoverridable supervisor: 0
    end
  end

  defp maybe_inject_type_name(nil), do: quote(do: nil)

  defp maybe_inject_type_name(type_name) do
    quote do
      def type_name, do: unquote(type_name)
      defoverridable type_name: 0
    end
  end

  @doc """
  Attach a Behavior to this Kind.

      attach Ezagent.ActionSet.Session,
        actions: [:send, :receive],
        init_state: %{members: %{}}

  Optional opts:
  - `actions:` — restrict which of the Behavior's declared actions
    are exposed on THIS Kind. Default: all of the Behavior's actions.
  - `init_state:` — map of initial state keys for the Kind. Default `%{}`.
  """
  defmacro attach(behavior_module, opts \\ []) do
    quote do
      @ezagent_kind_attached {unquote(behavior_module), unquote(opts)}
    end
  end

  # Phase 4 Item 3 (2026-05-28) — the `read_graph %{...}` macro and its
  # generated `__read_graph__/0` accessor were a planned Kind-level DSL
  # for declaring cross-Behavior read permissions. No Kind in the
  # codebase used it (rg `read_graph %{` returns only this file), and
  # the runtime authoritatively read sibling-slice permissions via the
  # per-Behavior `reads_sibling_slices/0` callback resolved by
  # `Ezagent.ActionSet.reads_sibling_slices_of/1`. The dual path was the
  # codex r3 finding on PR #458 ("two sources of truth, one of them
  # unused"). Macro + accessor removed; `reads_sibling_slices_of/1` is
  # the canonical and only source of truth. A future PR can re-add a
  # Kind-level read-graph DSL when it ALSO wires consumption in
  # `Kind.Runtime.maybe_inject_sibling_slices/3`.

  @doc false
  defmacro __before_compile__(env) do
    attached = Module.get_attribute(env.module, :ezagent_kind_attached) || []
    pattern = Module.get_attribute(env.module, :ezagent_kind_pattern)

    # ---- OQ-5: cross-Behavior action collision check ----
    #
    # Each Behavior declares actions; on attach, the Kind builds
    # an action → Behavior map. Collisions raise CompileError.
    {action_to_behavior, collisions} =
      Enum.reduce(attached, {%{}, []}, fn {behavior_mod, opts}, {acc, errs} ->
        declared_actions = action_names_of_behavior(behavior_mod)

        restricted_actions =
          case Keyword.get(opts, :actions) do
            nil -> declared_actions
            list when is_list(list) -> list
          end

        Enum.reduce(restricted_actions, {acc, errs}, fn action, {a2b, e} ->
          case Map.fetch(a2b, action) do
            {:ok, other_behavior} ->
              {a2b,
               [
                 "action :#{action} declared by both #{inspect(other_behavior)} " <>
                   "and #{inspect(behavior_mod)} on Kind #{inspect(env.module)}"
                 | e
               ]}

            :error ->
              {Map.put(a2b, action, behavior_mod), e}
          end
        end)
      end)

    unless collisions == [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "Ezagent.Kind action collision (OQ-5) on #{inspect(env.module)}:\n  " <>
            Enum.join(collisions, "\n  ")
    end

    # ---- OQ-2: compile-time pattern enforcement ----
    #
    # Entity-pattern Kinds: must not attach a Behavior that
    # declares Resource-lifecycle actions (`:cascade_destroy`).
    # Resource-pattern Kinds: must not attach a Behavior that
    # declares an Entity-only action (`:set_password`).
    #
    # The check is intentionally minimal in Phase 1 (only the
    # data_owner: shape is used as a structural hint). Phase 2
    # PRs will add stricter compatibility rules per pattern.
    Enum.each(attached, fn {behavior_mod, _opts} ->
      validate_pattern_compatibility!(env, pattern, behavior_mod)
    end)

    behavior_modules = Enum.map(attached, fn {b, _} -> b end) |> Enum.uniq()

    quote do
      @doc false
      def __attached__, do: unquote(Macro.escape(attached))

      @doc false
      def __attached_behaviors__, do: unquote(Macro.escape(behavior_modules))

      @doc false
      def __action_to_behavior__, do: unquote(Macro.escape(action_to_behavior))
    end
  end

  defp action_names_of_behavior(mod) when is_atom(mod) do
    Code.ensure_loaded(mod)

    cond do
      function_exported?(mod, :__action_names__, 0) ->
        apply(mod, :__action_names__, [])

      function_exported?(mod, :actions, 0) ->
        apply(mod, :actions, [])

      true ->
        []
    end
  end

  defp validate_pattern_compatibility!(env, pattern, behavior_mod) do
    Code.ensure_loaded(behavior_mod)

    # Pattern-specific structural checks. Stays liberal in Phase 1
    # — the strict per-pattern rules ship as Phase 2 PRs (per SPEC
    # §6.1 Phase 2).
    case pattern do
      :session ->
        :ok

      :entity ->
        :ok

      :resource ->
        :ok

      {:resource, :hot} ->
        :ok

      {:resource, :hot, _opts} ->
        :ok

      {:custom, _opts} ->
        :ok

      _ ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "Ezagent.Kind pattern compatibility: #{inspect(env.module)} has unknown pattern #{inspect(pattern)}"
    end
  end

  # RF-3 — the Kind-level `attach_behavior/2` runtime registration entry was
  # RETIRED here (it had NO runtime callers — only a unit test + a docstring
  # reference). Per-instance behavior loading is the supported path: a
  # recipe-loaded behavior dispatches via RF-1's per-instance resolution
  # without any Kind-level `{kind, action}` registration, and a behavior is
  # added/removed on a LIVE instance via `Ezagent.Kind.mount/2` /
  # `Ezagent.Kind.detach/2` (RF-2/RF-3). The compile-time declaration +
  # action-collision machinery (`attach/2`, `__before_compile__`,
  # `action_names_of_behavior/1`) is UNCHANGED — only the unused runtime
  # registration helper (+ its `collected_actions/1`) was removed.

  @spec new_style?(module()) :: boolean()
  defdelegate new_style?(mod), to: Ezagent.Kind.Introspection

  @spec pattern_of(module()) :: pattern() | nil
  defdelegate pattern_of(mod), to: Ezagent.Kind.Introspection

  @spec behaviors_of(module()) :: [module()]
  defdelegate behaviors_of(kind_module), to: Ezagent.Kind.Introspection

  @spec persistence_of(module()) :: persistence_policy()
  defdelegate persistence_of(kind_module), to: Ezagent.Kind.Introspection

  # C5 §3.4 AuthzPort — the holds-cap spine is reached through the
  # config-resolved port, never a literal core-module reference. Wired at
  # core boot (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.AuthzAdapter`.
  defp authz, do: Application.fetch_env!(:ezagent_actor, :authz)
end
