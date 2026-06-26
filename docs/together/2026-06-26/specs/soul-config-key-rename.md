# SPEC — Rename the default config-cascade key `advisor.behavior` → `agent.soul`

**Status:** PLAN ONLY. Do **NOT** execute the rename or the data migration. The lead
confirms this plan (and the codex adversarial-review verdict) before any execution.

**Date:** 2026-06-26
**Branch (this plan only):** `chore/retire-session-advisor` (docs add; the rename is a
separate future PR)
**Name decision (lead, relayed):** `agent.soul` — confirmed below with reasoning.

---

## 1. Problem

`"advisor.behavior"` is the **default config-cascade key** under which every agent's
behavior/persona config is stored. Its body projects to the agent's **soul file**
(`CLAUDE.md`) via `Ezagent.Socialware.ConfigProjection.render_soul/1` (`@soul_file
"CLAUDE.md"`).

The literal `advisor` is misleading historical residue. It was the advisor-demo's
config key (from #606); when config-evolve generalized, it got hardcoded as the
*generic* `@default_key` / `@default_cascade_key`. The advisor demo vertical itself is
being retired (Task 1 / PR #1034). The default key should describe what it is — the
agent's soul — not the demo it came from.

This document is the **rename plan**: every reader/writer of the literal, the
non-destructive data-migration design, the deploy-ordering coordination, and the name
recommendation.

---

## 2. Name recommendation — `agent.soul`

| Candidate | Verdict | Reasoning |
|---|---|---|
| **`agent.soul`** | **RECOMMENDED (lead choice)** | The body literally projects to the agent's SOUL file (`CLAUDE.md`, `render_soul/1`, `@soul_file`). `agent.` prefix mirrors the existing dotted-namespace convention (`model.settings` is already a sibling cascade key — see `config_crud_test.exs:73`). Self-explained: a reader sees "the agent's soul config" with zero history needed. |
| `soul` | Rejected | Loses the namespace prefix that `model.settings` establishes; a bare top-level key reads as less structured next to dotted siblings. |
| `agent_config.behavior` | Rejected | Re-introduces "behavior" (the same residue we're removing) and uses snake_case where the existing convention is dotted (`model.settings`). |

**Collision check (verified):** no existing config key named `agent.soul` / `soul` /
`agent_soul`. The only `soul`-substring hits in code are `soul_md` (a *body field inside*
the config object — UNCHANGED by this rename), `render_soul`, `@soul_file`, and an
unrelated `turn_id("soul")` test helper. The new key name is collision-free.

> Note the distinction the rename must preserve: the **key** is `advisor.behavior`
> (→ `agent.soul`); the **body field** inside that key's object is `soul_md` (the raw
> CLAUDE.md markdown). Only the KEY changes. `soul_md` stays.

---

## 3. Every reader/writer of the literal `"advisor.behavior"`

Repo-wide grep (`.ex/.exs/.heex` + unfiltered `.json/.yaml/.txt/seed`). Result:
**three production code touchpoints**, the rest are tests + docs + log artifacts.

### 3.1 Production code (MUST change — 3 sites)

| # | File:line | Form | Role |
|---|---|---|---|
| 1 | `apps/ezagent_domain_agent/lib/ezagent/agent/config.ex:13` | `@default_key "advisor.behavior"` | Facade default key (read_cascade fallback key, write default key via `key/1` at :332). |
| 2 | `apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex:87` | `@default_cascade_key "advisor.behavior"` | Durable mutation owner's default cascade key (used at :442 `default_key:`, :461 keys union, :517 reconcile read, :738 `attrs_from_args` default). |
| 3 | `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex:754` | hardcoded literal `read_key(agent_uri, "advisor.behavior", …)` | **Bypasses both constants** — re-hardcodes the string to read the soul_md field for the console. |

> ⚠️ **Touchpoint #3 is the trap.** `identity_data.ex:754` does NOT reference either
> constant; it inlines the string. A rename that only changes the two `@default_*`
> constants would leave this reader pointed at the old key → the console's soul_md field
> silently goes blank. **Recommendation:** change #3 to reference
> `Ezagent.Agent.Config.default_key/0` (expose the constant as a public `@spec`'d fn) so
> the value cannot drift again. This is a small refactor bundled into the rename PR.
>
> (The task brief cited `identity_data.ex:658`; that is stale line-numbering — the grep
> proves a single occurrence, now at :754.)

### 3.2 Tests asserting the literal (MUST update in lockstep — 7 files)

These hardcode `advisor.behavior` as the expected default key. They are the behavioral
contract for "the default key is always present in the cascade", so they move WITH the
rename (not after):

- `apps/ezagent_domain_agent/test/ezagent/agent/config_crud_test.exs:10` (`@default_key`)
- `apps/ezagent_domain_agent/test/ezagent/agent/config_no_activation_test.exs:24`
- `apps/ezagent_domain_socialware/test/integration/turn_config_evolve_rewire_test.exs:33` (`@cascade_key`)
- `apps/ezagent_domain_identity/test/ezagent/socialware/config_projection_test.exs:20` (`@key`)
- `apps/ezagent_domain_identity/test/ezagent/behavior/config_evolve_test.exs:25` (`@cascade_key`)
- `apps/ezagent_domain_session/test/ezagent/entity/agent_config_materialize_test.exs:34` (`@key`)
- `apps/ezagent_plugin_world/test/ezagent/world/agent_config_state_test.exs` + `agent_config_dispatch_test.exs` — **behavioral contract**: assert the default key is *always present* in cascade `keys` (`agent_config_state_test.exs:103-104`). After the rename these assert `"agent.soul" in key_names`.

### 3.3 Docs to refresh (not a blocker; same PR)

- `docs/together/2026-06-24/agent-config-frontend-contract.md` (many)
- `docs/together/2026-06-24/agent-config-backend-delivery.md`
- `docs/together/2026-06-24/agent-config-backend-contract-plan.md`
- `docs/together/2026-06-24/handoffs/agent-console-crud-handoff.draft.md`
- `docs/together/2026-06-25/analysis/agent-console-gap-analysis.md`
- `config.ex` moduledoc/`@doc` prose (line 40 "advisor.behavior key plus…")

These are contract docs the frontend/backend agents read; refresh them so the
console contract names `agent.soul`. (Leave any *historical* design specs that
document the old name as-was — annotate, don't rewrite history.)

### 3.4 Non-touchpoints (confirmed safe to ignore)

- `.txt` hit = a captured SQL-log artifact (test output), not a source writer.
- No seed/fixture/`.json`/`.yaml` writer mints `advisor.behavior` at provision time
  (incl. the `<username>-default` cc-agent seed — it carries no fixed config key).
- **Frontend / React console reads the key dynamically, NOT a hardcoded JS literal**
  (verified): the unfiltered grep found ZERO `.js/.mjs/.ts/.tsx` occurrence of
  `advisor.behavior`. The agent-config console renders whatever `default_key` /
  `keys[]` the backend cascade response returns (see the
  `agent-config-frontend-contract.md` shape — `default_key` is server-supplied), so
  no client code changes with the rename.

### 3.5 Two constants stay separate by design (not a missed dedup)

`config.ex:13 @default_key` and `config_evolve.ex:87 @default_cascade_key` are two
copies of the same string in two different apps. They are **intentionally not
collapsed to one source** because `ezagent_domain_identity` (config_evolve) must not
take a compile dep on `ezagent_domain_agent` (config) — that would invert the domain
layering. Both flip together in the rename PR, and the §3.2 test suite asserts the key
in BOTH apps, so a one-sided flip is caught by tests. Recommendation #3 (point
`identity_data.ex:754` at `Config.default_key/0`) is safe because `ezagent_plugin_world`
already depends on `ezagent_domain_agent`; the cross-app constant duplication is only
between agent↔identity.

---

## 4. The data migration (DESIGN — do NOT run)

### 4.1 Where the key lives in the DB

Two tables (migration `20260618000500_add_socialware_config_store.exs`):

| Table | `key` location | Rename impact |
|---|---|---|
| `socialware_config_objects` | plain `:string` column | `UPDATE … SET key='agent.soul' WHERE key='advisor.behavior'` |
| `socialware_config_pointers` | plain `:string` column **AND embedded in the `id` primary key** (`id = "layer\|workspace_uri\|subject_uri\|key"`, see `ConfigPointer.id/4`) | rewrite **both** the `key` column **and** the `id` PK |

`config_id` / `previous_config_id` are object UUIDs — **unchanged** (the object identity
and its `resource://…/socialware-config-object/<b64(id)>` URI do not depend on the key).

### 4.2 Read-path criticality (verified)

The hot read path queries **pointers** only:
`ConfigStore.resolve/4` (`p.key == ^key`, :151), `layer_objects_for_key/2` (:198),
`list_keys_for_subject/1` (select `p.key`, :176), `current_user_object/2` (→ `resolve`).
`objects.key` is read only for lineage/consistency, never on the hot cascade-resolve
path. **⇒ Pointers are the critical migration target; objects migrate too for
consistency (a row whose pointer says `agent.soul` but object says `advisor.behavior`
would be confusing in audits), but the correctness-critical rewrite is the pointer rows
(column + PK).**

### 4.3 Immutability caveat (call out for the reviewer)

`ConfigObject` rows are documented append-only/immutable ("Objects are append-only …
never by mutating this row"). This migration **does** `UPDATE` the `key` column on
existing object rows. That is acceptable for an *operator key-rename* (it changes a
routing label, not the config `body`, and the object id/URI are untouched, so no
materialized projection changes) — but it is a deliberate one-time exception to the
immutability rule and must be stated as such in the migration's moduledoc. The
*pointer* table has no immutability contract (it is the mutable layer), so rewriting it
is unremarkable.

### 4.4 Migration mechanics (non-destructive, forward-only)

A single Ecto migration, all in one transaction, **no destructive `drop`/`delete`**:

```elixir
defmodule EzagentCore.Repo.Migrations.RenameAdvisorBehaviorToAgentSoul do
  use Ecto.Migration
  # One-time exception to ConfigObject immutability: this renames a routing KEY
  # (not a body), object ids/URIs unchanged. Forward-only, idempotent (guarded by
  # WHERE key = 'advisor.behavior'); re-running is a no-op once migrated.
  @old "advisor.behavior"
  @new "agent.soul"

  def up do
    # 1. Objects — plain column.
    execute("""
    UPDATE socialware_config_objects SET key = '#{@new}' WHERE key = '#{@old}'
    """)

    # 2. Pointers — column AND the id PK (id = layer|ws|subject|key).
    #    Rebuild id by string-replacing the trailing key segment. The unique index
    #    (layer,ws,subject,key) guarantees no two rows share the rewritten id, so the
    #    PK rewrite cannot collide.
    execute("""
    UPDATE socialware_config_pointers
       SET key = '#{@new}',
           id  = substr(id, 1, length(id) - length('#{@old}')) || '#{@new}'
     WHERE key = '#{@old}'
    """)
  end

  # Reversible for safety (NOT a data delete — just the inverse rename).
  def down do
    execute("UPDATE socialware_config_objects SET key = '#{@old}' WHERE key = '#{@new}'")
    execute("""
    UPDATE socialware_config_pointers
       SET key = '#{@old}',
           id  = substr(id, 1, length(id) - length('#{@new}')) || '#{@old}'
     WHERE key = '#{@new}'
    """)
  end
end
```

(SQL above is illustrative; the executor decides SQLite-vs-Postgres `substr`/`||`
portability. Both are ANSI; verify against the live adapter before running.)

**Safety properties:**
- **Non-destructive:** only `UPDATE`s; no row is dropped. `down/0` is the exact inverse.
- **`down/0` limitation (state it, not a bug):** `down/0` renames *every* `agent.soul`
  row back to `advisor.behavior`, including any created legitimately AFTER the rename
  ships — it cannot distinguish migrated rows from new ones. This is acceptable only as
  the inverse of the coordinated one-shot (§4.5 strategy 1): a rollback happens inside
  the same maintenance window before new `agent.soul` rows exist. If a rollback is ever
  needed after agents have written fresh `agent.soul` config, `down/0` would over-revert
  them — so a post-window rollback must instead be a forward-fix, not `ecto.rollback`.
- **Idempotent:** the `WHERE key = @old` guard makes a re-run a no-op.
- **No PK collision:** the pointer unique index `(layer, workspace_uri, subject_uri,
  key)` already enforces one row per tuple, so rewriting the embedded-key portion of the
  id yields a still-unique id.
- **Anti-pattern guard (per the destructive-migration rule):** do **not**
  `mix ecto.migrate` this against live dev/prod data without a sandbox dry-run +
  coordination. Run first on the disposable E2E stack with a snapshot/seed, diff row
  counts before/after (`SELECT count(*) … WHERE key = …`), confirm `up` then `down`
  round-trips to byte-identical ids.

### 4.5 Deploy ordering (the coordination the codex review will probe)

Code-rename and data-rename are two events; the gap between them is the risk:

- **Code-first, data-later** → reads default to `agent.soul`, find no rows → agents
  momentarily lose their soul (blank `CLAUDE.md` projection).
- **Data-first, code-later** → rows are `agent.soul` but reads still default to
  `advisor.behavior` → same blank-soul window, inverted.

Two strategies:

1. **Coordinated one-shot (RECOMMENDED here).** Migrate the data, then deploy the code
   that defaults to `agent.soul`, in one maintenance step. Simplest and correct **given
   the current infra reality**: dev/prod docker is decommissioned; the only live data is
   the **disposable E2E stack** (re-seeded each run) + the single-node dev stack. There
   is no multi-node rolling fleet to straddle, so the brief window is a non-issue — and
   on the disposable stack the rows are re-seeded fresh under the new key anyway, so the
   migration is effectively a dev-stack-only concern. **State this assumption explicitly
   when executing**; if it ever stops holding (durable multi-node prod), switch to (2).

2. **Dual-read transition (fallback, NOT recommended now — likely YAGNI).** Make the
   readers try `agent.soul` then fall back to `advisor.behavior` for a transition window;
   deploy → migrate → later PR drops the fallback. Zero-downtime but introduces a
   transitional shim (a let-it-crash/no-workaround smell) for a window that, on
   disposable infra, never matters. Reserve for a future durable-prod scenario.

**Recommendation:** strategy (1), one-shot, with the disposable-infra assumption written
into the migration PR description and the dry-run-on-disposable-stack gate from §4.4.

---

## 5. Execution checklist (for the FUTURE rename PR — not this one)

1. Add `Ezagent.Agent.Config.default_key/0` public accessor returning `@default_key`.
2. Flip `@default_key` (config.ex:13) and `@default_cascade_key` (config_evolve.ex:87)
   to `"agent.soul"`.
3. Repoint `identity_data.ex:754` at `Ezagent.Agent.Config.default_key/0` (kill the
   inline literal).
4. Update the 7 test files (§3.2) to the new key / accessor.
5. Add the forward+reverse data migration (§4.4).
6. Refresh contract docs (§3.3).
7. Dry-run the migration on the disposable E2E stack; diff row counts; verify up/down
   round-trip.
8. Gates: `mix compile --warnings-as-errors --force`, full `mix test`,
   `mix ezagent.check_invariants`, `mix ezagent.arch.scan`.
9. Coordinated one-shot deploy (§4.5 strategy 1).

---

## 6. Open question for the lead

- Confirm strategy (1) coordinated one-shot is acceptable, OR flag any durable
  multi-node prod data that would force the dual-read transition (2).
- Confirm bundling the `identity_data.ex:754` literal→constant refactor into the rename
  PR (recommended, prevents future drift).
