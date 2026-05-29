defmodule Ezagent.Lifecycle do
  @moduledoc """
  `use Ezagent.Lifecycle` — the agent-SDK-shaped developer API that hides
  the CQRS engine (slice / invocation / snapshot / persistence-strategy)
  behind two state containers and a small set of lifecycle moments.

  SPEC: `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md`.
  This module is the Phase A foundation — the macro + the engine wiring.
  Phase B migrates the 23 developer Behaviors; Phase C flips the grep
  gates. Phase A is **additive**: `Ezagent.Behavior` stays as the
  internal engine contract (§10-R3) and every existing Behavior keeps
  working through the old surface unchanged.

  ## Compile-down (SPEC §3 / §10-R3)

  `use Ezagent.Lifecycle` is a thin code generator over `use
  Ezagent.Behavior`. It emits `@behaviour Ezagent.Behavior` + the engine
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
  | `pre_handle/3` / `post_handle/4` | fine interception (composed in handler path) | cross-cutting |

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
  # `Ezagent.Behavior` `action/3` @before_compile). The macro injects
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
  semantics). Returned `state` is persisted before exit; `transients`
  are discarded.
  """
  @callback deactivate(reason :: term(), ctx :: ctx()) :: :ok | {:ok, state()}

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
  `handle_signal/2` — non-action GenServer messages (`:DOWN`, PubSub
  deliveries). Returns the same effect list as `handle_<action>/2` (so a
  `:DOWN` returns `{:set_transient, :monitors, ...}` + `{:set,
  :last_seen, ...}`). Successor to the engine's `handle_kind_message/3`.
  """
  @callback handle_signal(message :: term(), ctx :: ctx()) ::
              {:ok, [Ezagent.Behavior.effect()]} | :ignore

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
              effects :: [Ezagent.Behavior.effect()],
              ctx :: ctx()
            ) :: {:ok, term(), [Ezagent.Behavior.effect()]} | :cont

  @optional_callbacks [
    create: 1,
    activate: 2,
    deactivate: 2,
    destroy: 2,
    activated: 2,
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
      # Ezagent.Behavior` injects `action/3`, `@before_compile
      # Ezagent.Behavior`, and the `__behavior__?/0` marker the runtime
      # dispatches through.
      use Ezagent.Behavior
      @behaviour Ezagent.Behavior
      @behaviour Ezagent.Lifecycle

      # Auto-derive `state_slice/0` from the module name unless an
      # explicit override is supplied (snapshot-compat hatch). The
      # override path is overridable so the author may still hand-roll it.
      @ezagent_lifecycle_state_slice_override unquote(state_slice_override)

      @impl Ezagent.Behavior
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
      @impl Ezagent.Behavior
      def init_slice(args) do
        Ezagent.Lifecycle.__init_slice__(__MODULE__, args)
      end

      # post_init/2 schedules the unified activate step. Always emitted
      # (the engine probes function_exported?/3) so EVERY Lifecycle
      # module rebuilds transients on every start with no author opt-in.
      @impl Ezagent.Behavior
      def post_init(_args, _slice), do: {:continue, :ezagent_activate}

      # handle_continue/3 runs the author's activate/2 and writes the
      # rebuilt transients (+ any reconciled state) back into the
      # two-container slice. Runs PRE-`:ready` (§10-R1).
      @impl Ezagent.Behavior
      def handle_continue(:ezagent_activate, slice, ctx) do
        Ezagent.Lifecycle.__run_activate__(__MODULE__, slice, ctx)
      end

      # terminate/3 → deactivate/2 (graceful stop, entity persists).
      # Returned `{:ok, state}` is folded into the slice's state sub-map.
      # (`destroy/2` deletion path is driven by the framework's destroy
      # primitive — Phase A wires the deactivate path; the destroy
      # data-clear is exercised via `Ezagent.Lifecycle.destroy/1`.)
      @impl Ezagent.Behavior
      def terminate(reason, slice, ctx) do
        Ezagent.Lifecycle.__run_deactivate__(__MODULE__, reason, slice, ctx)
      end

      # handle_kind_message/3 → handle_signal/2 (§9 OQ-3). The signal
      # returns the same effect list as a handler; the macro reduces it
      # into the two-container slice via apply_effects/2.
      #
      # NOTE: `handle_kind_message/3` is a convention probed by
      # `Kind.Server` via `function_exported?/3`, NOT a formal
      # `@callback` on `Ezagent.Behavior`, so no `@impl` annotation.
      def handle_kind_message(message, slice, ctx) do
        Ezagent.Lifecycle.__run_signal__(__MODULE__, message, slice, ctx)
      end

      # on_ready/2 → activated/2 (§9 OQ-5, post-`:ready`).
      @impl Ezagent.Behavior
      def on_ready(slice, ctx) do
        Ezagent.Lifecycle.__run_activated__(__MODULE__, slice, ctx)
      end

      # ---- Overridable developer-hook defaults (SPEC §2.3 — a module
      # may omit any of these) ----
      def create(_args), do: {:ok, %{}}
      def activate(_state, _ctx), do: {:ok, %{}}
      def deactivate(_reason, _ctx), do: :ok
      def destroy(_reason, _ctx), do: :ok
      def activated(_state, _ctx), do: :ok
      def handle_signal(_message, _ctx), do: :ignore

      defoverridable create: 1,
                     activate: 2,
                     deactivate: 2,
                     destroy: 2,
                     activated: 2,
                     handle_signal: 2
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

  defp ever_created?(%{uri: %URI{} = uri}), do: ever_created?(URI.to_string(uri))
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
  @spec __run_deactivate__(module(), term(), %{state: map(), transients: map()}, map()) :: :ok
  def __run_deactivate__(module, reason, %{state: st}, ctx) do
    deactivate_ctx = Map.put(ctx, :state, st)
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
        # Reduce the signal's effects into the two-container slice via
        # the same pure reducer dispatch uses. Only the container
        # mutations matter for a signal; side-effect buckets
        # (dispatch/notify/...) are NOT executed from the signal path in
        # Phase A (the engine's handle_kind_message contract returns a
        # new slice, not buckets). Signals SHOULD therefore emit only
        # `:set` / `:set_transient` effects in Phase A.
        case Ezagent.Behavior.apply_effects(effects, slice) do
          {:ok, %{state: new_slice}} -> {:ok, new_slice}
          {:halt, _reason, _partial} -> :ignore
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

  # ---------------------------------------------------------------
  # Framework destroy primitive (SPEC §2 destroy path). Clears the
  # durable `state` for a URI and flips the ever-created marker off, so
  # a respawn at the same URI goes through `create/1` again. Best-effort
  # `destroy/2` cleanup is the author's; this is the framework's durable
  # erase. Phase A exposes it as a function (no dispatch action yet —
  # that is a per-Kind concern in Phase B).
  # ---------------------------------------------------------------

  @doc """
  Permanently erase the durable `state` for `uri` and clear the
  ever-created marker (so a future spawn re-runs `create/1`). Deletes
  the `kind_snapshots` row. Idempotent.
  """
  @spec destroy(URI.t() | String.t()) :: :ok
  def destroy(uri) do
    uri_str =
      case uri do
        %URI{} = u -> URI.to_string(u)
        s when is_binary(s) -> s
      end

    Ezagent.Ecto.KindSnapshot.delete(uri_str)
  end
end
