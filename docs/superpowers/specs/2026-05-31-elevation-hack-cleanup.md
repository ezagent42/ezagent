# SPEC — Privilege-elevation HACK cleanup (Class A fixed; Class B staged)

**Status:** r1 — 2026-05-31. Class A IMPLEMENTED + tested in this branch
(`fix/elevation-hack-cleanup`). Class B is a per-site disposition + staged
follow-up plan (no blind swaps).

**Trigger:** independent codex audit of the elevation surface. The action
axis (`Ezagent.Capability.action`, 5th `matches?/2` dimension) is already
merged (SPEC `2026-05-27-capability-action-axis.md`), so cross-action
over-grants are now *expressible* — this SPEC closes the remaining
predicate / principal gaps the audit found.

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — no shims; for genuine internal
  steps the fix is a *narrow internal action cap*, NOT removing elevation
  and NOT a workaround/default/whitelist.
- `feedback_register_lookup_key_parity` — when a routing/cap key changes,
  audit BOTH sides.
- `feedback_completion_requires_invariant_test` — each behavioral change
  earns a regression test that fails when the elevation reopens.

---

## 1. Problem in one paragraph

Capability checks at dispatch step 5.5 (`Ezagent.Kind.Runtime.authz_check/5`)
read **`ctx.caps`** as the authority source; the `ctx.caller` URI is used
only for provenance (`granted_by`) and the owner-match shortcut in
`Identity.check_grant_authorized/2`. So any call site that supplies
`caps: SystemPrincipal.caps("system://template-materialize" | "…session-internal")`
authorizes the dispatch regardless of what the *caller* actually holds. Two
distinct shapes appear in the codebase:

- **(H) Hack shape** — `caller:` is a REAL user/agent URI but `caps:` is a
  system-principal wildcard. The user performs a privileged mutation
  (cap-grant / template-instantiate / member-join) without holding any
  narrow action-scoped cap.
- **(L) System-acting-as-itself** — `caller:` is the system principal URI
  itself (`SystemPrincipal.uri("template-materialize")`). The system
  machinery performs a *structural consequence* of an
  already-authorized operation (e.g. granting a new member the
  `:create_session` cap after `add_member` succeeded). `granted_by` records
  provenance separately.

Shape (L) is legitimate per the LEGITIMATE list (system acting as itself).
Shape (H) is the elevation the audit targets — BUT for every (H) site found,
the real caller is a regular user/orchestrator that **does not hold** the
narrow grant/instantiate authority, so a blind swap to "caller's narrow cap"
yields `:unauthorized` and breaks the flow. These are genuine internal
materialization steps, not blind-swappable.

## 2. Class A — notifications admin-exemption (IMPLEMENTED this branch)

`Ezagent.NotificationSubscriptions.notifications_admin?/1`
(`apps/ezagent_core/lib/ezagent/notification_subscriptions.ex`) gated
subscription administration (register / unregister on behalf of ANOTHER
user) on `behavior: Ezagent.Behavior.Notifications, workspace_uri: :any`
with **no action axis**. `Behavior.Notifications` declares two actions:
`:notify` (a plugin pushing a notification INTO an inbox) and `:subscribe`
(LV / admin reading a user's notification stream). A holder of a
`:notify`-scoped cross-workspace cap therefore qualified as a *subscription
administrator* — cross-action elevation.

**Fix (shipped):** require `action: :subscribe` in the predicate. Admin over
subscriptions IS the `:subscribe` action axis. Per SPEC
`2026-05-27-capability-action-axis` §3.6.1, admin predicates match the
action axis EXPLICITLY (no missing-key `:any` tolerance — that tolerance is
matcher-boundary-only). The three callers (`register` ~461, `unregister`
~527, and the `subscribe`/`unsubscribe` wrappers via the same predicates)
inherit the fix.

**Tests (shipped):** `notification_subscriptions_test.exs`
- `notifications_admin_cap/0` fixture updated to carry `action: :subscribe`.
- New `notify_only_cap/0` fixture (`action: :notify`, cross-workspace).
- New describe block "action-axis admin-exemption" — a `:notify`-only cap is
  denied admin on unregister / register / subscribe-on-behalf; the
  `:subscribe` wildcard remains a valid admin (positive control).
- Result: `63 tests, 0 failures` (incl. the 4 new + the pre-existing
  "narrow cross-workspace cap (non-Notifications) does NOT count as admin").

## 3. Class B — per-site disposition

### 3.1 Already (L) — `caller:` is the system principal (NOT the hack shape)

These were migrated to `caller: SystemPrincipal.uri(...)` in a prior caps
pass; `granted_by` carries the operator/owner provenance separately. They
are the LEGITIMATE "system acting as itself" pattern and are **NOT touched**.

| Site | caller | Note |
|---|---|---|
| `behavior/workspace.ex:1301,1310` | `uri("template-materialize")` | post-`add_member` `:create_session` grant — the *breadth* concern (action over-grant) is already closed (`action: :create_session`); the residual concern is the cap matching extra actions, tracked as the PR #408 over-grant in `docs/futures/todo.md`, independent of this audit. |
| `orchestrator/tools.ex:1448` | `uri("template-materialize")` | save-template owner-cap grant (template materialization side-effect). |
| `entity/session_template.ex:352` | `uri("template-materialize")` | opts-less `system_ctx/0`. |
| `entity/session_template.ex:638` | `uri("template-materialize")` | owner `:within_workspace` template cap grant. |
| `entity/session.ex:542` | `uri("session-internal")` | member sync (`chat.join`). |
| `entity/session.ex:2078,2174` | `uri("template-materialize")` | template content / agent flavor READ during materialization. |
| `behavior/template.ex:731` | `uri("template-materialize")` | fork owner-cap grant. |
| `template/generic_session.ex:135` | `uri("template-materialize")` | GenericSession member join during instantiation. |

**Reasoning:** the principal performing the dispatch IS the system (template
materializer / session-internal sync). There is no real-user impersonation —
`caller == caps' principal`. The audit's per-site notes (which described
several of these as "real user URI as caller") predate this migration; the
code on this branch already has the system URI as caller.

