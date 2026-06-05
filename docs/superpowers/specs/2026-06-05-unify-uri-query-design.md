# Unify URI Query — Design Spec (preliminary)

**Status:** preliminary — for codex to complete & implement. Authored 2026-06-05 (Claude), per Allen's direction. Branch/worktree: `unify-uri-query` (off `main` @ 53f3c48b, post `domain_chat → domain_instance_message` rename).

**Goal (one sentence):** A URI is an opaque, stable identifier; every secondary/mutable/creation-time attribute (agent **flavor**, **orchestrator/role**, session **template**) is a STORED attribute fetched through a single query function — code must never parse attributes out of, nor hand-concatenate, URI strings.

**Why now (sequencing):** The acute symptom was the `cc_` orchestrator prefix bug — the orchestrator URI is *re-derived by formula* at 4 sites instead of stored+queried, and the flavor prefix is *load-bearing* because the bridge parses it from the URI. That is one instance of a system-wide anti-pattern. Per [[feedback_systematic_fix_over_local_entropy]]: don't point-patch — locate ALL instances via a test/scan (#30), then fix them in one mechanical pass (#31). The `domain-agent-handoff` rename has already landed on `main`, so this work builds on the final `ezagent_domain_instance_message` paths with no rename conflicts.

---

## 1. The principle / invariant

> **A URI carries only: the immutable structural Kind (scheme + type axis) + a stable opaque `name` + the `workspace` tenant segment. Nothing else.**
>
> All mutable / creation-time / secondary attributes — agent **flavor** (cc/codex/curl), **role** (orchestrator vs member), session **template** association — are STORED on the entity and read through ONE query function. No code may (a) parse such an attribute out of a URI string, nor (b) hand-concatenate a URI to *address* an entity by attribute.

This is the same principle already accepted for identifiers elsewhere: [[feedback_uuid_is_canonical_identifier]] (UUID canonical, username display-only, resolve via a lookup step — never key by the mutable attribute).

### Legitimate vs illegitimate URI content

The finite, legitimate URI shape (already enforced by `Ezagent.URI` + `Ezagent.URI.SchemeRegistry`):

```
<scheme>://<type>/<workspace>/<name>[?action=<behavior>.<action>]
```

The **6 registered schemes** (boot seed, `apps/ezagent_core/lib/ezagent_core/application.ex:185`):
`entity` · `workspace` · `session` · `template` · `resource` · `system`

- `entity://<type>/<ws>/<name>` — `type ∈ {user, agent, worker}` (the Kind; immutable, structural → **OK in URI**)
- `session://<type>/<ws>/<name>` — here `<type>` currently encodes the **session template** → **VIOLATION** (template is a secondary attribute)
- `workspace://<name>`, `template://<type>/<ws>/<name>`, `system://<type>/<name>` — scheme+type are structural → OK

