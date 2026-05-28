defmodule Ezagent.Behavior do
  @moduledoc """
  Behavior — contract for a piece of action-handling logic.

  A Behavior is a small module that:
  - declares what actions it implements (`actions/0`)
  - declares the slice of Kind state it owns (`state_slice/0`)
  - initialises that slice (`init_slice/1`)
  - executes an action against the slice (`invoke/4`)
  - exposes its `@interface` for adapter generation and arg validation
    (`interface/0`)

  Phase 1's only Behavior is `Ezagent.Behavior.Echo` (in `ezagent_plugin_echo`,
  arrives at step 4); the contract is defined here in `ezagent_core` so any
  plugin can implement it.

  ## Why no macros

  Per Decision #84 / DECISIONS P1-D2, Phase 1 picks the
  `@behaviour Ezagent.Behavior` + callback pattern over a `use Ezagent.Behavior`
  macro. The trade-off is identical to the Kind one (compile-time vs
  runtime isolation); same rationale applies (single Behavior in Phase 1,
  re-evaluate Phase 2+).

  ## Post-init continuation hook (PR-EM-CORE)

  Two OPTIONAL callbacks let a Behavior schedule deferred work that
  runs between the URI being registered in `Ezagent.KindRegistry`
  and the URI being published as `:ready` in `Ezagent.ReadyGate`:

  - `post_init/2` — called from `Ezagent.Kind.Server.init/1` just
    after `init_slice/1`. Returns either `:ok` (no post-init work
    needed) or `{:continue, term()}` to schedule one
    `handle_continue/3` round.
  - `handle_continue/3` — invoked by `Ezagent.Kind.Server` once for
    each `{:continue, term}` returned from `post_init/2`. Receives
    the continuation term, this Behavior's slice, and a context map
    (`%{kind_module:, self_uri:}`). Returns `{:ok, new_slice}` to
    update the slice or `:ignore` to leave it unchanged.

  Boot-order invariant (codex round-2 HIGH-1): the Kind is
  registered + ALL post-init `handle_continue/3` callbacks have
  completed BEFORE `Ezagent.ReadyGate.mark_ready/1` fires. External
  dispatches arriving during post-init buffer to `PendingDelivery`
  (`:cast`) or fail-fast (`:call`) — they are NOT delivered to a
  half-initialised Kind. Per-Behavior `handle_continue/3` callbacks
  run in `Kind.behaviors/0` declaration order, each as its own
  `handle_continue/2` step on the Kind.Server (so each is a fresh
  scheduler pass; long-running post-init work is not advised).

  This means a post-init `handle_continue/3` MAY call OUT to other
  ready Kinds (their ReadyGate is consulted independently) but
  MUST NOT dispatch back into its own Kind synchronously — self
  is still `:not_ready` and a `:call` would fail-fast; a `:cast`
  would buffer to `PendingDelivery` and run AFTER post-init
  completes. Both are surprising behaviours for a Behavior author
  who hasn't read this doc.

  Canonical use case: the ExternalMirror Worker (see SPEC
  `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §6.1 split-init pattern) — `init_slice/1` returns minimal state
  with no subscriptions or external I/O, and the post-init
  continuation does the subscribe + binding open. Without this hook
  a Worker calling back into its Session during `init_slice/1`
  would deadlock against the Session's synchronous `Kind.spawn/2`.
  """

  @type action :: atom()
  @type slice :: map()
  @type args :: map()
  @type ctx :: map()
  @type result :: term()

  @type invoke_return ::
          {:ok, new_slice :: slice()}
          | {:ok, new_slice :: slice(), result :: result()}
          | {:ok, new_slice :: slice(), stream :: Enumerable.t()}
          | {:error, reason :: term()}

  @doc "List of action atoms this Behavior implements."
  @callback actions() :: [action()]

  @doc """
  Atom key under which this Behavior's slice lives in the Kind's state
  map. Convention: `:behavior_name` (e.g. `:echo`, `:chat`). Per
  DECISIONS impl-time §`Ezagent.Kind.Server` state shape — atoms not
  modules.
  """
  @callback state_slice() :: atom()

  @doc """
  Build the initial slice from boot-time args. Called by
  `Ezagent.Kind.Server.init/1` for each declared Behavior.
  """
  @callback init_slice(args :: args()) :: slice()

  @doc """
  Execute an action against the slice.

  Returns one of:
  - `{:ok, new_slice}` — silent success (cast)
  - `{:ok, new_slice, result}` — success with return value (call)
  - `{:ok, new_slice, stream}` — streaming return (call_stream)
  - `{:error, reason}` — action failed
  """
  @callback invoke(
              action :: action(),
              slice :: slice(),
              args :: args(),
              ctx :: ctx()
            ) :: invoke_return()

  @doc """
  Adapter-generation + arg-validation source.

  Shape: `%{<action_atom> => %{description: <String.t()>, args: <type_spec>,
  returns: <type_spec>, modes: [<mode>]}}`. Used by
  `Ezagent.InterfaceValidator.validate/2` at dispatch time.

  `description:` is OPTIONAL (V1 UI SPEC §0) — a one-line human-readable
  summary of what the action does, surfaced by the CLI `tree_builder` and
  CmdK. When present it MUST be a binary; `Ezagent.InterfaceValidator.validate_action/1`
  enforces this. Behaviors SHOULD supply it so consumers rarely fall back
  to generic text.
  """
  @callback interface() :: %{
              atom() => %{
                optional(:description) => String.t(),
                args: map(),
                returns: map(),
                modes: [atom()]
              }
            }

  @doc """
  List of `{action, description}` tuples — the cap subjects this
  Behavior gates. Every action returned from `actions/0` MUST appear
  here with a human-readable English description; the description
  surfaces in `/admin/caps`, the future `mix ezagent.caps.list` CLI,
  and audit/forensic queries.

  Cap-only Behaviors (`dispatchable?/0 == false`, e.g. a future
  `Ezagent.Behavior.Presence`) still list their actions here — that
  is HOW Presence-style auth gates get their cap shape into
  `Ezagent.CapabilityRegistry`.

  Enforcement is via the `@behaviour` compile warning + CI's
  `--warnings-as-errors`. SPEC `docs/superpowers/specs/2026-05-23-capability-registry.md`
  §3.1 — non-bypassable single-entry semantics.

  Example:
      def cap_subjects do
        [
          {:send,  "send a message to session members"},
          {:join,  "join a session as a member"},
          {:leave, "leave a session"}
        ]
      end
  """
  @callback cap_subjects() :: [{action(), String.t()}]

  @doc """
  Is this Behavior dispatchable? Default `true` — most Behaviors
  expose `invoke/4` for action dispatch. Set to `false` for
  cap-only Behaviors (the cap shape exists for auth but there is
  no dispatchable action) — e.g. a future `Ezagent.Behavior.Presence`'s
  `:online` action is a subscription gate, not a dispatch target.

  When `dispatchable?/0 == false`, `Ezagent.CapabilityRegistry.register/3`
  records the cap subject but does NOT write to
  `Ezagent.BehaviorRegistry`, so `Invocation.dispatch/1` can never
  accidentally invoke the Behavior.

  Optional callback (default-true probed via `function_exported?/3`).
  """
  @callback dispatchable?() :: boolean()

  @doc """
  Return the URI that legitimately grants caps for this Behavior's data
  on the given `instance`. The SPEC at
  `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` §3
  defines the contract: every cap = CRUD authorization on a class of
  data; only the data owner (or a delegate chain ending at the owner)
  may grant that cap.

  ## Return shapes

  | Return | Meaning | Who can grant via `grant_cap` |
  |---|---|---|
  | `%URI{}` | Concrete owner — Behavior resolves the owner of THIS instance | Only that URI (or its delegate chain) |
  | `:any` | Class-wide cap (instance is `:any` or workspace-scoped) | Workspace admin |
  | `:no_owner` | System-scope data (no domain owner exists) | Only bootstrap admin |
  | `{:scope, atom(), URI.t()}` | Scope-bounded cap (e.g. `{:within_session, S}`) | Owner of the scope URI |

  PR-OWN-1 ships this as an OPTIONAL callback (default `:no_owner`).
  PR-OWN-2..6 migrate concrete Behaviors to declare real `data_owner/1`.
  PR-OWN-FINAL adds an invariant test that every Behavior declaring
  `cap_subjects/0` MUST also declare `data_owner/1`.

  Lookup via `Ezagent.CapabilityRegistry.data_owner_of/2` which uses
  `function_exported?/3` to probe — Behaviors that don't implement
  this callback fall through to `:no_owner`.

  Optional callback.
  """
  @callback data_owner(
              instance ::
                URI.t()
                | :any
                | {atom(), URI.t()}
            ) ::
              URI.t()
              | :any
              | :no_owner
              | {:scope, atom(), URI.t()}

  @doc """
  Post-init hook — invoked once by `Ezagent.Kind.Server.init/1`
  after `init_slice/1` has populated this Behavior's slice and
  BEFORE `:announce_ready` runs.

  Returns:
  - `:ok` — no deferred work; Server proceeds with its standard
    `:announce_ready` continuation, then any other Behavior's
    post-init continuations.
  - `{:continue, term()}` — schedule one `handle_continue/3` round
    on this Behavior. The term is opaque to `Kind.Server` (it is
    just forwarded back when the continuation fires) and is
    typically an atom or a small tuple naming the deferred step.

  Boot-order guarantee: ALL `post_init/2` calls happen BEFORE the
  Kind is marked `:ready`, but the resulting `handle_continue/3`
  callbacks run AFTER `:announce_ready` has completed. This means
  `post_init/2` MUST be cheap + side-effect free (it is on the
  init critical path); side-effecting work goes in
  `handle_continue/3`. See moduledoc + ExternalMirror SPEC §6.1
  for the canonical split-init pattern.

  Optional callback (default: not implemented → no post-init work).
  """
  @callback post_init(args :: args(), slice :: slice()) ::
              :ok | {:continue, term()}

  @doc """
  Per-Behavior continuation handler invoked by
  `Ezagent.Kind.Server.handle_continue/2` for each `{:continue, term}`
  this Behavior returned from `post_init/2`.

  Arguments:
  - `term` — the opaque term this Behavior returned from `post_init/2`
  - `slice` — this Behavior's current slice (key = `state_slice/0`)
  - `ctx` — `%{kind_module: module(), self_uri: URI.t()}` so the
    Behavior can identify itself (e.g. to pass `self_uri` as the
    `caller` of an outbound dispatch)

  Returns:
  - `{:ok, new_slice}` — `Kind.Server` writes `new_slice` into
    `state.state[state_slice()]` via the same snapshot-commit path
    as dispatch
  - `:ignore` — slice unchanged (no write-back)

  Each post-init continuation is its own `handle_continue/2` step on
  the Kind.Server — they do not block each other on the same
  scheduler pass.

  ## Dispatch state during post-init (codex round-2 HIGH-1 +
  round-3 HIGH-1 — see moduledoc)

  Self is `:not_ready` for the duration of post-init; `:ready` is
  only published after the LAST `handle_continue/3` completes AND
  the PendingDelivery buffer has been drained. Implications for the
  Behavior author:

  - Dispatching OUT to OTHER ready Kinds is fine — ReadyGate is
    consulted per-target.
  - Self-dispatching synchronously (`Invocation.dispatch/1` with
    `mode: :call` targeting `self_uri`) will fail-fast with
    `{:error, :not_ready}` (hard-invariant #3). Don't do it.
  - Self-dispatching asynchronously (`mode: :cast`) will buffer to
    PendingDelivery and run AFTER post-init completes — which is
    rarely what the author intended. Prefer mutating the slice
    directly via the `{:ok, new_slice}` return.

  Optional callback (probed via `function_exported?/3` per call);
  Behaviors that return `{:continue, term}` from `post_init/2` MUST
  also export this callback.
  """
  @callback handle_continue(term :: term(), slice :: slice(), ctx :: ctx()) ::
              {:ok, new_slice :: slice()} | :ignore

  @doc """
  Map from action atom to the required capability for that action.

  Read by `Ezagent.Kind.Runtime.handle_dispatch/4` step 5.5 (the dispatch
  authz chokepoint, post-PR-CC-2-v2). Every action returned by `actions/0`
  MUST have an entry here unless the action is listed in
  `cap_exempt_actions/0` (see below).

  Compile-time / runtime invariant: the keys of `required_caps/0` ∪
  `cap_exempt_actions/0` MUST equal `actions/0` exactly. Enforced by
  `:ezagent_plugin_check` check 10 (for plugin Behaviors) +
  `Ezagent.Invariants.BehaviorRequiredCapsParityTest` (for core/domain).

  ## Plugin-author UX

  The recommended construction site uses the `Ezagent.Capability.cap/3`
  helper (a regular function, NOT a macro):

      @impl true
      def required_caps do
        %{
          send:    Ezagent.Capability.cap(:chat, __MODULE__, :send),
          receive: Ezagent.Capability.cap(:chat, __MODULE__, :receive),
          join:    Ezagent.Capability.cap(:chat, __MODULE__, :join)
        }
      end

  Direct struct construction is also valid (more verbose; useful when
  declaring a workspace- or instance-bounded cap inline).

  SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  """
  @callback required_caps() :: %{required(action :: atom()) => Ezagent.Capability.t()}

  @doc """
  Optional: actions that intentionally are NOT cap-gated.

  Default: `[]` (every action requires a cap declaration). Used for
  read-only / pure-inspection actions where a cap check is gratuitous
  (e.g. a future `:status` probe). The presence of this callback
  weakens `:ezagent_plugin_check` check 10's keys-equal-actions
  assertion: `keys(required_caps) ∪ cap_exempt_actions == actions`.

  Optional callback — `function_exported?/3` probed at call time;
  defaults to `[]` when not exported.

  SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §7
  (LOW-1 check-10 escape hatch).
  """
  @callback cap_exempt_actions() :: [atom()]

  @doc """
  Does this Behavior's actions require the caller and target to be in
  the same workspace?

  Read by `Ezagent.Kind.Runtime.handle_dispatch/4` step 5.6 (workspace
  isolation enforcement). Defaults to `true` — when not exported, the
  Behavior is assumed to need workspace isolation (the safer default
  per memory `feedback_let_it_crash_no_workarounds`).

  Return `false` for genuinely workspace-agnostic Behaviors — typically
  `Lifecycle` (admin termination), pure data-inspection callbacks, or
  system-scope Behaviors whose targets are `:any`-workspace by URI
  shape.

  Optional callback — `function_exported?/3` probed at call time.

  SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2b.
  """
  @callback workspace_scoped?() :: boolean()

  @doc """
  Optional terminate hook invoked by `Ezagent.Kind.Server.terminate/2`
  on graceful Kind shutdown (NOT on a brutal crash — the Kind.Server
  itself must reach its OTP terminate callback for this to fire,
  which requires the supervisor to send `:shutdown` rather than
  `:kill`).

  Use this for per-Behavior resource cleanup that needs to run
  before the process exits — e.g. closing transport handles owned
  by `Ezagent.Behavior.ExternalMirrorWorker`'s bound
  `Ezagent.ExternalMirror.Binding.terminate/2` callback.

  Each Behavior's `terminate/3` runs in `behaviors/0` declaration
  order. A raise / throw / exit inside one Behavior's terminate
  does NOT prevent siblings from cleaning up (isolated by
  try/rescue in `Kind.Server.terminate/2`); the failure is logged
  and teardown continues. The process IS exiting regardless of
  the callback's outcome.

  Slice mutations from `terminate/3` are NOT persisted — by the
  time this runs, the snapshot for the persistence policy has
  already been written (`:on_terminate` saves above this drain;
  `:on_change` / `:periodic` already persisted on the last
  mutation).

  Optional callback — `function_exported?/3` probed at call time.

  Added 2026-05-25 as part of PR-EM-2 codex round-1 HIGH-1 fix.
  """
  @callback terminate(reason :: term(), slice :: slice(), ctx :: ctx()) :: :ok

  @doc """
  Declare the SIBLING slices this Behavior needs to read in-process
  during `invoke/4`. Returned list members are atoms naming OTHER
  Behaviors' `state_slice()` keys on the SAME Kind instance.

  Default `[]` — most Behaviors only touch their own slice (the
  third arg to `invoke/4`). When this callback returns a non-empty
  list, `Ezagent.Kind.Runtime.handle_dispatch/4` injects a
  read-only `ctx[:sibling_slices]` map containing JUST those keys,
  letting the Behavior do an O(1) lookup instead of a self-dispatch
  that would deadlock (a `GenServer.call(self)` on the same
  `Kind.Server`).

  Example — `Behavior.CurlAgent` reads its agent's API key:

      def reads_sibling_slices, do: [:api_keys]

  ## Security note

  The injected `ctx[:sibling_slices]` is NOT cap-gated — by
  declaring a sibling slice you're promising the runtime that
  reading it from your Behavior's process is intentional and safe.
  Any Behavior running INSIDE the Kind.Server has BEAM-level
  access to all sibling slices regardless (the process holds them
  in state); this callback is the audit seam — declaring the list
  makes the read explicit and grep-able. **Do NOT add slices you
  don't need.** The CapabilityRegistry cap gate at dispatch step
  5.5 still gates CROSS-PROCESS reads.

  Optional callback — defaults to `[]` if not exported.

  Added 2026-05-26 as part of the ApiKeys-to-Agent flip (Allen
  directive); codex review CRIT-1 closure.
  """
  @callback reads_sibling_slices() :: [atom()]

  @doc """
  Reconcile this Behavior's slice with an external source of truth
  (e.g. a projection table in the DB) after the Kind has loaded
  state from a snapshot.

  ## Why this exists

  `Ezagent.Kind.Snapshot.load_or_init/3` merges the snapshot's
  loaded state OVER the `init_slice/1` fresh state. For Behaviors
  whose slice is backed by a DB projection table (e.g.
  `Ezagent.Behavior.ExternalMirror.bindings` reads from
  `external_mirror_bindings`), this means: rows inserted AFTER
  the last snapshot write but BEFORE the next Kind restart are
  silently lost from the live slice. The Kind's
  `handle_continue/3` reconcile loop then walks an out-of-date
  slice, and downstream consumers (worker spawn, etc.) never see
  the new rows.

  `reconcile_after_load/2` runs once after merge: the Behavior
  re-reads its DB-backed fields, unions them with the merged
  slice, and returns the corrected slice. The default
  implementation is identity (`slice -> slice`).

  Behaviors with no DB projection don't need to implement this.

  ## Idempotence

  Must be idempotent: calling `reconcile_after_load(uri,
  reconcile_after_load(uri, slice))` must equal
  `reconcile_after_load(uri, slice)`. The expected pattern is
  set-union with a key (e.g. binding id), not list-append.

  Added 2026-05-26 as part of task #34 (worker spawn design fix —
  Allen directive after observing ExternalMirrorWorker not
  spawning for SQL-inserted binding rows post-restart).
  """
  @callback reconcile_after_load(uri :: URI.t(), slice :: slice()) :: slice()

  @doc """
  Post-ready hook — invoked once by `Ezagent.Kind.Server` AFTER
  `Ezagent.ReadyGate.mark_ready/1` has flipped this Kind to
  `:ready` and the `PendingDelivery` buffer has been drained.

  ## Why a separate hook from `handle_continue/3`

  `handle_continue/3` runs BEFORE `mark_ready` (codex round-2 HIGH-1
  + round-3 HIGH-1 invariant — see `Ezagent.Kind.Server` moduledoc).
  A Behavior that broadcasts a `"the Kind is ready"` signal from
  `handle_continue/3` will fire that signal while ReadyGate is
  still `:not_ready`. Any subscriber that handles the signal with
  a `:call`-mode dispatch back to this Kind will fail-fast with
  `{:error, :not_ready}` — silently dropping the signal's intent.

  `on_ready/2` exists for exactly that pattern: fire a
  `"hey, I'm now reachable"` broadcast AFTER ReadyGate flips, so
  subscribers' `:call`-mode round-trips can complete.

  ## When to use which

  - `handle_continue/3` — slice-affecting boot work
    (subscribe-to-PubSub-with-immediate-effect, open transport,
    read DB projection). Slice mutations from `handle_continue/3`
    persist via the standard snapshot commit path.
  - `on_ready/2` — side-effecting boot work that requires
    `ReadyGate` to already say `:ready` (lifecycle broadcasts that
    invite peer-side `:call` round-trips).

  ## Arguments + return

  - `slice` — this Behavior's slice as it stands AFTER all
    `handle_continue/3` callbacks have completed.
  - `ctx` — `%{kind_module: module(), self_uri: URI.t()}`.
  - Returns `:ok`. The slice is NOT mutated — `on_ready/2` runs
    after the snapshot has already been committed at the end of
    post-init, so a slice-mutating hook here would race the next
    dispatched action. Use `handle_continue/3` for slice changes.

  ## Error semantics

  A raise / throw / exit inside `on_ready/2` is logged + isolated
  by `Kind.Server` — the Kind STAYS `:ready` (ReadyGate already
  flipped before the hook ran; we can't un-flip it without
  contradicting an external observer who already saw `:ready`).
  This matches the `terminate/3` boundary — best-effort callback,
  per-Behavior isolation, structural ready-state invariant unchanged.

  Optional callback — `function_exported?/3` probed per call;
  Behaviors that don't export it contribute zero overhead to the
  Kind's boot path.

  Added 2026-05-27 as part of task #49 codex round-1 FAIL #6 fix —
  the publisher-lifecycle broadcast was previously emitted from
  `handle_continue/3`, racing peer-side `:call` dispatches against
  the unflipped ReadyGate.
  """
  @callback on_ready(slice :: slice(), ctx :: ctx()) :: :ok

  @optional_callbacks [
    dispatchable?: 0,
    data_owner: 1,
    post_init: 2,
    handle_continue: 3,
    terminate: 3,
    cap_exempt_actions: 0,
    workspace_scoped?: 0,
    reads_sibling_slices: 0,
    reconcile_after_load: 2,
    on_ready: 2
  ]

  # ---------------------------------------------------------------
  # SPEC 2026-05-28 Router/Behavior/Kind — new contract (additive)
  # ---------------------------------------------------------------
  #
  # Everything BELOW this comment is the NEW per-action declarative
  # contract. Modules opt-in via `use Ezagent.Behavior` instead of
  # `@behaviour Ezagent.Behavior`. The two coexist throughout
  # Phase 1 + Phase 2 — see `Ezagent.LegacyBehaviorAdapter`.

  @doc """
  `use Ezagent.Behavior` — opt into the new per-action declarative
  contract per SPEC §2.2.

  ## Injects

  - `Module.register_attribute(__MODULE__, :ezagent_actions, accumulate: true)`
  - The `action/3` macro for declaring an action's args/returns/caps
  - `@before_compile Ezagent.Behavior` to aggregate `@ezagent_actions`
    into `__actions__/0`, `__action_spec__/1`, and the legacy
    derived callbacks (`actions/0`, `interface/0`, `required_caps/0`,
    `cap_subjects/0`) so a single Behavior can be discovered by the
    legacy registry AND the new Router.
  - A `__behavior__?/0` marker function returning `true` (used by
    `Ezagent.Kind.attach_behavior` collision check).

  ## Compile-time invariants

  - Every `action :foo, ...` declaration MUST have a corresponding
    `def handle_foo(args, ctx)` clause defined in the same module.
    Enforced by `@before_compile`.
  - Action spec keys are validated: required keys `:args`, `:returns`
    must be present; `:caps`, `:modes`, `:description`, `:data_owner`
    are optional.
  """
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :ezagent_actions, accumulate: true)

      import Ezagent.Behavior, only: [action: 2, action: 3]

      @before_compile Ezagent.Behavior

      @doc false
      def __behavior__?, do: true
    end
  end

  @doc """
  Declare an action this Behavior handles.

      action :send,
        args: %{message: Ezagent.Message},
        returns: %{stored: :boolean},
        caps: [:send],
        modes: [:cast],
        description: "send a message to session members"

  The full grammar follows SPEC §4.3 / §4.4:

  | Key | Required | Default | Meaning |
  |---|---|---|---|
  | `args` | YES | — | Map of arg-name → type spec, consumed by `InterfaceValidator` |
  | `returns` | YES | — | Return type spec — see InterfaceValidator |
  | `caps` | no | `[name]` | Per-action cap list; see §4.3 grammar |
  | `modes` | no | `[:call]` | `:call`, `:cast`, `:call_stream` |
  | `description` | no | `""` | Surfaced in `/admin/caps` + CLI tree |
  | `data_owner` | no | `:no_owner` | `:self` / `:any` / `:no_owner` / `{:scope, atom, URI}` |
  | `workspace_scoped?` | no | `true` | Per-action override (SPEC §4.3 form 5) |
  """
  defmacro action(name, opts) when is_atom(name) and is_list(opts) do
    action_impl(name, opts, __CALLER__)
  end

  defmacro action(_name, _opts, _block) do
    raise ArgumentError,
          "action/3 macro called with a block — use action/2 (the second arg is the keyword list of opts)"
  end

  defp action_impl(name, opts, env) do
    # The opts values may be ASTs at macro-expansion time (e.g.
    # `args: %{name: :string}` arrives as `{:%{}, [], [...]}`).
    # We do compile-time validation on the keys present, but pass
    # the raw ASTs through to the accumulating attribute so they
    # evaluate AT MODULE COMPILE TIME (not now). Without this the
    # spec map ends up storing AST tuples instead of the actual
    # map / list / atom values.
    args_ast = Keyword.get(opts, :args)
    returns_ast = Keyword.get(opts, :returns)
    caps_ast = Keyword.get(opts, :caps, [name])
    modes_ast = Keyword.get(opts, :modes, [:call])
    description_ast = Keyword.get(opts, :description, "")
    data_owner_ast = Keyword.get(opts, :data_owner, :no_owner)
    workspace_scoped_ast = Keyword.get(opts, :workspace_scoped?, true)

    cond do
      is_nil(args_ast) ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "action :#{name} is missing required key :args (#{inspect(env.module)})"

      is_nil(returns_ast) ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "action :#{name} is missing required key :returns (#{inspect(env.module)})"

      true ->
        :ok
    end

    # Emit a quoted expression that, when evaluated in the module
    # body's compile context, builds the spec map with EVALUATED
    # values. The compile-time check for "must have handle_<name>/2"
    # runs in `__before_compile__` against the materialised
    # `@ezagent_actions` accumulator.
    quote do
      modes = unquote(modes_ast)
      description = unquote(description_ast)

      unless is_list(modes) do
        raise CompileError,
          description:
            "Ezagent.Behavior action :#{unquote(name)} :modes must be a list (got #{inspect(modes)})"
      end

      unless is_binary(description) do
        raise CompileError,
          description:
            "Ezagent.Behavior action :#{unquote(name)} :description must be a string (got #{inspect(description)})"
      end

      @ezagent_actions {unquote(name),
                        %{
                          name: unquote(name),
                          args: unquote(args_ast),
                          returns: unquote(returns_ast),
                          caps: unquote(caps_ast),
                          modes: modes,
                          description: description,
                          data_owner: unquote(data_owner_ast),
                          workspace_scoped?: unquote(workspace_scoped_ast)
                        }}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    actions = Module.get_attribute(env.module, :ezagent_actions) || []

    # Reverse so first-declared wins on duplicate (matches user expectation)
    actions =
      actions
      |> Enum.reverse()
      |> Enum.uniq_by(fn {name, _spec} -> name end)

    # Compile-time invariant: every `action :foo, ...` must have a
    # matching `def handle_foo(args, ctx)` clause defined in the
    # module. Skip the check for `Ezagent.LegacyBehaviorAdapter` —
    # it builds handlers programmatically via `defoverridable`.
    defined = Module.definitions_in(env.module, :def)

    if env.module != Ezagent.LegacyBehaviorAdapter do
      Enum.each(actions, fn {name, _spec} ->
        handler = String.to_atom("handle_#{name}")

        unless {handler, 2} in defined do
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "Behavior #{inspect(env.module)} declares action :#{name} but is missing " <>
                "def #{handler}(args, ctx) — every action MUST have a matching handler/2"
        end
      end)
    end

    action_names = Enum.map(actions, fn {n, _} -> n end)

    cap_subjects =
      Enum.map(actions, fn {name, spec} ->
        {name, spec.description}
      end)

    interface =
      Map.new(actions, fn {name, spec} ->
        {name,
         %{
           description: spec.description,
           args: spec.args,
           returns: spec.returns,
           modes: spec.modes
         }}
      end)

    actions_map = Map.new(actions)

    introspection_ast =
      quote do
        @doc false
        def __actions__, do: unquote(Macro.escape(actions_map))

        @doc false
        def __action_spec__(name) when is_atom(name) do
          Map.get(__actions__(), name)
        end

        @doc false
        def __action_names__, do: unquote(action_names)
      end

    legacy_ast = maybe_inject_legacy_callbacks(env, action_names, interface, cap_subjects, actions)

    quote do
      unquote(introspection_ast)
      unquote_splicing(legacy_ast)
    end
  end

  # Build the legacy callbacks (`actions/0`, `interface/0`,
  # `required_caps/0`, `cap_subjects/0`) ONLY if the module hasn't
  # defined them already AND only if it sets `@behaviour
  # Ezagent.Behavior` (so we don't pollute pure macro-only modules
  # like the Router test fixtures).
  defp maybe_inject_legacy_callbacks(env, action_names, interface, cap_subjects, actions) do
    defined = Module.definitions_in(env.module, :def)

    # Detect adherence to legacy behaviour — if no slice machinery
    # is declared (`state_slice/0` is missing), we generate the
    # derived callbacks. Otherwise the author is mixing both
    # contracts and we honour what they've already defined.
    legacy_required_caps =
      Enum.map(actions, fn {name, spec} ->
        {name, build_required_cap_ast(env.module, name, spec.caps)}
      end)

    cap_subjects_ast = Macro.escape(cap_subjects)
    interface_ast = Macro.escape(interface)
    action_names_ast = Macro.escape(action_names)

    pieces =
      []
      |> maybe_add_unless_defined(defined, :actions, 0,
        quote do
          def actions, do: unquote(action_names_ast)
        end
      )
      |> maybe_add_unless_defined(defined, :cap_subjects, 0,
        quote do
          def cap_subjects, do: unquote(cap_subjects_ast)
        end
      )
      |> maybe_add_unless_defined(defined, :interface, 0,
        quote do
          def interface, do: unquote(interface_ast)
        end
      )
      |> maybe_add_unless_defined(defined, :required_caps, 0,
        quote do
          def required_caps,
            do:
              unquote(legacy_required_caps)
              |> Map.new()
        end
      )

    pieces
  end

  defp maybe_add_unless_defined(acc, defined, name, arity, ast) do
    if {name, arity} in defined do
      acc
    else
      [ast | acc]
    end
  end

  defp build_required_cap_ast(behavior_module, action_name, caps_opt) do
    # Reduce the per-action caps list down to a SINGLE cap struct
    # for the legacy `required_caps/0` map. New-style multi-cap
    # action declarations collapse to the first cap (it determines
    # what the legacy adapter & registry see) — Router's new path
    # consults `__action_spec__(name).caps` directly for the full
    # multi-cap list.
    first_cap =
      case caps_opt do
        [first | _] -> first
        [] -> :any
        atom when is_atom(atom) -> atom
      end

    case first_cap do
      atom when is_atom(atom) ->
        quote do
          Ezagent.Capability.cap(:any, unquote(behavior_module), unquote(atom))
        end

      {action_atom, _opts} when is_atom(action_atom) ->
        quote do
          Ezagent.Capability.cap(:any, unquote(behavior_module), unquote(action_atom))
        end

      _ ->
        quote do
          Ezagent.Capability.cap(:any, unquote(behavior_module), unquote(action_name))
        end
    end
  end

  # ---------------------------------------------------------------
  # Effect applier (SPEC §4.4)
  # ---------------------------------------------------------------

  @typedoc """
  Effect — the vocabulary a `handle_<action>/2` handler returns.
  See SPEC §4.4 for the full normative table.
  """
  @type effect ::
          {:set, atom(), term()}
          | {:emit, atom(), map()}
          | {:dispatch, Ezagent.Cmd.t()}
          | {:notify, String.t(), term()}
          | {:effect, mfa_or_fun(), [term()]}
          | {:effect_returning, mfa_or_fun(), [term()], keyword()}
          | {:terminate, :self | URI.t()}
          | {:saga, term()}
          | {:halt, term()}

  @type mfa_or_fun ::
          (... -> term())
          | {module(), atom()}

  @typedoc """
  The handler's return contract:

      {:ok, result, [effect]}     # happy path
      {:ok, result}               # happy path with no effects
      {:error, reason}            # business error — framework propagates
  """
  @type handler_return ::
          {:ok, term(), [effect()]}
          | {:ok, term()}
          | {:error, term()}

  @doc """
  Apply a list of effects in the SPEC §4.4 phase order against an
  in-memory `state` map. Returns the new state, the events
  appended (for EventLog), the dispatches to enqueue, the notifies
  to broadcast, the deferred terminations, and any saga handle.

  Phase 1 implementation: pure synchronous reducer over the effect
  list. Phases 1+2 (`:set`, `:emit`) run first (in declared
  order); Phase 3 (`:effect_returning`/`:effect`) runs and binds
  return values to a continuation map that downstream `{:ref,
  name, path}` references substitute against; Phases 4+5+6
  (`:dispatch`/`:notify`/`:terminate`/`:saga`) collect into output
  buckets. `{:halt, reason}` short-circuits.

  The CALLER (Router / Kind.Host in Phase 2) is responsible for:
  - persisting `state` via SnapshotStore
  - appending `events` to EventLog
  - enqueuing `dispatches` via Router.dispatch
  - broadcasting `notifies` via Phoenix.PubSub
  - scheduling `terminations` post-reply
  - handing `saga` to SagaRunner

  This split lets `apply_effects/2` stay pure + testable without
  any process/IO setup.
  """
  @spec apply_effects([effect()], map()) ::
          {:ok, %{state: map(), events: list(), dispatches: list(), notifies: list(), terminations: list(), saga: term() | nil, returning: map()}}
          | {:halt, term(), map()}
  def apply_effects(effects, state) when is_list(effects) and is_map(state) do
    initial = %{
      state: state,
      events: [],
      dispatches: [],
      notifies: [],
      terminations: [],
      effects: [],
      effects_returning: [],
      saga: nil,
      returning: %{}
    }

    case bucket_by_phase(effects, initial) do
      {:halt, reason, partial} -> {:halt, reason, partial}
      {:ok, bucketed} -> apply_buckets(bucketed)
    end
  end

  # First pass: separate effects into phase buckets, preserving
  # declared-order within each phase. Also catches `{:halt, _}`.
  defp bucket_by_phase([], acc), do: {:ok, acc}

  defp bucket_by_phase([effect | rest], acc) do
    case effect do
      {:halt, reason} ->
        {:halt, reason, acc}

      {:set, _key, _value} = e ->
        bucket_by_phase(rest, Map.update!(acc, :events, &[{:__set__, e} | &1]) |> bucket_set(e))

      {:emit, _type, _payload} = e ->
        bucket_by_phase(rest, Map.update!(acc, :events, &[e | &1]))

      {:effect_returning, _fn, _args, _opts} = e ->
        bucket_by_phase(rest, Map.update!(acc, :effects_returning, &[e | &1]))

      {:effect, _fn, _args} = e ->
        bucket_by_phase(rest, Map.update!(acc, :effects, &[e | &1]))

      {:dispatch, %Ezagent.Cmd{}} = e ->
        bucket_by_phase(rest, Map.update!(acc, :dispatches, &[e | &1]))

      {:notify, _topic, _payload} = e ->
        bucket_by_phase(rest, Map.update!(acc, :notifies, &[e | &1]))

      {:terminate, _target} = e ->
        bucket_by_phase(rest, Map.update!(acc, :terminations, &[e | &1]))

      {:saga, _saga} = e ->
        bucket_by_phase(rest, %{acc | saga: e})

      other ->
        raise ArgumentError,
              "Ezagent.Behavior.apply_effects/2 encountered unknown effect: #{inspect(other)}"
    end
  end

  # Apply `:set` effects to state in-place during the first pass so
  # downstream effect-substitution can see them via {:ref, ...}.
  defp bucket_set(acc, {:set, key, value}) do
    %{acc | state: Map.put(acc.state, key, value)}
  end

  # Second pass: filter the synthetic `__set__` markers out of
  # `events` (they were only there to preserve declared-order; the
  # real :set state mutation already happened in `bucket_set`).
  # Then reverse all buckets to restore declared order.
  defp apply_buckets(acc) do
    events =
      acc.events
      |> Enum.reverse()
      |> Enum.reject(&match?({:__set__, _}, &1))

    dispatches = Enum.reverse(acc.dispatches)
    notifies = Enum.reverse(acc.notifies)
    terminations = Enum.reverse(acc.terminations)
    effects = Enum.reverse(acc.effects)
    effects_returning = Enum.reverse(acc.effects_returning)

    # Execute :effect_returning calls in declared order, binding
    # returns into `returning` map. Subsequent effects' `{:ref,
    # name, path}` references substitute against this map.
    {returning, returning_errors} =
      Enum.reduce(effects_returning, {acc.returning, []}, fn
        {:effect_returning, fun, args, opts}, {bound, errs} ->
          name = Keyword.fetch!(opts, :bind_as)

          result =
            case fun do
              f when is_function(f) -> apply(f, args)
              {m, f} when is_atom(m) and is_atom(f) -> apply(m, f, args)
            end

          {Map.put(bound, name, result), errs}
      end)

    # Execute :effect (fire-and-forget) — wrap in try so a failing
    # effect surfaces in the returned map but doesn't crash the
    # caller's reduce.
    effect_errors =
      Enum.reduce(effects, [], fn {:effect, fun, args}, errs ->
        try do
          case fun do
            f when is_function(f) -> apply(f, args)
            {m, f} when is_atom(m) and is_atom(f) -> apply(m, f, args)
          end

          errs
        rescue
          e -> [{:effect_failed, fun, args, e} | errs]
        end
      end)

    # Substitute {:ref, name, path} in dispatches/notifies/events
    # against `returning`.
    events = Enum.map(events, &substitute_refs(&1, returning))
    dispatches = Enum.map(dispatches, &substitute_refs(&1, returning))
    notifies = Enum.map(notifies, &substitute_refs(&1, returning))

    {:ok,
     %{
       state: acc.state,
       events: events,
       dispatches: dispatches,
       notifies: notifies,
       terminations: terminations,
       saga: acc.saga,
       returning: returning,
       errors: Enum.reverse(effect_errors) ++ Enum.reverse(returning_errors)
     }}
  end

  # Recursive ref substitution — walks maps, lists, tuples.
  @doc false
  def substitute_refs({:ref, name, path}, bound) when is_atom(name) and is_list(path) do
    case Map.fetch(bound, name) do
      {:ok, value} -> get_in_safe(value, path)
      :error -> {:ref, name, path}
    end
  end

  def substitute_refs({:ref, name}, bound) when is_atom(name) do
    case Map.fetch(bound, name) do
      {:ok, value} -> value
      :error -> {:ref, name}
    end
  end

  def substitute_refs(%URI{} = uri, _bound), do: uri

  def substitute_refs(%MapSet{} = ms, _bound), do: ms

  def substitute_refs(%_struct{} = s, bound) do
    # For non-URI/MapSet structs (e.g. Ezagent.Cmd), walk fields.
    s
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, substitute_refs(v, bound)} end)
    |> Enum.into(%{})
    |> then(&struct!(s.__struct__, &1))
  end

  def substitute_refs(m, bound) when is_map(m) do
    Map.new(m, fn {k, v} -> {k, substitute_refs(v, bound)} end)
  end

  def substitute_refs(l, bound) when is_list(l) do
    Enum.map(l, &substitute_refs(&1, bound))
  end

  def substitute_refs(t, bound) when is_tuple(t) do
    t
    |> Tuple.to_list()
    |> Enum.map(&substitute_refs(&1, bound))
    |> List.to_tuple()
  end

  def substitute_refs(other, _bound), do: other

  defp get_in_safe(value, []), do: value

  defp get_in_safe(value, [k | rest]) when is_map(value) do
    case Map.fetch(value, k) do
      {:ok, v} -> get_in_safe(v, rest)
      :error -> nil
    end
  end

  defp get_in_safe(_, _), do: nil

  # ---------------------------------------------------------------
  # Behavior-module introspection helpers
  # ---------------------------------------------------------------

  @doc """
  Is the given module a new-style Behavior (declared via `use
  Ezagent.Behavior`)?
  """
  @spec new_style?(module()) :: boolean()
  def new_style?(mod) when is_atom(mod) do
    function_exported?(mod, :__behavior__?, 0) and apply(mod, :__behavior__?, [])
  end

  @doc """
  List the action names declared by a new-style Behavior module.
  Returns `[]` for legacy modules.
  """
  @spec action_names(module()) :: [atom()]
  def action_names(mod) when is_atom(mod) do
    if function_exported?(mod, :__action_names__, 0) do
      apply(mod, :__action_names__, [])
    else
      []
    end
  end

  @doc """
  Look up the full action spec for a new-style Behavior's action.
  Returns `nil` if not declared.
  """
  @spec action_spec(module(), atom()) :: map() | nil
  def action_spec(mod, action) when is_atom(mod) and is_atom(action) do
    if function_exported?(mod, :__action_spec__, 1) do
      apply(mod, :__action_spec__, [action])
    else
      nil
    end
  end

  # ---------------------------------------------------------------
  # Legacy helpers (existed pre-SPEC; preserved)
  # ---------------------------------------------------------------

  @doc """
  Read `reads_sibling_slices/0` from `behavior_module`, defaulting
  to `[]` when the optional callback is not exported.

  Used by `Ezagent.Kind.Runtime.handle_dispatch/4` to decide which
  sibling slices to expose via `ctx[:sibling_slices]`.
  """
  @spec reads_sibling_slices_of(module()) :: [atom()]
  def reads_sibling_slices_of(behavior_module) when is_atom(behavior_module) do
    if function_exported?(behavior_module, :reads_sibling_slices, 0) do
      behavior_module.reads_sibling_slices()
    else
      []
    end
  end

  @doc """
  Read `cap_exempt_actions/0` from `behavior_module`, defaulting to `[]`
  when the optional callback is not exported.
  """
  @spec cap_exempt_actions_of(module()) :: [atom()]
  def cap_exempt_actions_of(behavior_module) when is_atom(behavior_module) do
    if function_exported?(behavior_module, :cap_exempt_actions, 0) do
      behavior_module.cap_exempt_actions()
    else
      []
    end
  end

  @doc """
  Read `workspace_scoped?/0` from `behavior_module`, defaulting to `true`
  when the optional callback is not exported (per SPEC §2b — safer default).
  """
  @spec workspace_scoped?(module()) :: boolean()
  def workspace_scoped?(behavior_module) when is_atom(behavior_module) do
    if function_exported?(behavior_module, :workspace_scoped?, 0) do
      behavior_module.workspace_scoped?()
    else
      true
    end
  end
end
