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

  1. Resolves the entity's caps via `Ezagent.Identity.list_caps_for/1`.
  2. Converts the `needed` `%Capability{}` into the 4-field map
     `Capability.matches?/2` consumes.
  3. Returns `true` iff any held cap matches.

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
  @callback holds_cap?(entity_uri :: URI.t() | String.t(), needed :: Ezagent.Capability.t()) ::
              boolean()

  @optional_callbacks [
    uri_from_args: 1,
    snapshot_version: 0,
    supervisor: 0,
    spawn_strategy: 0,
    terminate_strategy: 0,
    holds_cap?: 2
  ]

  @doc """
  Default `holds_cap?/2` impl — used by `Ezagent.Kind.holds_cap?/3`
  when the target Kind module does not export the optional callback.

  Reads the entity's caps via `Ezagent.Identity.list_caps_for/1` (which
  returns a `MapSet.t(Capability.t())`) and tests each against `needed`
  via `Capability.matches?/2`. Returns `false` on any error in the
  lookup path (per `feedback_let_it_crash_no_workarounds` — the dispatch
  step deny-by-default is the safer posture; a malformed slice is a bug
  for separate forensic investigation, not a permission grant).

  SPEC §3 default impl.
  """
  @spec default_holds_cap?(URI.t() | String.t() | :system | nil, Ezagent.Capability.t()) ::
          boolean()
  def default_holds_cap?(:system, %Ezagent.Capability{}), do: true

  def default_holds_cap?(nil, %Ezagent.Capability{}), do: false

  def default_holds_cap?(entity_uri, %Ezagent.Capability{} = needed) do
    needed_map = %{
      kind: needed.kind,
      behavior: needed.behavior,
      # SPEC 2026-05-27 capability-action-axis — propagate action axis
      # into the needed-map shape `Capability.matches?/2` consumes.
      action: Ezagent.Capability.action_of(needed),
      instance: needed.instance,
      workspace_uri: needed.workspace_uri
    }

    # Read the entity's `:identity` slice directly via `Kind.get_slice/2`
    # (a `GenServer.call` to the Kind.Server, NOT a re-entry into
    # `Invocation.dispatch/1`). This breaks the self-reference
    # recursion that an `Identity.list_caps_for/1`-based lookup would
    # otherwise introduce when step 5.5 runs against the User Kind's
    # own `:list_caps` action.
    #
    # Per the Behavior.Identity contract, the slice shape is
    # `%{caps: MapSet.t(Capability.t())}`. A missing / nil slice
    # (Kind not yet alive, or non-cap-bearing Kind) → no held caps →
    # deny-by-default per `feedback_let_it_crash_no_workarounds`.
    case get_slice(entity_uri, :identity) do
      {:ok, %{caps: caps}} when is_struct(caps, MapSet) ->
        Enum.any?(caps, fn held ->
          try do
            Ezagent.Capability.matches?(held, needed_map)
          rescue
            _ -> false
          catch
            _, _ -> false
          end
        end)

      _ ->
        false
    end
  end

  @doc """
  Resolve `holds_cap?/2` for `kind_module`, defaulting to
  `default_holds_cap?/2` when the optional callback is not exported.

  This is the entry point dispatch step 5.5 uses — never call
  `kind_module.holds_cap?(...)` directly without going through this
  helper, or you skip the default impl for the (common) Kinds that
  haven't overridden it.
  """
  @spec holds_cap?(module(), URI.t() | String.t(), Ezagent.Capability.t()) :: boolean()
  def holds_cap?(kind_module, entity_uri, %Ezagent.Capability{} = needed)
      when is_atom(kind_module) do
    if function_exported?(kind_module, :holds_cap?, 2) do
      kind_module.holds_cap?(entity_uri, needed)
    else
      default_holds_cap?(entity_uri, needed)
    end
  end

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
    strategy = spawn_strategy(kind_module)

    result =
      case strategy do
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

    # Readiness contract (remediation SPEC 2026-05-30 C-A): a `Kind.Server`
    # returns from `start_child` BEFORE its post-init/`activate` phase
    # completes (`handle_continue` runs async; ReadyGate stays `:not_ready`
    # through it — see `Kind.Server` invariant #3, external CALLS fail-fast
    # while not-ready). So a caller doing the natural `spawn` then
    # synchronous `dispatch` (`spawn_session(...) ; join(...)`, create→use,
    # template seed #50) raced the activate window and got
    # `{:error, :not_ready}`. We close the window at the SPAWN boundary
    # (NOT by buffering calls — that risks the re-entrant deadlock invariant
    # #3 deliberately avoids): await `:ready` here so every post-spawn
    # synchronous dispatch observes a fully-initialised Kind. Best-effort —
    # a genuinely slow/looping `activate` degrades to the prior behaviour
    # (logged; first dispatch may still see `:not_ready`) rather than failing
    # the spawn.
    #
    # `:standard`-strategy ONLY (remediation SPEC 2026-05-30, second pass):
    # `{:custom, …}` Kinds (today: ExternalMirrorWorker) own their OWN
    # readiness sequencing inside a domain supervision tree, and — critically
    # — their `activate` does a synchronous `:call` BACK to the Kind that
    # spawned them (the Worker subscribes to its Session Publisher). When the
    # spawning Kind runs `Kind.spawn(Worker)` from INSIDE its own
    # `handle_call` (the canonical `external_mirror.bind` flow), awaiting the
    # Worker's `:ready` here is a re-entrant DEADLOCK: spawn-await blocks the
    # Session while the Worker's `activate` subscribe `:call` blocks on that
    # same Session. The custom-spawn contract is "spawn returns immediately;
    # the Kind self-sequences its own post-spawn readiness/subscribe" — so we
    # do NOT await it. No caller synchronously dispatches to a freshly-spawned
    # custom Kind (the Worker is reached only via Publisher fan-out, which it
    # subscribes to itself), so the readiness window C-A closes does not apply.
    case strategy do
      :standard -> await_ready_after_spawn(result, params)
      _ -> :ok
    end

    result
  end

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

  ## Two-container normalization (Lifecycle Phase B foundation, T3)

  A Behavior converted to `use Ezagent.Lifecycle` stores its slice as the
  two-container shape `%{state: persistent, transients: volatile}` (SPEC
  2026-05-29 §0.1). Cross-module callers (`Ezagent.Identity`,
  `Ezagent.Behavior.ApiKeys`, `Ezagent.Behavior.ExternalMirror`,
  `Ezagent.Entity.Session`, the admin LVs, …) read a converted producer's
  slice via FLAT field access — e.g. `get_slice(uri, :chat).owner_uri`.
  Returning the raw two-container map would make every such field resolve
  to `nil` (the flat field lives under `:state`, not at the top level) —
  a silent-nil that corrupts the consumer without crashing.

  `get_slice/2` therefore returns the `:state` view at this single
  chokepoint when the slice is two-container, and the slice UNCHANGED when
  it is legacy-flat. This makes a converted producer transparent to all
  consumers (the Phase-A sibling-normalization precedent, generalized to
  the cross-process read path) — the consumer never learns whether the
  producer migrated. This is NOT a back-compat shim: it turns a
  silent-nil into the correct durable data (`feedback_let_it_crash_no_workarounds`).
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
          {:ok, normalize_slice_view(slice)}
        catch
          :exit, reason -> {:error, {:get_slice_exit, reason}}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Read a slice WITHOUT the T3 two-container normalization — the RAW slice
  as the host GenServer holds it.

  For a converted Lifecycle Behavior this returns the full
  `%{state: persistent, transients: volatile}` map (NOT the flattened
  `:state` view that `get_slice/2` returns). This is the introspection
  path the Lifecycle test infrastructure
  (`Ezagent.LifecycleCase.assert_transients_rebuilt/2`) needs to assert on
  the `transients` container — a normalized read would hide it.

  Production cross-module consumers want the flat `.state` view and MUST
  use `get_slice/2`; this raw variant exists for test infra + any rare
  caller that legitimately needs to see the container split.
  """
  @spec get_raw_slice(URI.t() | String.t(), atom()) ::
          {:ok, term()} | {:error, term()}
  def get_raw_slice(uri, slice_key) when is_atom(slice_key) do
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

  @doc """
  Normalize a slice to its consumer-facing flat view (T3).

  A converted Lifecycle slice is `%{state: persistent, transients:
  volatile}`; cross-module consumers want the `state` map. A legacy flat
  slice has no `:transients` sub-key and passes through unchanged. The
  detection is purely structural (a map carrying BOTH `:state` and
  `:transients` keys), so no engine/Behavior coupling is introduced —
  symmetric with `Ezagent.Kind.Snapshot.strip_transients/1`.

  Exposed (not private) so the persisted-snapshot read path
  (`McpServer.load_chat_slice` and any other `decode_state`-then-read
  consumer) can apply the SAME normalization to an on-disk slice that a
  converted Kind wrote in the two-container shape.

  ## Persisted shape (the transients-stripped case)

  The in-MEMORY converted slice is `%{state, transients}`. But the snapshot
  persist path strips `:transients` (`Ezagent.Kind.Snapshot.strip_transients/1`),
  so the ON-DISK slice is a single-key `%{state: persistent}` with NO
  `:transients`. The first clause (both keys present) therefore does NOT match a
  persisted slice — hence the second clause below, which unwraps a single-key
  `%{state: map}`. Without it, a `decode_state`-then-read consumer reads the
  wrapped shape and finds none of the persistent fields (the regression that
  broke orchestrator MCP registration + Feishu mirror #502).

  > CONSTRAINT for Kind authors: a Kind's flat persistent state must NEVER be a
  > bare single-key `%{state: map}`, or it would be wrongly unwrapped here. (All
  > current Kinds' flat states are multi-key or `%{caps: ...}`/`%{content:
  > ...}`/`%{}` — verified.)
  """
  @spec normalize_slice_view(term()) :: term()
  def normalize_slice_view(%{state: state, transients: _transients}) when is_map(state),
    do: state

  # Persisted (transients-stripped) two-container slice: a single-key
  # `%{state: map}`. The `map_size == 1` guard matches ONLY this exact shape,
  # never a legacy-flat slice that merely carries a `:state` field among others.
  def normalize_slice_view(%{state: state} = slice) when is_map(state) and map_size(slice) == 1,
    do: state

  def normalize_slice_view(slice), do: slice

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

      attach Ezagent.Behavior.Chat,
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
  # `Ezagent.Behavior.reads_sibling_slices_of/1`. The dual path was the
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

  @doc """
  Top-level entry for attaching a Behavior to a Kind from outside
  the Kind's module body (e.g. from a plugin module). Performs
  the same collision check as `attach/2` but at runtime — emits
  an error if a collision is detected.

  Phase 1 implementation: registers via the existing
  `Ezagent.BehaviorRegistry.register/3` using the Behavior's
  declared actions.
  """
  @spec attach_behavior(module(), to: module()) :: :ok | {:error, term()}
  def attach_behavior(behavior_module, to: kind_module)
      when is_atom(behavior_module) and is_atom(kind_module) do
    actions = action_names_of_behavior(behavior_module)

    # Detect collision with already-registered Behaviors on this Kind.
    existing = collected_actions(kind_module)

    case Enum.find(actions, &Map.has_key?(existing, &1)) do
      nil ->
        # Route through CapabilityRegistry (SPEC 2026-05-23) — the
        # single canonical chokepoint for BehaviorRegistry +
        # CapSubject co-registration. Direct BehaviorRegistry.register/3
        # is blocked by the invariant.
        Enum.each(actions, fn action ->
          :ok = Ezagent.CapabilityRegistry.register(kind_module, action, behavior_module)
        end)

        :ok

      colliding ->
        {:error,
         {:action_collision, colliding, existing[colliding], behavior_module, kind_module}}
    end
  end

  defp collected_actions(kind_module) do
    cond do
      function_exported?(kind_module, :__action_to_behavior__, 0) ->
        apply(kind_module, :__action_to_behavior__, [])

      function_exported?(kind_module, :behaviors, 0) ->
        kind_module.behaviors()
        |> Enum.flat_map(fn b -> Enum.map(action_names_of_behavior(b), &{&1, b}) end)
        |> Map.new()

      true ->
        %{}
    end
  end

  @doc """
  Is the given module a new-style Kind (declared via `use
  Ezagent.Kind`)?
  """
  @spec new_style?(module()) :: boolean()
  def new_style?(mod) when is_atom(mod) do
    function_exported?(mod, :__kind__?, 0) and apply(mod, :__kind__?, [])
  end

  @doc """
  Returns the SPEC §3 pattern for this Kind, or `nil` if the
  Kind doesn't use the new contract.
  """
  @spec pattern_of(module()) :: pattern() | nil
  def pattern_of(mod) when is_atom(mod) do
    if function_exported?(mod, :__pattern__, 0) do
      apply(mod, :__pattern__, [])
    end
  end

  # ---------------------------------------------------------------------
  # Phase 4 Item 1 (2026-05-28) — unified attach-metadata accessors.
  #
  # Background: a Kind module may declare its Behaviors via TWO paths:
  #
  #   - The legacy `@behaviour Ezagent.Kind` + explicit `def behaviors/0`
  #     callback (every Kind in `apps/ezagent_domain_*` uses this).
  #   - The new `use Ezagent.Kind, pattern: ...` + `attach Behavior, ...`
  #     DSL, which auto-generates `__attached_behaviors__/0`.
  #
  # Plugin Kinds (Echo, CurlAgent, NpAgent) use BOTH simultaneously — they
  # `use Ezagent.Kind` AND keep `def behaviors/0` for explicit clarity.
  # Pre-PR-464 (Phase 3) the two could silently drift: Kind.Server +
  # Kind.Runtime called `kind.behaviors()` (explicit), the registry
  # introspection called `__attached__()` (macro). codex r3 on PR #458
  # flagged the dual-source-of-truth.
  #
  # `behaviors_of/1` is the canonical accessor for runtime consumers.
  # When BOTH paths are exported AND disagree, we PREFER the macro
  # metadata (`__attached_behaviors__/0` — what the compile-time DSL
  # actually produced + verified for collisions) and log a warning so
  # the drift surfaces in dev logs without crashing the live system.
  # ---------------------------------------------------------------------

  @doc """
  Return the list of Behaviors attached to this Kind.

  Prefers the macro-generated `__attached_behaviors__/0` (produced by
  `use Ezagent.Kind` + `attach`) when available. Falls back to the
  explicit `behaviors/0` callback for Kinds that don't yet use the
  DSL. When BOTH are present AND their lists differ, the macro list
  wins and a `Logger.warning/1` records the drift so the author sees
  it in dev logs.
  """
  @spec behaviors_of(module()) :: [module()]
  def behaviors_of(kind_module) when is_atom(kind_module) do
    has_attach? = function_exported?(kind_module, :__attached_behaviors__, 0)
    has_callback? = function_exported?(kind_module, :behaviors, 0)

    cond do
      has_attach? and has_callback? ->
        attach_list = apply(kind_module, :__attached_behaviors__, [])
        callback_list = apply(kind_module, :behaviors, [])

        if MapSet.new(attach_list) != MapSet.new(callback_list) do
          require Logger

          Logger.warning(
            "Ezagent.Kind.behaviors_of/1: " <>
              "#{inspect(kind_module)} declares Behaviors via BOTH `use Ezagent.Kind` + " <>
              "`attach` (#{inspect(attach_list)}) AND `def behaviors/0` " <>
              "(#{inspect(callback_list)}); the two sets differ. Preferring the " <>
              "attach-metadata list (compile-time verified for action collisions). " <>
              "Reconcile by removing `def behaviors/0` or updating the `attach` block."
          )
        end

        attach_list

      has_attach? ->
        apply(kind_module, :__attached_behaviors__, [])

      has_callback? ->
        apply(kind_module, :behaviors, [])

      true ->
        []
    end
  end

  @doc """
  Return the persistence strategy declared by this Kind.

  Today every Kind exports `def persistence/0` explicitly (the
  `use Ezagent.Kind` macro does not inject it — there's no sensible
  default). This accessor exists for symmetry with `behaviors_of/1`
  so runtime call sites read a single uniform API; a future PR that
  teaches the macro to inject persistence via `use Ezagent.Kind,
  persistence: ...` won't need to touch every consumer.
  """
  @spec persistence_of(module()) :: persistence_policy()
  def persistence_of(kind_module) when is_atom(kind_module) do
    kind_module.persistence()
  end
end
