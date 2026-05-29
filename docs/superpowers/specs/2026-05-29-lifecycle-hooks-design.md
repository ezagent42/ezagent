# SPEC — Lifecycle API: hiding the CQRS engine behind agent-SDK-style hooks

- **Date**: 2026-05-29
- **Status**: DESIGN ONLY (no implementation in this PR)
- **Author**: Claude Opus 4.8 (1M context), grounded against `origin/main` `b5acb1f8`
- **Owner**: Allen — the decisive design choices in §0 are HIS and are not relitigated here
- **Supersedes (developer surface only)**: the developer-facing portions of `2026-05-28-router-behavior-kind-architecture.md`. That SPEC's Router/Behavior/Kind primitives are NOT deleted — they become the INTERNAL engine this API compiles down to.
- **Related**: `2026-05-29-dispatch-returning-effect.md` (effect grammar), `2026-05-24-caps-data-ownership-v2.md` (`data_owner`), `2026-05-25-caps-cleanup-v1-r4-impl.md` (caps), Decision Log #147-#152.

---

## §0 — The decisive design choices (Allen, do-not-relitigate)

These are GIVEN. The rest of this SPEC is the consequence of honoring them exactly.

1. **Two-container state.** A Lifecycle module holds two named containers and nothing else:
   - `state` — PERSISTENT. The framework auto-snapshots it. The developer NEVER calls snapshot/commit.
   - `transients` — NEVER persisted. PIDs, refs, ETS handles, ports, subprocess handles, monitor refs, cached external connections. Rebuilt from scratch on every `activate`.
   The framework PHYSICALLY persists only `state`; `transients` has no serialization path at all. A transient therefore *cannot* be accidentally persisted. This is the mechanism that kills the cold-restart bug class **by construction**.
2. **Big-bang migration.** Convert ALL Behaviors to the Lifecycle API at once. No long-lived coexistence of two developer-facing styles.
3. **Lifecycle is the SOLE public API.** Eliminate developer-facing R/B/K usage entirely: `use Ezagent.Behavior`, hand-written `init_slice`, `handle_<action>`, direct `slice` access, and any developer-facing `Invocation` / `slice` / `snapshot` concept are GONE from plugin and domain code. Router/Behavior/Kind become an internal engine that the Lifecycle macro compiles down to.
4. **Keep the declarative effect grammar.** Handlers still return effects (`:set` / `:emit` / `:dispatch` / `:dispatch_returning` / `:notify` / `:effect` / `:effect_returning` / `:saga` / `:halt` / `:terminate` / `{:ref, ...}`). Only the slice/invocation/snapshot MECHANICS are hidden. The effect DSL is the value-add and stays verbatim.
5. **Two-tier phase model.**
   - COARSE (OTP-grounded): `create` / `activate` / `handle` / `deactivate` / `destroy`.
   - FINE (Claude-Code-hook-grounded): optional `pre_handle` / `post_handle` cross-cutting interception.

---

## §1 — Goal + non-goals

### The problem

Today a plugin author who wants to add an agent must understand five framework concepts that have nothing to do with their domain: `state_slice/0` (which atom key their data lives under), `init_slice/1` (fresh-spawn construction), the snapshot merge semantics (`load_or_init/3` merges snapshot OVER fresh, snapshot wins), the five persistence strategies, and the **four different boot hooks** (`post_init/2`, `handle_continue/3`, `on_ready/2`, `reconcile_after_load/2`) each with subtly different timing relative to the `ReadyGate` flip. `references/slice-and-snapshot.md` opens by quoting Allen: *"这是 ezagent 中实现最为复杂、意义最不清晰的一部分"* ("this is the most complex and least-meaningful part of ezagent").