### 3.2 (H) Real-user-caller + system-caps — genuine internal steps, NOT blind-swappable

For each: the real caller does NOT hold the narrow cap, so the swap recommended
by the audit would `:unauthorized`. Verified against the actual grant flow.

| Site | caller | What it does | Why the swap fails |
|---|---|---|---|
| `ezagent_domain_chat.ex:598` | `owner_uri` | grant owner an ownership cap at session-create | a fresh session owner holds only `default_caps` (session-scoped chat) + a self-Identity cap — NOT `IdentityAdmin :grant_cap` on their own User Kind, NOR `Workspace`-admin authority that `check_grant_authorized` re-checks. Step 5.5 + the in-handler check both need the grant authority the owner lacks. |
| `ezagent_domain_chat.ex:643` | `creator_uri` | creator `chat.join` (member sync) | needs `Chat :join` on the session; the creator is being *added as a member* — they don't yet hold a session-scoped `:join` cap. This is the bootstrap of their own membership. |
| `entity/session.ex:1215` | `orchestrator_uri` | `template.instantiate` of workers | orchestrator holds `Template :any` `{:within_workspace}` (cap #3/#4) **only when the session owner held template caps** (see `delegable_template_caps/2`). For default sessions (owner without template caps) the orchestrator was NOT delegated #3/#4 — swapping to the orchestrator's caps breaks the common case. |
| `entity/session.ex:1687,1755` | `owner_uri` | grant owner `OrchestratorAdmin :restart` (audit: MOST exploitable) | same as `:598` — owner lacks `IdentityAdmin :grant_cap`. The cap being granted is a *self-grant* to the owner; authority to grant it is the system's, performed during materialization. |
| `behavior/chat.ex:823` | `owner_uri` | first-join owner `OrchestratorAdmin :restart` grant (legacy fallback) | same authority gap as `:1687`. `mode: :cast` already (deadlock avoidance). |
| `ezagent_web/.../home_live.ex:182` | `caller_uri` | wizard echo-join (`chat.join` for the echo agent) | the LV user is not joining themselves — they're adding the *echo agent* as a member. The user holds no `Chat :join` cap for the echo agent on that session. |
| `plugin_liveview/admin_live.ex:1214` | `socket.assigns.caller_uri` | UI `template.instantiate` (orchestrator restart) | same as `session.ex:1215` — the LV user typically lacks `Template :instantiate`; the restart is a system materialization action surfaced through a (separately cap-gated) UI button. |

**The audit's CRITICAL caveat applies in full here.** Each of these is an
internal materialization / bootstrap step. The defensible cleanup is NOT to
remove elevation, but to replace the BROAD `template-materialize` /
`session-internal` wildcards with **dedicated narrow internal action caps**
— which is a *catalog* change, not a per-site swap.

### 3.3 Real authority check today (verified)

- **Step 5.5** (`runtime.ex:357-368`): `granted_via_ctx_caps?` first, then
  `granted_via_holds_cap?` (caller's `:identity` slice). `caller` is NOT the
  authority — `ctx.caps` is.
- **`Identity.check_grant_authorized/2`** (`identity.ex:457-509`): a SECOND
  gate inside `grant_cap`. `caller == data_owner` shortcut, else
  `holds_admin_caps?(ctx)` / `holds_workspace_admin_cap?(ctx, ws)`. The
  `template-materialize` principal satisfies this via its
  `cap(:workspace, Workspace, :any)` row.
- **`check_action_wildcard_grant_authorized/2`** (`identity.ex:435-449`):
  rejects `action: :any` grants from non-admins UNLESS the instance is
  scope-bounded (`:within_session` / `:within_workspace` / `:spawned_by`).
  The owner-cap grants at (H) sites use concrete actions
  (`OrchestratorAdmin :restart`) or scope-bounded `:any`, so they pass.

## 4. Staged follow-up — narrow the internal principals (deferred, with rationale)

The structurally-correct cleanup for the (H) sites is to split the two broad
wildcard principals into purpose-named, action-narrow internal principals,
so a future drift can't silently widen them. This is **deferred** (NOT done
in this branch) because:

1. It is a `SystemPrincipal.Catalog` change — adding a row requires a
   dedicated PR + SPEC table update + the `no_wildcard_system_principals`
   invariant gate review (per the Catalog moduledoc contract).
2. The `template-materialize` principal's `cap(:any, Template, :any)` /
   `cap(:session, Chat, :any)` / `cap(:workspace, Workspace, :any)` are each
   consumed by MULTIPLE (L) sites; narrowing them needs a register/lookup
   parity audit across all consumers (`feedback_register_lookup_key_parity`)
   to avoid silently breaking the materialization fan-out.
3. The Catalog moduledoc (lines 61-68) still claims "the cap struct doesn't
   carry an `:action` field" — this is STALE post-action-axis. The catalog
   caps DO now carry `action: :any` (via `cap/3`). Fixing the moduledoc +
   re-justifying each `:any` against the action axis is a prerequisite for
   the narrowing and is itself a reviewable change.

### 4.1 Proposed target shape (for the follow-up PR)

| Today | Narrowed internal principal | Caps |
|---|---|---|
| `system://template-materialize` (4 broad caps) | `system://template-grant-owner` | `cap(:user, IdentityAdmin, :grant_cap)` + `cap(:workspace, Workspace, :grant_session)` — for the owner-cap grant sites only |
| | `system://template-instantiate` | `cap(:any, Template, :instantiate)` + `cap(:agent, Template, :read)` — for the worker-instantiate sites |
| `system://session-internal` (2 broad caps) | `system://session-member-sync` | `cap(:session, Chat, :join)` + `cap(:session, Chat, :leave)` — for member-join sync only |

Each (H) site then references the *purpose-narrow* principal instead of the
catch-all wildcard. The elevation is preserved (these are genuine internal
steps), but the blast radius of any single principal shrinks from "all
Template + Chat + Workspace actions" to "exactly the actions this step
performs". The `Workspace :create_session` over-grant currently tracked in
`docs/futures/todo.md` is the same class and should be folded into the same
PR.

### 4.2 Invariant test for the follow-up (completion gate)

Per `feedback_completion_requires_invariant_test`: a catalog audit test that
asserts NO internal principal used by a materialization site carries an
`action: :any` cap on a multi-action Behavior unless the consuming site
demonstrably needs every action. Concretely: extend
`system_principal_catalog_action_audit_test.exs` (the C2 gate from the
action-axis SPEC) to flag any `action: :any` Behavior-wildcard whose
principal is referenced from a (H) site, requiring an explicit allowlist
entry with a one-line justification. The test fails when a new broad cap is
added to a materialization principal without justification.

## 5. What this branch ships vs defers

**Ships (this branch):**
- Class A predicate fix + 4 regression tests (Section 2).

**Defers (this SPEC documents; separate PR):**
- Class B internal-principal narrowing (Section 4) — a catalog + multi-site
  PR, gated by the moduledoc correction + the parity audit + the C2 test
  extension.

**Explicitly NOT done (would break flows / violate let-it-crash):**
- Blind swap of (H) sites to "caller's narrow cap" — the caller provably
  lacks that cap (Section 3.2), so the swap is `:unauthorized`, not a fix.
- Removing elevation from (L) sites — they are the system acting as itself.

## 6. Risks / failure modes

| Failure | Disposition |
|---|---|
| Class A tightening denies a legitimate admin | The admin's subscription-admin cap is now `:subscribe`-scoped; the only callers are LV self-subscribe (caller == entity, never the admin path) — verified no production caller passes a `:notify` admin cap. Positive-control test guards the real admin path. |
| Follow-up narrowing breaks a materialization fan-out | Mitigated by the §4.1 parity audit + the §4.2 C2 test; staged behind a dedicated PR, never a silent in-place edit. |
| Catalog moduledoc stays stale | Flagged in §4 as a prerequisite for the follow-up; not load-bearing for Class A. |
