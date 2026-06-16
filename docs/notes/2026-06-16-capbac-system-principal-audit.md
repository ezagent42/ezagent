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

**The decisive structural tell for B:** a principal that *mints* permissions —
holds a `cap(_, IdentityAdmin, :grant_cap | :revoke_cap)` — is, by construction, the
"unowned `granted_by`" case. Exactly three principals do: `template-materialize`
(grant + revoke), `agent-internal` (grant), `feishu-binding-policy` (grant).

## Audit table

| principal | category | current use (evidence) | proposed granter / rule |
|---|---|---|---|
| **boot-reconciler** | A | `cap(:session, ExternalMirror, :any)`. Boot reconciliation of session external-mirror bindings (`kind/runtime.ex`, external_mirror). Boot infra; honest granter = boot/admin. | (none — A) |
| **adapter-install** | A | `cap(:session, ExternalMirror, :bind)`. Fires `session.<flavor>.bind` at adapter install (`binding_policy.ex` references it as a closed boot principal). Boot/install infra. | (none — A) |
| **chat-router** | needs-Allen | Holds the wildcard cap (open-plugin `:receive` fan-out, `routing/resolver.ex`). Acts as a routing fan-out proxy, not a permission minter. Lean A (system message-routing infra, granter = admin), but it carries admin-equivalent wildcard authority for an open plugin set — Allen should confirm whether a routing fan-out is "real accountable infra" or wants a real configurer (the rule author). | If B: granter = the routing-rule configurer entity (the admin/owner who added the routing rule that drives the fan-out — exactly the principle's "whoever configured the RULE"). |
| **chat-reply** | needs-Allen | Holds the wildcard cap (same open-plugin `chat.send`/`chat.receive` fan-out, `curl_agent.ex`/`echo.ex`). Same reasoning as chat-router — fan-out proxy, not minter. Lean A. | If B: granter = the rule configurer / replying agent's creator. |
| **worker-publish** | A | `cap(:external_mirror_worker, ExternalMirrorWorker, :publish)` + `cap(:session, PublisherSI, :subscribe_from)`. The ExternalMirror worker acts on ITS OWN bound session's publisher (`external_mirror_worker.ex`). Self-authority — the worker operating on its own slice/binding. | (none — A; self-authority) |
| **template-materialize** | **B (confirmed)** | `cap(:user, IdentityAdmin, :grant_cap)` + `:revoke_cap` + Template/Session/Workspace caps. **Mints** the orchestrator's owner-restart + scoped caps during session-template materialization (`SessionTemplate.create/fork`, `Orchestrator.Caps`). SPEC §1 explicitly names this the workaround that owner/manager-delegation replaces ("granted via `system://template-materialize` with owner as caller instead of the natural 'I manage this, I equip it' authority"). #811's cap#2 is its first removal target. | **grant op:** session owner via manager-delegation (#153). The owner is the manager of the session/orchestrator it created; the owner is the real `granted_by`. (Template-read materialization itself may stay legit system work — only the `grant_cap`/`revoke_cap` minting is the unowned part.) |
| **orchestrator-tools** | needs-Allen | `cap(:session, Session, :any)` + `cap(:agent, Identity, :list_caps)`. Loads the orchestrator agent's OWN four delegated caps + writes the session's chat slice (`McpServer.load_orchestrator_caps`). Lean A (the orchestrator acting via its own MCP tools on its own session — self-authority), but the Session `:any` write is broad — Allen to confirm self-authority vs needs a real granter. | If B: granter = the orchestrator agent's creator / session owner. |
| **session-internal** | needs-Allen | `cap(:any, Session, :any)` + `cap(:workspace, Workspace, :any)`. Chat fan-out `chat.receive` across User+Agent Kinds + workspace reads (`session.ex`, `legends.ex`). Fan-out/proxy, not a minter. Lean A. | If B: granter = the session owner / rule configurer driving the fan-out. |
| **agent-internal** | needs-Allen (strong B-lean) | `cap(:user, IdentityAdmin, :grant_cap)` + `cap(:agent, Sandbox, :write_path)`. The `:write_path` half is self-authority (agent records its own sandbox state, `template_spawn.ex:521`). **But it also holds `grant_cap`** — it mints a User cap during agent spawn. The minting half is the unowned case (the honest granter is the agent's creator, not an abstract principal). Allen to rule whether to split the minting cap out for conversion. | **grant op:** the agent creator entity (the User/owner who spawned the agent) via manager-delegation. The `:write_path` self-authority cap stays A. |
| **workspace-loader** | A | `cap(:workspace, Workspace, :any)`. Boot-time workspace loading/instantiation (`workspace.ex`, `loader.ex`). Boot infra; honest granter = boot/admin. LiveView surfaces MUST route through it (workspace.ex:121). | (none — A) |
| **mix-task** | A | Wildcard cap, explicitly exempted (operator-driven; in-VM trust model §10.5 — same authority as admin User by deployment contract). Operator IS the real accountable entity (they have shell access). | (none — A; honest granter = operator ≈ `entity://system/user/admin`) |
| **feishu-binding-policy** | needs-Allen (strong B-lean) | `cap(:user, IdentityAdmin, :grant_cap)` + `cap(:workspace, Workspace, :any)`. **Mints** the bound user's baseline session caps when a Feishu binding is created (`binding_policy.ex`). The *rule* is the admin-authorized binding — and `admin_uri` ("the operator who authorized the bind") ALREADY flows into the policy as `granted_by` attribution + dispatch ctx. So the honest granter is that admin operator, a real entity; the abstract principal is a stand-in. Strong B-lean; Allen to confirm converting to the admin-as-granter. | **grant op:** the admin/operator who configured the Feishu binding (already available as `admin_uri`). The binding is the RULE; its configurer is the granter — textbook principle case. |
| **lv-anon-mount** | A | `[]` (empty caps). The §4.4 auth-bug surfacer — deliberately holds NO authority so anonymous LV mount surfaces the missing-auth path (`agent_extensions_live.ex`, `system_principal.ex`). No authority ⇒ nothing to be unowned. | (none — A; empty) |
| **credential-materializer** | A | `[]` (empty caps). Audit identity only (#17 cascade PR-0, codex H1). The least-privilege source-read cap is derived per-grant by `Ezagent.Credential.GrantCap` and passed as dispatch caps; the identity holds NO standing cap. No standing authority ⇒ nothing to be unowned. | (none — A; empty) |
| **socialware-gc** | A | `cap(:session, Session, :leave)`. The in-app GC sweeper reaps abandoned anon-Users by leaving them from their session (`gc.ex`, `sweeper.ex`). The anon-User holds EMPTY caps and CANNOT self-leave (spec §3.3), so a system principal MUST perform the fail-safe leave. **Allen explicitly chose this as a dedicated closed-catalog GC principal (Option A, 2026-06-15)** over ambient/per-session authority — a deliberately-accountable system role, granter = admin/system-by-design. | (none — A; Allen-blessed dedicated GC role) |

## Counts

- **A (conforms): 8** — boot-reconciler, adapter-install, worker-publish, workspace-loader, mix-task, lv-anon-mount, credential-materializer, socialware-gc.
- **B (confirmed violates): 1** — template-materialize.
- **needs-Allen: 6** — chat-router, chat-reply, orchestrator-tools, session-internal, agent-internal (strong B-lean), feishu-binding-policy (strong B-lean).

Total = 8 + 1 + 6 = 15. ✓

## Enforcement

The ratchet gate `apps/ezagent_core/test/invariants/no_unowned_system_principal_grant_test.exs`
allowlists ONLY the **confirmed-B** set (`template-materialize`) — an allowlist of 1 that
ratchets to 0 as conversions land (#811 cap#2 + #808 anon-access are the first removals).
The 6 needs-Allen principals are carried in a SEPARATE manifest the gate tracks (so a 16th
principal forces a classification entry) but does NOT conflate with B: Allen moves each
needs-Allen → A (drop from the manifest) or → B (add to the allowlist, then convert).

## What this PR does / does not do

- **Does:** Decision #154 + this audit + the ratchet gate (green now via the confirmed-B
  allowlist).
- **Does NOT:** convert any principal. Conversions are later PRs (the manager-delegated
  grant of #153/#811 is the mechanism; each conversion shrinks the allowlist toward 0).