That complexity is not incidental — it has produced a recurring, expensive bug CLASS: **a resource is rebuilt correctly on fresh spawn but NOT on cold-load-from-snapshot**, because the rebuild logic was written in one of the four boot hooks but the author did not realize cold-load takes a different path. Three concrete instances (§4): the orchestrator MCP ETS row (Task #110), the codex bridge subprocess (Task #113), the AgentLineage ETS table (Task #114 class). Every one is "fresh works, restart doesn't."

The deepest cause is that **persistent state and transient handles live in the same `slice` map**, distinguished only by author discipline. Nothing physically prevents a PID or an ETS reference from being snapshotted (and then rehydrated as a dead reference on restart), and nothing physically reminds the author that a transient must be rebuilt every start.

### The conceptual solution

Give the developer an agent-SDK-shaped API with exactly two state containers and five lifecycle moments. Make `transients` un-persistable by construction, and make `activate` the single, unified "(re)build everything transient" moment that runs on EVERY process start — fresh spawn and cold-load alike. The author can no longer write rebuild logic in "the wrong hook" because there is exactly ONE rebuild hook.

### Goals

- G1. Hide CQRS mechanics (slice / invocation / snapshot / persistence-strategy) entirely behind the Lifecycle API.
- G2. Make Lifecycle the sole developer-facing API; the R/B/K engine becomes internal.
- G3. Eliminate the cold-restart bug class by construction via the two-container model + unified `activate`.
- G4. Preserve the effect grammar verbatim (it is the value-add, not the accidental complexity).
- G5. Preserve behavioral parity — every existing test must pass after migration.

### Non-goals

- NG1. NOT changing the wire-level dispatch envelope (`%Ezagent.Cmd{}`), the Router, capability model (CapBAC), URI SPEC v2/v3, or the effect-execution order. The engine is untouched except for the macro layer that emits it.
- NG2. NOT introducing back-compat shims for the old developer surface. Per `feedback_let_it_crash_no_workarounds` + ezagent-developer convention "No back-compat shims": the old surface is deleted, not preserved alongside the new.
- NG3. NOT inventing a new persistence backend. `state` persists through the existing `SnapshotStore` / `kind_snapshots` path; this SPEC only changes WHAT is eligible to persist (only `state`, never `transients`).
- NG4. NOT redesigning idle-eviction / `deactivate` semantics beyond what is needed to give the lifecycle a graceful-stop hook (see §7 OQ-4).

---

## §2 — The Lifecycle contract

### The problem this section solves

The developer needs a single module shape that (a) names the two state containers, (b) declares actions + returns effects exactly as today, and (c) exposes lifecycle moments mapped to OTP semantics — without ever naming a slice, an invocation, or a snapshot.

### Proposed macro name

```elixir
use Ezagent.Lifecycle
```

Rationale: "Lifecycle" names the developer-facing concept (the five moments) rather than the internal mechanism ("Behavior" is the engine word). Matches `feedback_self_explained_naming` (user-facing names describe intent). The engine module `Ezagent.Behavior` is unchanged and stays internal.

### The full hook signature set

```elixir
defmodule MyAgent.Lifecycle do
  use Ezagent.Lifecycle

  # ---- Action + effect declarations (UNCHANGED grammar — §2.3) ----
  action :send,
    args:        %{recipient: :uri, body: :string},
    returns:     %{ok: :boolean},
    caps:        [:send],
    modes:       [:cast],
    data_owner:  :self,
    description: "Send a message to another entity."

  # ============================================================
  # COARSE lifecycle hooks (OTP-grounded). All OPTIONAL except
  # `handle` clauses for declared actions (compile-time enforced).
  # ============================================================

  # `create/1` — FIRST-EVER existence of this URI. Runs ONCE in the
  # entity's entire history (gated by the persisted ever-created
  # marker — see §3 + §7 OQ-1). Build the initial PERSISTENT state.
  # MUST NOT build transients (no process exists yet that owns them
  # for the long run — `activate` does that, and runs immediately
  # after `create` on this same first start).
  #   args   :: map()  — boot-time args supplied to the spawner
  #   return :: {:ok, state :: map()} | {:error, reason}
  @impl Ezagent.Lifecycle
  def create(args)

  # `activate/2` — EVERY process (re)start. OTP `init/1` semantics.
  # Runs on: fresh spawn (right after `create`), supervisor restart,
  # AND cold-load-from-snapshot (phx restart / demand-spawn of a URI
  # whose state is on disk). This is the UNIFIED start hook — there is
  # NO separate "restart" / "on_load" / "on_ready" hook. Rebuild ALL
  # transients here, every time, from `state` (+ external SoT reads).
  # Self-heal here too (orphan-reap prior-incarnation resources) —
  # `destroy` is best-effort and may not have run (§OTP).
  #   state      :: map()  — the persistent state (freshly created OR
  #                          rehydrated from snapshot; activate cannot
  #                          tell the difference, and MUST NOT need to)
  #   ctx        :: %{self_uri: URI.t(), kind: module()}
  #   return     :: {:ok, transients :: map()}
  #              |  {:ok, transients :: map(), state :: map()}  # state may be
  #                 reconciled against an external SoT here (subsumes
  #                 reconcile_after_load — see §3)
  #              |  {:error, reason}   # crash → supervisor restarts → activate re-runs
  @impl Ezagent.Lifecycle
  def activate(state, ctx)

  # `handle/?` — process one command. Declared per action as
  # `handle_<action>(args, ctx)` (UNCHANGED from today's contract).
  # Returns the effect list. `ctx` exposes read access to BOTH
  # containers (see §2.2). Pure + directly testable.
  #   return :: {:ok, result, [effect]} | {:ok, result} | {:error, reason}
  def handle_send(args, ctx)   # one clause per `action`

  # `deactivate/2` — graceful stop; the ENTITY PERSISTS (state is kept
  # on disk; this is NOT destroy). Use to flush buffers, close handles
  # politely. Best-effort (OTP terminate semantics — §OTP).
  #
  # CONTRACT (resolved 2026-05-29, F5): `:ok`-only. deactivate runs
  # through OTP terminate/3, AFTER the final persistence snapshot is
  # already written (and not at all on a brutal kill), so it CANNOT
  # mutate persisted state — a returned state would be a silent no-op
  # or a torn write. Durable changes go in a handle_<action> or
  # activate/2's reconciliation return; deactivate is for side-effecting
  # external cleanup only.
  #   return :: :ok
  @impl Ezagent.Lifecycle
  def deactivate(reason, ctx)

  # `destroy/2` — PERMANENT deletion of the entity. Clears `state`
  # from disk and flips the ever-created marker off. Best-effort
  # (OTP terminate / explicit-destroy semantics — §OTP). Cleanup that
  # MUST happen even on a crash that skips `destroy` belongs in the
  # next incarnation's `activate` self-heal, NOT solely here.
  #   return :: :ok
  @impl Ezagent.Lifecycle
  def destroy(reason, ctx)

  # ============================================================
  # FINE interception hooks (Claude-Code-hook-grounded). OPTIONAL.
  # Cross-cutting concerns (authz, audit, effect injection) attached
  # WITHOUT editing `handle`. Compose across attached Lifecycles.
  # ============================================================

  # `pre_handle/3` — runs BEFORE the matched `handle_<action>`.
  # WIRED in Phase A (F6): `Ezagent.Kind.Runtime` probes
  # `function_exported?(mod, :pre_handle, 3)` and, when present, runs it
  # around the handler dispatch.
  #   :cont                       → proceed to handle unchanged
  #   {:cont, args}               → proceed with rewritten args
  #   {:halt, result}             → skip handle; return result, no effects
  #   {:error, reason}            → deny (e.g. extra authz gate)
  @impl Ezagent.Lifecycle
  def pre_handle(action, args, ctx)

  # `post_handle/4` — runs AFTER `handle_<action>` returns, BEFORE the
  # effect list is executed. May inject/append effects (audit, mirror).
  # WIRED in Phase A (F6) in `Ezagent.Kind.Runtime` (also fires when the
  # handler returned `{:ok, result}` with no effects, so a post_handle
  # may INJECT effects).
  #   {:ok, result, effects}      → replace the handler's result + effects
  #   :cont                       → result + effects unchanged
  @impl Ezagent.Lifecycle
  def post_handle(action, result, effects, ctx)
end
```

`ctx` for `handle_*` / `pre_handle` / `post_handle` carries (framework-injected; the developer never plumbs these): `:self_uri`, `:kind` (module), `:caller`, `:reply`, `:caps`, `:state` (read view), `:transients` (read view), plus the `read/2` helper (`ctx.read.(key, default)`) for ergonomic state reads. See §2.2.

### §2.1 — The two-container model (state vs transients)

| | `state` | `transients` |
|---|---|---|
| Persisted? | YES — framework auto-snapshots | NEVER — no serialization path exists |
| Holds | domain data (members, conversation, config, caps) | PIDs, refs, ETS handles, ports, subprocess handles, monitor refs, cached connections |
| Written via | `{:set, key, value}` effects from `handle_*`; returned from `create`/`activate`/`deactivate` | returned from `activate` (rebuilt every start); never an effect target |
| Read via | `ctx.read.(key, default)` or `ctx.state[key]` | `ctx.transients[key]` |
| Survives restart? | YES (durable) | NO — gone with the process; `activate` rebuilds |

The framework physically separates the two: only `state` is handed to `SnapshotStore`. `transients` lives in the host GenServer's memory and is dropped on every stop. **A transient cannot be accidentally persisted** because there is no code path that serializes it. **A transient cannot be forgotten on restart** because `activate` is the only place it can be built and `activate` runs on every start.

### §2.2 — How `handle` declares actions + returns effects (UNCHANGED)

Reuse the existing `action :name, args:, returns:, caps:, modes:, description:, data_owner:, workspace_scoped?:` declaration grammar VERBATIM (`Ezagent.Behavior.action/2` macro, behavior.ex L605-L704). Reuse the effect vocabulary VERBATIM (`Ezagent.Behavior.@type effect`, behavior.ex L876-L890, plus the execution order from `Ezagent.Kind.Runtime`). The ONLY change visible to a handler author:

- Old: handler reads its slice via `ctx[:read].(key, default)`; sibling slices via `reads_sibling_slices/0` + `ctx[:sibling_slices]`.
- New: handler reads its own state via `ctx.read.(key, default)` (identical helper, renamed to drop the "slice" word) and reads transients via `ctx.transients[key]`. Sibling-state reads are declared via `reads_siblings/0` (renamed from `reads_sibling_slices/0`) and surfaced via `ctx.siblings` — the same opt-in, same scoping, same `:all_slices`-is-banned rule (invariant 18).

The handler return contract `{:ok, result, [effect]}` is byte-identical. `apply_effects/2` and the bucket execution order (State → Halt → Saga → DispatchesReturning → Dispatches → Notifies → Events → Terminations) are untouched.

### §2.3 — Before/after for the 3 representative modules

#### (A) `Ezagent.Behavior.CurlAgent` (simple) → `Ezagent.Lifecycle.CurlAgent`

The simplest case: pure-state agent, one sibling-state read (`:api_keys`), no transients.

BEFORE (today, `apps/ezagent_plugin_curl_agent/lib/ezagent/behavior/curl_agent.ex`):
```elixir
use Ezagent.Behavior
@behaviour Ezagent.Behavior
def state_slice, do: :curl_agent
def reads_sibling_slices, do: [:api_keys]
def init_slice(args), do: %{provider: ..., conversation: [], last_error: nil, ...}
def required_caps, do: %{receive: cap(:curl_agent, __MODULE__, :receive), ...}
def handle_receive(%{message: %Message{} = msg}, ctx) do
  current_conv = ctx[:read].(:conversation, [])
  api_key = ctx |> Map.get(:sibling_slices, %{}) |> Map.get(:api_keys, %{}) |> ...
  ... {:ok, %{ok: true, ...}, [{:set, :conversation, final_conv}, {:dispatch, cmd}]}
end
```

AFTER:
```elixir
use Ezagent.Lifecycle
reads_siblings [:api_keys]                         # renamed; same opt-in semantics
required_caps %{receive: cap(:curl_agent, __MODULE__, :receive), ...}  # unchanged

action :receive, args: %{message: :map}, returns: %{ok: :boolean}, caps: [:receive], modes: [:cast]
action :reset_conversation, ...
action :configure, ...

# init_slice/1 → create/1: build the PERSISTENT state once.
def create(args) do
  {:ok, %{provider: Map.get(args, :provider, "deepseek"),
          conversation: [], last_error: nil, last_tokens: nil, ...}}
end

# No transients → activate is a no-op rebuild. (Could be omitted; the
# macro injects `def activate(_state, _ctx), do: {:ok, %{}}` default.)
def activate(_state, _ctx), do: {:ok, %{}}

# handle_<action> BYTE-IDENTICAL except `ctx.read` / `ctx.siblings`.
def handle_receive(%{message: %Message{} = msg}, ctx) do
  current_conv = ctx.read.(:conversation, [])
  api_key = ctx.siblings[:api_keys][:keys][provider]
  {:ok, %{ok: true, ...}, [{:set, :conversation, final_conv}, {:dispatch, cmd}]}
end
```
Load-bearing change: NONE to the effect bodies. The migration is mechanical — `init_slice` → `create`, drop `state_slice`, rename two `ctx` reads.

#### (B) `Ezagent.Behavior.Sandbox` (post_init + handle_continue subprocess rebuild) → `Ezagent.Lifecycle.Sandbox`

This is THE canonical win. Today (sandbox.ex) the subprocess-respawn-on-boot lives in `post_init/2` → `handle_continue/3`, the PTY phase-topic subscription is a transient effect smuggled through `handle_continue/3`, and the destroyed?-gate is a process-dict hack precisely BECAUSE the slice would persist it. After migration, ALL of that collapses into `activate` + `transients`.

BEFORE (sketch — the real module is ~760 lines):
```elixir
use Ezagent.Behavior
def state_slice, do: :sandbox
def init_slice(args), do: %{config_dir_path: ..., template_class: ..., respawn_template_data: ..., pty_phase: ...}
# destroyed? gate is in PROCESS DICT (not slice) so a respawn starts clean — a HACK
@destroyed_pdict_key {__MODULE__, :destroyed?}
def post_init(_args, slice), do: {:continue, {:setup_phase_tracking, tc, rtd}}
def handle_continue({:setup_phase_tracking, tc, rtd}, slice, ctx) do
  subscribe_to_phase_topic(ctx.self_uri)                 # transient subscription
  if should_ensure_subprocess?(tc, rtd), do: do_ensure_subprocess_alive(tc, ctx.self_uri, rtd)  # respawn
  :ignore
end
def handle_kind_message({:pty_phase, uri, phase, meta}, slice, ctx), do: {:ok, Map.put(slice, :pty_phase, phase)}
```

AFTER:
```elixir
use Ezagent.Lifecycle

def create(args) do
  {:ok, %{config_dir_path: Map.get(args, :config_dir_path),
          template_class: Map.get(args, :template_class),
          respawn_template_data: Map.get(args, :respawn_template_data),
          pty_phase: validate_phase(Map.get(args, :pty_phase))}}
end

# activate UNIFIES init_slice + post_init + handle_continue. Runs on
# fresh spawn AND cold-load identically — the bug that #113 fought
# ("fresh starts the subprocess, restart doesn't") is impossible here:
# the respawn is in the ONE start hook.
def activate(state, ctx) do
  # 1. transient: subscribe to the phase topic (was a smuggled
  #    handle_continue side effect; now an explicit transient build).
  ref = subscribe_to_phase_topic(ctx.self_uri)
  # 2. self-heal: (re)spawn the plugin subprocess if state says there
  #    should be one. Orphan-reap of a prior incarnation runs here too
  #    (destroy is best-effort — §OTP).
  if should_ensure_subprocess?(state.template_class, state.respawn_template_data) do
    :ok = ensure_subprocess_alive(state.template_class, ctx.self_uri, state.respawn_template_data)
  end
  {:ok, %{phase_topic_ref: ref}}      # the only transient
end

# destroyed? is no longer a process-dict hack: it is simply ABSENT
# from `state`. A destroyed agent has its state cleared from disk +
# ever-created marker flipped (see destroy/2); a respawn at the same
# URI goes through `create` again (clean) — the model removes the
# need for the gate entirely (see §4 + §7 OQ-1).
def destroy(_reason, ctx) do
  st = ctx.state
  _ = invoke_destroy_config_dir(ctx.self_uri, st.config_dir_path, st.template_class)
  :ok   # framework clears `state` + ever-created marker
end

# phase mirror: handler-free message hook stays (see §7 OQ-3 for the
# handle_kind_message → handle_signal mapping). It writes STATE
# (pty_phase) via {:set, :pty_phase, phase}.
```
Three of today's four boot hooks (`post_init`, `handle_continue`, the process-dict gate) collapse into `activate` + `state`/`transients`. The subprocess respawn is now structurally guaranteed to run on every start.

#### (C) `Ezagent.Behavior.Chat` (rich: members map, monitors, effects) → `Ezagent.Lifecycle.Chat`

The richest case. Note the natural split: `members` / `owner_uri` / `last_seen` / `send_cursor` / `recent_messages` / `template_working_copy` are STATE (must survive restart). `monitors` (the `ref → URI` map from `Process.monitor`) is TRANSIENT — the refs are dead after a restart and today are silently snapshotted-then-rehydrated-as-garbage, a latent bug.

BEFORE (chat.ex): `monitors` lives in the SAME `:chat` slice as `members`, so it gets persisted. On restart the monitor refs are stale; `handle_kind_message({:DOWN, ...})` can never match them; the offline detection silently degrades.

AFTER:
```elixir
use Ezagent.Lifecycle

def create(args) do
  {:ok, %{members: %{}, owner_uri: Map.get(args, :owner_uri),
          last_seen: %{}, last_message_id: nil, last_message: nil,
          send_cursor: 0, recent_messages: [],
          template_working_copy: default_template_working_copy()}}
  # NOTE: `monitors` is GONE from state — it's a transient now.
end

# activate rebuilds the monitor map from the persisted member set:
# Process.monitor each live member, producing a fresh ref→URI map.
# This is the self-heal that today's snapshot-of-dead-refs lacks.
def activate(state, ctx) do
  monitors =
    state.members
    |> Map.keys()
    |> Enum.flat_map(fn uri ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} -> [{Process.monitor(pid), uri}]
        :error -> []
      end
    end)
    |> Map.new()
  {:ok, %{monitors: monitors}}
end

# handle_send / handle_join / handle_leave: BYTE-IDENTICAL effect
# bodies, except reads of `:monitors` go to `ctx.transients[:monitors]`
# and writes to monitors are returned as transient updates (see §7
# OQ-2 for the transient-write-from-handle mechanism) rather than
# {:set, :monitors, _}. `members`/`owner_uri`/etc stay {:set, _, _}.
def handle_join(%{member: %URI{} = member_uri}, ctx) do
  members = ctx.read.(:members, %{})
  monitors = ctx.transients[:monitors]
  ... {:ok, %{members: Map.keys(new_members)},
       [{:set, :members, new_members},
        {:set, :last_seen, new_last_seen},
        {:set, :owner_uri, new_owner_uri},
        {:set_transient, :monitors, new_monitors}]    # transient write — §7 OQ-2
       ++ broadcast_membership_effects(session_uri, {:member_joined, member_uri})}
end
```
Migration benefit beyond mechanics: it FIXES the latent stale-monitor-ref bug by forcing `monitors` into `transients`, where `activate` rebuilds it live every start.

---

## §3 — How it maps to / compiles down to R/B/K internals

### The problem this section solves

The engine (`Ezagent.Behavior`, `Ezagent.Kind.Server`, `Ezagent.Kind.Runtime`, `SnapshotStore`, `Router`, `Invocation`) is mature, CI-gated, and correct. We do not rewrite it. The Lifecycle macro must EMIT the existing `@behaviour Ezagent.Behavior` implementation underneath, so the engine sees exactly the shape it sees today.

### What the `use Ezagent.Lifecycle` macro emits

The macro is a thin code generator over `use Ezagent.Behavior`. It injects a `state_slice/0` (auto-derived from the module name, e.g. `Ezagent.Lifecycle.Chat` → `:chat`), wires `create`/`activate` into the existing boot path, and translates the two-container return shapes into the slice shape the engine already commits.

### Old → new mapping table

| Engine concept (today, internal) | Old developer hook | New Lifecycle hook | Mechanism |
|---|---|---|---|
| slice (`state[state_slice()]`) | the `slice` map, mixed persistent+transient | `state` (persistent) + `transients` (volatile) | macro stores them under TWO sub-keys of the slice; only the `state` sub-key is handed to `SnapshotStore` |
| `state_slice/0` | author-declared atom | auto-derived from module name | macro injects `def state_slice` |
| `init_slice/1` | fresh construction | `create/1` (persistent) + `activate/2` (transients) | macro: `init_slice(args)` = `create(args)` on first-ever, then merged with `activate/2`'s transient build |
| `Snapshot.load_or_init/3` merge | invisible to author | invisible to author | unchanged; macro feeds ONLY the `state` sub-key into the merge; `transients` always starts empty and is filled by `activate` |
| `post_init/2` | deferred boot work | folded into `activate/2` | macro emits a `post_init/2` returning `{:continue, :ezagent_activate}` |
| `handle_continue/3` | deferred boot work (slice-affecting) | folded into `activate/2` | macro emits `handle_continue(:ezagent_activate, slice, ctx)` that calls the author's `activate/2`, writes transients into the transient sub-key + reconciled state into the state sub-key |
| `on_ready/2` | post-`:ready` broadcast | folded into `activate/2` (default) OR explicit (§7 OQ-5) | most `on_ready` uses are "I'm reachable" broadcasts; `activate` runs before `:ready` so a broadcast that invites a `:call` round-trip needs the post-ready timing — see §7 OQ-5 |
| `reconcile_after_load/2` | DB-projection reconcile after merge | folded into `activate/2` via the 3-arity `{:ok, transients, state}` return | author re-reads the DB SoT inside `activate` and returns the reconciled `state`; macro routes it through the same post-merge commit |
| `handle_<action>/2` | the handler | `handle_<action>/2` | UNCHANGED — same name, same arity, same return |
| `invoke/4` | retired `@optional_callback` | n/a | macro never emits it; gone from developer surface |
| `Invocation` / `Cmd` | dispatch envelope | n/a (developer emits `{:dispatch, %Cmd{}}` effects only) | unchanged engine; author never constructs an `Invocation` |
| snapshot commit | automatic on slice change | automatic on `state` change | unchanged; `commit_and_notify/3` only ever sees the `state` sub-key diff, so a `transients` change NEVER triggers a snapshot write |
| `terminate/3` (per-Behavior) | graceful cleanup | `deactivate/2` | macro emits `terminate(reason, slice, ctx)` → `deactivate(reason, ctx)` |
| (no hook today; explicit-delete) | scattered `:destroy` actions + process-dict gates | `destroy/2` | macro wires `destroy` to the existing termination path + clears the `state` sub-key + flips the ever-created marker |
| `reads_sibling_slices/0` | sibling opt-in | `reads_siblings/0` | rename; same injection (`ctx.siblings`) |
| `required_caps/0` / `data_owner/1` / `cap_subjects/0` | declared on Behavior | declared on Lifecycle module | macro passes through; `data_owner` may move to the `action :name, data_owner:` form (already supported, behavior.ex L624) |

### The `create` vs `activate` split needs a persisted marker

`create/1` runs ONCE ever; `activate/2` runs every start. The engine today has no "ever-created" bit — `init_slice/1` runs on every cold-load. The macro therefore needs a persisted boolean (e.g. a reserved `state` key `:__created__` or a dedicated column on `kind_snapshots`) so the boot path can decide "first-ever → run `create` then `activate`" vs "cold-load → run `activate` only against the rehydrated state." This is flagged as **§7 OQ-1** (the one design decision needing Allen's call: reserved-state-key vs dedicated-column vs presence-of-snapshot-row as the marker).

---

## §4 — Bug-fix-by-construction

### The problem this section solves

The cold-restart bug class must become impossible to write, not merely fixed case by case. Below, each historical bug becomes a trivial `activate` rebuild, and the two-container model is what makes forgetting structurally impossible.

### Why the two-container model makes forgetting impossible

1. A transient resource (ETS handle / PID / subprocess) has NOWHERE to live except `transients`. `transients` is dropped on every stop and built ONLY in `activate`. So the resource is necessarily (re)built on every start — there is no "I built it in `create` and forgot it doesn't re-run" path, because `create` returns only `state`, and `state` cannot hold a live handle that survives serialization.
2. Conversely, persistent data has nowhere to live except `state`, which IS auto-persisted. The author cannot "forget to snapshot" because they never snapshot at all.
3. There is exactly ONE start hook (`activate`), so there is no "wrote the rebuild in `post_init` but cold-load uses `reconcile_after_load`" mismatch — the four-hook confusion that caused this class is gone.

### #110 — orchestrator MCP ETS row (PR #474 is the conceptual precedent)

Today: `Ezagent.Orchestrator.McpRegistry` is an ETS table rebuilt EMPTY on phx restart; the orchestrator's 7 MCP tools went dead until a fresh re-spawn. PR #474 fixed it with a read-through cache that lazily rebuilds the context from the Session's durable `kind_snapshots` row.

Under Lifecycle: the McpRegistry row IS a transient (an ETS entry keyed by orchestrator URI). It belongs in `transients`, rebuilt in the Session/orchestrator's `activate` from the durable `state` (which already holds `session_template_uri`, `owner_uri`, `default_workspace_uri` on the `template_working_copy`). PR #474's lazy-rebuild-from-snapshot is exactly the conceptual shape `activate` formalizes — except `activate` runs it eagerly and unconditionally on every start, so there is no first-miss latency and no "bridge connected before the Session cold-spawned" race.
```elixir
def activate(state, ctx) do
  if orchestrator?(state) do
    Ezagent.Orchestrator.McpRegistry.register(ctx.self_uri,
      session_uri: ctx.self_uri,
      workspace_uri: state.template_working_copy.default_workspace_uri,
      owner_uri: state.owner_uri,
      parent_template_uri: state.template_working_copy.session_template_uri)
  end
  {:ok, %{}}
end
```

### #113 — codex bridge subprocess (current branch: `fix/codex-bridge-cold-respawn-113`)

Today: `EzagentPluginCodex.BridgeSidecar` is a `Port`-backed subprocess (a GenServer under a `DynamicSupervisor`) that dies with the BEAM and is NOT re-spawned on cold-load unless the boot hook happens to run. The fix lives partly in `Sandbox.post_init/2` → `ensure_subprocess_alive/2` — the exact "wrong hook on cold-load" hazard.

Under Lifecycle: the bridge subprocess handle is a TRANSIENT. The codex agent's `activate` (re)spawns it every start and orphan-reaps any prior incarnation (best-effort `destroy` may have been skipped on a brutal kill — §OTP). Because `activate` is the ONLY start hook and runs on fresh + cold-load identically, "fresh works, restart doesn't" cannot occur.
```elixir
def activate(state, ctx) do
  _ = EzagentPluginCodex.OrphanReaper.reap(ctx.self_uri)        # self-heal prior incarnation
  {:ok, bridge_pid} = EzagentPluginCodex.BridgeSidecar.ensure(ctx.self_uri, state.bridge_params)
  {:ok, %{bridge: bridge_pid}}
end
```

### #114 — AgentLineage ETS

Today: `:ezagent_agent_lineage` is an ETS table (`agent_uri → spawned_by_uri`) owned by `EtsOwner`, created empty at boot and populated by `Agent.spawn/4`. Its moduledoc explicitly says lineage is "set once at spawn, never changes" and is "not per-Agent state worth snapshotting" — but that is the bug: on phx restart the table is empty, so `{:spawned_by, P}` cap matching silently returns `false` until each agent is re-spawned, which never happens for already-running agents.

Under Lifecycle: `spawned_by` is durable per-agent fact → it belongs in the Agent's `state` (auto-persisted). The ETS *index* (for fast `spawned_in_lineage?` walks) is a TRANSIENT, rebuilt in the Agent's `activate` from `state.spawned_by`. So the index is always populated on start, and the durable fact is never lost.
```elixir
def create(args), do: {:ok, %{spawned_by: Map.get(args, :spawned_by), ...}}
def activate(state, ctx) do
  if state.spawned_by, do: Ezagent.AgentLineage.record(ctx.self_uri, state.spawned_by)  # rebuild index
  {:ok, %{}}
end
```

In all three: the developer writes one obvious line in `activate`; the framework's container split is what makes omitting it structurally impossible, because the resource has no other home.

---

## §5 — Migration plan (big-bang)

### The problem this section solves

~25 developer-facing Behavior modules must convert at once, with parity, executable by multiple parallel subagents, with grep-able acceptance gates that prove the old surface is gone.

### Inventory (grep `use Ezagent.Behavior` across `apps/*/lib`, `b5acb1f8`)

26 hits total; 3 are ENGINE/TOOLING (not developer Behaviors — they do NOT migrate to Lifecycle):
- `apps/ezagent_core/lib/ezagent/behavior.ex` — the engine macro itself
- `apps/ezagent_core/lib/ezagent/kind/runtime.ex` — the executor
- `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` — the compile check

The **23 developer Behaviors to migrate**:

| # | Module | App | Tier |
|---|---|---|---|
| 1 | `Ezagent.Behavior.Lifecycle` | ezagent_core | core (note: existing module name clashes with the new macro namespace — see §7 OQ-6) |
| 2 | `Ezagent.Behavior.Notifications` | ezagent_core | core |
| 3 | `Ezagent.Behavior.Presence` | ezagent_core | core |
| 4 | `Ezagent.Behavior.Routing` | ezagent_core | core |
| 5 | `Ezagent.Behavior.Sandbox` | ezagent_core | core (rep. example B — transients) |
| 6 | `Ezagent.Behavior.Chat` | ezagent_domain_chat | domain (rep. example C — rich) |
| 7 | `Ezagent.Behavior.OrchestratorAdmin` | ezagent_domain_chat | domain |
| 8 | `Ezagent.Behavior.Publisher.SessionImpl` | ezagent_domain_chat | domain |
| 9 | `Ezagent.Behavior.Template` (chat) | ezagent_domain_chat | domain |
| 10 | `Ezagent.Behavior.ExternalMirrorWorker` | ezagent_domain_external_mirror | domain (transients: transport handles) |
| 11 | `Ezagent.Behavior.ExternalMirror` | ezagent_domain_external_mirror | domain (DB-projection → reconcile-in-activate) |
| 12 | `Ezagent.Behavior.ApiKeys` | ezagent_domain_identity | domain |
| 13 | `Ezagent.Behavior.Identity` | ezagent_domain_identity | domain |
| 14 | `Ezagent.Behavior.UserCredentials` | ezagent_domain_identity | domain |
| 15 | `Ezagent.Behavior.UserTokens` | ezagent_domain_identity | domain |
| 16 | `Ezagent.Behavior.WorkspaceUserAdmin` | ezagent_domain_identity | domain |
| 17 | `Ezagent.Behavior.Pty` | ezagent_domain_pty | domain (transients: PTY port) |
| 18 | `Ezagent.Behavior.Workspace` | ezagent_domain_workspace | domain (`:external` persistence → state-from-SoT in activate) |
| 19 | `Ezagent.Behavior.CurlAgent` | ezagent_plugin_curl_agent | plugin (rep. example A — simple) |
| 20 | `Ezagent.Behavior.Echo` | ezagent_plugin_echo | plugin |
| 21 | `Ezagent.PluginFeishu.Behavior.FeishuAllow` | ezagent_plugin_feishu | plugin |
| 22 | `Ezagent.PluginFeishu.Behavior.UserBinding` | ezagent_plugin_feishu | plugin |
| 23 | `Ezagent.Behavior.NpAgent` | ezagent_plugin_np | plugin |

Verified completeness: the bare `@behaviour Ezagent.Behavior` (engine behaviour) appears ONLY on `curl_agent.ex`, `echo.ex`, `np_agent.ex` — all three already in the list above (they also `use Ezagent.Behavior`). Other `@behaviour Ezagent.Behavior.*` hits are `Ezagent.Behavior.Publisher` (a SEPARATE plugin-extension CONTRACT defined in `external_mirror/.../behavior/publisher.ex`, implemented by `chat/.../entity/session.ex` — these are Kinds/contracts, NOT engine Behaviors, and do NOT migrate to Lifecycle). **Pre-migration task 0: re-run both greps on the actual migration HEAD to confirm no new Behavior was added since `b5acb1f8` (`feedback_enumerate_all_gates_before_deletion`); the `Publisher` extension-contract pattern itself (a Behavior author defining a downstream contract) needs a Lifecycle-equivalent story — flag as a sub-question of OQ-7 if any such contract is found in the developer tier.**

### Conversion recipe (per module — the deterministic checklist a subagent follows)

1. `use Ezagent.Behavior` → `use Ezagent.Lifecycle`. Drop `@behaviour Ezagent.Behavior` if present.
2. Delete `def state_slice` (macro auto-derives) UNLESS the slice key must stay stable for snapshot compatibility — in which case keep an explicit override (§7 OQ-7).
3. `init_slice/1` → `create/1`: keep only the PERSISTENT fields; move every PID/ref/ETS/port/subprocess/monitor field OUT.
4. Move the fields removed in step 3 into `activate/2`'s returned transients map; write the rebuild logic (the line that re-opens the handle / re-spawns / re-`Process.monitor`s).
5. Fold `post_init/2` + `handle_continue/3` boot logic into `activate/2`. Fold `reconcile_after_load/2` into `activate/2`'s 3-arity return. Decide `on_ready/2` per §7 OQ-5.
6. `terminate/3` → `deactivate/2`. Scattered `:destroy` actions / process-dict gates → `destroy/2` + rely on the ever-created marker (delete the gate).
7. `handle_<action>/2`: rename `ctx[:read]` → `ctx.read`, `ctx[:sibling_slices]` → `ctx.siblings`; transient reads → `ctx.transients[k]`; transient writes → `{:set_transient, k, v}` (§7 OQ-2). Effect bodies otherwise UNCHANGED.
8. `reads_sibling_slices/0` → `reads_siblings/0`. `required_caps/0` / `data_owner/1` pass through unchanged.
9. Run the module's existing test file — MUST pass unchanged (parity gate, §6).
10. Add the cold-restart invariant test (§6) for any module that gained a non-empty `transients`.

### Order + parallelism

- **Phase A (engine, sequential, 1 PR):** implement `Ezagent.Lifecycle` macro + the ever-created marker + the `{:set_transient, ...}` effect (§7 OQ-2) + the transient sub-key split in `Kind.Server`/`SnapshotStore`. No Behavior migrates yet. Gate: the macro can emit a working `@behaviour Ezagent.Behavior` for a trivial fixture; full engine test suite green.
- **Phase B (parallel, by app):** convert the 23 modules in parallel subagent batches grouped by app so there are no shared-file conflicts (identity batch, chat batch, external_mirror batch, plugin batch, core batch). Each subagent: loads `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (`feedback_subagent_must_load_project_skills`), passed `model: opus` (`feedback_subagent_model_parity`), converts its batch, runs that app's tests for parity. Representative examples A/B/C land first as reference conversions the other subagents copy the shape from.
- **Phase C (sequential, 1 PR):** flip the grep gates to HARD-fail; delete any now-dead engine carve-outs that only existed for the old surface; update `references/new-contract.md` → `references/lifecycle.md`, GLOSSARY, ARCHITECTURE.md §6.0, Decision Log.

### Removing the old public surface + acceptance gates (grep-gates)

Add to `mix ezagent.check_invariants` (and/or the plugin compile check), failing CI if ANY developer-tier file (`apps/ezagent_domain_*` / `apps/ezagent_plugin_*` / developer modules in `ezagent_core`) matches:

- `use Ezagent.Behavior` (must be `use Ezagent.Lifecycle`) — engine files exempted by an allowlist of the 3 engine modules.
- `def state_slice` (developer no longer declares it) — except sanctioned snapshot-compat overrides (§7 OQ-7), which must carry a `# lifecycle:state_slice_override` marker comment.
- `def init_slice` (replaced by `create`).
- `def invoke(` (the retired callback — must not reappear).
- `def post_init` / `def handle_continue` / `def on_ready` / `def reconcile_after_load` in developer modules (folded into `activate`).
- `ctx[:read]` / `ctx[:sibling_slices]` (renamed) and any direct `slice` parameter in a developer handler.
- `Ezagent.Invocation.dispatch(` / `Ezagent.SnapshotStore.` / `Ezagent.EventLog.append(` / `Ezagent.Router` internals / `Phoenix.PubSub.broadcast(` inside a developer handler (these were already SPEC §11 gates; keep them, re-pointed at Lifecycle modules).

---

## §6 — Testing strategy

### The problem this section solves

Big-bang migration must not change behavior, and the whole point — transients rebuild on every start — needs a reusable, gate-able invariant test, not a once-off check (`feedback_completion_requires_invariant_test`).

### Parity (every converted module)

Each module's EXISTING test file MUST pass unchanged. Where a test reached into `slice` internals or called the old hooks directly, the test is updated MECHANICALLY (same assertions, new accessor) and the change is reviewed to confirm no assertion weakened. Handlers are still pure `(args, ctx)` functions, directly callable in ExUnit (the engine's testing pattern is preserved).

### The reusable cold-restart invariant test pattern (the gate)

A shared helper `Ezagent.LifecycleCase` provides `assert_transients_rebuilt/2`:

1. Spawn the Kind fresh; drive it to a non-trivial state (join members / open subprocess / register lineage).
2. Capture `state` + `transients`. Assert `transients` is non-empty (the resource exists).
3. Force a cold restart: terminate the host process WITHOUT a graceful `deactivate` (simulate brutal kill — `Process.exit(pid, :kill)`), so ONLY the durable `state` survives and `destroy`/`deactivate` are skipped (§OTP best-effort).
4. Demand-spawn the same URI (cold-load path).
5. Assert: `state` rehydrated correctly AND `transients` rebuilt to a LIVE equivalent (new PIDs/refs, but functionally present — the ETS row exists, the subprocess is alive, the monitors are installed). Assert NO stale reference from the prior incarnation survived (no dead PID in `transients`).

This is the architectural-goal gate: it FAILS if a module persisted a transient or failed to rebuild one — i.e. it fails exactly when the cold-restart bug class reappears.

### The four historical cases become standard restart tests

- **session-members-survive-restart**: Chat — members in `state` survive; `monitors` in `transients` rebuilt live (catches the latent stale-monitor bug §2.3C).
- **orchestrator-MCP**: McpRegistry transient rebuilt in `activate` (catches #110).
- **codex-bridge**: bridge subprocess transient re-spawned + prior orphan reaped (catches #113).
- **AgentLineage**: lineage index transient rebuilt from `state.spawned_by` (catches #114).

Each lives next to its module and uses `assert_transients_rebuilt/2`. Per `feedback_e2e_failure_earns_unit_test`, any e2e restart failure during migration earns one of these fast regression tests before the fix lands.

---

## §7 — Risks + open questions

Lead with the problem; flag the items needing Allen's / owner's decision.

- **OQ-1 (NEEDS DECISION) — the `create` vs `activate` ever-created marker.** `create` must run exactly once; `activate` every start. The engine has no such bit today (`init_slice` runs on every cold-load). Options: (a) reserved `state` key `:__created__`; (b) dedicated `kind_snapshots` column; (c) "snapshot row exists" = already-created. (c) is cheapest but conflates "has state" with "was created" (a `create` that returns empty state would loop). Recommendation: (b) dedicated column — explicit, survives a legitimately-empty initial state. **Allen's call.**

- **OQ-2 (NEEDS DECISION) — how a `handle_<action>` writes a transient.** Handlers return effects; today every `{:set, k, v}` writes the (persistent) slice. A transient write (e.g. Chat installing a new monitor in `handle_join`) needs a distinct effect, proposed `{:set_transient, key, value}`, applied to the transient sub-key and NEVER snapshotted. Alternative: forbid transient writes from handlers entirely and require all transient mutation to go through `activate` + a `handle_signal` (the `handle_kind_message` successor) — cleaner but forces some handlers to round-trip. Recommendation: add `{:set_transient, ...}`; it is the minimal, honest extension. **Allen's call** (it touches the effect grammar, which is otherwise frozen per §0.4).

- **OQ-3 — `handle_kind_message/3` (non-action GenServer messages: `:DOWN`, PubSub deliveries).** These are not actions but they mutate state/transients (Chat's `:DOWN` offline flip; Sandbox's `:pty_phase`). Proposed mapping: a `handle_signal(message, ctx)` Lifecycle hook returning the same effect list as `handle_*` (so `:DOWN` returns `{:set_transient, :monitors, ...}` + `{:set, :last_seen, ...}`). This keeps signals in the effect grammar. Low risk; recommend adopting. Confirm naming.

- **OQ-4 — `deactivate` / idle-eviction semantics.** The brief lists `deactivate` = "graceful stop, entity persists." Today only Session (`:ephemeral`) terminates on task-end; there is no idle-eviction mechanism. `deactivate` maps cleanly onto the existing per-Behavior `terminate/3` for the graceful-stop case. Idle-eviction (evict a cold entity from memory, keep state on disk, re-`activate` on next dispatch) is NOT present today and is OUT OF SCOPE here (NG4) — but the Lifecycle shape is forward-compatible with it (eviction = `deactivate` without `destroy`; next dispatch = `activate` from snapshot). Flag: confirm we are NOT building idle-eviction now.

- **OQ-5 — `on_ready` timing vs `activate`.** `activate` (= `init/1` + `handle_continue` boot work) runs BEFORE the `ReadyGate` flips. A few Behaviors (Publisher.SessionImpl) MUST broadcast "I'm reachable" AFTER `:ready` so subscribers' `:call` round-trips don't hit `{:error, :not_ready}`. If we fold `on_ready` into `activate`, those broadcasts fire too early. Options: (a) keep a thin optional `activated/2` hook that runs post-`:ready` (rename of `on_ready`, still Lifecycle-surface); (b) detect "broadcast effects from `activate`" and defer them to post-ready automatically. Recommendation: (a) — explicit `activated/2`, documented as "rare, only for reachability broadcasts." Not strictly an Allen decision but worth a nod.

- **OQ-6 (NEEDS DECISION) — name clash: existing `Ezagent.Behavior.Lifecycle` module vs the new `Ezagent.Lifecycle` macro namespace.** There is already a core Behavior literally named `Ezagent.Behavior.Lifecycle` (admin terminate). The new macro is `Ezagent.Lifecycle`. Migrated, it would want to be `Ezagent.Lifecycle.Lifecycle` (awkward) or be renamed (e.g. `Ezagent.Lifecycle.AdminControl`). Recommendation: rename the existing Behavior on migration. **Allen's call on the macro name AND the rename** (this is the one naming collision in the whole set).

- **OQ-7 — Kinds compose MULTIPLE Behaviors; how do they map to Lifecycle modules?** A Kind today lists several Behaviors via `behaviors/0` / `attach` (e.g. `Ezagent.Entity.Agent` attaches Chat + Sandbox + ApiKeys + ...). Each Behavior owns one slice key. The clean mapping is **one Lifecycle module per current Behavior** (preserve the per-key isolation, the slice-key stays the snapshot-compat key — hence the `state_slice` override allowlist in §5). A Kind then composes several Lifecycle modules, and the host GenServer holds N `state` sub-maps + N `transients` sub-maps. This preserves `feedback_north_star_plugin_isolation` (one author per Lifecycle module, no coordination). Do NOT collapse a multi-Behavior Kind into one mega-Lifecycle. Confirm this 1:1 mapping is the intended shape.

- **OQ-8 — DB-projection Behaviors (`ExternalMirror`, `Workspace` `:external`, `Identity` caps).** Their slice is a CACHE of a DB SoT, today reconciled via `reconcile_after_load/2` after the snapshot merge. Under Lifecycle the reconcile moves into `activate` (re-read SoT, return reconciled `state`). Risk: `activate` now does DB I/O on every start — acceptable (it already did via `reconcile_after_load`) but must stay idempotent (set-union by key, the existing invariant 20 rule). Low risk; documented, not a blocker.

- **R-1 — big-bang blast radius.** 23 modules at once is the riskiest part. Mitigation: Phase A ships the engine + macro with the OLD surface still working (the macro EMITS the old surface), so Phase B conversions are independently revertible per module, and the parity-test gate (§6) catches regressions per module before the Phase C hard-flip deletes the old surface.

- **R-2 — snapshot compatibility.** Existing `kind_snapshots` rows hold the OLD merged slice (persistent + transient mixed). On first cold-load post-migration, the macro must (a) read the old merged map, (b) keep the persistent keys as `state`, (c) DROP the transient keys (they will be rebuilt by `activate`). This is a one-time read-side migration in the macro's load path. Per the ezagent "DB data is wiped + rebuilt on URI/structural migrations" convention this could alternatively be a clean wipe — confirm whether a wipe is acceptable (simpler) or a read-side coercion is required (safer for live data).

---

## §8 — Acceptance criteria

Concrete, gate-able. The phase is DONE when ALL hold.

- **AC-1 (sole API).** Grep gate: zero `use Ezagent.Behavior` in developer-tier files (allowlist: the 3 engine modules). Zero developer-facing `def init_slice` / `def invoke(` / `def post_init` / `def handle_continue` / `def on_ready` / `def reconcile_after_load` / `def state_slice` (except marked snapshot-compat overrides). Zero `ctx[:read]` / `ctx[:sibling_slices]` / direct `slice` params / `Ezagent.Invocation.dispatch(` / `Ezagent.SnapshotStore.` references in developer handlers. CI fails on any hit.
- **AC-2 (inventory complete).** All 23 modules in §5 compile under `use Ezagent.Lifecycle`; the reconciled grep (task 0) shows no un-migrated developer Behavior remains.
- **AC-3 (parity).** The full pre-migration test suite passes with no assertion weakened; the 30 documented scenarios in `docs/scenarios/` remain green.
- **AC-4 (the architectural-goal gate).** `Ezagent.LifecycleCase.assert_transients_rebuilt/2` exists and is used by ≥1 test per module that has non-empty transients. The four named restart tests (session-members, orchestrator-MCP, codex-bridge, AgentLineage) pass, and each FAILS if its transient is moved into `state` or its `activate` rebuild is deleted (verified by a deliberately-broken mutation in review).
- **AC-5 (no shims).** No back-compat developer surface remains after Phase C; the engine carve-outs that existed only for the old surface are deleted; `references/`, GLOSSARY, ARCHITECTURE.md §6.0, Decision Log updated.
- **AC-6 (engine untouched at the wire).** `%Ezagent.Cmd{}`, Router dispatch, CapBAC, URI SPEC, and the effect-execution order are byte-unchanged except for the additive `{:set_transient, ...}` effect (if OQ-2 adopted) and the ever-created marker (OQ-1). Confirmed by diffing the engine modules' public surfaces.
- **AC-7 (the 8 OQs resolved).** OQ-1, OQ-2, OQ-6 (the three needing Allen) have recorded decisions; OQ-3/4/5/7/8 have documented resolutions in the implementation plan before Phase A starts.

---

## OTP correctness invariants baked into this SPEC (normative)

- `activate` = OTP `init/1`: runs on every start including supervisor/phx restart. There is NO separate "restart" hook. Merging fresh-start and cold-load into one hook is what makes the "fresh works, restart doesn't" (#110/#113/#114) class structurally impossible.
- `destroy` ≈ OTP `terminate/2`: BEST-EFFORT. Not called on SIGKILL / VM-crash / brutal-kill / `Process.exit(pid, :kill)`. Therefore cleanup MUST NOT rely solely on `destroy`; `activate` MUST self-heal (orphan-reap prior-incarnation resources). Same for `deactivate`.
- OTP provides NO cross-restart state persistence. The framework's transparent persistence of `state` (and ONLY `state`) is the value-add layer over OTP — and the deliberate NON-persistence of `transients` is what forces correct rebuild.

---

## §9 — Decision log (resolved 2026-05-29, Allen-delegated)

Allen delegated SPEC finalization ("不用等我回来审spec；和codex配合review+实施"). Decisions on the §7 open questions, to be carried into the implementation plan:

- **OQ-1 (ever-created marker) → DECIDED: dedicated `kind_snapshots` column.** Option (c) "snapshot-row-exists" is rejected — a `create` that legitimately returns empty state, or a crash between `create`'s state-write and the first snapshot, would wrongly re-run `create`. An explicit `created_at`/`ever_created` column on `kind_snapshots` is unambiguous and survives an empty initial state. Phase A adds the column + migration.
- **OQ-2 (handler transient writes) → DECIDED: add `{:set_transient, key, value}` to the effect grammar.** Minimal, honest extension; applied to the transient sub-key, NEVER snapshotted. The effect grammar is otherwise frozen (§0.4); this is the one additive change, mirrored by the engine's existing `{:set, ...}` executor. (See R-note below on atomicity — for codex.)
- **OQ-3 (non-action messages: `:DOWN`, PubSub) → DECIDED: `handle_signal(message, ctx)` Lifecycle hook** returning the same effect list as `handle_*` (so a `:DOWN` returns `{:set_transient, :monitors, ...}` + `{:set, :last_seen, ...}`). Successor to `handle_kind_message/3`.
- **OQ-4 (idle-eviction) → DECIDED: OUT OF SCOPE.** Not building idle-eviction now (NG4). The Lifecycle shape is forward-compatible (eviction = `deactivate` without `destroy`; next dispatch = `activate` from snapshot) but no eviction mechanism ships in this migration.
- **OQ-5 (post-ready broadcasts) → DECIDED: thin optional `activated/2` hook** that runs AFTER the `ReadyGate` flip (rename of the engine's existing `on_ready/2`), documented as "rare — only for reachability broadcasts" (Publisher.SessionImpl). This PRESERVES the existing boot-order invariant: `activate` compiles down to the engine's `post_init`+`handle_continue` (pre-`:ready`); `activated/2` compiles to `on_ready/2` (post-`:ready`). The macro is a compile-time facade over the UNCHANGED engine sequence — the `:not_ready` buffering contract is enforced by the engine, not the macro, so it cannot regress.
- **OQ-6 (name clash) → DECIDED: macro is `Ezagent.Lifecycle`; rename the existing `Ezagent.Behavior.Lifecycle` (admin-terminate) → `Ezagent.Lifecycle.AdminControl`** on its migration. (Allen confirmed the two-tier lifecycle concept + macro direction; this is the one naming collision.)
- **OQ-7 (multi-Behavior Kinds) → DECIDED: 1:1 — one Lifecycle module per current Behavior.** Preserve per-slice-key isolation (snapshot-compat); a Kind composes N Lifecycle modules; the host holds N `state` sub-maps + N `transients` sub-maps. Do NOT collapse into a mega-module (preserves plugin-isolation north star). The `Ezagent.Behavior.Publisher` extension-CONTRACT pattern stays a contract (not migrated to Lifecycle).
- **OQ-8 (DB-projection Behaviors) → DECIDED: reconcile-in-`activate`** (re-read SoT, return reconciled `state`), idempotent set-union by key (existing invariant 20). `activate` doing DB I/O on every start is acceptable (it already did via `reconcile_after_load`).
- **R-2 (snapshot compatibility) → DECIDED: WIPE.** Allen confirmed (2026-05-29) the current "production" is a TEST environment that can be cleared + rebuilt. On the migration cutover: clean-stop phx → deploy → WIPE `kind_snapshots` (+ dependent rebuildable rows) → restart, letting `create`/`activate` rebuild from the durable SoT (DB projections, templates, configs). No read-side old-merged-slice coercion needed — simpler + cleaner. (The new two-container snapshot format is written fresh.)

Acceptance §8 AC-7 ("the 8 OQs resolved") is hereby satisfied at the SPEC level; codex adversarial review is the final design gate before Phase A.

---

## §10 — Codex adversarial review resolutions (2026-05-29)

Codex review verdict: **NEEDS-REWORK → resolved here.** Codex CONFIRMED the core architecture is viable and that the real engine enforces `activate` pre-`:ready` + `activated`/`on_ready` post-`:ready` (the load-bearing §9 OQ-5 claim holds). Four refinements, all incorporated as BINDING rules for the implementation plan:

- **R10-1 (was CRIT — post-ready self-deferred work).** The §5 recipe step "fold `post_init` + `handle_continue` into `activate`" is INSUFFICIENT for Behaviors whose `handle_continue/3` SELF-DEFERS work past `:ready` via `send(self(), ...)` (canonical: `ExternalMirror.handle_continue/3` → `{:ezagent_em_reconcile, ...}` mailbox message → worker spawn, which MUST run after the Session is `:ready` or the workers' `subscribe_from` `:call` hits `{:error, :not_ready}`). **BINDING RULE:** such self-deferred work does NOT go in `activate` (which is pre-`:ready`). It maps to EITHER `activated/2` (post-`:ready` hook) OR the `activate → send(self(), msg) → handle_signal(msg, ctx)` pattern (handle_signal runs after the mailbox drains, i.e. post-`:ready`). The conversion recipe (§5 step 5) MUST classify each old `handle_continue` as "pre-ready boot" (→ `activate`) vs "self-deferred post-ready" (→ `activated`/`handle_signal`). **Add an acceptance grep-gate:** any developer `handle_continue` that contains `send(self(), ` must, post-migration, have its deferred body in `activated`/`handle_signal`, not `activate`.

- **R10-2 (was MED — transient/state commit atomicity).** `{:set_transient,...}` and `{:set,...}` in one handler return are SAFE only as PURE PRE-COMMIT MAP REDUCTIONS. **BINDING RULE:** the engine reduces BOTH the `state` effects AND the `transient` effects into their respective new maps BEFORE `Snapshot.commit/4`; `state` is snapshotted, `transients` are NEVER snapshotted; if `commit` fails, NEITHER container advances (the Kind keeps its prior state+transients and the dispatch errors). No window where state is snapshotted but the transient apply is lost — because both are computed before, and only `state` is persisted. The `{:set_transient,...}` executor lives next to `{:set,...}` in `runtime.ex` apply order, applied to the `:transients` sub-map.

- **R10-3 (was HIGH — Phase C must not delete the engine contract).** `Ezagent.Behavior` STAYS as the internal engine contract — it is the macro's COMPILE TARGET (`use Ezagent.Lifecycle` emits `@behaviour Ezagent.Behavior` + the callbacks underneath) and `Kind.Runtime`/`Kind.Server` dispatch through it. **BINDING RULE:** Phase C deletes ONLY (a) developer-TIER `use Ezagent.Behavior` usage + the now-folded developer callbacks (`init_slice`/`post_init`/`handle_continue`/`on_ready`/`reconcile_after_load`/`state_slice`/`invoke`), and (b) carve-outs that are PROVABLY dead after all 23 modules convert. It MUST NOT delete the `Ezagent.Behavior` engine module, its callback definitions, or `Kind.Runtime`'s use of them. The §8 AC-1 grep-gates already scope to developer-tier files (engine allowlist) — keep that scoping; AC-5 "no shims" means no developer-facing back-compat, NOT removal of the engine contract.

- **R10-4 (was MED — wipe must be a verified ordered cutover).** The R-2 snapshot WIPE is safe ONLY if no old `kind_snapshots.state_binary` row survives into a node that runs the new two-container loader. **BINDING RULE:** the cutover is a VERIFIED ordered sequence, not best-effort: (1) clean-stop ALL phx/BEAM nodes (confirm none listening), (2) deploy the new code, (3) DELETE the `kind_snapshots` rows (+ any dependent rebuildable projection rows) and CONFIRM the table is empty, (4) start phx — `create`/`activate` rebuild from the durable SoT (DB projections / templates / configs). Never start a new-code node against a DB still holding old merged-slice rows.

These four are inputs to writing-plans (they shape Phase A's macro + engine work and Phase C's gate definitions). With them incorporated, the SPEC is implementation-ready.
