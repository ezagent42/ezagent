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
  runs AFTER the Kind's standard `:announce_ready` continuation has
  completed (i.e. AFTER the URI is registered + marked `:ready` in
  `Ezagent.ReadyGate` and any buffered casts have been flushed):

  - `post_init/2` — called from `Ezagent.Kind.Server.init/1` just
    after `init_slice/1`. Returns either `:ok` (no post-init work
    needed) or `{:continue, term()}` to schedule one
    `handle_continue/3` round.
  - `handle_continue/3` — invoked by `Ezagent.Kind.Server` once for
    each `{:continue, term}` returned from `post_init/2`. Receives
    the continuation term, this Behavior's slice, and a context map
    (`%{kind_module:, self_uri:}`). Returns `{:ok, new_slice}` to
    update the slice or `:ignore` to leave it unchanged.

  Boot-order invariant: `:announce_ready` ALWAYS runs first. The
  per-Behavior `handle_continue/3` callbacks run in
  `Kind.behaviors/0` declaration order, each as its own
  `handle_continue/2` step on the Kind.Server (so each is a fresh
  scheduler pass; long-running post-init work is not advised).

  Canonical use case: the ExternalMirror Worker (see SPEC
  `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §6.1 split-init pattern) — `init_slice/1` returns minimal state
  with no subscriptions or external I/O, and the post-init
  continuation does the subscribe + binding open AFTER dispatch is
  ready. Without this hook a Worker calling back into its Session
  during `init_slice/1` would deadlock against the Session's
  synchronous `Kind.spawn/2`.
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
    Behavior can route based on Kind / dispatch back into itself

  Returns:
  - `{:ok, new_slice}` — `Kind.Server` writes `new_slice` into
    `state.state[state_slice()]`
  - `:ignore` — slice unchanged (no write-back)

  Runs AFTER `:announce_ready` has completed, so dispatch is open by
  the time the Behavior performs any side-effecting subscribe /
  external I/O. Each post-init continuation is its own
  `handle_continue/2` step on the Kind.Server — they do not block
  each other or anything else on the same scheduler pass.

  Optional callback (probed via `function_exported?/3` per call);
  Behaviors that return `{:continue, term}` from `post_init/2` MUST
  also export this callback.
  """
  @callback handle_continue(term :: term(), slice :: slice(), ctx :: ctx()) ::
              {:ok, new_slice :: slice()} | :ignore

  @optional_callbacks [
    dispatchable?: 0,
    data_owner: 1,
    post_init: 2,
    handle_continue: 3
  ]
end
