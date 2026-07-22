defmodule Ezagent.Lifecycle do
  @moduledoc """
  `use Ezagent.Lifecycle` — the agent-SDK-shaped developer API that hides
  the CQRS engine (slice / invocation / snapshot / persistence-strategy)
  behind two state containers and a small set of lifecycle moments.

  SPEC: `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md`.
  This module is the Phase A foundation — the macro + the engine wiring.
  Phase B migrates the 23 developer Behaviors; Phase C flips the grep
  gates. Phase A is **additive**: `Ezagent.ActionSet` stays as the
  internal engine contract (§10-R3) and every existing Behavior keeps
  working through the old surface unchanged.

  ## Compile-down (SPEC §3 / §10-R3)

  `use Ezagent.Lifecycle` is a thin code generator over `use
  Ezagent.ActionSet`. It emits `@behaviour Ezagent.ActionSet` + the engine
  callbacks UNDERNEATH so the engine (`Kind.Server` / `Kind.Runtime` /
  `SnapshotStore`) sees exactly the shape it sees today. The developer
  never names a slice, an invocation, or a snapshot.

  ### Developer hook → engine callback mapping

  | Developer hook (this module) | Engine callback emitted | When |
  |---|---|---|
  | `create/1` | `init_slice/1` (persistent fields only) | first-ever existence |
  | `activate/2` | `post_init/2` → `{:continue, :ezagent_activate}` + `handle_continue/3` | every start, PRE-`:ready` |
  | `handle_<action>/2` | `handle_<action>/2` (unchanged) | per dispatched action |
  | `deactivate/2` | `terminate/3` (graceful path) | graceful stop, entity persists |
  | `destroy/2` | `terminate/3` (destroy path) + clears `state` + flips marker | permanent deletion |
  | `activated/2` | `on_ready/2` | every start, POST-`:ready` (§10-R1) |
  | `handle_signal/2` | `handle_kind_message/3` | `:DOWN` / PubSub deliveries |
  | `pre_handle/3` / `post_handle/4` | wired in `Ezagent.Kind.Runtime` around the handler dispatch (probed via `function_exported?/3`) | cross-cutting, per dispatched action |

  ## Two-container state (SPEC §0.1 / §2.1)

  A Lifecycle module's slice is physically `%{state: map(), transients:
  map()}`:

  - `state` — PERSISTENT. The framework auto-snapshots it (and ONLY it).
  - `transients` — NEVER persisted. PIDs / refs / ETS handles / ports /
    monitor refs. Rebuilt from scratch on every `activate`.

  The split is enforced structurally: `Ezagent.Kind.Snapshot.strip_transients/1`
  drops the `:transients` sub-key at the single serialize boundary, so a
  transient CANNOT be accidentally persisted, and `activate/2` is the
  ONLY place it can be (re)built, so it CANNOT be forgotten on restart.

  ## The ever-created marker (SPEC §9 OQ-1)

  `create/1` runs ONCE in the entity's history; `activate/2` every start.
  The durable marker is the dedicated `kind_snapshots.ever_created`
  column (decision (b), not a reserved state key). See
  `Ezagent.Ecto.KindSnapshot.ever_created?/1` + `mark_ever_created/1`.
  """

  # ---------------------------------------------------------------
  # Developer-facing callbacks (the Lifecycle contract — SPEC §2).
  # All OPTIONAL except `handle_<action>/2` (enforced by the
  # `Ezagent.ActionSet` `action/3` @before_compile). The macro injects
  # overridable defaults for every coarse + fine hook so a module that
  # omits one compiles cleanly.
  # ---------------------------------------------------------------

  @type state :: map()
  @type transients :: map()
  @type ctx :: map()

  @doc """
  `create/1` — FIRST-EVER existence of this URI. Runs ONCE in the
  entity's entire history (gated by the persisted ever-created marker).
  Build the initial PERSISTENT `state`. MUST NOT build transients.
  """
  @callback create(args :: map()) :: {:ok, state()} | {:error, term()}

  @doc """
  `activate/2` — EVERY process (re)start (OTP `init/1` semantics):
  fresh spawn, supervisor restart, AND cold-load-from-snapshot. The
  UNIFIED start hook — rebuild ALL transients here from `state`. May
  reconcile `state` against an external SoT via the 3-arity return.
  Runs PRE-`:ready`.
  """
  @callback activate(state :: state(), ctx :: ctx()) ::
              {:ok, transients()}
              | {:ok, transients(), state()}
              | {:error, term()}

  @doc """
  `deactivate/2` — graceful stop; the ENTITY PERSISTS (NOT destroy).
  Flush buffers / close handles politely. Best-effort (OTP terminate
  semantics — NOT called on a brutal kill / VM crash; `activate/2`
  self-heals).

  ## Contract: `:ok`-only — deactivate CANNOT mutate persisted state (F5)

  `deactivate/2` runs through OTP `terminate/3`, which fires AFTER the
  final persistence snapshot has already been written (`:on_terminate`
  saves above the per-Behavior terminate drain; `:on_change` / `:periodic`
  persisted on the last mutation). A state mutation returned here could
  NOT be reliably persisted (the snapshot is already on disk, and on a
  brutal kill this hook never runs at all). Returning a new state would
  therefore be a silent no-op or a torn write — a contradictory contract.

  We resolve it by making `deactivate/2` `:ok`-only: it is for
  side-effecting graceful cleanup (flush a buffer to an EXTERNAL system,
  close a handle politely), not for mutating the entity's own persisted
  `state`. Durable state changes belong in a `handle_<action>` (effects)
  or in `activate/2`'s reconciliation return.
  """
  @callback deactivate(reason :: term(), ctx :: ctx()) :: :ok

  @doc """
  `destroy/2` — PERMANENT deletion of the entity. The framework clears
  `state` from disk and flips the ever-created marker off afterward.
  Best-effort — cleanup that MUST happen even on a brutal kill belongs
  in the next incarnation's `activate/2` self-heal, not solely here.
  """
  @callback destroy(reason :: term(), ctx :: ctx()) :: :ok

  @doc """
  `activated/2` — post-`:ready` hook (SPEC §10-R1 / §9 OQ-5). Where
  self-deferred-post-ready work goes (e.g. a "I'm reachable" broadcast
  that invites a peer `:call` round-trip). Compiles down to the engine's
  `on_ready/2` (runs AFTER the `ReadyGate` flip). NOT `activate`.
  """
  @callback activated(state :: state(), ctx :: ctx()) :: :ok

  @doc """
  `detached/2` — RF-3 per-behavior teardown hook. Runs when THIS behavior is
  DETACHED from a LIVE instance (`Ezagent.Kind.detach/2`). Side-effecting
  cleanup of TRANSIENT handles (close a transport, release a port, deregister
  from an ETS index, broadcast a "going away" notice). `:ok`-only — the
  framework DROPS the slice afterward, so a returned state is discarded.
  Compiles down to the engine's `on_detach/2`. The whole-entity `deactivate`
  (graceful stop) / `destroy` (permanent deletion) are distinct: detaching one
  behavior leaves the entity + its other behaviors running.
  """
  @callback detached(state :: state(), ctx :: ctx()) :: :ok

  @doc """
  `handle_signal/2` — non-action GenServer messages (`:DOWN`, PubSub
  deliveries). Returns the same effect list as `handle_<action>/2` (so a
  `:DOWN` returns `{:set_transient, :monitors, ...}` + `{:set,
  :last_seen, ...}`). Successor to the engine's `handle_kind_message/3`.
  """
  @callback handle_signal(message :: term(), ctx :: ctx()) ::
              {:ok, [Ezagent.ActionSet.effect()]} | :ignore

  @doc """
  `pre_handle/3` — fine interception BEFORE the matched
  `handle_<action>`. See SPEC §2 for the return grammar.
  """
  @callback pre_handle(action :: atom(), args :: map(), ctx :: ctx()) ::
              :cont | {:cont, map()} | {:halt, term()} | {:error, term()}

  @doc """
  `post_handle/4` — fine interception AFTER `handle_<action>` returns,
  BEFORE the effect list executes. May inject/append effects.
  """
  @callback post_handle(
              action :: atom(),
              result :: term(),
              effects :: [Ezagent.ActionSet.effect()],
              ctx :: ctx()
            ) :: {:ok, term(), [Ezagent.ActionSet.effect()]} | :cont

  @optional_callbacks [
    create: 1,
    activate: 2,
    deactivate: 2,
    destroy: 2,
    activated: 2,
    detached: 2,
    handle_signal: 2,
    pre_handle: 3,
    post_handle: 4
  ]

  @doc """
  `use Ezagent.Lifecycle` — opt into the Lifecycle developer API.

  Options:

  - `state_slice:` — override the auto-derived slice key (the snapshot-
    compatibility escape hatch, SPEC §5 / §7 OQ-7). When given, the
    module MUST carry a `# lifecycle:state_slice_override` marker comment
    (the Phase C grep gate sanctions only marked overrides). When
    omitted, the slice key is derived from the module's last segment
    (`Ezagent.Lifecycle.Chat` → `:chat`).
  """
  defmacro __using__(opts) when is_list(opts) do
    state_slice_override = Keyword.get(opts, :state_slice)

    quote do
      # The engine contract — compile-down target (§10-R3). `use
      # Ezagent.ActionSet` injects `action/3`, `@before_compile
      # Ezagent.ActionSet`, and the `__behavior__?/0` marker the runtime
      # dispatches through.
      use Ezagent.ActionSet
      @behaviour Ezagent.ActionSet
      @behaviour Ezagent.Lifecycle

      # The Lifecycle-surface sibling-read declaration (SPEC §2.2). A
      # converted module writes `reads_siblings [:api_keys]`; this emits
      # `def reads_siblings, do: [:api_keys]` which the runtime reads via
      # `Ezagent.ActionSet.reads_siblings_of/1` to surface `ctx.siblings`.
      import Ezagent.Lifecycle, only: [reads_siblings: 1]

      # Auto-derive `state_slice/0` from the module name unless an
      # explicit override is supplied (snapshot-compat hatch). The
      # override path is overridable so the author may still hand-roll it.
      @ezagent_lifecycle_state_slice_override unquote(state_slice_override)

      @impl Ezagent.ActionSet
      def state_slice do
        Ezagent.Lifecycle.__derive_state_slice__(
          __MODULE__,
          @ezagent_lifecycle_state_slice_override
        )
      end

      defoverridable state_slice: 0

      # ---- Engine boot wiring (SPEC §3 mapping table) ----
      #
      # init_slice/1 builds the TWO-CONTAINER slice. `state` comes from
      # create/1 on first-ever existence (gated by the ever-created
      # marker); on cold-load the snapshot merge shadows it with the
      # rehydrated `state` (`Kind.Snapshot.load_with_fallback`). The
      # `transients` container always starts EMPTY here and is filled by
      # activate/2 in the post_init continuation — that is the structural
      # guarantee that a transient is rebuilt on every start.
      @impl Ezagent.ActionSet
      def init_slice(args) do
        Ezagent.Lifecycle.__init_slice__(__MODULE__, args)
      end

      # post_init/2 schedules the unified activate step. Always emitted
      # (the engine probes function_exported?/3) so EVERY Lifecycle
      # module rebuilds transients on every start with no author opt-in.
      @impl Ezagent.ActionSet
      def post_init(_args, _slice), do: {:continue, :ezagent_activate}

      # handle_continue/3 runs the author's activate/2 and writes the
      # rebuilt transients (+ any reconciled state) back into the
      # two-container slice. Runs PRE-`:ready` (§10-R1).
      @impl Ezagent.ActionSet
      def handle_continue(:ezagent_activate, slice, ctx) do
        Ezagent.Lifecycle.__run_activate__(__MODULE__, slice, ctx)
      end

      # terminate/3 → deactivate/2 (graceful stop, entity persists).
      # `deactivate/2` is `:ok`-only (F5): it runs AFTER the final
      # persistence snapshot is already on disk, so any returned value is
      # DISCARDED by `__run_deactivate__/4` and the slice is left
      # unchanged. It is for side-effecting graceful cleanup, never a
      # (torn) state write — durable changes belong in a `handle_<action>`
      # or in `activate/2`'s reconciliation return.
      #
      # The DESTROY (permanent deletion) path is DISTINCT — it does NOT
      # run through OTP `terminate/3` (which fires on every graceful stop,
      # including idle-eviction where the entity persists). It is driven
      # explicitly by `Ezagent.Lifecycle.destroy/2`, which calls the
      # macro-emitted `__ezagent_lifecycle_destroy__/3` convention BELOW
      # so the author's `destroy/2` runs (in the Kind's own process, with
      # its slice) BEFORE the framework clears durable `state` + the
      # ever-created marker. This is the engine's destroy-vs-deactivate
      # signal (§2 + §OTP): graceful stop → `terminate/3` → `deactivate`;
      # permanent deletion → explicit destroy call → `destroy`.
      @impl Ezagent.ActionSet
      def terminate(reason, slice, ctx) do
        Ezagent.Lifecycle.__run_deactivate__(__MODULE__, reason, slice, ctx)
      end

      # Destroy convention — probed by `Ezagent.Kind.Server` via
      # `function_exported?/3` during the explicit destroy path. Runs the
      # author's `destroy/2` hook with the live slice's `:state` view; the
      # framework clears durable state + the marker AFTER this returns.
      @doc false
      def __ezagent_lifecycle_destroy__(reason, slice, ctx) do
        Ezagent.Lifecycle.__run_destroy__(__MODULE__, reason, slice, ctx)
      end

      # handle_kind_message/3 → handle_signal/2 (§9 OQ-3). The signal
      # returns the same effect list as a handler; the macro reduces it
      # into the two-container slice via apply_effects/2.
      #
      # NOTE: `handle_kind_message/3` is a convention probed by
      # `Kind.Server` via `function_exported?/3`, NOT a formal
      # `@callback` on `Ezagent.ActionSet`, so no `@impl` annotation.
      def handle_kind_message(message, slice, ctx) do
        Ezagent.Lifecycle.__run_signal__(__MODULE__, message, slice, ctx)
      end

      # on_ready/2 → activated/2 (§9 OQ-5, post-`:ready`).
      @impl Ezagent.ActionSet
      def on_ready(slice, ctx) do
        Ezagent.Lifecycle.__run_activated__(__MODULE__, slice, ctx)
      end

      # on_detach/2 → detached/2 (RF-3, runtime per-behavior teardown). Runs
      # the author's `detached/2` hook (side-effecting cleanup of TRANSIENT
      # handles) when this behavior is detached from a LIVE instance. The
      # framework drops the slice afterward, so the return is :ok-only.
      @impl Ezagent.ActionSet
      def on_detach(slice, ctx) do
        Ezagent.Lifecycle.__run_detached__(__MODULE__, slice, ctx)
      end

      # ---- Overridable developer-hook defaults (SPEC §2.3 — a module
      # may omit any of these) ----
      def create(_args), do: {:ok, %{}}
      def activate(_state, _ctx), do: {:ok, %{}}
      def deactivate(_reason, _ctx), do: :ok
      def destroy(_reason, _ctx), do: :ok
      def activated(_state, _ctx), do: :ok
      def detached(_state, _ctx), do: :ok
      def handle_signal(_message, _ctx), do: :ignore

      defoverridable create: 1,
                     activate: 2,
                     deactivate: 2,
                     destroy: 2,
                     activated: 2,
                     detached: 2,
                     handle_signal: 2
    end
  end

  @doc """
  `reads_siblings [:api_keys]` — declare the sibling state keys this
  Lifecycle module reads (SPEC §2.2). Surfaced on `ctx.siblings`
  (normalized to each sibling's persistent flat view). Same opt-in /
  scoping as the legacy `reads_sibling_slices/0`.
  """
  defmacro reads_siblings(keys) do
    quote do
      @impl Ezagent.ActionSet
      def reads_siblings, do: unquote(keys)
    end
  end

  # ---------------------------------------------------------------
  # Runtime helpers invoked by the macro-emitted callbacks. Kept as
  # functions (not inlined into the quote) so the generated module body
  # stays small + the logic is unit-testable directly.
  # ---------------------------------------------------------------

  @doc false
  @spec __derive_state_slice__(module(), atom() | nil) :: atom()
  def __derive_state_slice__(_module, override) when is_atom(override) and not is_nil(override),
    do: override

  def __derive_state_slice__(module, _nil) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  @doc false
  @spec __init_slice__(module(), map()) :: %{state: map(), transients: map()}
  def __init_slice__(module, args) do
    # Create-once semantics (SPEC §9 OQ-1). The durable ever-created
    # marker (`kind_snapshots.ever_created`) is the source of truth:
    #   - never-created → run `create/1` to build the initial state.
    #   - already-created → SKIP `create/1`; the snapshot merge in
    #     `Kind.Snapshot.load_with_fallback` shadows this empty state
    #     with the rehydrated `state` sub-key anyway, so re-running
    #     `create` would be wasted work (and is semantically wrong for a
    #     `create` an author intended to run once). `transients` is
    #     ALWAYS empty here; `activate/2` fills it on every start.
    if ever_created?(args) do
      %{state: %{}, transients: %{}}
    else
      {:ok, st} = module.create(args)
      %{state: st, transients: %{}}
    end
  end

  @doc """
  Public create-vs-activate signal (#533 5a). Returns `true` iff `target`
  (a `%URI{}`, a URI string, or an args map carrying `:uri`) has NOT yet
  been durably created — i.e. THIS boot's `init` will run `create/1` (a
  fresh create) rather than `activate/2` (rehydrate of an existing Kind).

  This is the single **Lifecycle-owned** source of the freshness signal
  the engine keys decisions off — e.g. the create-entry's manage-cap
  grant (#533 §3.1). It MUST be read BEFORE the initial-snapshot persist
  sets the `ever_created` marker (`Kind.Server.init/1` does this between
  `KindRegistry.put_new` and `persist_initial_snapshot`).

  Callers MUST NOT re-derive freshness by reading the snapshot table
  (`KindSnapshot.ever_created?`), `Repo`, or a save return value directly
  — go through this Lifecycle function so the create/activate decision has
  exactly one definition and cannot drift.
  """
  @spec fresh_create?(URI.t() | String.t() | map()) :: boolean()
  def fresh_create?(%URI{} = uri), do: fresh_create?(URI.to_string(uri))
  def fresh_create?(uri_str) when is_binary(uri_str), do: not marker_lookup(uri_str)
  def fresh_create?(%{uri: uri}), do: fresh_create?(uri)
  def fresh_create?(_), do: true

  @doc """
  Metadata predicate: does `kind_module` host at least one Lifecycle
  behaviour — one that `use Ezagent.Lifecycle` (detected by the injected
  `__ezagent_lifecycle_destroy__/3`)?

  Use this — NOT a runtime check for a `:transients` sub-key in the slice
  — to decide whether a Kind has a create/activate (marker-tracked)
  lifecycle. The slice shape is unreliable across a cold restart: on
  rehydrate `load_or_init` can yield a slice without `:transients` even for
  a Lifecycle Kind, so a slice-based check mis-classifies a rehydrated
  Lifecycle Kind as non-Lifecycle (codex review #533 5a P2). The Kind's
  behaviour list is stable across fresh-create and rehydrate.
  """
  @spec hosts_lifecycle?(module()) :: boolean()
  def hosts_lifecycle?(kind_module) when is_atom(kind_module) do
    kind_module
    |> Ezagent.Kind.behaviors_of()
    |> any_lifecycle?()
  end

  @doc """
  P1 (SPEC §3.1, E10) — instance-set-aware variant. Computes the
  create/activate metadata from THIS INSTANCE's effective set (the persisted
  `:kind_base`-derived set), not the module's declared superset, so a superset
  Kind whose instance carries no Lifecycle behavior is not mis-classified.

  In practice every composed instance carries `KindBase` (a base Lifecycle
  behavior) via `BehaviorSet.base_behaviors/0`, so this returns `true` for any
  composed instance — which is correct: every instance genuinely hosts a
  Lifecycle. The arity-2 variant exists for symmetry with every other E1–E9
  entry point (compute from the instance set), not because a real instance
  could ever be non-Lifecycle.
  """
  @spec hosts_lifecycle?(module(), %{atom() => map()}) :: boolean()
  def hosts_lifecycle?(kind_module, slice_state)
      when is_atom(kind_module) and is_map(slice_state) do
    kind_module
    |> Ezagent.Kind.BehaviorSet.effective_set(slice_state)
    |> any_lifecycle?()
  end

  defp any_lifecycle?(behaviors) do
    Enum.any?(behaviors, fn behaviour ->
      Code.ensure_loaded?(behaviour) and
        function_exported?(behaviour, :__ezagent_lifecycle_destroy__, 3)
    end)
  end

  defp ever_created?(%{uri: %URI{} = uri}), do: ever_created?(Ezagent.URI.stable_key(uri))
  defp ever_created?(%{uri: uri}) when is_binary(uri), do: ever_created?(uri)
  defp ever_created?(uri_str) when is_binary(uri_str), do: marker_lookup(uri_str)
  defp ever_created?(_), do: false

  # Wrap the DB read so a Repo-less context (pure-macro unit tests, the
  # `:ephemeral` no-DB path) degrades to "not created" rather than
  # crashing — the create path then runs, which is the correct default
  # for a brand-new in-memory entity.
  defp marker_lookup(uri_str) do
    Ezagent.Ecto.KindSnapshot.ever_created?(uri_str)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc false
  @spec __run_activate__(module(), %{state: map(), transients: map()}, map()) ::
          {:ok, %{state: map(), transients: map()}} | :ignore
  def __run_activate__(module, %{state: st} = slice, ctx) do
    activate_ctx = Map.put(ctx, :state, st)

    # NOTE: on a cold-load the merged slice is `%{state: persisted}` with
    # NO `:transients` key (it was stripped at persist + the snapshot
    # merge replaced fresh's empty transients). We therefore Map.put the
    # rebuilt transients rather than `%{slice | ...}` (which would raise
    # on the missing key). This is the structural rebuild that makes the
    # cold-restart bug class impossible — `activate` is the ONLY site
    # that fills `:transients`, and it runs on every start.
    case module.activate(st, activate_ctx) do
      {:ok, transients} when is_map(transients) ->
        {:ok, Map.put(slice, :transients, transients)}

      {:ok, transients, reconciled_state}
      when is_map(transients) and is_map(reconciled_state) ->
        # 3-arity return — `activate` reconciled `state` against an
        # external SoT (subsumes the old `reconcile_after_load/2`).
        {:ok, slice |> Map.put(:state, reconciled_state) |> Map.put(:transients, transients)}
    end
  end

  @doc false
  # F5 — `deactivate/2` is `:ok`-only. We deliberately DISCARD any return
  # value (the contract is documented as "cannot mutate persisted state")
  # and always return `:ok` so the engine's graceful-stop path is a pure
  # side-effecting cleanup, never a (torn) state write.
  @spec __run_deactivate__(module(), term(), %{state: map(), transients: map()}, map()) :: :ok
  def __run_deactivate__(module, reason, slice, ctx) do
    # Phase B (T1 batch follow-on): `deactivate/2` does side-effecting
    # cleanup of TRANSIENT handles (close a transport, release a port) — so
    # its ctx MUST expose `:transients` + `:read` + `:state`, mirroring the
    # `__run_signal__`/`__run_destroy__` ctx shape. The original Phase A
    # `__run_deactivate__` forwarded only `:state`, so a `deactivate` that
    # reached for `ctx.transients[handle]` (the canonical use — e.g.
    # `ExternalMirrorWorker` releasing its binding transport) raised
    # `KeyError :transients`. This is an additive ctx completion; it does
    # NOT change the F5 `:ok`-only contract (the return is still discarded).
    st = Map.get(slice, :state, %{})
    transients = Map.get(slice, :transients, %{})

    deactivate_ctx =
      ctx
      |> Map.put(:state, st)
      |> Map.put(:transients, transients)
      |> Map.put(:read, fn key, default -> Map.get(st, key, default) end)

    _ = module.deactivate(reason, deactivate_ctx)
    :ok
  end

  @doc false
  @spec __run_signal__(module(), term(), %{state: map(), transients: map()}, map()) ::
          {:ok, %{state: map(), transients: map()}} | :ignore
  def __run_signal__(module, message, slice, ctx) do
    signal_ctx =
      ctx
      |> Map.put(:read, fn key, default -> Map.get(slice.state, key, default) end)
      |> Map.put(:state, slice.state)
      |> Map.put(:transients, slice.transients)

    case module.handle_signal(message, signal_ctx) do
      :ignore ->
        :ignore

      {:ok, effects} when is_list(effects) ->
        # T1 (Phase B foundation) — run the FULL effect pipeline, not just
        # `:set` / `:set_transient`. Real signal handlers DISPATCH /
        # EMIT / NOTIFY (e.g. ExternalMirror's `:publisher_event` →
        # dispatch-to-self, `:ezagent_em_reconcile` → spawn workers;
        # Chat's `:DOWN` → set_transient + notify). Under Lifecycle those
        # MUST be declarative effects executed here (the Phase C "no
        # imperative Invocation.dispatch in dev code" gate), with the SAME
        # ordering (State → Halt → Saga → DispatchesReturning → Dispatches
        # → Notifies → Events → Terminations) and the R10-2 pre-commit
        # atomicity (state + transient reduced into the new slice BEFORE
        # any commit) as the action path.
        #
        # `Ezagent.Kind.Runtime.apply_signal_effects/3` is the SAME
        # `apply_effects/2` + `execute_buckets/2` the action path uses; it
        # returns `{:ok, new_slice}` (the engine's `handle_kind_message/3`
        # contract carries only a new slice, no result) or `:ignore` on a
        # `{:halt, _}` short-circuit OR a side-effect bucket failure
        # (slice NOT advanced either way — the signal is an atomic unit,
        # so partial side effects don't leak, mirroring the action path).
        #
        # ctx already carries `:self_uri` (the engine's signal ctx); that
        # is what the dispatch/event buckets need for caller default +
        # EventLog aggregate.
        case Ezagent.Kind.Runtime.apply_signal_effects(slice, effects, signal_ctx) do
          {:ok, new_slice} -> {:ok, new_slice}
          :ignore -> :ignore
        end
    end
  end

  @doc false
  @spec __run_activated__(module(), %{state: map(), transients: map()}, map()) :: :ok
  def __run_activated__(module, %{state: st}, ctx) do
    activated_ctx = Map.put(ctx, :state, st)
    _ = module.activated(st, activated_ctx)
    :ok
  end

  @doc false
  # RF-3 — run the author's `detached/2` developer hook (engine `on_detach/2`)
  # with the live slice's `:state` view. Side-effecting cleanup of TRANSIENT
  # handles; the return is discarded (the framework drops the slice afterward),
  # mirroring `__run_activated__`/`__run_deactivate__`.
  @spec __run_detached__(module(), %{state: map(), transients: map()} | map(), map()) :: :ok
  def __run_detached__(module, slice, ctx) do
    st = Map.get(slice, :state, %{})
    transients = Map.get(slice, :transients, %{})

    detach_ctx =
      ctx
      |> Map.put(:state, st)
      |> Map.put(:transients, transients)
      |> Map.put(:read, fn key, default -> Map.get(st, key, default) end)

    _ = module.detached(st, detach_ctx)
    :ok
  end

  @doc """
  RF-2 — build the FRESH two-container slice for a behavior MOUNTED onto a
  LIVE instance (`Ezagent.Kind.mount/2`).

  Unlike `__init_slice__/2`, this ALWAYS runs `create/1` (never the
  ever-created-marker SKIP branch). The marker tracks the INSTANCE's first
  existence and is TRUE by mount time, but the MOUNTED behavior has never been
  created on THIS instance — its persistent `state` must be built now, exactly
  as it would at first spawn. The `transients` container starts empty and is
  filled by `activate/2` (run via the post-init continuation in
  `Ezagent.Kind.MountDetach`), so the cold-restart guarantee is preserved: on
  reload `activate` rebuilds the transients via the normal boot path.

  For a non-Lifecycle behavior `init_slice/1` is the right fresh builder (no
  marker gate exists), so `MountDetach` calls `init_slice/1` for those and
  this only for Lifecycle behaviors.
  """
  @spec __mount_slice__(module(), map()) :: %{state: map(), transients: map()}
  def __mount_slice__(module, args) do
    {:ok, st} = module.create(args)
    %{state: st, transients: %{}}
  end

  @doc false
  @spec __run_destroy__(module(), term(), %{state: map(), transients: map()} | map(), map()) ::
          :ok
  def __run_destroy__(module, reason, slice, ctx) do
    st =
      case slice do
        %{state: state_map} when is_map(state_map) -> state_map
        other when is_map(other) -> other
        _ -> %{}
      end

    destroy_ctx =
      ctx
      |> Map.put(:state, st)
      |> Map.put(:read, fn key, default -> Map.get(st, key, default) end)

    _ = module.destroy(reason, destroy_ctx)
    :ok
  end

  # ---------------------------------------------------------------
  # Framework destroy primitive (SPEC §2 destroy path). PERMANENT
  # deletion: (1) run each Lifecycle Behavior's `destroy/2` cleanup hook
  # while the Kind is still LIVE (so the author can tear down subprocess
  # handles / external mirrors with access to its `state`), THEN (2) clear
  # the durable `state` + ever-created marker (delete the snapshot row),
  # THEN (3) terminate the Kind process. A respawn at the same URI goes
  # through `create/1` again. This is distinct from `deactivate` (graceful
  # stop — the entity persists; runs through OTP `terminate/3`).
  # ---------------------------------------------------------------

  @doc """
  Permanently DELETE the entity at `uri`.

  Ordered (SPEC §2 / F4):

  1. Invoke each Lifecycle Behavior's `destroy(reason, ctx)` cleanup hook
     against the LIVE Kind (subprocess teardown, ExternalMirror release,
     etc.) — BEFORE durable state is cleared, so the hook can read its
     own `state`. Best-effort + per-Behavior isolated (§OTP).
  2. Clear durable `state` + the ever-created marker (delete the
     `kind_snapshots` row) so a future spawn re-runs `create/1`.
  3. Terminate the Kind process.

  Idempotent — an already-absent URI clears nothing and returns `:ok`.

  ## Self-destroy is rejected (codex r2 F2)

  `destroy/2` runs in the caller's process. A Lifecycle `handle_<action>`
  (or `destroy`/`deactivate`) hook runs INSIDE the target Kind.Server
  process; if such a hook calls `Ezagent.Lifecycle.destroy(ctx.self_uri)`,
  step 1's hook-drain would `GenServer.call(self(), …)` — a re-entrant
  call that deadlocks until the 5s timeout, after which steps 2-3 would
  still delete the durable row + terminate the process. That is the torn
  invariant "row deleted but process alive (mid-call)".

  Self-destroy through this synchronous primitive is never legitimate (a
  Kind cannot run its own destroy hooks while it is the process executing
  them), so we REJECT it structurally with `{:error,
  :cannot_self_destroy}` BEFORE touching the durable row or the process
  (per `feedback_let_it_crash_no_workarounds` — a clear refusal, not a
  silent degrade). The row stays intact and the process stays alive. A
  Kind that wants to delete itself must emit a `:terminate` effect (which
  ends its own life) and let an EXTERNAL caller invoke `destroy/2`.
  """
  @spec destroy(URI.t() | String.t(), term()) :: :ok | {:error, term()}
  def destroy(uri, reason \\ :destroy) do
    uri = canonical_instance_uri(uri)

    with_entity_transition(uri, fn -> do_destroy(uri, reason) end)
  end

  @doc "Best-effort permanent deletion for callers that do not observe cleanup convergence."
  @spec destroy!(URI.t() | String.t(), term()) :: :ok
  def destroy!(uri, reason \\ :destroy) do
    _ = destroy(uri, reason)
    :ok
  end

  @doc """
  Serialize an entity lifecycle transition on this node.

  The resource key is the canonical instance URI, so action-qualified and
  instance-only forms contend on the same lock. The requester is `self()`,
  making same-process nesting reentrant (for example `Users.delete/1` wrapping
  `destroy/2`) while preserving mutual exclusion between callers.

  A target Kind may not synchronously transition itself. The guard runs both
  before waiting and again after acquiring the lock so no row/process mutation
  can slip through a registration change while the caller was queued.
  """
  @spec with_entity_transition(URI.t() | String.t(), (-> result)) ::
          result | {:error, :cannot_self_destroy}
        when result: term()
  def with_entity_transition(uri, fun) when is_function(fun, 0) do
    uri = canonical_instance_uri(uri)

    if self_target?(uri) do
      {:error, :cannot_self_destroy}
    else
      stable_key = Ezagent.URI.stable_key(uri)
      held_key = {__MODULE__, :entity_transition_held, stable_key}

      # `:global` accepts the same requester recursively, but an inner
      # `trans/3` also calls `del_lock` when its callback returns. Re-entering
      # `trans/3` here would therefore release the outer critical section too
      # early. Keep one node-local lock per process/resource and run nested
      # callbacks directly; the outer `after` remains the sole release point.
      if Process.get(held_key, false) do
        run_entity_transition(uri, fun)
      else
        lock_id = {{:ezagent_entity_transition, stable_key}, self()}

        :global.trans(
          lock_id,
          fn ->
            Process.put(held_key, true)

            try do
              run_entity_transition(uri, fun)
            after
              Process.delete(held_key)
            end
          end,
          [node()]
        )
      end
    end
  end

  defp run_entity_transition(uri, fun) do
    if self_target?(uri), do: {:error, :cannot_self_destroy}, else: fun.()
  end

  defp do_destroy(uri, reason) do
    uri_str = Ezagent.URI.stable_key(uri)

    # 1. Run the developer destroy hooks against the live Kind (best-
    #    effort — a brutal kill may have skipped this, which is why the
    #    next incarnation's `activate/2` must self-heal — §OTP). The
    #    self-call guard lives HERE (before the durable clear) so a
    #    rejected self-destroy leaves the row + process untouched.
    with :ok <- run_developer_destroy_hooks(uri_str, reason),
         :ok <- terminate_live(uri_str) do
      # A live target retires its authority while draining developer destroy
      # hooks in Kind.Server. A cold target has no hook process, so retire the
      # active row here as well. Idempotency makes this the single post-
      # termination guarantee for both paths: a later genuine create must
      # append a strictly newer generation instead of reopening the old key.
      :ok = Ezagent.Cap.Authority.retire(uri)

      # Clear durable state only after teardown is CONFIRMED. A failed custom
      # teardown or module query leaves the snapshot intact for the reaper.
      :ok = Ezagent.Ecto.KindSnapshot.delete(uri_str)

      :ok
    end
  end

  defp terminate_live(uri_str) do
    case Ezagent.KindRegistry.lookup(uri_str) do
      {:ok, _pid} -> Ezagent.Kind.terminate(Ezagent.URI.new!(uri_str))
      :error -> :ok
    end
  end

  defp canonical_instance_uri(%URI{} = uri), do: Ezagent.URI.instance(uri)

  defp canonical_instance_uri(uri) when is_binary(uri),
    do: uri |> Ezagent.URI.new!() |> Ezagent.URI.instance()

  defp self_target?(uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) -> pid == self()
      :error -> false
    end
  end

  # Ask the live Kind.Server to drain each of its Lifecycle Behaviors'
  # `destroy/2` hooks (via the macro-emitted `__ezagent_lifecycle_destroy__/3`
  # convention) IN the Kind's own process, so each hook reads its slice.
  # No live Kind → nothing to drain (the durable clear in the caller still
  # runs). Best-effort: a failed call must not block the durable delete.
  #
  # Self-destroy guard (codex r2 F2): if the resolved Kind pid IS the
  # current process, the hook-drain `GenServer.call` would re-enter this
  # very GenServer and deadlock. Reject up-front with
  # `{:error, :cannot_self_destroy}` so the caller aborts BEFORE the
  # durable row delete + terminate — never leaving the torn state.
  defp run_developer_destroy_hooks(uri_str, reason) do
    case Ezagent.KindRegistry.lookup(uri_str) do
      {:ok, pid} when is_pid(pid) and pid == self() ->
        {:error, :cannot_self_destroy}

      {:ok, pid} when is_pid(pid) ->
        try do
          case GenServer.call(pid, {:ezagent_lifecycle_destroy, reason}, 5_000) do
            {:error, _reason} = error -> error
            _result -> :ok
          end
        catch
          :exit, {:timeout, _} -> {:error, :destroy_hook_timeout}
          :exit, reason -> {:error, {:destroy_hook_exit, reason}}
        end

      :error ->
        :ok
    end
  end
end
