# SPEC — Router/Behavior/Kind self-built architecture (full plugin contract rewrite)

**Status:** r2 — codex r1 closures (7 HIGH + 4 MED + 2 LOW addressed inline; verdict REJECT → CONDITIONAL)
**Supersedes (forward design only — alternatives trail retained):** [PR #442 / `spec/eventstore-commanded-migration`](https://github.com/ezagent42/ezagent/pull/442)

## r2 changelog (codex r1 closures, 2026-05-28)

Codex r1 returned **REJECT** with 7 HIGH + 4 MEDIUM + 2 LOW. All 13 findings addressed in r2 via inline edits (sections noted below):

| Finding | Where addressed |
|---|---|
| HIGH-1 — effects grammar can't express value-returning/transactional `MessageStore.write` | §4.4: added `{:effect_returning, mfa, args, bind_as: :name}` effect + inline-Ecto carve-out documented in §4.5 "Allowed direct calls" |
| HIGH-2 — LegacyBehaviorAdapter is non-replay-equivalent | §6.1 Phase 1: now explicitly labels adapter as **dispatch-equivalent, NOT replay-equivalent**; Phase 3 deletes the adapter AND the parity test set ceases to validate replay for adapted Behaviors |
| HIGH-3 — Resource=on_change wrong for high-volume ExternalMirrorWorker (currently `:ephemeral`) | §5.2: Resource pattern split into `:cold_resource` (default `on_change`) + `:hot_resource` (default `:ephemeral` + opt-in periodic); Kind macro accepts `pattern: {:resource, :hot}` |
| HIGH-4 — Resource ownership model under-specified: binding "owned by Session" vs "owned by Workspace"; cap-grants bidirectional | §3.3: added `primary_owner` + `cascade_from` distinction; cap-grants are TWO Resources (one per side, GranteeView + GrantorView) with cross-link |
| HIGH-5 — Saga rollback overstated as "automatic compensation"; should be "best-effort partial" | §4.2 Example 2 + §5.4: changed "framework's destroy-saga walks Resources with automatic compensation if any step fails" → "framework's destroy-saga walks Resources with BEST-EFFORT compensation. Irreversible steps (already-sent notifications, lost in-flight messages) are NOT restored; the compensation reverses what CAN be reversed and leaves an operator-repair marker for the rest" |
| HIGH-6 — `ctx.read` rules contradict examples (UserCredentials calls `Ezagent.Users.set_password` inline) | §4.5: new subsection "Allowed direct calls vs forbidden" — Ecto writes via Repo-backed query modules (`Ezagent.Users`, `Ezagent.MessageStore`, etc.) ARE allowed inline IF they are idempotent + transactional on their own. Non-idempotent side effects, PubSub broadcasts, cross-Kind dispatches MUST go via effects |
| HIGH-7 — `caps:` macro doesn't preserve 5-axis cap shape (`kind: :any`, scope tuples, cross-workspace) | §4.3: full macro grammar rewritten — `caps: [{action, axes_map}]` form supports all 5 axes (`kind`, `behavior`, `action`, `instance`, `workspace_uri`, plus `scope:` for tuple-bounded caps); `workspace_scoped?` opt-out via `caps: [{action, workspace_scoped?: false}]` |
| MED-1 — Resource URI shape drops workspace (`resource://agent/cc_demo/...` collides cross-workspace) | §3.3 + OQ-1: Resource URI is now `resource://<owner_kind>/<workspace>/<owner_name>/<type>/<name>` — workspace segment mandatory |
| MED-2 — Multi-Behavior routing not explicit about BehaviorRegistry shape | §2.3 + §4.1: `attach Behavior, actions: […]` builds the equivalent of today's `BehaviorRegistry.register(kind_module, action, behavior_module)` — existing stored `%Capability{behavior: Module}` rows remain valid |
| MED-3 — Migration parity excludes EventLog rows but EventLog has observable consumers | §7.3: split into "dispatch parity" (legacy adapter mode — same reply, same PubSub) vs "replay parity" (new-design only — events fold to same state). The new EventLog rows are documented as **intentional incompatibility**, not equivalence |
| MED-4 — Effort estimate optimistic (8-10wk most-likely is closer to 15-21wk) | §6.3 revised: 8-10wk is now the LOWER-confidence band; 12-16wk is most-likely; 21wk is the upper bound. Phase 1 floor raised to 4-5wk to account for legacy adapter (~300 LOC). Phase 2 floor raised based on PR-G AgentBridge precedent |
| LOW-1 — `{:dispatch_call, on_result:}` in grammar but OQ-7 recommends removing | §4.4: `:dispatch_call` removed; saga is the only synchronous chaining mechanism |
| LOW-2 — PubSub ordering claims conflict between example and OQ-3 | §4.4: ordering normative — effects fire in **declared order within each phase**; the phases are (1) set, (2) emit, (3) dispatch, (4) notify, (5) effect, (6) terminate/saga (post-reply). The Chat example reordered to match |

The remaining open questions (OQ-1 through OQ-8) are unchanged; codex did NOT find new OQs.


**Allen directive trail (2026-05-28 09:33 → 10:36):** Allen confirmed (a) full breaking-change rewrite of plugin contract (Q2=a, no compat shim), (b) new forward SPEC supersedes #442 §2–§12 (Q3=a), (c) two in-flight slice/snapshot bugs (Bug A + Bug B) are stopped — to be re-attempted after this SPEC lands. PR #442's §1.5.7 (Native Consolidation Path / Option B'') is the **directly upstream design lineage** of this SPEC: B'' identified the 5 framework primitives; this SPEC tightens them into a 3-primitive (`Router` / `Behavior` / `Kind`) contract that **plugin authors never see slice or snapshot**.

**Architectural commitment**: this SPEC is the design ezagent commits to for the next 8–10 weeks of work (Phase 1: ~3wk framework primitives; Phase 2: ~4–6wk per-domain plugin migrations; Phase 3+4: ~1wk cleanup). The North Star is `feedback_north_star_plugin_isolation` — "future devs work on different plugins without coordination." Every decision in this SPEC was made by asking: does this keep plugin authors out of core?

---

## Table of contents

- [§1 — Problem statement](#§1--problem-statement)
- [§2 — The 3 core primitives (Router / Behavior / Kind)](#§2--the-3-core-primitives-router--behavior--kind)
- [§3 — The 3 composition patterns (Session / Entity / Resource)](#§3--the-3-composition-patterns-session--entity--resource)
- [§4 — Plugin contract surface](#§4--plugin-contract-surface)
- [§5 — Framework machinery (plugin-invisible)](#§5--framework-machinery-plugin-invisible)
- [§6 — Breaking-change migration plan](#§6--breaking-change-migration-plan)
- [§7 — Testing strategy](#§7--testing-strategy)
- [§8 — Open questions for Allen](#§8--open-questions-for-allen)
- [§9 — Codex adversarial-review attack vectors](#§9--codex-adversarial-review-attack-vectors)
- [§10 — Migration risk register](#§10--migration-risk-register)
- [§11 — Acceptance criteria (the "done" gate)](#§11--acceptance-criteria-the-done-gate)

---

## §1 — Problem statement

*This section answers: "what hurts today, and why does naming Router/Behavior/Kind as 3 distinct primitives — with Behaviors blind to slice and snapshot — structurally fix it?"*

PR #442 §1.1–§1.4 already inventoried the pain comprehensively: no formal event log, no replay, no projection split, no saga primitive, no idempotency on caller-supplied id, no cross-Kind orchestration abstraction. **This SPEC does not duplicate that inventory** — read PR #442 §1.1–§1.4 for the canonical list, then return here for the three new diagnostic axes this SPEC adds.

### §1.1 — The plugin-author cognitive overload class

Current `@behaviour Ezagent.Behavior` (file `apps/ezagent_core/lib/ezagent/behavior.ex`, 580 LOC of contract) forces every plugin author to learn:

| Concept | What the plugin author must learn | Where leaked from framework |
|---|---|---|
| Slice schema | The Behavior's `state_slice/0` atom, the slice's inner shape, defensive `Map.get/3` for legacy snapshots, how the slice is merged on snapshot load (`load_or_init/3`'s `init_slice` ∪ snapshot) | `state_slice/0`, `init_slice/1`, the 3rd arg of `invoke/4` |
| Snapshot policy | The 5-enum `persistence/0` (`:ephemeral` / `{:snapshot, :on_change}` / `{:snapshot, :periodic, ms}` / `:on_terminate` / `:external`), what gets persisted, what doesn't, what `:not_durable` means | `Kind.persistence/0`, post-init commit nuances, `handle_kind_message/3` persistence, `terminate/3` slice non-persistence |
| Invariant maintenance | Cross-Behavior slice fields (e.g. `:lifecycle` counter, `:identity` `caps`), `reads_sibling_slices/0` declaration, default `Map.update/4` lazy seeding for fold-on registered Behaviors | `reads_sibling_slices/0`, `Kind.Runtime.maybe_inject_sibling_slices/3` |
| Cross-Kind dispatch from inside `invoke/4` | The `Ezagent.Invocation.dispatch/1` call, ctx threading, the `try/rescue` cleanup pattern for partial-failure | `EzagentDomainChat.create_session/3` is the canonical anti-pattern: 5 dispatches across 4 Kinds with hand-rolled compensation |
| Error-on-persist semantics | What happens when `commit_and_notify/3` returns `{:error, _}` — `commit_post_init/2` swallows + logs; `commit_and_notify/3` (dispatch path) propagates `{:persistence_failed, _}`; `persist_handle_info_mutation/4` swallows | 3 different paths (dispatch / post-init / handle_info) with 3 different policies |
| Cap declaration with action axis | `required_caps/0` returns `Capability.cap/3` with kind+behavior+action; substitution of `:any` at dispatch time; `cap_exempt_actions/0`; `workspace_scoped?/0`; `data_owner/1` | 4 callbacks all interacting with `Kind.Runtime.handle_dispatch/4` step 5.5 |
| Boot-order lifecycle | `post_init/2` + `handle_continue/3` + `on_ready/2` + `terminate/3` — when does each fire, what's persisted, what's discarded | 4 optional callbacks across `behavior.ex` lines 217-524 |

That's **eight independent concept-clusters** a plugin author must internalize **before writing a single dispatchable action**. The current `behavior.ex` moduledoc is 580 LOC of contract; comparable Behaviors run 200–1300 LOC. The signal-to-boilerplate ratio is poor.

**Historical bugs traceable to plugin-author mishandling**:

1. **PR #141 SPEC v2 register/lookup key parity** — divergent default `workspace_scoped?` between register and lookup silently mis-bound dispatch (memory `feedback_register_lookup_key_parity`). Root cause: plugin author had to know the cap-key parity invariant, which lived implicitly in two separate callbacks.
2. **PR #150 ApiKeys-to-Agent flip CRIT-1 (`reads_sibling_slices` escape hatch)** — codex r1 flagged that the original "expose all sibling slices via `ctx.all_slices`" let any Behavior read any sibling's secrets. Fix: `reads_sibling_slices/0` explicit list. Root cause: plugin authors needed cross-Behavior reads but the framework's only mechanism was full slice exposure.
3. **SPEC #440 destroy cascade — 4-round codex REJECT** — `Behavior.Lifecycle.invoke(:terminate)` does `Task.start(fn -> ... DynamicSupervisor.terminate_child ... end)` after returning success. The "deferred termination" hack is necessary because `invoke/4` runs inside the target Kind's GenServer — killing self before reply lands. Root cause: cross-Kind orchestration in Behavior code.
4. **SPEC #423 cap-vis 4-round REJECT class** — every round, codex flagged "plugin code reads framework internals" (caps storage shape, slice projection vs source-of-truth, etc.). Root cause: slice exposure to Behaviors leaked framework cap storage.
5. **SPEC #431 URI-canonical r2 fix** — pre-fix snapshots contained `URI.parse`-built `%URI{authority: "user"}` structs that silently fail struct-equality vs the canonical `URI.new!`-built shape. Plugin authors compared URIs naively; framework canonicalized only at certain seams. Root cause: every Behavior author had to know which seams canonicalized and which didn't.

This violates `feedback_north_star_plugin_isolation`: a plugin author trying to write a 30-LOC Behavior must internalize ~580 LOC of framework contract first, plus 5+ historical-bug post-mortems. **The cognitive overhead has been the largest hidden cost of every multi-round REJECT cycle.**

### §1.2 — The repeated 4-round-REJECT class

Three recent SPECs hit 4-round codex REJECT walls:

| SPEC | What codex repeatedly flagged | Root cause |
|---|---|---|
| #440 destroy-lifecycle | "Synthetic events from invoke/4 are not real events", "deferred-termination Task is a hack to dodge self-kill", "cap on `(agent, :terminate)` overlaps with cap on `(workspace, :destroy)`" | `Behavior.invoke/4` cannot orchestrate cross-Kind cleanup; the framework has no Saga primitive |
| #442 eventstore-commanded | "Behavior's slice exposure leaks into business code", "snapshot policy in Behavior conflates persistence concern with action concern", "Commanded migration would just rewrite the same conflations against Commanded's primitives instead of fixing them" | Plugin contract conflates 3 framework concerns (state, snapshot, cross-Kind dispatch) into one callback |
| #423 cap-vis r1–r4 | "Plugin code reads framework internals", "the cap action axis lives in plugin code but is interpreted by framework matcher" | Cap action axis on `required_caps/0` is a plugin-declared shape consumed by framework; the interpretation rule moved between every round |

The pattern: codex isn't catching defects in the SPEC; **codex is repeatedly catching the same structural defect — the abstraction layer is at the wrong place.** Plugin code should not see slice, should not own snapshot policy, should not orchestrate cross-Kind cleanup, should not interpret cap-matching semantics.

### §1.3 — LOC growth pattern

Current 22 Behaviors ([`find apps -path "*/lib/ezagent/behavior/*.ex"`](#) yields):

| Behavior | LOC | Pattern dominator |
|---|---:|---|
| Chat (`domain_chat/.../chat.ex`) | 1343 | invoke/4 + `MessageStore.write` + `Phoenix.PubSub.broadcast` + `Resolver.resolve` + N recipient dispatches |
| Workspace (`domain_workspace/.../workspace.ex`) | 1332 | cross-Kind orchestration (workspace → bindings → sessions → agents) all in one invoke/4 |
| Identity (`domain_identity/.../identity.ex`) | 912 | cap MapSet management + slice fields + boot reconcile + cross-Kind grant propagation |
| ExternalMirror (`domain_external_mirror/.../external_mirror.ex`) | 877 | binding lifecycle, per-binding Worker spawn, slice-as-projection-cache |
| AgentTemplate (`domain_chat/.../template.ex`) | 747 | template instantiation cascade |
| Sandbox (`core/.../sandbox.ex`) | 746 | config_dir create/destroy + Template Class plugin contract |
| ExternalMirrorWorker (`...external_mirror_worker.ex`) | 692 | publisher cursor + ring + slice reconcile |
| Publisher.SessionImpl (`...publisher/session_impl.ex`) | 610 | slice-change observer + cursor management |
| NpAgent / CurlAgent / Echo plugin Behaviors | 1069 (combined) | dispatch fan-out + slice as request log |
| UserTokens / WorkspaceUserAdmin / Lifecycle | 807 (combined) | admin actions + workspace propagation |
| ApiKeys / Routing / Echo / UserCredentials | 826 (combined) | per-Behavior slice + cap declaration |

**Total**: ~11,000 LOC across 22 modules. Of that, very roughly:

- ~30% (~3,300 LOC) — actual business logic (what the action **means**)
- ~30% (~3,300 LOC) — slice management boilerplate (read/write/default/merge/reconcile)
- ~20% (~2,200 LOC) — cross-Kind dispatch + compensation (`try/rescue` cleanup)
- ~10% (~1,100 LOC) — snapshot/persistence wiring
- ~10% (~1,100 LOC) — cap declaration & framework-interface boilerplate

The 60–70% that is **not** business logic is the class of code this SPEC structurally eliminates. The framework absorbs slice/snapshot/dispatch/cap-interpretation as machinery; plugin authors write actions.

Per `feedback_let_it_crash_no_workarounds`: **the structural fix is to move the abstraction layer down**, not to add a compat shim, layer a Commanded migration on top, or attach event-sourcing as a third-party concern. Move the boundary; rewrite the plugin contract once; finish.

---

## §2 — The 3 core primitives (Router / Behavior / Kind)

*This section answers: "what are the three things plugins and operators interact with, and exactly which is owned by framework vs plugin?"*

ezagent's architecture is reducible to three primitives. Every concept in the codebase composes from these.

| Primitive | Owns | Plugin-author touches |
|---|---|---|
| **Router** | dispatch envelope, cap check, audit, idempotency, workspace iso, replay routing | NEVER calls directly; receives commands routed to it |
| **Behavior** | the action namespace + how each action's effects are computed | declares `action/3` + writes `handle_<action>/2` |
| **Kind** | URI identity, process lifecycle, attached Behavior list, composition pattern | declares Kind + attaches Behaviors |

### §2.1 — `Ezagent.Router`

#### Conceptual definition

The Router is the **dispatch primitive**. It takes a `%Cmd{target, action, args, ctx}` envelope and returns `{:ok, result} | {:error, term}` — having handled URI parsing, capability check, idempotency, workspace isolation, audit write, behavior-handler routing, effect application, and result post-processing.

Conceptually, it is what `Ezagent.Invocation.dispatch/1` + `Ezagent.Kind.Runtime.handle_dispatch/4` are today — but **named**, **owned by framework**, **never called from inside a Behavior**.

#### Public API

```elixir
defmodule Ezagent.Router do
  @type cmd :: %Ezagent.Cmd{
    target: URI.t(),                # the Kind instance URI
    action: atom(),                 # the action atom, e.g. :send, :destroy
    args: map(),                    # validated against the Behavior's @interface
    ctx: %{
      caller: URI.t() | :system,
      reply: Ezagent.Invocation.reply_target(),
      trace_id: String.t(),
      command_uuid: String.t() | nil,   # caller-supplied idempotency key
      deadline_ms: pos_integer() | nil
    }
  }

  @spec dispatch(cmd) ::
          {:ok, term()}
          | :ok
          | {:error, :unauthorized | :cross_workspace_denied | :no_such_actor |
                     :not_ready | {:unknown_action, atom()} | {:invalid_args, list()} |
                     {:behavior_exception, term(), term()} | term()}

  @spec dispatch_saga(saga :: Ezagent.Saga.t(), ctx :: map()) ::
          {:ok, effect_map :: map()}
          | {:error, step :: atom(), reason :: term(), compensated :: [atom()]}
end
```

#### Internal mechanics (framework-private)

1. URI canonicalization (`Ezagent.URI.instance/1`) — strips `?action=…`, normalizes scheme/host/path
2. Idempotency check via `ctx.command_uuid` (if present) against `Ezagent.Idempotency`
3. Ready-gate consultation (`:ready` / `:not_ready` / `:unknown` per `Ezagent.ReadyGate`)
4. Behavior lookup (`BehaviorRegistry.lookup({kind_module, action})`)
5. **Capability check at dispatch boundary** — Behaviors never see this
6. Workspace isolation check (caller's workspace ↔ target's workspace, with `:any` bypass)
7. Args validation against `behavior.interface()[action].args`
8. Read framework-managed state (the slice — but the Behavior gets a `read/1` function, NOT the slice itself)
9. Invoke handler: `behavior.handle_<action>(args, ctx)` → returns `{result, effects}`
10. Apply effects in declared order (see §4.4 vocabulary)
11. EventLog append (audit)
12. Snapshot commit (per Kind-level policy — Behavior is blind)
13. Result post-processing (`Invocation.reply/2` per ctx.reply)

#### What plugin authors DO touch vs DO NOT touch

| Concern | Plugin author | Framework |
|---|---|---|
| Build a `%Cmd{}` | Operators/LV/CLI/Channel adapters DO build commands (they call Router) | — |
| Call `Router.dispatch/1` | DO call (from adapters) | — |
| Receive `(args, ctx)` in handler | YES — sees handler's two args | injects ctx |
| Capability check | NEVER — declared via `caps:` on `action/3` macro | YES — at step 5 of dispatch |
| Audit write | NEVER | YES — at step 11 |
| Snapshot commit | NEVER | YES — at step 12 (per Kind policy) |
| Cross-Kind cascade | NEVER directly — emits `{:dispatch, %Cmd{}, …}` effect or returns a Saga | YES — Router routes the effect |
| URI canonicalization | NEVER | YES — at step 1 |

#### Concrete code example (5-line caller)

```elixir
# LV handle_event — operator clicks "Destroy" button
def handle_event("destroy", %{"agent_uri" => uri_str}, socket) do
  caller = socket.assigns.current_user_uri

  cmd = %Ezagent.Cmd{
    target: URI.new!(uri_str),
    action: :destroy,
    args: %{},
    ctx: %{caller: caller, reply: :ignore, trace_id: socket.assigns.trace_id, command_uuid: nil}
  }

  case Ezagent.Router.dispatch(cmd) do
    {:ok, _} -> {:noreply, push_navigate(socket, to: ~p"/agents")}
    {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "Permission denied.")}
    {:error, reason} -> {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
  end
end
```

The LV handler is the same shape regardless of whether `:destroy` lives on `Agent` (Entity pattern), `Worker` (Resource pattern), or `Session` (Session pattern). The Router doesn't care; the Behavior is responsible for what `:destroy` means.

#### Module location & LOC

`apps/ezagent_core/lib/ezagent/router.ex` — ~150–200 LOC. Roughly: 50 LOC dispatch pipeline + 50 LOC saga delegation + 50 LOC type definitions + 30 LOC error normalization. It is mostly a refactor of today's `Invocation.dispatch/1` + `Kind.Runtime.handle_dispatch/4`, **renamed and with slice handling moved out into framework-private modules**.

---

### §2.2 — `Ezagent.Behavior`

#### Conceptual definition

A Behavior is a **bundle of action handlers** attached to one or more Kinds. It declares what actions exist, what args/caps/return each requires, and the pure `(args, ctx) → {result, effects}` function for each.

**Crucial breaking change from today**: handlers no longer receive `slice`, no longer return `new_slice`, and never call `Ezagent.Invocation.dispatch/1` directly.

#### Public API — the new macro

```elixir
defmodule Ezagent.Behavior.Chat do
  use Ezagent.Behavior

  # Declarative action namespace — what actions exist, their schemas, their caps
  action :send,
    args: %{message: Ezagent.Message},
    returns: %{stored: :boolean},
    caps: [:send],                       # caller must hold cap with action: :send
    modes: [:cast]

  action :receive,
    args: %{message: Ezagent.Message},
    returns: :ok,
    caps: [:receive],
    modes: [:cast]

  # Handler — NO slice arg, NO new_slice return.
  # ctx exposes a `read` function for framework-managed state.
  def handle_send(%{message: %Ezagent.Message{} = msg}, ctx) do
    session_uri = ctx.self_uri

    case ctx.read.(:last_message_id) do
      ^msg.id ->
        # Idempotent retry — no effects
        {:ok, %{stored: true}, []}

      _ ->
        recipients = Ezagent.Routing.Resolver.resolve(msg, session_uri, ctx.read.(:members))

        effects = [
          {:set, :last_message_id, msg.id},
          {:set, :last_message, msg},
          {:set, :send_cursor, ctx.read.(:send_cursor, 0) + 1},
          {:emit, :message_sent, %{message: msg, session_uri: session_uri}},
          {:notify, "esr:session:#{URI.to_string(session_uri)}:events",
                    {:chat_message, session_uri, msg}}
        ] ++ Enum.map(recipients, fn rcpt ->
          {:dispatch, %Ezagent.Cmd{
            target: rcpt, action: :receive,
            args: %{message: msg},
            ctx: %{caller: session_uri, reply: :ignore, command_uuid: "chat:#{msg.id}:#{rcpt}"}
          }}
        end)

        {:ok, %{stored: true}, effects}
    end
  end

  def handle_receive(%{message: msg}, ctx) do
    case ctx.kind_module do
      Ezagent.Entity.User ->
        {:ok, :ok, [
          {:set, :recent_messages, prepend_bounded(ctx.read.(:recent_messages, []), msg, 20)},
          {:emit, :message_received, %{user_uri: ctx.self_uri, message: msg}}
        ]}

      Ezagent.Entity.Agent ->
        {:ok, :ok, [
          {:effect, &Ezagent.AgentBridge.deliver/2, [ctx.self_uri, msg]},
          {:emit, :message_received, %{agent_uri: ctx.self_uri, message: msg}}
        ]}
    end
  end
end
```

#### Macro mechanics

`use Ezagent.Behavior` injects:

- `@before_compile` hook that aggregates all `action :name, ...` declarations into `actions/0`, `required_caps/0`, `interface/0`, `cap_subjects/0` — the legacy contract callbacks are auto-derived from the new declarative form.
- A `handle_<action>/2` dispatcher that the Router calls.
- Compile-time invariants: every `action :foo, …` declaration MUST have a matching `def handle_foo(args, ctx)`. The plugin checks (current `Ezagent.Invariants.BehaviorRequiredCapsParityTest`) become compile-time errors.

#### The `ctx.read` contract

Inside a handler, `ctx.read.(key)` and `ctx.read.(key, default)` read **framework-managed state** for the current Kind instance. The handler:

- can NOT see the slice as a data structure (no defensive `Map.get`, no merge-on-load concerns)
- can NOT see sibling-Behavior state directly (cross-Behavior reads go through the Kind's declared cross-behavior-read contract — see §3.4 Mapping table)
- gets a strongly-consistent, in-process read (the same GenServer process owns the state)

#### What plugin authors DO touch vs DO NOT touch

| Concern | Plugin author | Framework |
|---|---|---|
| Declare actions | YES — via `action :name, args: …, caps: […]` macro | aggregates to `actions/0`/`interface/0`/`required_caps/0` |
| Write `handle_<action>/2` | YES | YES — calls it from Router step 9 |
| Read current state | YES — via `ctx.read.(:key)` | owns the storage |
| Mutate state | NEVER directly — emits `{:set, key, value}` effect | YES — applies effects in order |
| Emit an event | NEVER directly — emits `{:emit, type, payload}` effect | YES — writes to EventLog |
| Dispatch cross-Kind | NEVER directly — emits `{:dispatch, %Cmd{}}` effect | YES — Router fans out |
| Snapshot | NEVER — Kind-level policy | YES |
| Cap check | NEVER — declared via `caps:` on `action/3` | YES — at Router boundary |
| Compensation / saga | NEVER inside `handle_<action>/2` — handler returns `{:ok, result, [{:saga, %Ezagent.Saga{…}}]}` or the orchestrator builds a saga and `Router.dispatch_saga/2` runs it | YES — `Ezagent.SagaRunner` |

#### Module location & LOC budget

`apps/ezagent_core/lib/ezagent/behavior.ex` — ~250–300 LOC (the macro + behaviour callback definitions). The current 580-LOC `behavior.ex` shrinks because:

- `post_init/2` / `handle_continue/3` / `on_ready/2` / `terminate/3` boot-lifecycle hooks become Kind-level concerns (most Behaviors don't need them; Kinds that do — e.g. ExternalMirror Worker — declare them on the Kind, not on every Behavior).
- `reads_sibling_slices/0` is gone (Kind declares cross-Behavior read graph; see §3.4).
- `state_slice/0` is gone (Kind composes state from Behavior contributions via declared field schemas — see §4.4 effects vocabulary).
- `reconcile_after_load/2` becomes a Kind-level concern (the Kind composes its rebuild from its attached Behaviors' contributions).

---

### §2.3 — `Ezagent.Kind`

#### Conceptual definition

A Kind is **a named class of stateful entities** that have a URI, a lifecycle, and a state. ezagent today has 13 Kinds (counting all current `entity://` schemes + `session://` + `system://` derivatives). Each Kind declares: its URI scheme, the Behaviors attached to it, its composition pattern (§3), its supervision strategy, and its persistence policy.

Plugin authors declare Kinds. They do **not** touch the Kind's state machinery — that's framework-internal.

#### Public API — Kind declaration

```elixir
defmodule Ezagent.Entity.Agent do
  use Ezagent.Kind,
    pattern: :entity,                            # see §3
    uri_scheme: "entity://agent/",
    supervisor: EzagentDomainChat.AgentSupervisor

  # Behaviors attached to this Kind (and the cap-restriction shape)
  attach Ezagent.Behavior.Chat,            actions: [:receive]
  attach Ezagent.Behavior.Identity,        actions: [:list_caps, :grant_cap, :revoke_cap]
  attach Ezagent.Behavior.Sandbox
  attach Ezagent.Behavior.ApiKeys
  attach Ezagent.Behavior.Lifecycle,       actions: [:destroy]

  # Cross-Behavior read graph (replaces `reads_sibling_slices/0` per-Behavior declarations)
  read_graph %{
    Ezagent.Behavior.Chat => [Ezagent.Behavior.ApiKeys],
    # Chat handler on Agent reads ApiKeys.key to attach Authorization header
  }

  # Composition pattern's required slots (Entity pattern — §3.2)
  owner_kind Ezagent.Entity.User
  authenticates_via Ezagent.Behavior.ApiKeys
end
```

#### Required and optional callbacks

The legacy `@behaviour Ezagent.Kind` callbacks (`type_name/0`, `behaviors/0`, `persistence/0`, `uri_from_args/1`, `snapshot_version/0`, `supervisor/0`, `spawn_strategy/0`, `terminate_strategy/0`, `holds_cap?/2`) reduce to:

| New | Replaces (today) | Owner |
|---|---|---|
| `pattern:` macro arg | (none — pattern was implicit) | declared by Kind author |
| `attach Behavior, opts` | `behaviors/0` + per-Behavior `required_caps/0`/`actions/0` slicing | declared by Kind author |
| `uri_scheme:` macro arg | hard-coded module attr in each Kind | declared by Kind author |
| `supervisor:` macro arg | `supervisor/0` callback | declared by Kind author |
| `spawn_strategy:`/`terminate_strategy:` macro args | the same | declared by Kind author |
| `read_graph` | per-Behavior `reads_sibling_slices/0` | declared by Kind author |
| **(framework-owned, NO Kind callback)** | `persistence/0` | **framework decides per pattern** — see §5.2 |
| **(framework-owned)** | `snapshot_version/0` | framework derives from EventLog event-type version |
| **(framework-owned)** | `holds_cap?/2` | framework — uses `EventLog.stream_by_aggregate` + projection |

#### Internal mechanics

- The `Kind.Server` GenServer (`apps/ezagent_core/lib/ezagent/kind/server.ex`, 828 LOC today) becomes `apps/ezagent_core/lib/ezagent/kind/host.ex` — same role but state model is private to framework.
- State on the GenServer is a single map keyed by `{behavior_module, field_atom}` (instead of today's nested `%{slice_key => slice_map}`). Effects `{:set, key, value}` populate this map; `ctx.read.(:key)` queries it; the Behavior never sees the outer map shape.
- `reads_sibling_slices/0` becomes the Kind's `read_graph` declaration — checked at compile time against the attached Behaviors' actions.
- **`attach Behavior, actions: [...]` populates the BehaviorRegistry** (codex r1 MED-2 closure): the macro emits the equivalent of today's `Ezagent.BehaviorRegistry.register(kind_module, action, behavior_module)` at app boot. The routing key remains `(kind_module, action)` → `behavior_module`, IDENTICAL to today's lookup shape. Existing stored `%Capability{behavior: Ezagent.Behavior.Identity, ...}` MapSet entries in user identity slices remain valid — the Behavior module reference is preserved across the macro change. **No DB data migration needed for cap rows.**

#### Module location & LOC

`apps/ezagent_core/lib/ezagent/kind.ex` — the macro (~150 LOC) + the behaviour (~50 LOC), down from today's 459 LOC because `holds_cap?/2`, `default_holds_cap?/2`, `get_slice/2`, and the spawn/terminate strategy logic move to framework-internal modules (`Ezagent.Kind.Host`, `Ezagent.Caps.Engine`).

`apps/ezagent_core/lib/ezagent/kind/host.ex` — ~400–500 LOC (the GenServer that hosts every Kind instance).

---

## §3 — The 3 composition patterns (Session / Entity / Resource)

*This section answers: "every Kind is one of three patterns; this is the only knowledge a plugin author needs to know which lifecycle, identity, and cap shape applies."*

A Kind is **always exactly one** of three composition patterns. The pattern determines: URI scheme conventions, lifecycle hooks, default caps, ownership shape, and what kinds of cross-Kind references are allowed.

| Pattern | URI scheme | Lifecycle | Authentication | Owns | Typical Behaviors |
|---|---|---|---|---|---|
| **Session** | `session://` | created → members joined → messages → archived | inherits caller's identity | messages, members, monitors | Chat, ExternalMirror Worker binding, Routing |
| **Entity** | `entity://kind/workspace/name` | registered → caps granted → operates → destroyed | password/token/key (per Kind's `authenticates_via`) | Resources | Identity, Credentials, Lifecycle, Sandbox |
| **Resource** | `resource://owner_kind/owner_name/type/name` | created → mutated → destroyed (cascade with owner) | by Entity ownership (transitive) | nothing | one Behavior typically |

### §3.1 — Session pattern

#### Definition

A **multi-participant, time-bounded** context that mediates communication or state-coordination between entities. URI scheme: `session://<template>/<workspace>/<name>` (e.g. `session://default/team-alpha/main`).

#### Properties

- **Multi-participant**: members join/leave; one Session may have N entities attached
- **Time-bounded**: has a lifecycle distinct from any one member
- **External binding**: optionally bound to an external channel (Feishu group, WS bridge) via ExternalMirror — the binding is a Resource owned by the Session
- **Messages are first-class events**: every `:send` is an EventLog row; replay is meaningful (audit, time-travel)
- **Identity inheritance**: a Session does not authenticate; the caller's Entity URI flows through ctx.caller

#### Lifecycle hooks (framework-provided, opt-in per Kind)

- `created` — first dispatch arrives, no members yet
- `member_joined(entity_uri)` — Routing updates fan-out tables
- `message_sent(msg)` — EventLog append; PubSub fan-out
- `member_left(entity_uri)` — possibly archives Session if last member
- `archived` — frozen state; reads allowed; no new dispatches

#### Current Kinds matching this pattern

`Ezagent.Entity.Session` (despite its module name — it IS a Session-pattern Kind).

### §3.2 — Entity pattern

#### Definition

A **named, authenticatable principal** — a user, an agent, a workspace, a template. URI: `entity://<kind>/<workspace>/<name>`. Has an admin lifecycle (create / destroy / update). May own Resources.

#### Properties

- **Authenticatable**: declares an `authenticates_via` Behavior — `User` via `UserCredentials` (password); `Agent` via `ApiKeys`; `Workspace` via membership; `AgentTemplate` via owner-cap inheritance
- **Owns Resources**: each Entity may own N Resources; destroying the Entity cascades to its Resources (saga-driven, framework-managed)
- **Cap-bearing**: holds capabilities (delegated, structural, or admin-granted)
- **Admin lifecycle**: workspace-scoped admin can create / update / destroy

#### Current Kinds matching this pattern

`Ezagent.Entity.User`, `Ezagent.Entity.Agent`, `Ezagent.Entity.Workspace`, `Ezagent.Entity.AgentTemplate`, `Ezagent.Entity.SessionTemplate`.

### §3.3 — Resource pattern

#### Definition

A **thing owned by an Entity**, referenced by URI, lifecycle-managed and authorization-checked at per-action granularity. URI scheme: `resource://<owner_kind>/<workspace>/<owner_name>/<type>/<name>` (e.g. `resource://agent/team-alpha/cc_demo/config-dir/main`).

**Codex r1 MED-1 closure** — the URI now includes a workspace segment to prevent cross-workspace collisions (`resource://agent/team-alpha/cc_demo/...` vs `resource://agent/system/cc_demo/...` are distinct). The workspace segment is the **owner's workspace** at Resource-creation time and is immutable for the lifetime of the Resource.

#### Properties

- **Has a `primary_owner`**: the Entity URI that controls Resource lifecycle (create / destroy / cap-shape decisions). Declared as part of the Resource Kind, not as a slice field.
- **May have a `cascade_from`**: a SECONDARY relationship — when the cascade-from Entity is destroyed, this Resource is also destroyed, EVEN IF its primary_owner is still alive. Used for relationships like cap-grants (see below).
- **Type-tagged**: every Resource declares its type (`:config-dir`, `:secret`, `:file`, `:binding`, `:cap-grant`, `:token`, …)
- **Per-action authorization**: caps are checked per-action; the primary_owner is implicitly authorized for most actions but can be overridden via per-action `caps:` declaration
- **Cascade on owner destroy**: when the primary_owner OR any `cascade_from` Entity is destroyed, the framework's destroy-saga (§5.4) destroys this Resource

**Codex r1 HIGH-4 closure (Resource ownership model)** — the earlier draft had two contradictions:

1. **§3.1** said the external binding is "owned by Session" while **§3.3** said "owned by Workspace." Fix: a binding is **primary_owner: Session, cascade_from: Workspace**. Destroying the Session destroys the binding (primary lifecycle); destroying the Workspace also destroys the binding (cascade — the binding can't outlive its workspace).
2. **Cap-grants are bidirectional** — User1 grants cap to User2. Who "owns" the grant? The grantor controls revocation; the grantee holds the cap in their identity slice for matching. Single `owner_uri` cannot model this. Fix: a cap-grant is **TWO Resources** — `GrantorView` (primary_owner: grantor, indexes "what did I grant out") and `GranteeView` (primary_owner: grantee, indexes "what caps do I hold"), linked via a shared `grant_id`. Both have `cascade_from: <the other side>` — destroying the grantor User cascades destruction of the GranteeView too (grant no longer valid); destroying the grantee User cascades destruction of the GrantorView. The cap matcher at Router step 5 reads the GranteeView only.

#### Current items that ARE Resources (some embedded in Entity slices today — boundary fix)

| Resource | Currently lives in | Should be | primary_owner | cascade_from | New URI shape |
|---|---|---|---|---|---|
| Agent's config-dir | `Behavior.Sandbox` slice on Agent Kind | `Resource` Kind | Agent | (none) | `resource://agent/<ws>/cc_demo/config-dir/main` |
| Agent's API keys | `Behavior.ApiKeys` slice on Agent Kind | `Resource` Kind | Agent | (none) | `resource://agent/<ws>/cc_demo/api-key/anthropic` |
| User's password hash | `Ezagent.Users` Ecto schema (NOT in slice — already a Resource shape, just not URI-addressable) | `Resource` Kind | User | (none) | `resource://user/<ws>/admin/credential/password` |
| External-mirror binding (Feishu chat → Session) | `external_mirror_bindings` table | `Resource` Kind | Session | Workspace | `resource://session/<ws>/<sess>/binding/feishu-main` |
| ExternalMirror Worker | `Ezagent.Entity.ExternalMirrorWorker` (today its own Kind) | `Resource` Kind (hot) | Session | Workspace | `resource://session/<ws>/<sess>/worker/<binding-id>` |
| Cap-grant **GrantorView** | (today: not addressable; grant lives in grantee's `:caps` MapSet) | `Resource` Kind | Grantor User | Grantee User | `resource://user/<grantor-ws>/<grantor>/cap-grant/<grant-id>` |
| Cap-grant **GranteeView** | `Ezagent.Behavior.Identity` slice on grantee User Kind (`:caps` MapSet) | `Resource` Kind | Grantee User | Grantor User | `resource://user/<grantee-ws>/<grantee>/cap-held/<grant-id>` |
| User's magic-link token | `Ezagent.Entity.MagicLinkToken` (currently its own Kind — already Resource-shaped) | `Resource` Kind | User | (none) | `resource://user/<ws>/<owner>/magic-link/<token-id>` |
| Agent's lineage parent | `Ezagent.AgentLineage` ETS table | stays as a registry (NOT a Resource — it's a query index, not addressable state) | — | — | (no URI; registry-only) |

This boundary fix is the largest single change a plugin-author actually sees in the migration. Today, "config-dir" is a slice field; tomorrow, it's a Resource with its own URI, its own lifecycle, its own cap shape. The plugin author writes the Resource Kind once; cascade-on-destroy comes free from the framework.

### §3.4 — Mapping table — current Kinds → pattern

| Current Kind | Module path | Pattern | Boundary issues (file:line) |
|---|---|---|---|
| `Ezagent.Entity.User` | `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:1` | Entity | Today: `MagicLinkToken` is a parallel Kind but conceptually owned-by-User — should be `resource://user/<owner>/magic-link/<id>` |
| `Ezagent.Entity.Agent` | `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex:1` | Entity | Today: `:sandbox` slice holds `config_dir_path` (line 79: `Ezagent.Behavior.Sandbox` attached) — should be Resource. `:api_keys` slice (line 80: `Ezagent.Behavior.ApiKeys`) — should be Resource |
| `Ezagent.Entity.Workspace` | `apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex:1` | Entity | Today: binding lifecycle leaks into `Behavior.Workspace` slice — bindings should be Resources owned by Workspace |
| `Ezagent.Entity.AgentTemplate` | `apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex:1` | Entity | Clean — already Entity-shaped |
| `Ezagent.Entity.SessionTemplate` | `apps/ezagent_domain_chat/lib/ezagent/entity/session_template.ex:1` | Entity | Clean |
| `Ezagent.Entity.Session` | `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:1` | **Session** | The single Session-pattern Kind today. Misleading `Entity.` namespace — rename to `Ezagent.Session.Default` post-migration |
| `Ezagent.Entity.ExternalMirrorWorker` | `apps/ezagent_domain_external_mirror/lib/ezagent/entity/external_mirror_worker.ex:1` | **Resource** | Currently named `Entity.` but conceptually owned by `(Workspace, Binding)`. Has two-tier supervisor for this reason. URI should be `resource://workspace/<ws>/worker/<binding-id>` |
| `Ezagent.Entity.Token` | `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:1` | Resource | Already owned-by-User, just not URI-shaped as resource |
| `Ezagent.Entity.MagicLinkToken` | `apps/ezagent_domain_identity/lib/ezagent/entity/magic_link_token.ex:1` | Resource | Owned by User |
| `Ezagent.Entity.Profile` | `apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex:1` | Resource (or merge into User) | Today a parallel Kind; mostly read-only display data — OQ-5 |
| `Ezagent.Plugin.Np.Agent` | `apps/ezagent_plugin_np/lib/ezagent/entity/np_agent.ex:1` | Entity | Plugin-defined |
| `Ezagent.Plugin.Curl.Agent` | `apps/ezagent_plugin_curl_agent/lib/ezagent/entity/curl_agent.ex:1` | Entity | Plugin-defined |
| `Ezagent.Plugin.Echo.Echo` | `apps/ezagent_plugin_echo/lib/ezagent/entity/echo.ex:1` | Entity | Plugin-defined (test plugin) |
| `Ezagent.Entity.System` | `apps/ezagent_core/lib/ezagent/entity/system.ex:1` | Entity (bootstrap special-case) | Used for `:system` caller principal; mostly framework-owned |

**Count by pattern**: 1 Session, 9 Entity (5 ezagent + 3 plugin + 1 system), 3 Resource (today; ~5 more after the boundary fix above).

---

## §4 — Plugin contract surface

*This section answers: "what's the entire surface a plugin author touches when writing a new Behavior or Kind?"*

### §4.1 — The whole contract

A plugin defines:

1. **Zero or more Kinds** (typically only ezagent core + each domain define Kinds; most plugins attach Behaviors to existing Kinds)
2. **One or more Behaviors** (each Behavior is a bundle of actions)
3. **A plugin module** that wires them together at app boot

```elixir
defmodule Ezagent.Plugin.MyPlugin do
  use Ezagent.Plugin

  # 1. Declare new Kinds (only if introducing one)
  defkind MyEntity,
    pattern: :entity,
    uri_scheme: "entity://my-kind/",
    behaviors: [Behavior.MyKind.Basic, Behavior.MyKind.Advanced]

  # 2. Attach Behaviors to existing Kinds (most common case)
  attach_behavior Behavior.MyCrossKind, to: [Ezagent.Entity.Agent, Ezagent.Entity.User]
end

defmodule Behavior.MyKind.Basic do
  use Ezagent.Behavior

  action :greet,
    args: %{},
    returns: %{greeted: :boolean},
    caps: [:greet],
    modes: [:call]

  def handle_greet(_args, ctx) do
    name = ctx.read.(:name, "world")
    {:ok, %{greeted: true}, [
      {:emit, :greeted, %{to: name, at: DateTime.utc_now()}}
    ]}
  end
end
```

That's the **entire** plugin contract. ~10–30 LOC per Behavior typically (down from 200–1300 LOC today).

### §4.2 — Side-by-side: 3 current Behaviors before / after

#### Example 1: `Behavior.UserCredentials.set_password`

**Before** (`apps/ezagent_domain_identity/lib/ezagent/behavior/user_credentials.ex`, 177 LOC):

```elixir
defmodule Ezagent.Behavior.UserCredentials do
  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:set_password]

  @impl Ezagent.Behavior
  def required_caps do
    %{set_password: Ezagent.Capability.cap(:user, __MODULE__, :set_password)}
  end

  @impl Ezagent.Behavior
  def cap_subjects, do: [{:set_password, "set or rotate user password (bcrypt)"}]

  @impl Ezagent.Behavior
  def state_slice, do: :user_credentials

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{set_password_count: 0}

  @impl Ezagent.Behavior
  def invoke(:set_password, slice, %{password: pw}, ctx) do
    case Ezagent.Users.set_password(ctx.self_uri, pw) do
      :ok ->
        new_slice = Map.update(slice, :set_password_count, 1, &(&1 + 1))
        {:ok, new_slice, %{user_uri: URI.to_string(ctx.self_uri), password_set: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Ezagent.Behavior
  def interface do
    %{set_password: %{
      description: "...",
      args: %{password: :string},
      returns: %{user_uri: :string, password_set: :boolean},
      modes: [:call]
    }}
  end

  @impl Ezagent.Behavior
  def data_owner(%URI{} = uri), do: uri
end
```

**After** (`apps/ezagent_domain_identity/lib/ezagent/behavior/user_credentials.ex`, ~30 LOC):

```elixir
defmodule Ezagent.Behavior.UserCredentials do
  use Ezagent.Behavior

  action :set_password,
    args: %{password: :string},
    returns: %{user_uri: :string, password_set: :boolean},
    caps: [:set_password],
    description: "set or rotate user password (bcrypt)",
    data_owner: :self,                # self = ctx.self_uri owns this action's target
    modes: [:call]

  def handle_set_password(%{password: pw}, ctx) do
    case Ezagent.Users.set_password(ctx.self_uri, pw) do
      :ok ->
        {:ok,
         %{user_uri: URI.to_string(ctx.self_uri), password_set: true},
         [{:emit, :password_set, %{user_uri: ctx.self_uri, at: DateTime.utc_now()}}]}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

**LOC reduction**: 177 → ~30 (83% reduction).

#### Example 2: `Behavior.Lifecycle.terminate`

**Before** (`apps/ezagent_core/lib/ezagent/behavior/lifecycle.ex`, 243 LOC — the deferred-task hack to avoid self-kill is ~50 LOC of plumbing):

```elixir
def invoke(:terminate, slice, _args, ctx) do
  self_uri = Map.get(ctx, :self_uri)
  kind_module = Map.get(ctx, :kind_module)
  schedule_termination(self_uri, kind_module)   # Task.start → 20ms sleep → DynamicSupervisor.terminate_child
  notify_spawning_principal(self_uri)            # AgentLineage → Notifications.notify
  {:ok, bump(slice), {:ok, :terminated}}
end
```

**After** (~25 LOC; framework handles deferred termination via `{:terminate, self}` effect):

```elixir
defmodule Ezagent.Behavior.Lifecycle do
  use Ezagent.Behavior

  action :destroy,
    args: %{},
    returns: %{destroyed: :boolean},
    caps: [:destroy],
    data_owner: :self,
    modes: [:call]

  def handle_destroy(_args, ctx) do
    # The destroy saga handles cascade + cleanup; framework knows the Kind's
    # composition pattern (Entity) and walks owned Resources first.
    {:ok, %{destroyed: true},
     [{:emit, :destroyed, %{uri: ctx.self_uri, by: ctx.caller, at: DateTime.utc_now()}},
      {:terminate, :self}]}  # framework defers termination until after dispatch reply
  end
end
```

The Resource cascade (User destroy → revoke all caps → destroy all sessions → destroy all agents) is no longer hand-rolled in `EzagentDomainChat.create_session/3`-style imperative code. The framework's destroy-saga walks `pattern: :entity`'s declared Resource set in declared order, with automatic compensation if any step fails. See §5.4.

**LOC reduction**: 243 → ~25 (90% reduction).

#### Example 3: `Behavior.Chat.send` (the biggest, hairiest Behavior)

**Before** (`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:297-419`, ~120 LOC for `:send` alone):

The pre-existing handler does: `MessageStore.write` → `Phoenix.PubSub.broadcast` → `WorkspaceRegistry.lookup` → `Routing.Resolver.resolve` → `notify_dropped_mentions` → per-recipient `dispatch_receive` / `dispatch_cross_session` → 3-field slice mutation for SliceChange.

**After** (~35 LOC):

```elixir
action :send,
  args: %{message: Ezagent.Message},
  returns: %{stored: :boolean},
  caps: [:send],
  modes: [:cast]

def handle_send(%{message: %Ezagent.Message{} = msg}, ctx) do
  session_uri = ctx.self_uri
  members = ctx.read.(:members, %{})
  workspace_uri = ctx.read.(:workspace_uri)

  case Ezagent.Routing.Resolver.resolve(msg, session_uri, Map.keys(members),
                                         workspace_uri: workspace_uri) do
    [] ->
      {:ok, %{stored: false, reason: :no_recipients}, []}

    recipients ->
      # Codex r1 HIGH-1 closure: use :effect_returning to get the stamped message back.
      # Downstream effects reference it via {:ref, :stored_msg, [...]}.
      # Effects fire in the 6 phases declared in §4.4:
      #   Phase 1 (:set): slice updates
      #   Phase 2 (:emit): EventLog appends
      #   Phase 3 (:effect_returning + :effect): side effects (Repo write happens here)
      #   Phase 4 (:dispatch): cross-Kind fan-out
      #   Phase 5 (:notify): PubSub broadcasts
      #   Phase 6 (:terminate/:saga): post-reply (n/a here)
      effects = [
        # Phase 3: Repo write (returning stamped msg for downstream refs)
        {:effect_returning, &Ezagent.MessageStore.write/2, [msg, session_uri],
         bind_as: :stored_msg},

        # Phase 1: slice updates — reference the stored stamped msg via {:ref, ...}
        {:set, :last_message_id, {:ref, :stored_msg, [:id]}},
        {:set, :last_message,    {:ref, :stored_msg}},
        {:set, :send_cursor,     ctx.read.(:send_cursor, 0) + 1},

        # Phase 2: EventLog append
        {:emit, :message_sent, %{message: {:ref, :stored_msg}, session_uri: session_uri,
                                  recipient_count: length(recipients)}}
      ] ++
      # Phase 4: per-recipient dispatch (uses stored msg via {:ref, ...})
      Enum.map(recipients, &recipient_dispatch_effect(&1, session_uri)) ++
      [
        # Phase 5: notify session subscribers AFTER dispatches enqueued
        {:notify, "esr:session:#{URI.to_string(session_uri)}:events",
                  {:chat_message, session_uri, {:ref, :stored_msg}}}
      ]

      {:ok, %{stored: true}, effects}
  end
end

defp recipient_dispatch_effect(%URI{scheme: "session"} = recipient, _session) do
  {:dispatch, %Ezagent.Cmd{target: recipient, action: :receive_cross_session,
                            args: %{message: {:ref, :stored_msg}}, ctx: %{...}}}
end

defp recipient_dispatch_effect(recipient, session_uri) do
  {:dispatch, %Ezagent.Cmd{target: recipient, action: :receive,
                            args: %{message: {:ref, :stored_msg}},
                            ctx: %{caller: session_uri, reply: :ignore,
                                   command_uuid: "chat:#{URI.to_string(recipient)}"}}}
end
```

**LOC reduction**: ~120 → ~45 (62% reduction; slightly larger than r1 estimate because `:effect_returning` + `{:ref, ...}` references are a few more chars but fully explicit). The `notify_dropped_mentions` side path moves to `Routing.Resolver.resolve`'s return (it knows which mentions were dropped).

**Phase ordering visible in this example**: the runtime applies effects by phase, not by source-line order — but the source-line grouping makes intent obvious. The `command_uuid` in dispatch effects no longer needs the message id (it's derived from the stored msg's id by the framework before substitution).

### §4.3 — Capability declaration

Caps are declared **inside the `action/3` macro** — there is no separate `required_caps/0` callback. The Router enforces the cap at the dispatch boundary BEFORE the handler runs. The handler never sees auth state.

```elixir
action :grant_cap,
  args: %{target_uri: URI, cap: Ezagent.Capability},
  returns: :ok,
  caps: [
    {:grant_cap, scope: :self},        # caller may grant caps they hold
    {:grant_cap_any, scope: :admin}    # OR admin can grant arbitrary caps
  ],
  modes: [:call]
```

**Full `caps:` grammar** (codex r1 HIGH-7 closure — preserves all 5 axes today's `%Ezagent.Capability{}` struct supports — `kind`, `behavior`, `action`, `instance`, `workspace_uri` — plus the scope tuples):

```elixir
caps: [
  # Form 1: bare atom — shorthand for {action: :send, ...defaults...}
  :send,

  # Form 2: tuple with explicit axes
  {:send, kind: :session, action: :send, instance: :self_target, workspace_uri: :target_workspace},

  # Form 3: with scope tuple (within-session, within-workspace, spawned-by)
  {:read, scope: {:within_session, :ctx_session}},
  {:cross_workspace_grant, scope: {:within_workspace, :any}},
  {:terminate, scope: {:spawned_by, :ctx_principal}},

  # Form 4: kind axis wildcard — for multi-Kind Behaviors like Chat
  {:receive, kind: :any},

  # Form 5: workspace_scoped? opt-out (per-action)
  {:admin_grant, kind: :user, workspace_scoped?: false},
]
```

The `caps:` argument accepts a list of items where each item is either:

- An atom (`:send`) — desugars to `{:send, []}` with framework defaults
- A tuple `{action_atom, opts_keyword}` where `opts_keyword` may contain:

| Key | Values | Default | Notes |
|---|---|---|---|
| `kind` | atom (e.g. `:user`, `:session`) or `:any` | the Kind this Behavior is attached to | Wildcard `:any` for cross-Kind Behaviors like Chat (today's `Capability.cap(:any, ...)`) |
| `behavior` | module atom | `__MODULE__` (current Behavior) | Rarely overridden |
| `action` | atom or `:any` | the action this `caps:` is declared on | `:any` means "any action of this Behavior matches" |
| `instance` | `:self_target` / `:any` / specific URI | `:self_target` (dispatch's target URI) | Use `:any` for class-wide caps |
| `workspace_uri` | URI / `:target_workspace` / `:any` | `:target_workspace` (derived from target) | `:any` for cross-workspace caps |
| `scope` | `{:within_session, X}` / `{:within_workspace, X}` / `{:spawned_by, X}` | (none) | Where `X` is a literal URI or one of the substitution tokens `:ctx_session`, `:ctx_principal`, `:ctx_workspace` |
| `workspace_scoped?` | `true` / `false` | `true` | When `false`, step 5.6 cross-workspace iso is bypassed for this action (today's `Behavior.workspace_scoped?/0` opt-out) |

**Substitution semantics**: tokens like `:self_target` / `:target_workspace` / `:ctx_session` are evaluated at dispatch time against the actual `%Cmd{}` and `ctx`. They are NOT runtime values held by the plugin; the macro emits the substitution as a struct field at compile time and the Router substitutes at step 5.

**Cap-vis SPEC #423 r4** (action-axis caps with `{:within_session, S}` shape) is fully expressible:

```elixir
caps: [{:read_messages, action: :any, scope: {:within_session, :ctx_session}}]
```

**Multi-Kind Behaviors** (Chat is attached to Session + User + Agent — three Kinds) use `kind: :any` to declare a single cap shape that matches against whichever Kind the dispatch lands on:

```elixir
defmodule Ezagent.Behavior.Chat do
  use Ezagent.Behavior

  action :receive,
    args: %{message: Ezagent.Message},
    returns: :ok,
    caps: [{:receive, kind: :any}],   # matches any Kind Chat is attached to
    modes: [:cast]
  # ...
end
```

Today's `IdentityAdmin` `workspace_scoped?: false` (the cross-workspace admin Behavior) is expressed as:

```elixir
action :grant_user_in_other_workspace,
  args: ...,
  caps: [{:cross_workspace_grant, kind: :user, workspace_scoped?: false}],
  ...
```

### §4.4 — Effects vocabulary

Effects are the **only** way a handler causes change in the world (with one carve-out for inline idempotent Repo writes — see §4.5). The complete grammar:

| Effect | Meaning | Example |
|---|---|---|
| `{:set, key, value}` | Update framework-managed state for this Kind instance | `{:set, :last_message_id, msg.id}` |
| `{:emit, event_type, payload}` | Append an event to EventLog (audit + replay) | `{:emit, :message_sent, %{...}}` |
| `{:dispatch, %Cmd{}}` | Fan out to another Kind via Router (async — cast semantics) | `{:dispatch, %Cmd{target: rcpt, action: :receive, ...}}` |
| `{:notify, topic, payload}` | Phoenix.PubSub broadcast (UI / external) | `{:notify, "esr:session:…:events", msg}` |
| `{:effect, mfa_or_fn, args}` | Side effect — file/IO/external API call; framework wraps with audit + (optional) retry; **return value discarded** | `{:effect, &Ezagent.AgentBridge.deliver/2, [user_uri, msg]}` |
| `{:effect_returning, mfa_or_fn, args, bind_as: name}` | Same as `:effect` but binds the return value into the handler's continuation map under `name`; downstream effects can reference it as `{:ref, name, path}` (codex r1 HIGH-1 closure) | `{:effect_returning, &MessageStore.write/2, [msg, session_uri], bind_as: :stored_msg}` |
| `{:terminate, :self \| uri}` | Schedule deferred Kind-termination (post-reply) — framework handles cascade | `{:terminate, :self}` (Lifecycle.destroy) |
| `{:saga, %Ezagent.Saga{}}` | Hand the rest of the cascade to SagaRunner | (see §5.4) |
| `{:halt, reason}` | Abort: framework rolls back already-applied state effects, discards pending effects, returns `{:error, reason}` | `{:halt, :preflight_failed}` |

**HIGH-1 closure**: an earlier draft used a bare `{:effect, ...}` for `MessageStore.write` but the legacy handler relied on its **return value** (the stamped message) for the subsequent broadcast/dispatch effects. A fire-and-forget effect can't express that. Two resolutions, both adopted:

1. **`:effect_returning`** is the structured way: the handler declares "I need the return value of this Repo write to populate downstream effects"; the framework executes the call, binds the result, and substitutes `{:ref, :stored_msg, [:id]}` references into downstream effects before applying them.
2. **The inline Repo carve-out** (§4.5) lets a handler call `Ezagent.MessageStore.write/2` directly when the call is idempotent + transactional on its own. This is what the `UserCredentials.set_password` example assumes.

The Chat.send example is rewritten (§4.2 Example 3) to use `:effect_returning` for clarity; the example handler then declares all downstream effects against `{:ref, :stored_msg, ...}`.

**Effect ordering semantics** (normative, codex r1 LOW-2 closure):

Effects fire in **declared order within each phase**. The 6 phases run sequentially:

1. **Phase 1 — `:set`**: state updates applied as a single Ecto transaction with the EventLog appends (handler's `ctx.read` reads the pre-handler snapshot; in-flight `:set` effects are not visible to subsequent `ctx.read` calls within the same handler)
2. **Phase 2 — `:emit`**: events appended to EventLog in declared order, **in the same transaction as phase 1**
3. **Phase 3 — `:effect_returning`** then **`:effect`**: side effects fire after the phase 1+2 transaction commits, in declared order. `:effect_returning` results are bound to the continuation map before subsequent effects are evaluated
4. **Phase 4 — `:dispatch`**: cross-Kind dispatches enqueued in declared order (each is async cast — Router fans them out concurrently; ordering between dispatches is best-effort)
5. **Phase 5 — `:notify`**: Phoenix.PubSub broadcasts fire in declared order (LV / external subscribers see them AFTER the dispatched Kinds have started but BEFORE they've necessarily completed — by design: notify is the "something happened on me" signal, dispatch is the actual fan-out)
6. **Phase 6 — `:terminate` / `:saga`**: fire after the synchronous reply has been delivered (today's `Task.start` 20ms-sleep pattern, but framework-owned)

`{:halt, reason}` short-circuits phases 1+2 — already-declared `:set`/`:emit` effects are **not committed** (the transaction rolls back); the handler appears never to have run from a state-observer's perspective. Phases 3-6 effects are never reached.

**HIGH-5 closure (saga compensation honesty)**: phase 6's saga can **only compensate steps that are themselves reversible**. Irreversible side effects (sent PubSub broadcasts in phase 5, fired external API calls in phase 3, dispatched messages in phase 4 already consumed by another Kind) are **not** rolled back — the saga marks them as "irreversibly happened" in the EventLog and proceeds to compensate what it can. The destroy cascade is **best-effort partial restore**, NOT true rollback. See §5.4 for the explicit compensation contract.

### §4.5 — What's gone vs current contract

| Callback / concept | Today | New design |
|---|---|---|
| `Behavior.invoke/4` | 3rd arg slice; returns `{:ok, new_slice, result}` | `handle_<action>/2`; returns `{:ok, result, [effect]}` |
| `state_slice/0` | Behavior declares its slice key | Gone — Kind owns state composition via field schema |
| `init_slice/1` | Behavior builds its initial slice | Gone — Kind's `attach Behavior, init_state: %{...}` (or per-Kind `init_state/1`) |
| `persistence/0` | Per-Kind enum (5 values) | Gone — framework decides per pattern (see §5.2) |
| `reads_sibling_slices/0` | Per-Behavior list | `Kind.read_graph` — declared once at Kind level, compile-checked |
| `data_owner/1` | Per-Behavior callback | Per-action `data_owner:` macro arg with declared shape (`:self`, `:any`, `{:owner_of, kind}`, etc.) |
| `cap_subjects/0` | Per-Behavior list | Per-action `description:` macro arg |
| `required_caps/0` | Per-Behavior map | Per-action `caps:` macro arg |
| `cap_exempt_actions/0` | Per-Behavior list | `caps: []` empty list on the action |
| `workspace_scoped?/0` | Per-Behavior boolean | `workspace_scoped:` macro arg on Kind level (default `true`) |
| `post_init/2` / `handle_continue/3` / `on_ready/2` / `terminate/3` | Per-Behavior optional callbacks | Per-Kind lifecycle hooks (declared via `lifecycle/2` macro; most Kinds need none) |
| `reconcile_after_load/2` | Per-Behavior callback | Per-Kind rebuild from EventLog (framework) + optional `on_rebuild/1` Kind callback |
| `Ezagent.Invocation.dispatch/1` from inside `invoke/4` | Allowed (used by Chat) | **Forbidden** — emit `{:dispatch, %Cmd{}}` effect |
| `Phoenix.PubSub.broadcast/3` from inside `invoke/4` | Allowed | **Forbidden** — emit `{:notify, topic, payload}` effect |
| `MessageStore.write` etc — Repo-backed query modules | Allowed | **Conditionally allowed inline** (see §4.5.1 below); otherwise use `{:effect_returning, ...}` |

### §4.5.1 — Allowed direct calls vs forbidden calls (codex r1 HIGH-6 closure)

**The line** between "plugin code can call this inline" and "plugin code must go through effects":

| Call shape | Allowed inline in handler? | Why |
|---|---|---|
| `ctx.read.(:key)` — framework state | ✓ Always | This IS the read API |
| Pure functions in your own domain modules | ✓ Always | E.g. `Routing.Resolver.resolve/4` — pure |
| Registry-style lookups: `AgentLineage.lookup`, `WorkspaceRegistry.lookup` | ✓ Always | These are read-only ETS reads; same idempotency profile as `ctx.read` |
| Repo-backed query modules with **idempotent** writes (`Ezagent.MessageStore.write/2` — `ON CONFLICT DO NOTHING`; `Ezagent.Users.set_password/2` — full row replacement) | ✓ Allowed | Each call is its own transaction; retry-safe; failure surfaces as `{:error, _}` the handler can return |
| Repo-backed writes that are **NOT** idempotent | ✗ Forbidden | Must go via `{:effect_returning, fn, args, bind_as: ...}` so framework can wrap retry + audit |
| Cross-Kind dispatch via `Ezagent.Invocation.dispatch/1` | ✗ Forbidden | Always via `{:dispatch, %Cmd{}}` effect |
| Phoenix.PubSub.broadcast | ✗ Forbidden | Always via `{:notify, topic, payload}` effect |
| File system writes, external HTTP, OS-level side effects | ✗ Forbidden | Always via `{:effect, mfa, args}` — framework wraps retry + audit |
| Reading any other Kind's state via `Kind.get_slice/2` | ✗ Forbidden | Cross-Kind reads go via `ctx.read` (Kind's `read_graph` declares them) |

**Why this carve-out**: forcing every Ecto write through `{:effect_returning, ...}` adds a syntactic burden for the common case (rotate a password, write a chat message) without buying replay-equivalence (the Ecto write is the source of truth; replay rebuilds slice state, NOT the Ecto rows). The carve-out is a **finite, enumerable list** of allowed Repo-backed query modules; adding a new one to the list is a SPEC change. The grep-gate in §7.4 enforces by name — any Repo module not in the allow-list trips the gate.

**Allow-list** (initial; growable via SPEC):

- `Ezagent.Users.*` — User Ecto schema (rare writes — password rotation, profile update)
- `Ezagent.MessageStore.write/2` — message persistence (idempotent on `(id, session_uri)`)
- `Ezagent.AgentLineage.*` — read-only ETS today; if it becomes write-backed, moves to forbidden
- `Ezagent.WorkspaceRegistry.lookup/1` — read-only ETS
- `Ezagent.CapabilityRegistry.*` — read paths only

Any call to `Ezagent.Repo` directly is **forbidden** in plugin code — wrap it in a domain query module that gets vetted into the allow-list.

---

## §5 — Framework machinery (plugin-invisible)

*This section answers: "where do the deleted plugin concerns live now, and how is the framework structured?"*

The framework internals live under `apps/ezagent_core/lib/ezagent/` and are **never** imported by plugins.

### §5.1 — `Ezagent.EventLog`

Appends events emitted by handlers via `{:emit, …}` effects. Wraps the existing `invocations` table (`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:6`). Public API:

```elixir
@spec append(envelope :: map) :: :ok | {:error, term}
@spec stream_by_aggregate(uri :: URI.t, opts :: [from: DateTime.t, limit: pos_integer]) :: [event_row]
@spec stream_by_workspace(ws :: URI.t, opts) :: [event_row]
@spec stream_since(cursor :: DateTime.t, opts) :: [event_row]
```

**Ordering**: rows ordered by `(inserted_at ASC, id ASC)` — `id` tie-breaker for same-microsecond writes. Cursor pagination keys on `(inserted_at, id)`.

**No plugin contact**. The Router writes; the StateRebuilder reads.

**LOC**: ~150 (mostly delegations over the existing `Audit.Writer`).

### §5.2 — `Ezagent.SnapshotStore`

Manages per-Kind state snapshots. Framework decides snapshot policy by composition pattern (with one sub-classification for Resource) — plugin authors pick the pattern but **never** the policy directly:

| Pattern | Default policy | Rationale |
|---|---|---|
| Session | `every_n_events: 100` + `on_archive` | Sessions have high event volume; periodic snapshots bound replay cost |
| Entity | `on_change` (sync) | Entities mutate rarely; durability per-mutation is cheap |
| Resource (`:cold_resource`) — default | `on_change` (sync) | Per-action mutations are infrequent; durability per-mutation is cheap |
| Resource (`:hot_resource`) | `:ephemeral` (no persistence) + opt-in `{:periodic, ms}` | High-volume Resources whose state is telemetry/cursors/counters — losing it on restart is by-design |

**HIGH-3 closure**: an earlier draft made Resource = `on_change` uniformly, which would have 10x'd write rate on `Ezagent.Entity.ExternalMirrorWorker` (currently `:ephemeral` because publish cursor + count are pure telemetry; see `apps/ezagent_domain_external_mirror/lib/ezagent/entity/external_mirror_worker.ex:50`). The fix is the `:hot_resource` sub-classification — declared on the Kind via `pattern: {:resource, :hot}` (cold is just `pattern: :resource`). The two-axis pattern keeps "framework decides policy" intact while preserving the existing Worker's correctness.

The Kind macro accepts:

```elixir
use Ezagent.Kind, pattern: :entity                    # default Entity → on_change
use Ezagent.Kind, pattern: :resource                  # default cold Resource → on_change
use Ezagent.Kind, pattern: {:resource, :hot}          # hot Resource → ephemeral
use Ezagent.Kind, pattern: {:resource, :hot, periodic: 5_000}  # opt-in periodic
use Ezagent.Kind, pattern: :session                   # Session → every_n_events
```

**Plugin authors do NOT pick `on_change` directly** — they pick the pattern, framework picks the policy. The escape hatch for genuinely-pattern-misfit Kinds is `pattern: {:custom, hooks: [...], snapshot: :on_change}` — but using it is a SPEC change (the Kind moves out of the standard 3 patterns + gets explicit review).

Each pattern's default is **a single decision made once in `Ezagent.SnapshotStore`**, not 22 per-Behavior `persistence/0` declarations.

Public API:

```elixir
@spec latest(uri :: URI.t) :: {:ok, state :: map, version :: non_neg_integer} | :empty
@spec write(uri :: URI.t, state :: map) :: :ok | {:error, term}
@spec delete(uri :: URI.t) :: :ok
```

**LOC**: ~200 (the existing `Kind.Snapshot` logic, minus the 5-enum dispatch — pattern dispatch replaces it).

### §5.3 — `Ezagent.Kind.StateRebuilder`

Generalizes today's per-domain `BootReconciler` (currently only `ExternalMirror.BootReconciler` exists). On Kind process spawn (cold start, restart, or first dispatch after crash):

1. Read snapshot from `SnapshotStore.latest/1`
2. Stream events since snapshot via `EventLog.stream_by_aggregate(uri, from: snapshot.at)`
3. Fold events into snapshot state via each Behavior's framework-derived `apply_event/2` (auto-generated from `{:set, …}` and `{:emit, …}` effects in the original handler)
4. Optional: per-Kind `on_rebuild/1` callback — runs after fold, before `:ready`, lets the Kind reconcile DB-projection-backed fields (today's `reconcile_after_load/2` use-case)

**Plugin authors NEVER call this**. The framework calls it from `Kind.Host.init/1`.

**LOC**: ~200.

### §5.4 — `Ezagent.SagaRunner`

Single-call linear orchestration with compensation. Used when:

- A handler returns `{:saga, %Ezagent.Saga{steps: [...]}}` effect
- The framework destroy-cascade (Entity destroy → Resource list → walk in declared order)
- The framework's per-pattern lifecycle saga (Session create → workspace bind → publisher start → ready)

Public API (subset of `Sage` — we don't need parallel/async):

```elixir
defstruct steps: [], compensations: [], ctx: %{}, name: nil, command_uuid: nil

@spec new(name :: String.t, opts :: [command_uuid: String.t]) :: t
@spec step(saga, name :: atom, forward :: (map -> {:ok, term} | {:error, term}),
                                compensate :: (map, map -> :ok | {:error, term})) :: t
@spec execute(saga, initial_ctx :: map) ::
        {:ok, effect_map :: map}
        | {:error, step :: atom, reason :: term, compensated :: [atom]}
```

**Saga compensation declaration** (OQ-4): inline step pairs `(forward, compensate)`. Framework runs reverse-compensation on failure. Per-step `command_uuid = "saga:<saga_name>:step:<step_name>"` gives idempotent retry-on-crash semantics.

**Compensation honesty (codex r1 HIGH-5 closure)**: compensation is **best-effort partial restore**, NOT true rollback. The SagaRunner contract is:

| Step type | Compensation possible? | What "compensation" means |
|---|---|---|
| Pure-state mutation (slice change) | ✓ Fully reversible | Snapshot the slice before forward; on rollback, restore it |
| `:emit` event (audit-only) | ✓ Reversible by appending a compensating event (not deleting) | Append `:compensated_<event>` event; downstream consumers see both |
| `:dispatch` cross-Kind (already cast to another Kind) | ✗ NOT reversible | The dispatched Kind may have already acted; saga marks "irreversibly happened" in EventLog |
| `:notify` PubSub broadcast (already received by subscribers) | ✗ NOT reversible | Same — subscribers already acted; saga marks irreversibly |
| `:effect` external IO (file write, HTTP call) | ✗ Generally NOT reversible | Compensation function can attempt a counter-action (DELETE the file, POST a "rollback"); but the original effect is logged as "happened" |
| `:terminate` (Kind already terminated) | ✗ NOT reversible in the same call | A re-spawn after termination is a SEPARATE Kind instance — caps/state from the original are LOST |

**The honest destroy-cascade contract**: when destroy User → revoke caps → destroy sessions → destroy agents → destroy resources → terminate user — if step "destroy agents" fails AFTER "destroy sessions" succeeded:

1. The saga's reverse-compensation will attempt to **resurrect sessions** by re-spawning them from their pre-destroy snapshot
2. BUT any in-flight messages that arrived from external channels (Feishu) during the destroy window are **lost** — they were dropped because the Session was gone
3. AND the resurrected Session is a new GenServer process; subscribers (LV chat stream, ExternalMirror Worker) need to re-subscribe
4. The saga marks the resurrection as `{:partial_restore, sessions_resurrected: [...], messages_lost: <count>}` in the EventLog
5. An operator-repair marker is written: `{:saga_incomplete_restore, saga: "destroy_user:#{uri}", step: :destroy_agents, recoverable: false}` — visible in `/admin/saga_history` LV

**This solves SPEC #440** by being honest about what's possible, NOT by claiming false rollback. The "User is in an inconsistent state" failure mode that codex flagged on #440 r4 becomes a **declared, observable, repair-tracked** state instead of a silent inconsistency. Operators have a UI to see "this destroy was 90% successful; 1 message was lost; here's the repair handle."

**LOC**: ~200 (the existing `EzagentDomainChat.create_session/3` hand-rolled `try/rescue` cleanup pattern, lifted into a reusable primitive) + ~50 LOC for the partial-restore marker handling.

### §5.5 — `Ezagent.EventSubscriber`

For asynchronous, event-driven cross-Kind reactions:

```elixir
defmodule Ezagent.Plugin.ExternalMirror.WorkerBootstrapSubscriber do
  use Ezagent.EventSubscriber, application: :ezagent_domain_external_mirror

  def interested?(%{type: :binding_created, kind_module: Ezagent.Entity.Workspace}), do: true
  def interested?(_), do: false

  def handle_event(%{target: workspace_uri, args: %{adapter: a, params: p}}, state) do
    {:dispatch, [%Ezagent.Cmd{
      target: derive_worker_uri(workspace_uri, a),
      action: :spawn,
      args: %{adapter: a, params: p},
      ctx: %{caller: :system, reply: :ignore,
             command_uuid: "subscriber:worker-bootstrap:#{workspace_uri}"}
    }], state}
  end
end
```

Subscribers DECLARE event interest + handler; framework owns supervision, restart, ordering.

**LOC**: ~250 (behaviour + supervisor + registry).

### §5.6 — `Ezagent.Caps.Engine`

Centralizes cap matching — the chokepoint at Router step 5. Today's `Ezagent.Capability.matches?/2` + `Kind.holds_cap?/3` + `Kind.default_holds_cap?/2` consolidate here. Plugin Behaviors never invoke this directly; they declare `caps:` and the engine consumes the declaration.

**LOC**: ~250 (mostly the existing `Ezagent.Capability` 1038 LOC slimmed — much of that file today is shape conversion glue between `Capability.cap/3`, `Capability.cap_for_action/3`, and `matches?/2`. Once `caps:` is declarative, the conversion glue is gone).

### §5.7 — `Ezagent.Kind.Host`

The GenServer that hosts every Kind instance (replaces today's `Ezagent.Kind.Server`, 828 LOC). Same role — but state is `{behavior_module, field} → value` flat, effect application happens via the Router pipeline not from inside the Server, and snapshot/event/notification ordering is framework-owned.

**LOC**: ~400–500.

### §5.8 — Total framework-internal LOC

| Module | LOC |
|---|---:|
| `Ezagent.Router` | ~200 |
| `Ezagent.Behavior` (macro + behaviour) | ~300 |
| `Ezagent.Kind` (macro + behaviour) | ~200 |
| `Ezagent.Kind.Host` (GenServer) | ~500 |
| `Ezagent.EventLog` | ~150 |
| `Ezagent.SnapshotStore` | ~200 |
| `Ezagent.Kind.StateRebuilder` | ~200 |
| `Ezagent.SagaRunner` | ~200 |
| `Ezagent.EventSubscriber` | ~250 |
| `Ezagent.Caps.Engine` | ~250 |
| `Ezagent.Cmd` (struct) | ~30 |
| **Total** | **~2,480** |

Today's equivalent (scattered across `behavior.ex`, `kind.ex`, `kind/server.ex`, `kind/runtime.ex`, `kind/snapshot.ex`, `snapshot/writer.ex`, `audit.ex`, `audit/writer.ex`, `invocation.ex`, `capability.ex`, `slice_change.ex`, `behavior_registry.ex`, `capability_registry.ex`, `idempotency.ex`, `ready_gate.ex`, `pending_delivery.ex`):

Roughly ~5,000 LOC of framework code today. The new design is **~2,500 LOC of framework** — **half the framework LOC**, doing strictly more (Router, EventLog stream-by-aggregate, SagaRunner, EventSubscriber, StateRebuilder are new primitives).

**Net plugin code savings**: per §1.3, plugin Behaviors total ~11,000 LOC today; the new design targets ~3,500 LOC (the actual business logic). **~7,500 LOC of plugin boilerplate eliminated.**

**Total net**: roughly -10,000 LOC across the codebase (2,500 framework saved + 7,500 plugin saved). And every line eliminated was high-cognitive-load (the §1.1 8-concept-cluster code).

---

## §6 — Breaking-change migration plan

*This section answers: "exactly how do we get from here to there, given Allen authorized Q2=a (no compat shim)?"*

### §6.1 — Phase plan

#### Phase 1 — Framework primitives (no plugin migration yet)

- Build `Ezagent.Router`, `Ezagent.Behavior` (new macro), `Ezagent.Kind` (new macro), `Ezagent.Kind.Host`, `Ezagent.EventLog`, `Ezagent.SnapshotStore`, `Ezagent.Kind.StateRebuilder`, `Ezagent.SagaRunner`, `Ezagent.EventSubscriber`, `Ezagent.Caps.Engine`
- **`LegacyBehaviorAdapter`** — old `Behavior.invoke/4`–shaped Behaviors continue to work via an adapter that wraps `invoke/4` returns into the new effect shape. The adapter:
  - Diffs old vs new slice via `Map.merge` and emits `{:set, key, value}` effects for each changed top-level key
  - Wraps the legacy handler's already-executed side-effects (PubSub broadcasts, cross-Kind dispatches, MessageStore writes) in a `{:legacy_already_executed, [<list of side-effect descriptors>]}` audit record — visible in EventLog but NOT re-executable
  - **Explicitly labeled NON-REPLAY-EQUIVALENT** (codex r1 HIGH-2 closure): the adapter preserves runtime dispatch behavior (same reply, same PubSub broadcasts at the same time) but does NOT preserve replay semantics. EventLog rows for adapter-mode Behaviors cannot be folded into state via `apply_event/2` because the legacy handler's side effects happened OUTSIDE the effect grammar. The StateRebuilder treats adapter-mode events as "snapshot-only" — it relies on the snapshot, not event fold, for those Behaviors. After Phase 3 (adapter deleted, all Behaviors native), full replay-equivalence holds.
  - **Deletion-tracked from day 1** — issue tagged `delete-by-end-of-phase-3`, deprecation warning on every load, `mix ezagent.audit.legacy_adapter` task lists remaining call sites
  - Estimated ~300-400 LOC (added to the Phase 1 LOC budget; was missing from the §5.8 table)
- All current tests pass (legacy plugins compile + run via adapter)
- Estimated: **~4-5 weeks** (codex r1 MED-4 closure — raised from 3wk; the adapter is non-trivial and the framework primitives reveal latent design issues during build, ~1wk for design closure on OQs 1-8)

#### Phase 2 — Per-Domain plugin migrations

Each domain migrates its Behaviors and Kinds to the new contract. Order optimized for blast-radius minimization:

| PR | Domain | Behaviors | Risk |
|---|---|---|---|
| Phase 2 PR 1 | `ezagent_core` | Lifecycle, Routing, Sandbox, Notifications, Presence | Low — core test infra catches regressions |
| Phase 2 PR 2 | `ezagent_domain_identity` | Identity, UserCredentials, UserTokens, ApiKeys, WorkspaceUserAdmin | Medium — auth touches every dispatch |
| Phase 2 PR 3 | `ezagent_domain_workspace` | Workspace | Medium — workspace iso is in every dispatch step 5.6 |
| Phase 2 PR 4 | `ezagent_domain_chat` | Chat, Template, OrchestratorAdmin, Publisher.SessionImpl | High — Chat is the biggest Behavior, multi-Kind |
| Phase 2 PR 5 | `ezagent_domain_external_mirror` | ExternalMirror, ExternalMirrorWorker, Publisher | High — Worker has two-tier supervisor + boot reconciler |
| Phase 2 PR 6 | `ezagent_domain_pty` | Pty | Low — small surface |
| Phase 2 PR 7 | Plugin packages | NpAgent, CurlAgent, Echo | Low — plugin-isolated |
| Phase 2 PR 8 | Resource boundary fix | Sandbox config-dir → Resource; ApiKeys → Resource; Workspace bindings → Resource | Medium — schema migration touches DB |

Each PR independently passes the migration parity test (§7.3). The legacy adapter remains until every domain has migrated.

Estimated: **~4–6 weeks** (parallelizable by domain; depends on whether multiple domains can land in the same week — Allen's review bandwidth is the constraint).

#### Phase 3 — Remove legacy adapter

- `LegacyBehaviorAdapter` deleted
- All Behaviors compile under the new macro
- The `:invoke/4` callback is removed from `Ezagent.Behavior`
- CI grep gate: zero `def invoke(` in `apps/*/lib/.../behavior/*.ex`

Estimated: **~3 days**.

#### Phase 4 — Cleanup

- `Kind.Server` → `Kind.Host` rename (or kept as alias, decided at PR time)
- `Kind.Runtime` deletion (its responsibilities folded into Router + Kind.Host)
- `Kind.Snapshot` → `SnapshotStore` rename
- `Ezagent.Invocation` keeps the reply/24h-format machinery; the `dispatch/1` entry becomes a thin facade calling `Router.dispatch/1` (or is deleted if all callers updated)
- Documentation rewrite (CONTRIBUTING.md, plugin author guide, ARCHITECTURE.md)
- The `slice_change.ex` SliceChange module is renamed `Ezagent.StateChange` and its semantics tighten (now event-driven, not slice-diff-derived)

Estimated: **~4 days**.

### §6.2 — Per-Behavior retrofit checklist

For each current Behavior the migrating plugin author:

1. **Identify all slice reads** in `invoke/4` body → replace with `ctx.read.(:key)` or `ctx.read.(:key, default)`
2. **Identify all slice writes** (returned `new_slice` map deltas) → emit `{:set, key, value}` effects in declared order
3. **Identify all `Snapshot.Writer` / `Snapshot.save_now` calls** → delete (framework handles)
4. **Identify all `Ezagent.Invocation.dispatch/1` calls** from inside `invoke/4` → emit `{:dispatch, %Cmd{...}}` effects
5. **Identify all `Phoenix.PubSub.broadcast/3` calls** → emit `{:notify, topic, payload}` effects
6. **Identify all direct side-effects** (file writes, Repo writes, external API calls) → emit `{:effect, &fn/N, args}` effects
7. **Identify all cap checks / `Ezagent.Capability.matches?` calls** → delete (framework handles via `caps:` declaration)
8. **Identify error returns** — distinguish business errors (handler returns `{:error, reason}`) from infra errors (let framework handle — handler raises, framework catches and writes failure event)
9. **Convert `state_slice`/`init_slice` declarations** → Kind-level `attach Behavior, init_state: %{...}` or per-Kind `init_state/1`
10. **Convert `data_owner/1`** → action-level `data_owner:` macro arg
11. **Convert `required_caps/0` / `cap_subjects/0` / `cap_exempt_actions/0`** → action-level macro args
12. **Convert `post_init/2` / `handle_continue/3` / `on_ready/2` / `terminate/3`** → Kind-level lifecycle hooks (if any survive; most don't)
13. Re-run domain test suite; ensure migration parity test §7.3 passes

### §6.3 — Estimated effort with confidence bounds (codex r1 MED-4 closure — REVISED UPWARD)

| Phase | Lower bound | **Most likely (REVISED)** | Upper bound |
|---|---|---|---|
| Phase 1 (framework primitives + LegacyBehaviorAdapter) | 3 wk | **4–5 wk** | 7 wk |
| Phase 2 (per-domain migrations, partially parallelizable) | 6 wk | **8–10 wk** | 14 wk |
| Phase 3 (remove adapter) | 3 days | **1 wk** | 2 wk |
| Phase 4 (cleanup) | 3 days | **1 wk** | 2 wk |
| **Total wall-time** | **10 wk** | **14–17 wk** | **25 wk** |

**Why the upward revision** (codex r1 MED-4 made the prior 8-10 wk look optimistic):

- Phase 1's prior 3wk estimate omitted ~300-400 LOC `LegacyBehaviorAdapter` and the design closure work for OQ-1 through OQ-8 (each OQ resolution ripples through the framework primitives — e.g. OQ-5's flat-namespace decision affects Router lookup keys, Behavior macro collision check, and Caps.Engine cap shape simultaneously)
- Phase 2's prior 4-6 wk assumed 2 PR/wk review cadence. Historical data on ezagent: PR-G AgentBridge alone took 3 weeks for ONE plugin extraction. ExternalMirror domain extraction (3 Behaviors + 1 Kind + 2-tier supervisor) took 5 weeks. Phase 2 PR 4 (`domain_chat` — Chat + Template + OrchestratorAdmin + Publisher.SessionImpl, the largest at ~3,800 LOC of Behavior code) realistically takes 2-3 weeks alone. Phase 2 PR 5 (`domain_external_mirror` — Worker has two-tier supervisor + post_init Resource lifecycle) realistically takes 3-4 weeks alone. Sequential sum is well over 6 weeks; parallelism caps at 2 in-flight PRs due to review bandwidth (codex round 1-2 per PR + Allen's bandwidth + ZH lockstep)

**Comparison to past migrations** (calibration data, not just floor):
- PR-G AgentBridge extraction: ~3 weeks for **one** plugin extraction
- PR-EM external_mirror domain extraction: ~5 weeks for **one** domain (3 Behaviors + 2-tier supervisor + boot reconciler)
- Phase 8b session-LV redesign: ~4 weeks for **one** subsystem (LV-side only, no Behavior contract change)

**The 14-17 wk most-likely band** places "ezagent fully on new contract" at **mid-September to early October 2026** (14-17 weeks from 2026-05-28). The 25-week upper bound (end of November 2026) accounts for: any HIGH finding in a future codex round triggering a structural rework, ExternalMirror Worker migration revealing deeper Resource-pattern issues (HIGH-3 already surfaced one), Allen's bandwidth being limited to 1 PR/wk during certain stretches.

**Allen's call on whether to accept this**: the original 8-10wk in r1 was aspirational; the 14-17wk in r2 is calibrated against actual past migration velocity. If 14-17wk is unacceptable, the only honest paths are (a) accept a smaller scope (don't migrate all 22 Behaviors — pick a subset), or (b) bring in additional contributor capacity. The SPEC as designed does NOT compress further without quality compromise.

---

## §7 — Testing strategy

### §7.1 — Framework primitive tests

Unit tests under `apps/ezagent_core/test/ezagent/`:

- `router_test.exs` — dispatch correctness, cap enforcement happens before handler, audit row written, idempotency dedup, workspace iso enforced, error normalization
- `behavior_macro_test.exs` — `action :name, ...` declaration aggregates correctly, compile-time error if `handle_<action>/2` missing, compile-time error if cap declared but not in cap subjects, `ctx.read.(:key)` returns correct value
- `kind_macro_test.exs` — `attach Behavior, ...` validates Behavior's actions exist, `read_graph` compile-checks against attached Behaviors, `pattern: :entity` macro adds expected lifecycle hooks
- `event_log_test.exs` — `stream_by_aggregate` ordering correct (with same-microsecond test), cursor pagination total + stable, append idempotent on duplicate command_uuid
- `state_rebuilder_test.exs` — rebuild = snapshot + fold(events_since_snapshot); 100-dispatch chaos test: kill, rebuild, compare against in-memory state
- `saga_runner_test.exs` — forward-only happy path, fail-at-step-N reverse-compensates, compensate-itself-fails leaves operator-repair marker

### §7.2 — Plugin contract invariant tests

Invariants ALL plugins must satisfy — checked at boot + in CI:

| Invariant | Test |
|---|---|
| Handler never sees slice | grep gate: `def handle_` in `apps/*/lib/.../behavior/*.ex` has no `slice` arg |
| Handler never dispatches directly | grep gate: zero `Ezagent.Invocation.dispatch` calls inside `def handle_` bodies |
| All state changes via effects | grep gate: no `Snapshot.Writer` / `Snapshot.save_now` outside `apps/ezagent_core/lib/ezagent/snapshot/` |
| Cap-required actions reject when cap missing | property test per Behavior |
| All effects are valid grammar | runtime invariant — effect-validator at Router step 10 |

### §7.3 — Migration parity tests (codex r1 MED-3 closure — split into 2 parity levels)

For each migrated Behavior, the parity test suite has **two distinct levels**:

#### Level 1 — Dispatch parity (legacy adapter mode)

Validates that running an unmodified `invoke/4`-shaped Behavior through `LegacyBehaviorAdapter` produces the **same dispatch-visible outcome** as running it natively (pre-migration). Compares:

- **Same input** (the `%Cmd{}` envelope under old `Invocation.dispatch/1` shape vs new `Router.dispatch/1` shape — both shapes wire-compatible)
- **Same final state** (snapshot row after dispatch — content-equal, modulo `inserted_at` jitter)
- **Same observable side effects** (PubSub broadcasts: same topic, same payload — by capturing both old & new via a probe subscriber)
- **Same dispatch reply** (`{:ok, result}` shape-equal)

Dispatch parity is the gate for each Phase 2 PR — the migration is allowed to land only if dispatch parity holds for every Behavior in that PR.

#### Level 2 — Replay parity (post-migration native Behaviors only)

Validates that, for a Behavior fully migrated to the new `handle_<action>/2` shape, **rebuilding state from EventLog yields the same slice as running the dispatch live**. This is a STRONGER claim than dispatch parity, and is only meaningful for native-shape Behaviors (not adapter-mode).

Compares:
- Start from empty snapshot
- Run N dispatches
- Capture in-memory slice state
- Kill the Kind process
- Re-spawn — StateRebuilder reads empty snapshot, folds events from EventLog via `apply_event/2`
- Assert: re-spawned slice = in-memory slice (modulo non-determinism markers like timestamps)

**Replay parity does NOT apply to LegacyBehaviorAdapter Behaviors** — they are documented as non-replay-equivalent (§6.1 Phase 1). The adapter wraps legacy side effects (PubSub broadcasts, cross-Kind dispatches, Repo writes) that happened OUTSIDE the effect grammar; folding events back through `apply_event/2` cannot reconstruct them. StateRebuilder treats adapter-mode Behaviors as "snapshot-only" — relies on the snapshot, NOT event fold, for those. Replay parity becomes meaningful AFTER Phase 3 when all Behaviors are native.

#### What the parity tests do NOT compare

- **EventLog row count** (intentional incompatibility — new design emits more events; this is by design, not a defect. Subscribers to `EventLog.stream_by_workspace/2` and EventSubscriber consumers WILL see new event types post-migration; the migration plan documents this in CHANGELOG entries per Phase 2 PR)
- **Snapshot frequency** (old: per `:on_change`; new: per pattern — by design, see HIGH-3 closure)
- **Telemetry events** (renamed under new structure — `[:ezagent, :invoke, :stop]` becomes `[:ezagent, :router, :dispatch_stop]`)

### §7.4 — Invariant test for "done"

Per `feedback_completion_requires_invariant_test`, the architectural goal is "future devs work on different plugins without coordination." The executable check that proves the migration is done:

```bash
# Phase 3 done gate — runs in CI
ALL_BEHAVIOR_FILES=$(find apps -path "*/lib/ezagent/behavior/*.ex" -not -path "*/test/*")

# 1. No plugin Behavior defines invoke/4
test "$(grep -l 'def invoke(' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 2. No plugin Behavior reads slice
test "$(grep -l ', slice,' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 3. No plugin Behavior calls Invocation.dispatch
test "$(grep -l 'Ezagent.Invocation.dispatch' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 4. No plugin Behavior calls Phoenix.PubSub.broadcast directly
test "$(grep -l 'Phoenix.PubSub.broadcast' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 5. No plugin Behavior calls Snapshot directly
test "$(grep -l 'Ezagent\.\(Kind\.\)\?Snapshot\.' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 6. No plugin Behavior touches BehaviorRegistry / CapabilityRegistry
test "$(grep -l 'Ezagent\.\(Behavior\|Capability\)Registry' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 7. Plugin LOC reduction ≥ 50%
NEW_LOC=$(cat $ALL_BEHAVIOR_FILES | wc -l)
test $NEW_LOC -lt 5500   # was ~11,000

echo "DONE — plugin contract is isolated from framework internals"
```

All 7 checks must pass. Until they do, the migration is incomplete. **This is the architectural-commitment test, run alongside `mix test` in CI.**

---

## §8 — Open questions for Allen

These are real architectural decisions that need Allen's input (or explicit deferral). Listed in priority order.

### OQ-1 — Resource URI scheme

**Question**: how should Resource URIs be formed?

- Option A: `resource://<owner_kind>/<owner_name>/<type>/<name>` — e.g. `resource://agent/cc_demo/config-dir/main`. Pro: type encoded in URI; clear ownership. Con: changing ownership re-keys the URI (a violation of `feedback_uuid_is_canonical_identifier` if ownership ever transfers)
- Option B: `<owner_uri>?resource=<type>:<name>` — query-string form on owner. Pro: ownership transfer doesn't re-key. Con: ugly; not RFC-3986-clean
- Option C: separate scheme per type — `config-dir://agent/cc_demo/main`, `api-key://agent/cc_demo/anthropic`. Pro: each resource type is a "first-class noun." Con: scheme explosion

**Recommendation**: Option A. Ownership transfer is rare; the readability win is large. Document the constraint that resource URIs are immutable after creation; if ownership must transfer, the resource is destroyed and recreated.

### OQ-2 — Per-Kind composition pattern enforcement

**Question**: is composition-pattern enforcement just documentation, or compile-time?

If the `use Ezagent.Kind, pattern: :entity` macro saw a Resource-pattern lifecycle hook (e.g. `cascade_on_owner_destroy`), should it (a) warn, (b) error at compile-time, (c) silently allow with runtime opt-in?

**Recommendation**: compile-time error. Per `feedback_let_it_crash_no_workarounds`, structural mismatches should be loud. Document escape hatch as `pattern: {:custom, [hook1, hook2]}` for the (rare?) case where the standard patterns don't fit.

### OQ-3 — Effects ordering semantics

**Question**: see §4.4 — effects applied in declared order, EventLog + state in one transaction, notifies/effects fire post-commit, dispatches async, terminate/saga post-reply. Is this the right ordering?

Specifically: should `{:dispatch, %Cmd{}}` effects be applied **before** `{:notify, …}` (so the dispatch fan-out is observable on PubSub via the dispatched Kind's own emits, not the originator's notify)? Or after (so the notify is the leading signal)?

**Recommendation**: post-commit, dispatch BEFORE notify. The dispatched Kinds emit their own events that subscribers will see; the originator's notify is a coarser "something happened on me" signal that arrives last. This matches today's Chat ordering (Resolver → dispatch_receive → PubSub broadcast for LV).

### OQ-4 — Saga compensation declaration

**Question**: inline `(forward, compensate)` pairs in the saga definition, or separate `compensate_<step_name>` callbacks?

- Inline: `SagaRunner.step(saga, :revoke_caps, &revoke_all_caps/1, &restore_caps/2)` — terse but couples definition + behavior
- Separate: `def compensate_revoke_caps(effect_map, prior_effects), do: ...` — pure functions, more discoverable but more files

**Recommendation**: inline. Sagas in ezagent are short (4–7 steps typically); inline keeps the saga readable as a single declarative pipeline.

### OQ-5 — Multi-Behavior-per-Kind merge

**Question**: User Kind currently has 4 Behaviors (Identity + UserCredentials + UserTokens + WorkspaceUserAdmin). In new model, does User Kind expose ONE merged action namespace, or per-Behavior namespaced?

Today: `entity://user/system/admin?action=user_credentials.set_password` — Behavior name prefix.

Options:
- A: drop the Behavior prefix — `entity://user/system/admin?action=set_password` (assumes no action name collisions across attached Behaviors)
- B: keep Behavior prefix — same as today
- C: rename Behaviors so that action names are unique across the Kind (e.g. `Behavior.UserCredentials` becomes `Behavior.UserPassword` and `:set_password` becomes `:set` — read against the Behavior name as namespace)

**Recommendation**: A, with compile-time collision check at `use Ezagent.Kind, ... attach Behavior, ...`. Action namespace flat across the Kind; collision is a compile error. This simplifies caller code dramatically.

### OQ-6 — ExternalMirror's special status

**Question**: today ExternalMirror Worker has its own `BootReconciler` (currently the ONLY Kind with one). Does ExternalMirror Worker become a regular Resource-pattern Kind, or stay special?

**Recommendation**: regular Resource-pattern Kind. The framework's StateRebuilder + the per-Kind `on_rebuild/1` callback handles the BootReconciler's role generically. The two-tier supervisor stays (it's a domain concern). The `external_mirror_bindings` projection table becomes a read-model that the StateRebuilder consults.

### OQ-7 — Effect handlers that need return values

**Question**: `{:dispatch, %Cmd{}}` is async (cast); the originator doesn't see the dispatched Kind's result. What about the (rare) case where the originator needs to chain on the dispatch's result?

- `{:dispatch_call, %Cmd{}, on_result: fn r -> [effect, effect] end}` — declarative continuation
- Or: refuse to support this; if you need to chain, write a saga

**Recommendation**: refuse. If a handler needs to chain on a dispatch result, it's actually a saga (orchestrating multi-step work). Force it through SagaRunner; saga primitive is cheap and the chained-dispatch effect-with-continuation is a recipe for callback hell.

### OQ-8 — Backward-compat for in-flight data migration

**Question**: existing data in `kind_snapshots` table holds slice-shaped state (`%{slice_key => slice_map}`); new design's snapshots hold flat `{behavior_module, field} → value` state. Migration?

Options:
- A: write a one-shot data-migration tool (`mix ezagent.migrate.snapshots`) that walks every row, applies the legacy-adapter transform, writes new shape
- B: snapshot rebuilding on first Kind load post-Phase-3 (StateRebuilder reads legacy shape, folds events, writes new-shape snapshot)
- C: keep both shapes in parallel during Phase 2 (one column per shape); pick at read time

**Recommendation**: B. The StateRebuilder is going to fold events anyway; legacy snapshots are a starting point but the event log is the SoT. Write a one-time `mix ezagent.snapshots.replay` that touches every Kind URI post-Phase-3 to force rebuild + new-shape persist.

---

## §9 — Codex adversarial-review attack vectors

Pre-loaded for codex review subagent (10 prompts; static-only — no `mix` commands per `feedback_codex_companion_no_mix`):

### AV-1 — Effects vocabulary coverage

Walk through `Behavior.Chat.invoke(:send)` (`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:297-419`), `Behavior.ExternalMirror.invoke(:bind_session)` (`apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex`), and `Behavior.Workspace.invoke(:create_session)` (`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex`). For each: is every side effect expressible via the §4.4 grammar? If not, what's the missing effect? Specifically check: `MessageStore.write` inside Chat (an Ecto write — covered by `{:effect, &fn/N, args}`?). `Process.monitor` inside Chat's `:join` (a runtime primitive, not really an effect — does the framework expose a `{:monitor, target_uri}` effect?). `Phoenix.PubSub.subscribe` from Worker's `post_init` (not via effects — does it stay as a Kind lifecycle hook?).

### AV-2 — Framework-managed snapshot policy correctness

§5.2 has the framework decide policy per pattern: Session = `every_n_events: 100`, Entity = `on_change`, Resource = `on_change`. Is this actually correct for every current Kind? Specifically: ExternalMirror Worker is high-volume (every binding event triggers a Worker dispatch); its current `persistence/0` is `:on_terminate`. Forcing it to `on_change` (per Resource pattern default) would 10x the snapshot write rate. Is the framework decision wrong here, or should Resource pattern have a sub-classification (`:hot_resource` vs `:cold_resource`)?

### AV-3 — Legacy adapter mechanics

§6.1 Phase 1 keeps old `Behavior.invoke/4` Behaviors working via `LegacyBehaviorAdapter`. Define the adapter's mechanics: it must wrap `invoke/4`'s return into `{result, effects}` shape. How does it know which slice keys to emit `{:set, k, v}` for? Via diff of old vs new slice — but the slice is the Behavior's private data shape; the adapter has to KNOW the slice shape to diff it. Is this actually a leak of slice into the framework? Walk through `Behavior.Chat`'s adapter run: the adapter sees old slice `%{members: ..., monitors: ..., last_message_id: nil}` and new slice `%{members: ..., monitors: ..., last_message_id: "abc", last_message: %Message{...}, send_cursor: 1}` — does it emit `{:set, :last_message_id, "abc"}, {:set, :last_message, %Message{...}}, {:set, :send_cursor, 1}`? Yes, and that's fine — the diff is generic Map manipulation, not slice-shape-aware. **Confirm or refute this claim.**

### AV-4 — Cap action-axis under the new `caps:` macro

The cap-vis SPEC #423 spent 4 rounds on the action-axis: caps are `{kind, behavior, action, instance}` 4-tuples; a cap with `action: :any` matches any action; a cap with `action: :send` only matches `:send`. The new `caps: [:send]` macro form looks like it FORCES action to `:send` — but what about a cap that should match any action of a Behavior (the "owner of this Behavior can do everything" shape)? Is there a `caps: [:any]` form? Walk through `Behavior.Identity`'s `:list_caps` (today: any cap on Identity Behavior matches; the action axis is `:any`).

### AV-5 — Resource pattern fits every owned-by-Entity thing

Walk through EVERY current "thing owned by an Entity" and confirm Resource pattern fits:

1. Agent's config_dir (today: `Behavior.Sandbox` slice on Agent)
2. Agent's API keys (today: `Behavior.ApiKeys` slice on Agent)
3. User's password hash (today: `Ezagent.Users` Ecto row)
4. Workspace's bindings (today: `external_mirror_bindings` Ecto + slice)
5. Cap-grants from User to Agent (today: `:caps` MapSet on User's Identity slice)
6. AgentTemplate config (today: `Behavior.Template` slice on AgentTemplate Kind)
7. Session messages (today: `Ezagent.MessageStore` Ecto)

For each: would treating it as a Resource Kind with `resource://owner/.../...` URI cause regressions in (a) lookup ergonomics (LV queries), (b) cascade-on-destroy correctness, (c) per-action cap shape clarity?

### AV-6 — Saga compensation end-to-end for destroy cascade

SPEC #440's #1 failing scenario: destroy User → revoke caps held by User → destroy all User's Sessions → destroy all User's Agents → destroy all User's Resources. Codex flagged: "If step 3 succeeds but step 4 fails, the User is in an inconsistent state — some Agents destroyed, others alive."

Walk through the new design's complete destroy saga:

```elixir
saga
|> step(:enumerate_resources, ...)
|> step(:snapshot_state_for_compensation, ...)
|> step(:revoke_held_caps, ..., compensate: &restore_caps/2)
|> step(:destroy_sessions, ..., compensate: &resurrect_sessions/2)
|> step(:destroy_agents, ..., compensate: &resurrect_agents/2)
|> step(:destroy_owned_resources, ..., compensate: &resurrect_resources/2)
|> step(:terminate_user_kind, ..., compensate: &noop/2)
|> execute(...)
```

For each compensation: is it actually possible? "resurrect_sessions" can mean restoring from the snapshot — but the Session has new messages that arrived during the compensation window. Are those lost? Is the saga's compensation actually a "best-effort partial restore" or a "true rollback"? Document the honest answer.

### AV-7 — `ctx.read` for state-dependent emits

The "no slice in plugin code" invariant — what about plugins that legitimately need to READ current state and emit an event based on the result?

Example: `Behavior.Lifecycle.destroy` reads the Agent's lineage parent to notify them. Today this is `Ezagent.AgentLineage.lookup(self_uri)` — a registry call. In the new design, is `AgentLineage` exposed via `ctx.read.(:lineage_parent)` or is it a runtime call inside the handler (i.e. handlers ARE allowed to call out to registry-style modules)?

Walk through the implications: if handlers can call ANY module that ISN'T `Ezagent.Invocation`/`Snapshot`/`Capability` directly, the "no framework internals in plugin code" invariant has escape hatches. Where exactly is the line?

### AV-8 — Migration parity test feasibility

§7.3 defines parity as "same input → same final state + same observable side effects + same dispatch reply." But the new design emits MORE events (every `{:emit, …}` is a new EventLog row that old design never wrote). The parity test must define "same observable" tightly: what about subscribers that today receive ZERO events from `Behavior.Chat.send` and tomorrow receive 1 `message_sent` event? Are they observing a "no-op change" or a "fundamental shift"?

Walk through a concrete migration parity test for `Behavior.Chat.send`: what's compared, what's intentionally divergent, what's the failure criterion.

### AV-9 — Multi-Behavior-per-Kind dispatch routing

User Kind has 4 Behaviors today (Identity + UserCredentials + UserTokens + WorkspaceUserAdmin). In the new model with OQ-5 Option A (flat action namespace), action name collisions across attached Behaviors are compile errors. But what about `Behavior.Chat` attached to BOTH User and Agent Kinds with `:receive` action? Same Behavior, same action, different Kind — does the Router route on `(kind, action)` or `(kind, behavior, action)`?

If `(kind, action)`: how does the Router know which Behavior to invoke when one Kind has multiple Behaviors? (Today: `BehaviorRegistry.lookup(kind_module, action)` returns the registered Behavior; collisions impossible because actions are unique per Behavior).

If `(kind, behavior, action)`: the URI includes the Behavior name, contradicting OQ-5 Option A.

What's the actual routing key, and how does it interact with cap-vis caps that today carry `{kind, behavior, action, instance}`?

### AV-10 — Effort estimate realism

§6.3 says 8–10 weeks most-likely, 16 weeks upper bound. Comparison: AgentBridge extraction was ~3 weeks for ONE plugin. ExternalMirror domain extraction was ~5 weeks for ONE domain. This SPEC migrates 22 Behaviors + 13 Kinds + the framework. Is 8–10 weeks realistic, or is it the rosy floor?

Walk through Phase 1 in detail: how much of the framework primitives are genuinely new code (Router, EventLog stream-by-aggregate, SagaRunner, EventSubscriber, StateRebuilder, Caps.Engine — ~1,200 LOC) vs refactor of existing code (Behavior macro, Kind macro, Kind.Host — ~1,200 LOC). At ~250 LOC/dev-day under ezagent's spec-heavy review process (codex rounds, ZH lockstep, parity tests), Phase 1's 2,400 LOC = ~10 dev-days = 2 wall-weeks of focused work — IF nothing surfaces. With realistic spec-review overhead, 3 weeks is the floor, 5 weeks the upper bound for Phase 1 alone.

Phase 2's 22 Behaviors at 1–3 days each (mechanical retrofit per §6.2) = ~44–66 dev-days = ~9–13 wall-weeks at 1 PR/wk review cadence. 4–6 wk most-likely assumes 2 PR/wk review cadence, which is aggressive for this codebase's REJECT-heavy past.

Honest re-estimate after this analysis?

---

## §10 — Migration risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R-1 | Behavior signature breaking change blocks unrelated work for 8+ weeks | High | High | Phase 2 PRs are independently mergeable; non-migration PRs continue to use legacy adapter through Phase 2 |
| R-2 | Legacy adapter (Phase 1) accidentally becomes permanent | Medium | High | Adapter has a `delete-by-end-of-phase-3` issue from day 1; deprecation warning on every load; `mix ezagent.audit.legacy_adapter` shows remaining sites; Phase 3 PR cannot land while sites remain |
| R-3 | Effect vocabulary discovered insufficient mid-migration | Medium | High | AV-1 codex pass MUST walk every current Behavior's effect needs BEFORE Phase 2 starts; any gap surfaced becomes part of Phase 1 closure |
| R-4 | Resource boundary fix (Phase 2 PR 8) requires schema migration that interacts with in-flight Phase 2 PRs | High | Medium | Resource boundary fix is the LAST Phase 2 PR; all other domains migrated before schema changes |
| R-5 | Saga compensation correctness gap (AV-6's "best-effort rollback") leaks into ezagent's destroy semantics, surprising operators | Medium | Medium | SagaRunner contract documents compensation as "best-effort", not "true rollback"; ezagent destroy SPEC #440 v2 (re-attempted after this lands) MUST explicitly call out the semantics |
| R-6 | StateRebuilder's "fold events into state" path discovers events that no `apply_event/2` can interpret | Low | High | Phase 1 Phase 1 builds `apply_event/2` derivation from `{:set, …}`/`{:emit, …}` effects; if a Behavior's pattern doesn't generate clean apply_event derivation, Phase 1 surface that as a blocker |
| R-7 | Allen's review bandwidth caps Phase 2 PRs to <1/wk, pushing wall-time to 16wk upper bound | Medium | Medium | Pair migration PRs with codex pre-review; Allen's bandwidth used only for design checkpoints, not line-by-line |
| R-8 | `feedback_north_star_plugin_isolation` invariant slips during Phase 2 (some sneaky framework access leaks into "just one Behavior") | Medium | High | The 7 invariant checks in §7.4 run in CI; Phase 2 PR blocked if any check fails post-migration |

---

## §11 — Acceptance criteria (the "done" gate)

Per `feedback_completion_requires_invariant_test`, the migration is "done" when ALL of the following are true (CI-checked):

1. **Zero `def invoke(` in plugin Behaviors** — `find apps -path "*/lib/ezagent/behavior/*.ex" -not -path "*/test/*" -exec grep -l "def invoke(" {} \; | wc -l == 0`
2. **Zero `slice` arg in plugin handlers** — same find, grep `, slice,` → 0 matches
3. **Zero `Ezagent.Invocation.dispatch` inside plugin handlers** — same find, grep → 0
4. **Zero `Phoenix.PubSub.broadcast` inside plugin handlers** — same find, grep → 0
5. **Zero direct snapshot calls in plugins** — same find, grep `Ezagent\.\(Kind\.\)\?Snapshot\.` → 0
6. **Zero plugin access to framework registries** — same find, grep `Ezagent\.\(Behavior\|Capability\)Registry` → 0
7. **Plugin LOC reduction ≥ 50%** — `wc -l apps/*/lib/ezagent/behavior/*.ex` totals ≤ 5,500 (was ~11,000)
8. **All current dispatch flows pass migration parity tests** — every Behavior has a `<behavior>_migration_parity_test.exs` that compares old vs new on fixture inputs (§7.3)
9. **The legacy adapter is deleted** — `apps/ezagent_core/lib/ezagent/legacy_behavior_adapter.ex` does not exist; `mix ezagent.audit.legacy_adapter` reports "no legacy callers"
10. **CONTRIBUTING.md and plugin author guide reflect new contract** — current per-Behavior boilerplate disappears from the guide; the 30-LOC example replaces the 200-LOC one

Until all 10 are green in CI on the main branch, this SPEC is unfinished.

---

## Appendix A — Comparison with PR #442 §1.5.7

PR #442 §1.5.7 (Option B'') already identified the 5 framework primitives — `EventLog`, `SnapshotStore`, `StateRebuilder`, `SagaRunner`, `EventSubscriber`. This SPEC keeps all 5 (§5.1–§5.5) **but adds three new primitives that PR #442 didn't surface**:

| PR #442 §1.5.7 | This SPEC |
|---|---|
| `EventLog` ✓ | `EventLog` ✓ (§5.1) — same |
| `SnapshotStore` ✓ | `SnapshotStore` ✓ (§5.2) — but plugin authors don't pick policy; framework decides per pattern |
| `StateRebuilder` ✓ | `StateRebuilder` ✓ (§5.3) — same |
| `SagaRunner` ✓ | `SagaRunner` ✓ (§5.4) — same |
| `EventSubscriber` ✓ | `EventSubscriber` ✓ (§5.5) — same |
| `Behavior.invoke/4` stays + opt-in `execute_command/apply_event/effects` triplet | **`Behavior.handle_<action>/2` REPLACES `invoke/4` — full breaking change**, no opt-in (Allen's 10:30 directive) |
| Slice stays as the plugin author's data model | **Slice GONE from plugin author surface** — `ctx.read` reads framework-managed state |
| `Router` mentioned as 6th module (~50 LOC, r8 addition) | **`Router` is the FIRST primitive**, ~200 LOC — promoted to peer of `Behavior` and `Kind` (Allen's 10:08 insight) |
| Composition patterns not named | **Session / Entity / Resource** patterns formalized — the 3-pattern axis is the new core (Allen's 10:30 directive) |
| ~880 LOC framework | ~2,480 LOC framework |
| ~50 Behaviors per author estimate | 22 Behaviors actual; ~10–30 LOC per Behavior post-migration |

The biggest delta from PR #442: **Allen's 10:30 reframe — "router, behavior, kind 三个" — is THE core architectural insight**. PR #442 was a CQRS-shaped refinement on top of the existing plugin contract. This SPEC reframes everything around plugin isolation: the plugin author writes `handle_<action>/2`, declares effects, knows nothing else. That's the bet.
