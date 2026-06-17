# CapBAC system-principal audit — "No unowned permissions"

**Date:** 2026-06-16
**Principle (GLOSSARY Decision #154, Allen's words):**

> No unowned permissions: every capability's `granted_by` MUST be a real entity.
> Auto-dispatched permissions are driven by a RULE, and whoever configured the rule is
> the granter of that permission. In the extreme case the granter is the
> `entity://system/user/admin` entity. Abstract `system://…` Catalog principals that are
> not real accountable entities violate this.

**SPEC:** `docs/superpowers/specs/2026-06-16-dynamic-mount-unmount-entity-model.md`
(read from commit `353c259f` — lands with PR #811; not yet on `origin/main`). #153's
manager-delegated grant is the conversion mechanism that lets a real owner/manager entity
grant in place of an abstract principal.

## Method

For each of the 15 `Ezagent.SystemPrincipal.Catalog` principals: read its Catalog inline
rationale + its caps + `grep` its production use-sites, then classify:

- **(A) Conforms** — legitimately admin/boot/operator infrastructure whose honest granter
  IS `system/admin`/operator, OR an entity acting on its own slices (self-authority), OR an
  empty-cap audit identity (no authority to be unowned).
- **(B) Violates** — performs an op that SHOULD trace to a configurer entity (session
  owner / agent creator / rule configurer) but currently rides an abstract principal.
- **needs-Allen** — evidence-grounded lean but a judgment call Allen must adjudicate
  (per the audit standard: unsure → needs-Allen, don't guess).

> **Allen's final ruling (2026-06-16):** all 6 prior needs-Allen entries resolved.
> `agent-internal` → **A** (its `grant_cap` was vestigial and is DROPPED — see below);
> `feishu-binding-policy` → **B** (granter should be the binding configurer/admin;
> conversion is a later PR); the other 4 (`chat-router`, `chat-reply`,
> `orchestrator-tools`, `session-internal`) → **A**. `needs-Allen` is now empty.

**The decisive structural tell for B:** a principal that *mints* permissions —
holds a cap that AUTHORIZES `grant_cap`/`revoke_cap` on `IdentityAdmin` under the
runtime matcher (the codex-P2 refinement: this now catches WILDCARD-shaped caps
like `cap(:user, IdentityAdmin, :any)`, not just the exact `:grant_cap`/`:revoke_cap`
action) — is, by construction, the "unowned `granted_by`" case. After Allen's
ruling + the `agent-internal` drop, exactly **two** principals mint:
`template-materialize` (grant + revoke) and `feishu-binding-policy` (grant) —
both confirmed-B. (The full bootstrap-wildcard sentinel held by `bootstrap` /
`mix-task` / `chat-router` / `chat-reply` also authorizes minting at runtime, but
is governed by the dedicated `no_wildcard_system_principals_test.exs` gate and the
fan-out / operator-trust rationale, so it is excluded from this gate's minter set.)

## Audit table

| principal | category | current use (evidence) | proposed granter / rule |
|---|---|---|---|
| **boot-reconciler** | A | `cap(:session, ExternalMirror, :any)`. Boot reconciliation of session external-mirror bindings (`kind/runtime.ex`, external_mirror). Boot infra; honest granter = boot/admin. | (none — A) |
| **adapter-install** | A | `cap(:session, ExternalMirror, :bind)`. Fires `session.<flavor>.bind` at adapter install (`binding_policy.ex` references it as a closed boot principal). Boot/install infra. | (none — A) |
| **chat-router** | **A (Allen ruled)** | Holds the wildcard cap (open-plugin `:receive` fan-out, `routing/resolver.ex`). Routing fan-out proxy, not a permission minter. Allen ruled A (system message-routing infra, granter = admin). The full bootstrap-wildcard authority is governed by `no_wildcard_system_principals_test.exs` (chat-router is one of the four permitted holders). | (none — A) |
| **chat-reply** | **A (Allen ruled)** | Holds the wildcard cap (same open-plugin `chat.send`/`chat.receive` fan-out, `curl_agent.ex`/`echo.ex`). Fan-out proxy, not minter. Allen ruled A. | (none — A) |
| **worker-publish** | A | `cap(:external_mirror_worker, ExternalMirrorWorker, :publish)` + `cap(:session, PublisherSI, :subscribe_from)`. The ExternalMirror worker acts on ITS OWN bound session's publisher (`external_mirror_worker.ex`). Self-authority — the worker operating on its own slice/binding. | (none — A; self-authority) |
| **template-materialize** | **B (confirmed)** | `cap(:user, IdentityAdmin, :grant_cap)` + `:revoke_cap` + Template/Session/Workspace caps. **Mints** the orchestrator's owner-restart + scoped caps during session-template materialization (`SessionTemplate.create/fork`, `Orchestrator.Caps`). SPEC §1 explicitly names this the workaround that owner/manager-delegation replaces ("granted via `system://template-materialize` with owner as caller instead of the natural 'I manage this, I equip it' authority"). #811's cap#2 is its first removal target. | **grant op:** session owner via manager-delegation (#153). The owner is the manager of the session/orchestrator it created; the owner is the real `granted_by`. (Template-read materialization itself may stay legit system work — only the `grant_cap`/`revoke_cap` minting is the unowned part.) |
| **orchestrator-tools** | **A (Allen ruled)** | `cap(:session, Session, :any)` + `cap(:agent, Identity, :list_caps)`. Loads the orchestrator agent's OWN four delegated caps + writes the session's chat slice (`McpServer.load_orchestrator_caps`). Self-authority (the orchestrator acting via its own MCP tools on its own session). Holds NO `IdentityAdmin` cap → non-minter. Allen ruled A. | (none — A; self-authority) |
| **session-internal** | **A (Allen ruled)** | `cap(:any, Session, :any)` + `cap(:workspace, Workspace, :any)`. Chat fan-out `chat.receive` across User+Agent Kinds + workspace reads (`session.ex`, `legends.ex`). Fan-out/proxy, holds NO `IdentityAdmin` cap → non-minter. Allen ruled A. | (none — A) |
| **agent-internal** | **A (Allen ruled — grant_cap DROPPED)** | NOW holds only `cap(:agent, Sandbox, :write_path)` — self-authority (agent records its own sandbox state, `template_spawn.ex:523`). The `cap(:user, IdentityAdmin, :grant_cap)` it previously held was **vestigial** and is **dropped** (2026-06-16): a repo-wide `git grep` confirms NO live `grant_cap`/`revoke_cap` dispatch ever ran under `system://agent-internal` as caller (the only live use is the `sandbox.write_path` `Sandbox` action). Evidence: `git grep "agent-internal" -- 'apps/**/lib/**' \| grep -i 'grant\|revoke'` returns ONLY the `credential/resolver.ex` codex-H1 guard (a NEVER-read assertion, not a grant), and the single `caller: …uri("agent-internal")` dispatch (`template_spawn.ex:523`) targets `sandbox.write_path`. With the cap dropped, agent-internal is a non-minter → category A. | (none — A; self-authority only after the vestigial-cap drop) |
| **workspace-loader** | A | `cap(:workspace, Workspace, :any)`. Boot-time workspace loading/instantiation (`workspace.ex`, `loader.ex`). Boot infra; honest granter = boot/admin. LiveView surfaces MUST route through it (workspace.ex:121). | (none — A) |
| **mix-task** | A | Wildcard cap, explicitly exempted (operator-driven; in-VM trust model §10.5 — same authority as admin User by deployment contract). Operator IS the real accountable entity (they have shell access). | (none — A; honest granter = operator ≈ `entity://system/user/admin`) |
| **feishu-binding-policy** | **B (Allen confirmed)** | `cap(:user, IdentityAdmin, :grant_cap)` + `cap(:workspace, Workspace, :any)`. **Mints** the bound user's baseline session caps when a Feishu binding is created (`binding_policy.ex`). The *rule* is the admin-authorized binding — and `admin_uri` ("the operator who authorized the bind") ALREADY flows into the policy as `granted_by` attribution + dispatch ctx. So the honest granter is that admin operator, a real entity; the abstract principal is a stand-in. **Allen confirmed B (2026-06-16)** — added to the confirmed-B allowlist; conversion to admin-as-granter is a later PR. | **grant op:** the admin/operator who configured the Feishu binding (already available as `admin_uri`). The binding is the RULE; its configurer is the granter — textbook principle case. |
| **lv-anon-mount** | A | `[]` (empty caps). The §4.4 auth-bug surfacer — deliberately holds NO authority so anonymous LV mount surfaces the missing-auth path (`agent_extensions_live.ex`, `system_principal.ex`). No authority ⇒ nothing to be unowned. | (none — A; empty) |
| **credential-materializer** | A | `[]` (empty caps). Audit identity only (#17 cascade PR-0, codex H1). The least-privilege source-read cap is derived per-grant by `Ezagent.Credential.GrantCap` and passed as dispatch caps; the identity holds NO standing cap. No standing authority ⇒ nothing to be unowned. | (none — A; empty) |
| **socialware-gc** | A | `cap(:session, Session, :leave)`. The in-app GC sweeper reaps abandoned anon-Users by leaving them from their session (`gc.ex`, `sweeper.ex`). The anon-User holds EMPTY caps and CANNOT self-leave (spec §3.3), so a system principal MUST perform the fail-safe leave. **Allen explicitly chose this as a dedicated closed-catalog GC principal (Option A, 2026-06-15)** over ambient/per-session authority — a deliberately-accountable system role, granter = admin/system-by-design. | (none — A; Allen-blessed dedicated GC role) |

## Counts (after Allen's final ruling, 2026-06-16)

- **A (conforms): 13** — boot-reconciler, adapter-install, chat-router, chat-reply, worker-publish, orchestrator-tools, session-internal, agent-internal (after grant_cap drop), workspace-loader, mix-task, lv-anon-mount, credential-materializer, socialware-gc.
- **B (confirmed violates): 2** — template-materialize, feishu-binding-policy.
- **needs-Allen: 0** — Allen ruled all 6 prior entries.

Total = 13 + 2 + 0 = 15 named principals (+ `bootstrap` = 16 Catalog entries). ✓

## Enforcement

The ratchet gate `apps/ezagent_core/test/invariants/no_unowned_system_principal_grant_test.exs`
allowlists the **confirmed-B** set (`template-materialize` + `feishu-binding-policy`) — an
allowlist of 2 that ratchets to 0 as conversions land (#811 cap#2 + #808 anon-access are the
first removals; the feishu + template grant-cap conversions are the next). The minter
predicate uses the RUNTIME matcher (`Capability.matches?/2`) against a concrete
`identity.grant_cap`/`revoke_cap` need, so it catches wildcard-shaped minters (codex P2);
the full bootstrap-wildcard sentinel is excluded (governed by
`no_wildcard_system_principals_test.exs`). `@needs_allen` is now empty — Allen ruled all 6.

## What this PR does / does not do

- **Does:** Decision #154 + this audit + the ratchet gate (green now via the confirmed-B
  allowlist).
- **Does NOT:** convert any principal. Conversions are later PRs (the manager-delegated
  grant of #153/#811 is the mechanism; each conversion shrinks the allowlist toward 0).
