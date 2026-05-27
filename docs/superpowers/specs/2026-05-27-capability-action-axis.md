# SPEC — Capability struct gains the `action` axis

**Status:** r1 (draft, awaiting codex review). 2026-05-27.
**Tier:** `apps/ezagent_core/` framework rectification + sweep across every grant site, every `required_caps/0`, every test that constructs a cap.
**Trigger:** Allen 2026-05-27 Feishu — "显然应该恢复 action 字段". PR #408 + #409 surfaced the long-known over-grant: a workspace member granted `Behavior.Workspace :create_session` also satisfies the cap-check for `add_member`, `remove_member`, `set_routing_rules`, `create_agent`, …, because the cap struct discards the action argument.
**Companion:** `2026-05-27-capability-action-axis.zh_cn.md` (per `feedback_bilingual_docs_convention`).

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — no shim, no dual-path. Action is added as a real struct field; default `:any` is the wildcard, not a sentinel-discarded value.
- `feedback_completion_requires_invariant_test` — the PR's merge gate is an invariant test that proves an `:add_member` cap on workspace://X does NOT satisfy `Behavior.Workspace :create_session`'s cap-check on the same workspace (today it does — that's the bug).
- `feedback_north_star_plugin_isolation` — plugin-author UX stays as `Capability.cap(:chat, __MODULE__, :send)`; the third arg becomes load-bearing rather than documentation.
- `feedback_subagent_must_load_project_skills` — the impl subagent dispatch MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.
- `feedback_codex_companion_no_mix` — codex reviews on this SPEC + impl PR carry the verbatim "no mix" clause.

**Parent / historical context:**
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md` r4 §0d — established struct-kept decision after reverting the PR-CC-2a/2b string-cap experiment. r4 chose to keep the existing 6-field struct shape; the action axis was discussed but **never implemented**.
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2 — even shows `action: :send` in the example struct construction (line 73 of that SPEC's signature block). The *intent* to encode action existed; the codebase never realized it.
- `docs/futures/todo.md` §"Capability struct lacks an action axis (codex PR #356 r1 CRIT)" — PR #356 codex r1 surfaced the gap; PR #408 round-3 reconfirmed it; this SPEC resolves it.

---

## 1. Problem in one paragraph

A capability today is a 4-axis match: kind × behavior × instance × workspace. The behavior axis carries the module name (`Ezagent.Behavior.Workspace`), so a cap "on the Workspace Behavior" is shape-equivalent across every action that Behavior defines. Most Behaviors today mix privilege tiers within one module — `Behavior.Workspace` has `list_members` (read-only), `add_member` (admin), and `create_session` (member-ok). Granting any single Workspace cap to a non-admin member opens the cap-check gate for every Workspace action on the same workspace. The same trap exists on every multi-action Behavior in the umbrella (Routing, ApiKeys, UserTokens, Feishu UserBinding, …). The fix is to add an explicit action axis to the cap match, so a cap granted for `:create_session` matches only `:create_session`'s gate, not `add_member`'s.

## 2. Why this can no longer wait

| Surface | Privilege mix today | Risk realized |
|---|---|---|
| `Behavior.Workspace` | list × admin × member | PR #408 round-3 — workspace member gets de-facto admin |
| `Behavior.Routing` | declare × set rules × list | low (no member-level grant site today) |
| `Behavior.IdentityAdmin` | grant × revoke × list | high — a "list-only" grant would also authorize grant/revoke |
| `Behavior.ApiKeys` | mint × revoke × list | high — same shape as IdentityAdmin |
| `Behavior.FeishuUserBinding` | bind × unbind × list | medium — exposed to plugin-author misuse |
| `Behavior.Template` (AgentTemplate + SessionTemplate) | read × write × instantiate × delete | high — instantiate is operator-tier; read is plugin-tier |

The PR #356 carve-out workaround (split each privileged action into its own Behavior module) is a partial mitigation that bloats the Behavior count and bleeds module names into UX surfaces. It is not the structural answer.

## 3. Design — one field, real comparison

### 3.1 Struct grows to 7 enforce_keys

```elixir
@enforce_keys [:kind, :behavior, :action, :instance, :workspace_uri, :granted_by, :granted_at]
defstruct kind: nil,
          behavior: nil,
          action: :any,
          instance: nil,
          workspace_uri: nil,
          granted_by: nil,
          granted_at: nil
```

Default `:any` matches the wildcard convention already used for `kind` / `behavior` / `instance` / `workspace_uri`. Old grant sites that pass no action become `action: :any` — the wildcard — preserving current admin / system-principal semantics.

### 3.2 Constructor stops discarding the action arg

```elixir
def cap(kind, behavior, action) when is_atom(kind) and is_atom(behavior) and is_atom(action) do
  %__MODULE__{
    kind: kind,
    behavior: behavior,
    action: action,            # ← was `_action`, the third-arg-discard hole
    instance: :any,
    workspace_uri: :any,
    granted_by: @plugin_declared_granter,
    granted_at: @compile_time_granted_at
  }
end

def cap(kind, behavior, action, instance, workspace_uri)
    when is_atom(kind) and is_atom(behavior) and is_atom(action) do
  %__MODULE__{
    kind: kind,
    behavior: behavior,
    action: action,
    instance: instance,
    workspace_uri: workspace_uri,
    granted_by: @plugin_declared_granter,
    granted_at: @compile_time_granted_at
  }
end
```

The signature is unchanged — only the body stops dropping the third arg on the floor.

### 3.3 `matches?/2` gains action as the fifth match dimension

```elixir
def matches?(%__MODULE__{} = cap, %{kind: k, behavior: b, action: a, instance: i, workspace_uri: w}) do
  field_match?(cap.kind, k) and
    field_match?(cap.behavior, b) and
    field_match?(cap.action, a) and
    instance_match?(cap.instance, i) and
    workspace_match?(cap.workspace_uri, w)
end
```

The needed-cap shape (the second arg) gains `:action`. Today's needed-cap is constructed by `Ezagent.Kind.Runtime`'s `authz_check` from the dispatch target + action atom; that call site needs one new field (`action: <the action atom>`).

### 3.4 Persistence: `caps_json` becomes 7-field JSON, with a backward-compat read path

| Read direction | Old row (6 fields, no `action`) | New row (7 fields) |
|---|---|---|
| Load → struct | Default `action: :any` injected at parse time | Read as-is |
| Save → JSON | All 7 fields serialized | All 7 fields serialized |

The backward-compat read path is **not a shim per the let-it-crash policy** — it is the canonical interpretation of an old row: a 6-field cap was always semantically "any action on this Behavior", and `:any` is precisely how the new shape spells that. The read path is one line: `Map.put_new(parsed_map, "action", "any")` before atomization. No migration required; old rows promote on first read.

### 3.5 `Behavior.required_caps/0` semantics — action is now load-bearing

Every Behavior's `required_caps/0` already enumerates one entry per action. Today the *map key* differentiates actions but the *cap struct* is shape-equivalent. After this SPEC, the struct's `action` field equals the map key — they double-encode the action, which is fine (the map key is the dispatch lookup, the struct field is the matcher input).

The plugin-author API stays identical:

```elixir
def required_caps do
  %{
    send: Capability.cap(:chat, __MODULE__, :send),
    receive: Capability.cap(:chat, __MODULE__, :receive)
  }
end
```

The third arg becomes load-bearing without any plugin-author migration.

### 3.6 Wildcard grants stay wildcard

`User.admin_uri()` and `system://bootstrap` already get a `kind: :any, behavior: :any, instance: :any, workspace_uri: :any` cap. After this SPEC they additionally get `action: :any` — same wildcard semantics. Catalog entries that named specific actions (`SystemPrincipal.Catalog`'s 14 entries) gain a real action value; their narrowing effect becomes structurally meaningful.

## 4. Migration strategy

### 4.1 Single coordinated PR — no dual-path

Allen's `feedback_let_it_crash_no_workarounds` forbids dual-path. The PR lands all of:

1. Capability struct + helpers + matches?/2 — one commit
2. All `required_caps/0` action threading audit — one commit (mostly verifies the third arg matches the map key; expect ≤5 typo fixes)
3. All grant sites (`Identity.grant_cap`, `IdentityAdmin`, `SystemPrincipal.Catalog`) — one commit
4. `caps_json` backward-compat read shim (the `Map.put_new(..., "action", "any")` line + a Capability.from_map/1 audit) — one commit
5. Invariant test + per-Behavior coverage tests — one commit
6. The over-grant regression test (PR #408 round-3's exact case: workspace member with `:create_session` cap is denied `:add_member`) — one commit

### 4.2 Compile-time check 10

`:ezagent_plugin_check`'s existing check 10 ("every action has a required_caps entry") gains a sibling check 11: `required_caps[action].action == action` — guarantees the map key and struct field don't drift.

### 4.3 No DB schema migration

`caps_json` is a JSONB column. New rows write 7 fields; old rows read with `:any` default. No `alter table` needed. The schema migration list in this PR is empty — that is the design.

## 5. Acceptance criteria

| # | Test | Pass condition |
|---|---|---|
| A1 | `Capability.cap(:chat, Chat, :send).action == :send` | unit test |
| A2 | `Capability.matches?/2` with held `action: :send` and needed `action: :join` → false | unit test |
| A3 | `Capability.matches?/2` with held `action: :any` and needed `action: :send` → true (wildcard preserved) | unit test |
| A4 | Old JSON row (6 fields) loads with `action: :any` | unit test |
| A5 | `required_caps/0` entries: every `Behavior` has `entry[action].action == action` | umbrella-wide property test |
| A6 | Compile-time check 11 fails a deliberately-broken fixture (`%{send: cap(.., .., :join)}`) | plugin-check test |
| **B1** | **The PR #408 regression test**: workspace member with `Capability.cap(:workspace, Behavior.Workspace, :create_session)` is **denied** dispatch to `workspace://X?action=workspace.add_member` | invariant test (THE merge gate) |
| B2 | The same member is granted dispatch to `workspace://X?action=workspace.create_session` | invariant test |
| C1 | Admin wildcard cap (`kind: :any, behavior: :any, action: :any, …`) still satisfies every action | regression test |
| C2 | `SystemPrincipal.Catalog` 14 entries each gain a real action; `system://chat-router :send` is denied `:receive` on the same Session | catalog audit test |

## 6. Files affected (estimated)

**Core changes (small):**
- `apps/ezagent_core/lib/ezagent/capability.ex` — struct + helpers + matches?/2
- `apps/ezagent_core/lib/ezagent/kind/runtime.ex` — authz_check needed-cap construction (one field added)
- `apps/ezagent_core/lib/ezagent/identity/admin.ex` — grant_cap / revoke_cap may need to normalize action on input
- `apps/ezagent_core/lib/ezagent/ecto/identity_slice.ex` (or wherever caps_json deserializes) — `Map.put_new("action", "any")` read path

**Sweep (mechanical, ~100 sites):**
- Every Behavior's `required_caps/0` — verify map key matches third arg (expect ≤5 typo fixes)
- Every test that constructs a `%Capability{}` directly — add `action:` field (search-and-replace + manual review of `:any` vs concrete action)
- `SystemPrincipal.Catalog` 14 entries — verify or fix action atoms

**New tests:**
- `apps/ezagent_core/test/ezagent/capability_action_test.exs` — A1–A4 + C1
- `apps/ezagent_core/test/ezagent/behavior_required_caps_action_invariant_test.exs` — A5
- `apps/ezagent_core/test/integration/cap_action_axis_invariant_test.exs` — **B1 + B2** (the merge gate)
- `apps/ezagent_core/test/ezagent/system_principal_catalog_action_audit_test.exs` — C2

## 7. Out of scope

- Cryptographic cap fields (signature, nonce, issued_at) — `2026-05-25-caps-cleanup-v1.md` r4 §44 mentions these as "additive future extensions"; this SPEC is one field at a time.
- `Capability.matches?/2` returning a structured reason for denial (today: boolean). Useful for diagnostics, separate PR.
- Renaming `cap_subjects/0` or any registry API. Existing UI / catalog flow unchanged.
- Removing the PR #356 `WorkspaceUserAdmin` carve-out — that module exists for a different reason (privilege isolation by registration) and stays.

## 8. Risks / failure modes considered

| Failure | Behavior |
|---|---|
| A grant site forgets to specify action and passes nothing | `cap/3` defaults the action via `:any` ONLY at the public constructor; direct struct construction must specify it (enforce_keys). The plugin-check 11 catches `required_caps/0` drift. |
| Two callers race writing caps_json with overlapping cap shapes | Existing Ecto optimistic concurrency / slice revision-CAS unchanged. |
| Old row reads as `:any` but the user's intent was a narrow cap | Impossible by construction — old code never wrote a narrow cap (the field didn't exist). `:any` is the only correct interpretation. |
| Plugin author's required_caps map key differs from the third arg | Compile-time check 11 fails the build. |
| `SystemPrincipal.Catalog` regression breaks boot | Catalog audit test in section 5 C2 catches it pre-merge. |
| Action atom typo passes compile but fails at runtime cap-check | Same as today's action-atom typos in `actions/0` — caught by integration tests. |

## 9. Codex adversarial review questions

1. **Backward-compat boundary**: is `Map.put_new("action", "any")` truly the canonical interpretation of an old 6-field row, or does it silently broaden a previously-narrow grant? Verify against an actual `caps_json` row from a running dev DB.
2. **Wildcard cascade**: a cap with `action: :any` plus `behavior: :any` plus `instance: :any` is the admin wildcard. After this SPEC, is there any way to construct a cap that authorizes the admin wildcard's behavior but NOT every action? Should there be?
3. **`SystemPrincipal.Catalog` 14 entries**: do all 14 entries' action atoms match real `actions/0` entries on the corresponding Behavior? Run a grep + cross-check.
4. **`Behavior.required_caps/0`'s implicit invariant `entry_key == cap.action`**: is the compile-time check 11 enforceable in `:ezagent_plugin_check`'s existing structure, or does it need a new AST walker?
5. **Cross-Behavior caps**: any Behavior whose `required_caps/0` references *another* Behavior's action (rare but possible — e.g. a derived action that internally calls dispatch on another Kind)? Action axis must match the OUTER action, not the inner.
6. **Test impact**: how many existing tests construct `%Capability{}` directly without going through `Capability.cap/N`? Each is a manual-edit site.
7. **Race condition between deployment of new code and reading old caps_json rows**: the read path's `Map.put_new("action", "any")` runs in-process when loading. Any path that bypasses it? (E.g. raw Repo.all where the cap struct is reconstructed by `Ecto.Schema.load/2` outside the from_map shim.)
8. **`Catalog` test C2 specificity**: `system://chat-router :send` denied `:receive` on the same Session — does the catalog actually grant `:send` only, or does it also grant `:receive`? Verify what the catalog currently encodes.

## 10. Open questions for Allen

1. **Cap-axis ordering for diagnostics**: when a cap-check fails, the error message could name which axis didn't match (`action mismatch: held :send, needed :join`). Useful for plugin-author debug. Default: log-only at debug level; UI surfaces a generic "unauthorized". Scope this in or out?
2. **`cap_exempt_actions/0`** — Behaviors that intentionally bypass cap-check for some actions (declared via `cap_exempt_actions/0`). After action-axis, exempt-action handling stays per-action; no change. Confirm OK.
3. **Future grant audits**: should the audit trail (`Ezagent.Audit`) start recording the action that was checked alongside the cap that authorized it? Today it records the cap but not the action match — a minor diagnostic improvement.

## 11. Rollback plan

Single-PR change. Rollback = revert the merge commit. The backward-compat read path means rolled-back code can still read rows written by the new code (they have an extra `action` field; old code ignores unknown JSON keys via the existing parse path). Risk: a row written with a narrow action under the new code reverts to "any action" semantics on rollback — strictly broader, never denies. Acceptable as a one-step rollback safety net.

---

## Appendix A — Why this SPEC is short

Per `feedback_explain_problem_not_code_structure`, the SPEC describes the problem + design intent. The PR's implementation subagent will execute the sweep mechanically — it's mostly threading one atom through a hundred call sites that already pass the right atom as the third arg. The interesting work is in the invariant test (B1) and the catalog audit (C2).

## Appendix B — Why the PR-CC-2-v2 SPEC's example showed `action: :send` even though the field doesn't exist

PR-CC-2-v2's SPEC at `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2 line 73 has:

```elixir
%Capability{
  kind: :chat,
  behavior: Ezagent.Behavior.Chat,
  action: :send,           # ← in SPEC, never in struct
  ...
}
```

This is a SPEC-vs-code drift dating to 2026-05-25. The SPEC reflected the *desired* shape; the implementation kept the existing 6-field struct. Allen's 2026-05-27 directive closes the drift by making the SPEC's intent the actual implementation. **The action field was never in the struct — the SPEC just promised it would be.**
