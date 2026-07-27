defmodule Ezagent.ActionSet do
  @moduledoc """
  Behavior — contract for a piece of action-handling logic.

  > **Phase 3 deletion (2026-05-28).** The legacy
  > `Behavior.invoke/4` dispatch entry point has been retired. New
  > Behaviors opt into the per-action declarative contract via
  > `use Ezagent.ActionSet` and implement one `handle_<action>(args,
  > ctx)` clause per declared action. `invoke/4` is preserved only
  > as an `@optional_callback` (no runtime path consults it) so
  > legacy callers see a precise CompileError rather than a silent
  > dispatch.

  A Behavior is a small module that:
  - declares what actions it implements (`actions/0`)
  - declares the slice of Kind state it owns (`state_slice/0`)
  - initialises that slice (`init_slice/1`)
  - implements one `handle_<action>(args, ctx)` clause per action
  - exposes its `@interface` for adapter generation and arg validation
    (`interface/0`)

  A worked example is `Ezagent.ActionSet.PyAgent` (in `ezagent_plugin_py`); the
  contract is defined here in `ezagent_core` so any plugin can implement it.

  ## Why no macros

  Per Decision #84 / DECISIONS P1-D2, Phase 1 picks the
  `@behaviour Ezagent.ActionSet` + callback pattern over a `use Ezagent.ActionSet`
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
  Execute an action against the slice. (DEPRECATED — Phase 3
  deletion 2026-05-28.)

  This callback was the original dispatch entry point in Phase 1.
  It is now an `@optional_callback` retained only to keep the
  callback declaration grep-able. New-style Behaviors (`use
  Ezagent.ActionSet`) MUST instead define `handle_<action>(args,
  ctx)` per action and let `Ezagent.Kind.Runtime` route through
  the new contract.

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

  Cap-only Behaviors (`dispatchable?/0 == false`, e.g.
  `Ezagent.ActionSet.Notifications`) still list their actions here — that
  is HOW cap-only auth gates get their cap shape into
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
  no dispatchable action) — e.g. `Ezagent.ActionSet.Notifications`'s
  `:subscribe` action is an auth gate, not a dispatch target.

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
          send:    Ezagent.Capability.cap(:session, __MODULE__, :send),
          receive: Ezagent.Capability.cap(:session, __MODULE__, :receive),
          join:    Ezagent.Capability.cap(:session, __MODULE__, :join)
        }
      end

  Direct struct construction is also valid (more verbose; useful when
  declaring a workspace- or instance-bounded cap inline).

  SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  """
  @callback required_caps() :: %{required(action :: atom()) => term()}

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
  by `Ezagent.ActionSet.ExternalMirrorWorker`'s bound
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
  Lifecycle Phase A (SPEC §2.2) — the Lifecycle-surface rename of
  `reads_sibling_slices/0`. A Lifecycle module declares the sibling
  state keys it reads via `reads_siblings [:api_keys]` (or
  `def reads_siblings, do: [:api_keys]`); the runtime surfaces them on
  `ctx.siblings` (normalized to each sibling's persistent flat view —
  see `Ezagent.Kind.Runtime`).

  Same opt-in, same scoping, same `:all_slices`-is-banned rule
  (invariant 18) as the legacy `reads_sibling_slices/0`. Optional
  callback — `Ezagent.ActionSet.reads_siblings_of/1` reads the UNION of
  this and the legacy callback so a Kind mixing legacy + Lifecycle
  Behaviors is correct.
  """
  @callback reads_siblings() :: [atom()]

  @doc """
  Reconcile this Behavior's slice with an external source of truth
  (e.g. a projection table in the DB) after the Kind has loaded
  state from a snapshot.

  ## Why this exists

  `Ezagent.Kind.Snapshot.load_or_init/3` merges the snapshot's
  loaded state OVER the `init_slice/1` fresh state. For Behaviors
  whose slice is backed by a DB projection table (e.g.
  `Ezagent.ActionSet.ExternalMirror.bindings` reads from
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

  @doc """
  RF-3 per-behavior teardown hook — invoked by `Ezagent.Kind.MountDetach`
  when this Behavior is DETACHED from a LIVE instance (runtime
  `Ezagent.Kind.detach/2`).

  ## Why a NEW hook (not `terminate/3` / deactivate / destroy)

  `terminate/3` (→ `deactivate/2`) fires on WHOLE-ENTITY graceful stop and
  runs AFTER the final snapshot, so it CANNOT mutate persisted state.
  `destroy/2` is PERMANENT deletion of the WHOLE entity. Detaching ONE
  behavior from a still-living instance is neither: the entity persists and
  the OTHER behaviors keep running, but THIS behavior's slice must be cleaned
  up and its captured-set membership removed — a write that survives the
  snapshot. There was no seam for that; `on_detach/2` is it.

  ## Arguments + return

  - `slice` — this Behavior's slice (the two-container `%{state: _,
    transients: _}` view) as it stands at detach time.
  - `ctx` — `%{kind_module: module(), self_uri: URI.t()}`.
  - Returns `:ok` (slice cleanup is structural — `MountDetach` DROPS the
    whole slice key after this hook runs, so a returned slice would be
    discarded; `on_detach/2` is for side-effecting teardown of TRANSIENT
    handles: close a transport, release a port, deregister from an ETS
    index, broadcast a "going away" notice).

  ## Error semantics

  A raise / throw / exit is logged + isolated by `MountDetach` — detach still
  proceeds (the behavior is removed regardless; a failed teardown side-effect
  must not strand the behavior half-attached). Best-effort, mirroring
  `terminate/3` / `on_ready/2`.

  Optional callback — `function_exported?/3` probed at detach time; Behaviors
  that don't export it contribute zero overhead.

  Added 2026-06-26 as part of RF-3 (role-foundation runtime detach).
  """
  @callback on_detach(slice :: slice(), ctx :: ctx()) :: :ok

  @optional_callbacks [
    invoke: 4,
    dispatchable?: 0,
    data_owner: 1,
    post_init: 2,
    handle_continue: 3,
    terminate: 3,
    cap_exempt_actions: 0,
    workspace_scoped?: 0,
    reads_sibling_slices: 0,
    reads_siblings: 0,
    reconcile_after_load: 2,
    on_ready: 2,
    on_detach: 2
  ]

  # ---------------------------------------------------------------
  # SPEC 2026-05-28 Router/Behavior/Kind — new contract
  # ---------------------------------------------------------------
  #
  # Everything BELOW this comment is the per-action declarative
  # contract. Modules opt-in via `use Ezagent.ActionSet` instead of
  # `@behaviour Ezagent.ActionSet`. (Phase 3 deletion 2026-05-28
  # removed the legacy adapter module that bridged the two contracts
  # during Phase 1 + Phase 2 migration.)

  @doc """
  `use Ezagent.ActionSet` — opt into the new per-action declarative
  contract per SPEC §2.2.

  ## Injects

  - `Module.register_attribute(__MODULE__, :ezagent_actions, accumulate: true)`
  - The `action/3` macro for declaring an action's args/returns/caps
  - `@before_compile Ezagent.ActionSet` to aggregate `@ezagent_actions`
    into `__actions__/0`, `__action_spec__/1`, and the legacy
    derived callbacks (`actions/0`, `interface/0`, `required_caps/0`,
    `cap_subjects/0`) so a single Behavior can be discovered by the
    legacy registry AND the new Router.
  - A `__behavior__?/0` marker function returning `true` (used by the
    compile-time `Ezagent.Kind.attach/2` collision check).

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

      import Ezagent.ActionSet, only: [action: 2, action: 3]

      @before_compile Ezagent.ActionSet

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
  | `args` | YES | — | Map of arg-name → type spec, or explicit `{:closed_map, schema}`; consumed by `InterfaceValidator` |
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

  @doc """
  Error guard for a common misuse: `action` takes `(name, opts)` (a keyword list),
  NOT a `do`-block. The `do`-block form expands to `action/3` and raises an
  `ArgumentError` at compile time pointing the author at `action/2`.
  """
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
          description: "action :#{name} is missing required key :args (#{inspect(env.module)})"

      is_nil(returns_ast) ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "action :#{name} is missing required key :returns (#{inspect(env.module)})"

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
            "Ezagent.ActionSet action :#{unquote(name)} :modes must be a list (got #{inspect(modes)})"
      end

      unless is_binary(description) do
        raise CompileError,
          description:
            "Ezagent.ActionSet action :#{unquote(name)} :description must be a string (got #{inspect(description)})"
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
    # module. (Phase 3 deletion 2026-05-28 removed the legacy
    # adapter carve-out — every new-style Behavior must now declare
    # its handlers explicitly.)
    defined = Module.definitions_in(env.module, :def)

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

    legacy_ast =
      Ezagent.ActionSet.LegacyCallbacks.inject(
        env,
        action_names,
        interface,
        cap_subjects,
        actions
      )

    quote do
      unquote(introspection_ast)
      unquote_splicing(legacy_ast)
    end
  end

  # ---------------------------------------------------------------
  # Effect applier + Behavior introspection delegators
  # ---------------------------------------------------------------

  @type mfa_or_fun :: Ezagent.ActionSet.Effects.mfa_or_fun()
  @type effect :: Ezagent.ActionSet.Effects.effect()

  @type handler_return ::
          {:ok, term(), [effect()]}
          | {:ok, term()}
          | {:error, term()}

  @doc "Apply a handler's effect list against `state`, returning the effects sorted into their buckets (state/events/dispatches/notifies/terminations/saga/returning) for the runtime to commit, or `{:halt, …}`. Delegates to `Ezagent.ActionSet.Effects`."
  @spec apply_effects([effect()], map()) ::
          {:ok,
           %{
             state: map(),
             events: list(),
             dispatches: list(),
             dispatches_returning: list(),
             notifies: list(),
             terminations: list(),
             saga: term() | nil,
             returning: map()
           }}
          | {:halt, term(), map()}
  defdelegate apply_effects(effects, state), to: Ezagent.ActionSet.Effects

  @doc false
  defdelegate substitute_refs(term, bound), to: Ezagent.ActionSet.Effects

  @doc "Whether `mod` is a new-contract (action-based) Behavior rather than a legacy `invoke/4` one — the branch the runtime takes when dispatching. Delegates to `Ezagent.ActionSet.Introspection`."
  @spec new_style?(module()) :: boolean()
  defdelegate new_style?(mod), to: Ezagent.ActionSet.Introspection

  @doc "The action atoms a Behavior module declares (via `action/2`). Delegates to `Ezagent.ActionSet.Introspection`."
  @spec action_names(module()) :: [atom()]
  defdelegate action_names(mod), to: Ezagent.ActionSet.Introspection

  @doc "The spec map for one `action` of a Behavior (args/returns/caps/modes/data_owner/…), or `nil` if undeclared. Delegates to `Ezagent.ActionSet.Introspection`."
  @spec action_spec(module(), atom()) :: map() | nil
  defdelegate action_spec(mod, action), to: Ezagent.ActionSet.Introspection

  @doc "Resolve a Behavior's cap data-owner for a given instance (entity URI / `:any` / scoped tuple) — used by the CapBAC chokepoint to find who owns the subject. Delegates to `Ezagent.ActionSet.Introspection`."
  @spec data_owner_of(module(), URI.t() | :any | {atom(), URI.t()}) ::
          URI.t() | :any | :no_owner | {:scope, atom(), URI.t()}
  defdelegate data_owner_of(behavior, instance), to: Ezagent.ActionSet.Introspection

  @doc "The LEGACY sibling-slice keys a Behavior reads (the pre-Lifecycle `reads_sibling_slices/0`). Delegates to `Ezagent.ActionSet.Introspection`; prefer `reads_siblings_of/1` for the union."
  @spec reads_sibling_slices_of(module()) :: [atom()]
  defdelegate reads_sibling_slices_of(behavior_module), to: Ezagent.ActionSet.Introspection

  @doc "The UNION of sibling state keys a Behavior reads (`reads_siblings/0` + the legacy `reads_sibling_slices/0`) — surfaced read-only on the handler ctx. Delegates to `Ezagent.ActionSet.Introspection`."
  @spec reads_siblings_of(module()) :: [atom()]
  defdelegate reads_siblings_of(behavior_module), to: Ezagent.ActionSet.Introspection

  @doc "The action atoms a Behavior marks cap-exempt (run without a CapBAC check — a deliberate, audited escape). Delegates to `Ezagent.ActionSet.Introspection`."
  @spec cap_exempt_actions_of(module()) :: [atom()]
  defdelegate cap_exempt_actions_of(behavior_module), to: Ezagent.ActionSet.Introspection

  @doc "Whether a Behavior's required caps are workspace-scoped (the cap must match the instance's workspace). Delegates to `Ezagent.ActionSet.Introspection`."
  @spec workspace_scoped?(module()) :: boolean()
  defdelegate workspace_scoped?(behavior_module), to: Ezagent.ActionSet.Introspection
end