**Two concrete violations of the principle today:**
1. **Agent flavor prefix** — agent `name` is written as `<flavor>_<name>` (e.g. `cc_orchestrator-<disc>`), and `flavor` is parsed back out by consumers.
2. **Session template segment** — `session://<template>/<ws>/<name>` bakes the template into identity (also the open segment-order question, old task #31).

`entity://<type>` keeping the Kind (user/agent/worker) is **not** a violation — that's immutable structure, the thing the URI legitimately routes on.

---

## 2. Storage slots (where the attributes live / will live)

Good news — most slots already exist; the bug is consumers not reading them:

| Attribute | Stored today? | Where | Gap |
|---|---|---|---|
| agent **flavor** | ✅ yes | `AgentTemplate` content `flavor: "cc"` (universal base, SPEC 2026-06-01 flavor-generic-template-data) | consumers parse the URI prefix instead of reading this |
| member **role** | ⚠️ partial | member `:role_name` facet on the chat slice (per-session unique; `behavior/chat.ex`) | no `query(role=…)`; orchestrator not looked up via it |
| **orchestrator** of a session | ❌ no | (re-derived by formula) | **add a stored `orchestrator_uri` field on the session** (single source of truth) |
| session **template** | ✅ yes (assoc known at create) | session working-copy / creation metadata | encoded in URI segment + no clean accessor |

---

## 3. The canonical query/constructor API (target)

Introduce (or consolidate onto) ONE module — proposed `Ezagent.UriQuery` (codex to confirm best home; likely alongside `Ezagent.URI`) — the *only* sanctioned way to obtain an entity URI by attribute or read an attribute from an entity:

- `Ezagent.UriQuery.orchestrator_of(session_uri) :: {:ok, URI.t()} | :none`
  reads the session's stored `orchestrator_uri` (NOT `derive_orchestrator_uri/2`).
- `Ezagent.UriQuery.flavor_of(agent_uri) :: {:ok, String.t()} | {:error, _}`
  reads `AgentTemplate.flavor` (NOT `String.split(name, "_")`).
- `Ezagent.UriQuery.member_by_role(session_uri, role) :: {:ok, URI.t()} | :none`
  reads the `:role_name` facet (generalizes the orchestrator case).
- `Ezagent.URI.new!/1` + `instance/1` / accessors remain the ONLY constructors/部分访问器 for the structural shape.

Everything else becomes a caller of these. No bespoke string building/parsing.

---

## 4. Known violations (audit — new-main paths @ 53f3c48b)

This is the *starting* fix list; #30's scan must find the complete set (do not assume this is exhaustive).

**A. Orchestrator URI re-derived by formula (should read stored `orchestrator_uri`)** — 4 sites:
- `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:369` (`ensure_orchestrator`), `:843` (`derive_orchestrator_uri/2` def), `:866` (`derive_orchestrator_instance_name/1` def)
- `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/session_creator.ex:470` (MCP re-register), `:1167` (ready_meta/status)
- `apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/health.ex:105`
- also `session.ex:370` hardcodes `template://agent/system/cc-orchestrator` (flavor-blind template pin).

**B. Flavor parsed out of the agent URI (should read `AgentTemplate.flavor`)** — bridge-routing hot path:
- `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge.ex:211` `derive_flavor/1` (`String.split(entity_name, "_")`)
- `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/channel.ex:179` `derive_flavor/1`

**C. Flavor parsed/validated/assembled in `<flavor>_<name>` form (audit each — some are legit display, some are addressing):**
- `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/mention_parser.ex` (strips flavor prefix to match `@name`)
- `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex` (parses/validates `<flavor>_<name>`)
- `apps/ezagent_plugin_liveview/.../agent_detail_live.ex`, `agent_extensions_live.ex`, `agent_new_live.ex` (extract flavor for display)
- `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/session_creator.ex:~1530` (`"#{flavor}_#{session_unique}"` assembly)
- cc/echo agent templates validating the prefix; cc-agents file-path layout `<flavor>_<name>/`.

**D. Session template encoded in URI segment** — `session://<template>/<ws>/<name>` (`session.ex:81`, SPEC v3 §3.6) + the segment-order question (old #31).

> Distinguish **display** (showing flavor in a UI label — acceptable if it reads the stored attribute) from **addressing/branching** (deciding behavior by parsing the URI — forbidden). The scan should flag addressing; display sites must switch to reading the stored attribute, not string-parsing.

---

## 5. Approach — two phases (Allen's plan)

### #30 — test-first scan (write the failing test FIRST)
A test/scan that mechanically enumerates violations and FAILS until they're gone. It encodes the invariant so future regressions are caught. Concretely it should:

1. Enumerate the finite legitimate URI forms from `SchemeRegistry` (the 6 schemes + type axes) — single source of truth, not a hardcoded list.
2. **Static scan** of `apps/**/*.ex` (exclude `_test.exs`, exclude the `Ezagent.URI*`/`Ezagent.UriQuery` modules themselves) for:
   - direct attribute parsing from URIs: `String.split` / `String.starts_with?` / regex over a URI's `path`/`host`/instance to extract flavor/role/template;
   - hand-concatenation that *builds an addressing URI* from a flavor/role/template string (`"#{flavor}_..."`, `"cc_orchestrator-" <> ...`, `<> "_orchestrator"`);
   - any call to the to-be-deprecated `derive_orchestrator_uri/2` / `derive_orchestrator_instance_name/1` outside the query module.
3. Assert: every attribute access goes through `Ezagent.UriQuery`; the scan set is **empty**. Until #31, the test enumerates the known offenders as an explicit allowlist that shrinks to zero (so the test is green only when the list is empty).

(Codex: decide the scan mechanism — an ExUnit test that walks files with `Code.string_to_quoted` AST matching is more robust than grep; a grep-based test is acceptable for a first cut if AST is too heavy. Prefer AST.)

### #31 — fix-all in one mechanical pass
Drive every violation the scan finds to zero:
1. Add the stored `orchestrator_uri` field to session state; set it once at create (in `session_creator`), read it everywhere (replace the 4 derive sites). Keep `flavor` stored per-session (already stamped) for the bridge.
2. Repoint `AgentBridge.derive_flavor` → `Ezagent.UriQuery.flavor_of/1` (reads `AgentTemplate.flavor`).
3. Convert C-list display sites to read the stored flavor; convert addressing sites to query.
4. Decide the agent-name shape: drop the `<flavor>_` prefix from new agent URIs → `entity://agent/<ws>/<name>`. **Migration** (below).
5. Session template: stop encoding template in the `session://` type segment (and resolve the segment-order question) — read the stored template assoc. **Migration** (below).
6. Make `derive_orchestrator_uri/*` private/deleted; the scan goes green.

---

## 6. Migration concerns (FLAG — needs care / possibly Allen input)

Dropping `<flavor>_` from agent URIs and the template segment from session URIs **changes existing identities** → existing persisted Kinds, caps (keyed by URI), routing rules, bindings, lineage, file paths all reference the old URIs.

Options (codex to evaluate, Allen to ratify the risky ones):
- **(a) Grandfather**: new entities use the new shape; a one-time data migration rewrites existing URIs across `kind_snapshots`, caps, routing rules, external-mirror bindings, lineage, workspace registry, and on-disk config-dir paths. High blast radius; must be atomic + reversible.
- **(b) New-shape-forward only**: keep old URIs as-is (opaque — the whole point is we no longer parse them), require the stored attributes to be backfilled for existing entities, and only NEW entities adopt the prefix-free name. Lower risk; leaves mixed shapes (acceptable *because* nothing parses them anymore).

Recommendation: lean (b) — it is the minimal change consistent with "URIs are opaque" and avoids a giant destructive migration ([[feedback_destructive_migration_anti_pattern]], [[feedback_let_it_crash_no_workarounds]] — no shims, but also no gratuitous rewrite). The orchestrator `orchestrator_uri` field + flavor-from-AgentTemplate work regardless of old vs new name shape. **Allen to confirm (a) vs (b).**

---

## 7. User-assist / risk flags (per [[feedback_flag_user_assist_steps]])
- **Allen decision**: migration strategy (a) vs (b) in §6.
- **Allen decision**: session URI segment order (old #31) — fix as part of this, or keep template out of URI entirely?
- No live-node hacks; prototype against the throwaday docker dev node only ([[feedback_no_hack_use_cli_on_live_node]]).
- codex companion runs static-only (no `mix` deps) — the AST scan must be runnable, but codex's own verification is static ([[feedback_codex_companion_no_mix]]).

## 8. Verification (the durable invariant test — [[feedback_completion_requires_invariant_test]])
The #30 scan IS the completion gate: it fails while any code parses/concatenates URI attributes and passes only when all access flows through `Ezagent.UriQuery`. Plus: existing suites green; tier2 live Feishu E2E still works (flavor now read from store, not URI).
