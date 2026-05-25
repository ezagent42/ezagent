# SPEC — Agent duplicate/clone primitive (Behavior.Agent `:duplicate`)

**Status:** DRAFT rev 1 · 2026-05-25
**Tier:** `apps/ezagent_domain_chat/` (new `Behavior.Agent` + action) + `apps/ezagent_core/` (slot in BehaviorRegistry) + `apps/ezagent_domain_workspace/` (mix task wrapper)
**Trigger:** Allen 2026-05-24 (memory `feedback_agent_clone_not_via_template`) — "agent 创建的 template 如果不走正常的 template 创建和 fork 流程，可能导致开发 drift，但如果走标准流程，又可能导致 Template Registry 里面大量临时创建后再也不用的 template". Clone must live as a domain.agent primitive, NEVER via Template Registry.
**Predecessors:**
- `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md` — `Behavior.Workspace.:create_agent` is the reused spawn facade
- PR #289 (`2c66903`) — per-agent config_dir + Kind.Template extension callbacks
- PR #288 — `Ezagent.Behavior.Sandbox` (the slice that holds `config_dir_path` + `template_class`)
- PR #330 (`8277d08`) — `Ezagent.Workspace.create_agent/3` facade (CLI/LV parity)
- `feedback_let_it_crash_no_workarounds` — no `:warning + degrade`, no shims
- `feedback_uuid_is_canonical_identifier` — agent URIs canonical; username display-only
- `feedback_fork_is_generic_template_concern` — distinguishes Template-level fork (already done in PR1 #287 as `Behavior.Template.:fork`) from this Agent-level clone
**Companion ZH:** `2026-05-25-agent-duplicate-clone.zh_cn.md`

---

## 0. Design decisions (pre-defaulted by Allen via `wake-but-don't-stop`)

Three open questions were answered by Allen's autonomous-mode default; this SPEC adopts them. Flagged for human reaffirmation at SPEC review; only escalate via Feishu if implementation surfaces a fundamental block.

| # | Question                                          | Default                              | Rationale                                                                                                                  |
|---|---------------------------------------------------|--------------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| 1 | Ownership transfer **or** copy?                   | **Copy**                             | Source agent stays live + owned by source user; target is a fresh instance owned by `target_owner_uri`. Cleaner reversal. |
| 2 | Bring conversation history?                       | **Fresh (none)**                     | Agent Kind does not carry chat history slice (Session does). Identity caps reset. If user wants history they keep the source agent. |
| 3 | `config_dir` semantics?                           | **Deep copy** (`File.cp_r/2`)        | Independent FS state; no shared mutation across agents. Matches what `create_agent_config_dir/2` does for fresh spawns.    |

These are SPEC defaults. If reviewers want different semantics, raise in PR review BEFORE impl PR opens.

---

## 1. Goal

**Add a single dispatchable Behavior action — `Ezagent.Behavior.Agent.:duplicate` — that clones an existing agent into a new agent URI, optionally in a different workspace and/or owned by a different user.** No Template Registry intermediary; no `save_as_template + fork + spawn` round-trip; no Template-Class drift risk.

After this SPEC's impl PR lands:
- `mix ezagent.agent.duplicate <source_uri> <target_uri> --owner <owner_uri>` produces a brand-new live agent at `target_uri`, with its own config_dir (FS-independent of source), fresh Identity caps (default grants synthesized from `target_owner_uri`), and **NO** chat-history coupling to source.
- The clone primitive lives on the **Agent Kind**, not on Template Registry. Template Class metadata is *referenced* (target agent keeps the same flavor + template_class) but no new Template Class is registered.
- Cross-workspace and cross-user clone is supported (caller needs a workspace-admin cap on the *target* workspace; source ownership/admin is required on the source).
- A regression-bar invariant test asserts cloned `config_dir` is structurally independent of source's: touching files in source's dir does NOT affect target's.

---

## 2. Scope

In-scope:
- New `Ezagent.Behavior.Agent` module (apps/ezagent_domain_chat/lib/ezagent/behavior/agent.ex) — the Agent Kind currently has no Behavior file of its own (`Ezagent.Entity.Agent.behaviors/0` lists `Chat + Identity + Sandbox` but no `Agent` Behavior). The new module hosts `:duplicate` as the first action. Slice is empty (Agent's domain state lives in sibling Behaviors); the new Behavior exists to host actions whose *subject is the agent itself*.
- New action `:duplicate` on that Behavior. Args: `%{source_uri: URI.t(), target_uri: URI.t(), target_owner_uri: URI.t()}`. Mode: `:call`.
- Cap subject `{Behavior.Agent, :duplicate}` — `data_owner/1` returns source agent's `Identity` owner (the source's owning user, resolved through Identity slice). Workspace-admin on target workspace can also clone (per `caps-data-ownership-v2.md` §5.2 admin branch).
- Action body steps (5) per §3.2 below.
- Mix task `Mix.Tasks.Ezagent.Agent.Duplicate` (`mix ezagent.agent.duplicate`) — thin construct-args + dispatch wrapper (mirrors `agent.create`).
- ExUnit acceptance tests (in impl PR) covering happy path + cap denial + collision + missing source + cross-workspace.
- Invariant test `apps/ezagent_core/test/invariants/agent_duplicate_isolation_invariant_test.exs` — touches source `config_dir` after clone, asserts target unchanged.

Out-of-scope:
- LV admin UI for clone. Operator-only-CLI for V1; admin LV gets a follow-up PR once the primitive is proven (deferred per `docs/futures/todo.md` — flagged in §10).
- "Save as template" semantics. If an operator wants a reusable blueprint, that is a `Behavior.Template.:fork` path (PR1 #287) and is governed; clone is for one-shot instance copies, not templates.
- Migration of any existing data. Clone is a forward-only new operation; nothing in current system needs upgrading.
- MCP-tool exposure of `:duplicate`. Reachable via dispatch from any caller with the right cap, but no MCP tool wrapper this PR.
- Chat history transfer. Per §0 decision 2 — out of scope by design.

---

## 3. Design

### 3.1 Behavior module — `Ezagent.Behavior.Agent`

New file: `apps/ezagent_domain_chat/lib/ezagent/behavior/agent.ex`. Agent's domain (chat domain — Agents live under chat's AgentSupervisor per `Ezagent.Entity.Agent.supervisor/0`).

```elixir
defmodule Ezagent.Behavior.Agent do
  @moduledoc """
  Agent Behavior — actions whose subject is the agent itself (the
  agent-domain operations that don't fit Chat / Identity / Sandbox).

  ## Why this Behavior exists

  Before this Behavior, `Ezagent.Entity.Agent` had three siblings —
  `Chat` (Session-scoped messaging), `Identity` (caps), `Sandbox`
  (per-agent config_dir). None of them owns "agent-as-a-thing"
  operations: clone, archive, rename, etc.

  This Behavior is the natural home. Its slice is empty by design —
  the agent's *state* lives in sibling slices; this Behavior is for
  *actions on the agent as an entity*.

  ## Actions

  - `:duplicate` (`:call`) — clone the source agent into a new agent
    at `target_uri`, owned by `target_owner_uri`. Per SPEC
    `docs/superpowers/specs/2026-05-25-agent-duplicate-clone.md`.

  Future actions (out of scope for V1): `:rename`, `:archive`,
  `:restore`.
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:duplicate]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:duplicate,
       "clone this agent into a new agent at <target_uri>, owned by " <>
         "<target_owner_uri>. Deep-copies config_dir (cc flavor); " <>
         "fresh Identity caps; no chat history. Source unchanged."}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :agent

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{}

  @impl Ezagent.Behavior
  def invoke(:duplicate, slice, args, ctx), do: # ... see §3.2

  @impl Ezagent.Behavior
  def interface, do: # ... see §3.3

  # Source agent's owner is the data_owner — the user that owns the
  # source agent (via Identity behavior). Workspace-admin on the
  # target workspace can also grant (per §5.2 admin branch).
  @impl Ezagent.Behavior
  def data_owner(%URI{} = source_agent_uri), do: source_agent_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
```

And `Ezagent.Entity.Agent.behaviors/0` (line 67-68 of `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex`) is amended:

```elixir
def behaviors,
  do: [Ezagent.Behavior.Chat, Ezagent.Behavior.Identity,
       Ezagent.Behavior.Sandbox, Ezagent.Behavior.Agent]
```

### 3.2 Action body — `:duplicate`

Runs inside the **source agent's** Kind GenServer (`ctx.self_uri` is the source agent URI; the dispatch target is `entity://agent/<src_ws>/<src_name>?action=agent.duplicate`).

```elixir
def invoke(:duplicate, _slice, args, ctx) do
  source_uri        = Map.fetch!(ctx, :self_uri)
  target_uri        = Map.fetch!(args, :target_uri)
  target_owner_uri  = Map.fetch!(args, :target_owner_uri)
  caller            = Map.fetch!(ctx, :caller)
  caps              = Map.fetch!(ctx, :caps)

  with {:ok, target_uri}     <- validate_target_uri(target_uri),
       :ok                   <- refuse_if_target_exists(target_uri),
       {:ok, source_meta}    <- read_source_metadata(source_uri),
       {:ok, target_ws_uri}  <- workspace_uri_from_agent(target_uri),
       {:ok, create_args}    <- build_create_args(source_meta, target_uri),
       {:ok, target_owner_ctx} <- impersonate_target_owner_ctx(target_owner_uri, caller, caps),
       {:ok, result}         <- spawn_target_via_workspace(target_ws_uri, create_args, target_owner_ctx),
       :ok                   <- deep_copy_config_dir(source_meta, result.agent_uri, source_uri) do
    {:ok, %{}, %{
      source_uri: source_uri,
      target_uri: result.agent_uri,
      template_name: result.template_name,
      owner_uri: target_owner_uri
    }}
  end
end
```

The 5 conceptual steps (matching memory `feedback_agent_clone_not_via_template`):

1. **Validate target_uri doesn't exist** — `Ezagent.KindRegistry.lookup(target_uri)` returns `:error` → continue; `{:ok, _pid}` → `{:error, {:already_exists, target_uri}}`.
2. **Read source's relevant slices** — dispatch `sandbox.read` against source to get `config_dir_path` + `template_class`. The Chat slice carries no per-agent state worth carrying (it's a Session concern; agents have an empty `:chat` slice). Identity slice is intentionally NOT read — target gets default caps via Identity's `init_slice/1` synthesis (per decision §0.2). Source flavor is derived from source URI's `<flavor>_<name>` prefix (PR-2 v3 §3 shape).
3. **Spawn target via Workspace.create_agent** — call `Ezagent.Workspace.create_agent(target_ws_uri, create_args, target_owner_ctx)` (the SPEC #330 facade). `create_args` carries `flavor`, `name`, `cwd` (inherited from source's PtyServer-recorded cwd or, when cwd is workspace-relative, re-resolved against the target workspace's root — TBD see §10). This path:
   - Validates flavor + name + cwd
   - Composes target agent URI (must equal the caller's `target_uri`)
   - Registers a Workspace-scoped template (for cc/echo) or direct-spawns (curl/np)
   - Calls `Loader.invoke_template` → cc plugin's `instantiate/3` → `ensure_agent_kind` + `create_agent_config_dir` + `ensure_pty_server`
   - At this point target has a FRESH config_dir copied from the **template's reference dir** (not source's). Step 5 overwrites it with source's.
4. **Identity caps for target** — INTENTIONALLY use `target_owner_ctx` so the spawn's `default_grants_from_data_owner/2` synthesizes the new owner's default caps. NO grant from source. Caller need NOT supply caps — they are derived from the new ownership.
5. **Deep-copy config_dir** — for cc flavor:
   - `source_dir = source_meta.config_dir_path` (read in step 2)
   - `target_dir = source_meta.template_class.agent_config_dir(target_uri)`
   - Atomically wipe target's just-created reference-derived dir (`File.rm_rf!(target_dir)`)
   - `File.cp_r!(source_dir, target_dir)` (deep copy includes `.claude/plugins/*` extensions + `.credentials.json` if present)
   - Re-chmod (`0o700` dir, `0o600` credentials) — same hardening as `do_atomic_copy/3` in `cc_agent.ex:977-988`
   - Re-write the `.ezagent-config-complete` marker so future spawns idempotency-detect "completed"
   - Dispatch `sandbox.write_path` on target to update its slice with new path + template_class (idempotent — was already populated by step 3 with template-reference path; this is a re-write to keep slice congruent)

For non-cc flavors (echo / curl / np), step 5 is a no-op (`config_dir_path: nil` on source means nothing to copy; the source's plugin Template Class didn't manage a dir).

**Failure handling (let-it-crash, no shims):**
- Step 5 failure (e.g. `File.cp_r` fails mid-copy): caller sees `{:error, {:config_dir_copy_failed, reason}}`. The freshly-spawned target agent is ALIVE — its sandbox slice points at a half-copied dir. The contract is: if step 5 fails, the duplicate operation reports the error and the operator is expected to invoke `sandbox.destroy` on target_uri to clean up. We do NOT auto-rollback the target spawn — partial state with a clear error is preferable to silent rollback failures.
  - This is consistent with `feedback_let_it_crash_no_workarounds`: no defensive `try/rescue` here; if `File.cp_r!` raises, the dispatched action returns `{:error, %File.CopyError{}}` and the caller decides.
  - Rationale: rollback is itself a destroy operation, which has its own failure modes; daisy-chaining destroy + destroy-of-destroy is the kind of "shim" we avoid. Single sharp edge: target exists, dir is partial, operator destroys it.

### 3.3 Interface schema

```elixir
def interface do
  %{
    duplicate: %{
      description:
        "Clone the source agent into a fresh agent at target_uri, owned by " <>
          "target_owner_uri. Deep-copies config_dir; fresh Identity caps; no chat history.",
      args: %{
        target_uri: :uri,
        target_owner_uri: :uri
      },
      returns: %{
        source_uri: :uri,
        target_uri: :uri,
        template_name: {:option, :string},
        owner_uri: :uri
      },
      modes: [:call]
    }
  }
end
```

(`source_uri` is NOT in `args` — it's `ctx.self_uri`, the dispatch target; the dispatch URI itself names the source.)

### 3.4 Mix task — `mix ezagent.agent.duplicate`

New file: `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.duplicate.ex` (parked in workspace so it's near `agent.create`; could move to a future `ezagent_domain_agent` if one is extracted).

```bash
mix ezagent.agent.duplicate <source_uri> <target_uri> --owner <owner_uri>
```

Example:

```bash
mix ezagent.agent.duplicate \
    entity://agent/system/cc_linyilun-default \
    entity://agent/system/cc_linyilun-clone \
    --owner entity://user/system/allen
```

Body is the standard `parse_uri` + `decompose` + `Invocation.dispatch` shape that `agent.create.ex` uses (see `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex:121-148`).

---

## 4. Cap-bAC

### 4.1 Cap subject

`{Behavior.Agent, :duplicate}` — registered via `Ezagent.BehaviorRegistry` at boot (free if `Ezagent.Entity.Agent.behaviors/0` includes the new Behavior).

### 4.2 Resolution

- `Behavior.Agent.data_owner(source_uri)` returns `source_uri`. Identity's `data_owner_of/2` then resolves to the user that owns the source agent (via Identity behavior's lineage / ownership records).
- `default_grants_from_data_owner/2` (in CapabilityRegistry, per SPEC `caps-data-ownership-v2.md` §3.3) synthesizes: source agent's owner holds `{Behavior.Agent, :duplicate}` on source by default.
- §5.2 admin branch: workspace admin on **target** workspace also satisfies the check — caller may move an agent from a workspace they don't own into one they do.

### 4.3 Caller scenarios

| Caller                                  | Source ws admin? | Target ws admin? | Source owner? | Allowed? |
|-----------------------------------------|------------------|------------------|---------------|----------|
| Source owner (cloning own agent)         | n/a              | n/a              | yes           | Yes (owner default grant) |
| Workspace admin of TARGET ws            | n/a              | yes              | n/a           | Yes (§5.2 admin branch on target) |
| Workspace admin of SOURCE ws            | yes              | no               | no            | No (admin grant is target-scoped) |
| Random user                              | no               | no               | no            | No (deny) |

The `caps-data-ownership-v2.md` §5.2 admin-branch precedent (workspace admin grants Workspace caps) extends naturally here: cloning *into* a workspace is a workspace-admin act on the *target*, not on the source.

---

## 5. Audit

The dispatch chain already logs the invocation (every `Invocation.dispatch/1` is audited per Phase 5 invocation envelope). The audit record will contain:

- `caller` — who initiated
- `target` — `<source_uri>?action=agent.duplicate`
- `args` — `%{target_uri:, target_owner_uri:}`
- `result` — `{:ok, %{source_uri, target_uri, template_name, owner_uri}}` or `{:error, _}`

No additional telemetry needed; the existing audit envelope captures the clone op fully. Operators can grep the audit log for `?action=agent.duplicate` to enumerate every clone.

---

## 6. Migration

**None.** No DB schema change, no behavior added to existing live agents (the new Behavior's slice is empty; `init_slice/1` returns `%{}`; no snapshot migration). Agents started before this PR get the new Behavior on next supervisor restart; their slice is `%{}`, no rehydration concern.

The `parent_template_uri` field considered in the original task description is NOT required — Template lineage already shipped in PR1 (#287) via `Behavior.Template.:fork`. Agent clone is instance-to-instance; it does not produce a new template, so no template lineage row is created.

---

## 7. Acceptance tests

In impl PR (not this SPEC). Listed here so the impl PR knows the bar.

1. **Happy path (cc, same workspace, same owner)**: clone a freshly-spawned cc agent → new agent has independent config_dir on disk; sandbox slice contains new dir path; new agent's Identity caps are the defaults for source owner; source agent still alive + unchanged.
2. **Happy path (cross-workspace)**: caller holds workspace admin on `target_ws` only; clone succeeds; target binds to `target_ws` via WorkspaceRegistry.
3. **Cap denial — random user**: caller has neither source-owner nor target-ws-admin → `{:error, :unauthorized}` (or whatever the Identity action body returns for cap-check fail).
4. **Target URI collision**: `target_uri` already alive in KindRegistry → `{:error, {:already_exists, target_uri}}`. Source unchanged.
5. **Source missing**: dispatch against a `source_uri` that doesn't exist → standard dispatch-time error `{:error, {:no_such_kind, source_uri}}`.
6. **Deep-copy isolation**: modify a file in source's `config_dir` post-clone; target's `config_dir` file at same relative path is unchanged. **(This is the invariant; see §8.)**
7. **Non-cc flavor (echo)**: clone an echo agent → no config_dir manipulation; spawn succeeds; sandbox slice on target has `config_dir_path: nil` (echo doesn't manage a dir). Idempotent / no-op for step 5.
8. **Idempotency of target spawn**: dispatching `:duplicate` twice with same target_uri → second call hits the collision guard, returns `{:error, {:already_exists, target_uri}}` cleanly. First call's target is unaffected.

---

## 8. Invariant test (per `feedback_completion_requires_invariant_test`)

`apps/ezagent_core/test/invariants/agent_duplicate_isolation_invariant_test.exs`:

```elixir
test "cloned agent's config_dir is FS-independent of source" do
  # 1. spawn source cc agent
  # 2. write canary file into source's config_dir
  # 3. dispatch :duplicate → target agent
  # 4. read canary file from source — still present
  # 5. read canary file from target — present (the deep-copy carried it)
  # 6. mutate canary file in source
  # 7. read canary file in target — UNCHANGED (proves no symlink / shared inode)
  # 8. delete source's entire config_dir
  # 9. target's config_dir still intact + functional
end
```

If this test would FAIL given the architecture (e.g. someone tried to use `File.ln_s` instead of `File.cp_r`), the PR is not complete regardless of unit tests passing.

---

## 9. CLAUDE.md / docs

No CLAUDE.md change required. Mix task `--help` auto-renders from `@moduledoc`. Operator-facing docs go in `docs/operations/agent-duplicate.md` in the impl PR (one-page, bilingual per `feedback_bilingual_docs_convention`).

---

## 10. Open follow-ups (deferred — flagged here per `feedback_dont_defer_what_is_solvable_now`)

- **cwd semantics on cross-workspace clone.** When source's PTY cwd is an absolute path on the operator host, what should target's cwd be? V1 default: same absolute path (operator typically clones for testing on same machine). Cross-host federation cwd resolution is a Phase-10 concern.
- **LV admin UI for clone.** A `/admin/agents/<uri>/clone` form would let admin LV users clone without dropping to CLI. Deferred per §2 out-of-scope; tracked in `docs/futures/todo.md` as a follow-up after primitive proves stable.
- **MCP tool surface.** Once primitive + invariant test land, exposing `:duplicate` as an MCP tool for in-session agent self-cloning is a 10-line wrapper. Deferred to avoid scope creep here.
- **Bulk clone.** "clone N copies" — useful for load testing. Trivial wrapper around the primitive. Out of V1.

---

## 11. Codex adversarial review (per `feedback_spec_codex_adversarial_review`)

After this SPEC merges to a branch, dispatch a `/codex:adversarial-review` subagent against this file BEFORE opening the impl PR. Catches "wrong approach", not just defects.

---

## 12. User-assist steps (per `feedback_flag_user_assist_steps`)

This SPEC has **no** user-assist steps. Impl PR runs entirely in CI + local mix tests. End-to-end manual verification (the suggested `mix ezagent.agent.duplicate` against `linyilun-default`) is *suggested* but not gated.
