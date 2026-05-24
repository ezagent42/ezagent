# Workspace + User mental model — v2 (Allen 2026-05-24 refinement)

> **Status:** SPEC v2 for Allen review (supersedes v1 — `2026-05-24-workspace-user-mental-model.md`). v1 left several OQs open; this v2 incorporates Allen's 2026-05-24 14:02 directive that **collapses magic-link whitelist into workspace creation** and drops `default` entirely.
> **Methodology:** `grill-with-docs` (v1 evidence reused; v2 design choices challenged inline).
> **Operational constraint:** Allen authorized DB wipe — no migration / back-compat required.

---

## 0. The model (after Allen's 2026-05-24 refinement)

### 0.1 Two boot-time entities, period

Boot creates EXACTLY:
- `entity://user/system/admin` — the admin User (URI keeps its current shape; "admin lives in system" is the literal truth, not a workaround)
- `workspace://system` — the system workspace (hidden, holds admin + future admin-equivalent invitees)

No `default` workspace. No seeded operator user. No `registration_domains` AppSetting.

### 0.2 Workspace is the magic-link gate

**Workspace creation IS the magic-link whitelist.** When admin creates a workspace, they specify both:

| Field | What it is |
|---|---|
| `name` | The workspace name (URL slug + display name) |
| `magic_link_rule` | One of: `{:domain, "h2oslabs.com"}` / `{:user_list, ["alice@x.com", "bob@y.com"]}` / `:invite_only` |

**UX shortcut:** when admin picks the domain rule, `name` auto-fills to the domain ("h2oslabs.com" → workspace name "h2oslabs"). Manual override still allowed.

This collapses three previous concepts into one:
- ❌ standalone `registration_domains` AppSetting (deleted)
- ❌ "what's the public-domain policy?" (no longer a question — admin sets per-workspace)
- ❌ "what's the domain↔workspace mapping?" (admin authoritative at creation)

### 0.3 User registration flow

1. **Magic link sent.** Send-side gates on: does the email match ANY existing workspace's `magic_link_rule`? If yes, send. If no, reject ("no workspace accepts this email").
2. **Click magic link.** Token consumed, email verified.
3. **Membership check.** Is the user already a member of some workspace?
   - **Yes** → land in that workspace (current `route_by_email` happy path)
   - **No** → drop into a **workspace-onboarding** page asking:
     - "Join an existing workspace?" (text input — workspace name; backend validates the email matches that workspace's rule)
     - "Or create a new workspace?" (text input — new workspace name + rule shape — admin-equivalent; whether non-admins can do this is OQ-V2-1)
4. **Add to chosen workspace** → land in it.

### 0.4 Cross-workspace admin promotion (`system` membership)

Admin's only special verb: **invite a user from any workspace into `workspace://system`**. Membership in `system` grants admin-equivalent caps via the existing `Ezagent.Capability.cross_workspace?/2` membership path (no separate cap-grant needed — already wired in code per v1 §1.2). The promoted user keeps their original `entity://user/<their-workspace>/<name>` URI; they just gain a membership row in `system`.

---

## 1. What changed from v1

| v1 item | v2 status |
|---|---|
| OQ1 (admin keeps `system/admin` URI?) | ✅ **Resolved** — keep as-is (Allen: "这个用户唯一") |
| OQ2 (fate of existing `default` sessions) | ✅ **Resolved** — DB wipe authorized |
| OQ4 (public-domain policy) | ✅ **No longer a question** — admin sets rule per-workspace; gmail.com isn't special |
| OQ5 (workspace↔domain cardinality) | ✅ **Resolved by design** — admin chooses 1:1 OR 1:N at creation via `magic_link_rule` |
| OQ6 (workspace creation primitive) | ✅ **Resolved** — `/workspaces` create form GAINS the magic_link_rule field; auto-creation on first registration is DROPPED in favor of "user prompts to create via onboarding page" (Allen's flow §0.3 step 3) |
| OQ7 (do operator user / non-admin seed survive?) | ✅ **Deleted** — Allen's model has no `default` user seed; user 0 is admin only |
| OQ8 (does admin cap survive boot?) | ✅ **No change** — admin's `admin_caps/0` (`:any` everything) remains the bootstrap path |

**New OQ:**

- **OQ-V2-1: Can non-admin users create workspaces via the onboarding page?**
  - Option A: yes — any user without a workspace can self-serve. Lowers admin friction. Risk: spam-create.
  - Option B: no — onboarding "create new workspace" requires admin approval (queues a request). Higher friction. Lower risk.
  - Option C: yes-with-rate-limit — first N per email allowed; further requires admin.
  - Allen to decide. Recommend A for V1 (rate limit added later if abuse appears).

- **OQ-V2-2: What's the on-disk representation of `magic_link_rule`?**
  - Stored as JSON in a new `workspaces.magic_link_rule` column? OR
  - As a separate `workspace_magic_link_rules` table (one workspace → many rules — e.g. "accept @h2oslabs.com AND @h2oslabs.io")?
  - Recommend table for extensibility (admin adds 2nd domain without rewriting JSON). Allen to confirm.

- **OQ-V2-3: Does `magic_link_rule` apply at SEND time only, or also at CLICK time?**
  - Send-only: efficient, but a stale token issued before rule change can still consume.
  - Both: defensive, slightly more DB hits.
  - Recommend both (cheap; closes race window).

---

## 2. Gap analysis vs v2 target

The v1 gap table (G1-G8) is now revised:

| # | v2 target | Today's state | PR |
|---|---|---|---|
| **G1** | Boot creates `admin` + `system` only | Boot creates admin + system + `default` + `operator` | PR-C (delete `default` + `operator` seeds) — gated on G3 landing first |
| **G2** | Workspace gains `magic_link_rule` field | Workspace has `name`, `visible`, no rule | PR-A (Workspace schema + Store API + Create form additions) |
| **G3** | Registration flow checks workspace membership; onboarding page if no workspace | `Registration.create_principal/3` hard-codes `entity://user/default/<slug>` | PR-B (registration rewrite + new onboarding LV) — depends on PR-A |
| **G4** | Magic-link SEND gates on workspace rules (not flat `registration_domains` AppSetting) | `session_controller.ex:594` calls `Registration.domain_allowed?/1` which reads flat AppSetting | PR-A2 (rule-evaluation helper) — bundled into PR-A |
| **G5** | Admin can promote any user to `system` membership | No UI; today admin caps come from URI (`entity://user/system/admin`), not membership | PR-D (admin LV: "Promote to system" action; depends on G3 so we have a user list) |
| **G6** | `/workspaces` hides `system` | Fixed ✅ in PR #290 (`fix/workspaces-leak-system`) | DONE |
| **G7** | Auth-boundary pages share CSS | Login has 270 LOC, registration has 25 LOC stripped | PR-E (extract shared auth CSS helper) — INDEPENDENT, can ship any time |
| **G8** | No `default` references anywhere | ~30 files reference `default` | PR-F (cleanup sweep — runs AFTER G1 so the references are dead) |

---

## 3. PR plan

**Sequence (strict dep order):**

```
G6 ──── DONE (PR #290)
G7 ─────────────────────────────── PR-E (independent, any time)

G2 (PR-A) ──→ G3 (PR-B) ──→ G1 (PR-C) ──→ G5 (PR-D)
                  │                              │
                  └──→ G8 (PR-F) ────────────────┘
                       (cleanup, last)
```

### PR-A — Workspace gains `magic_link_rule`

**Scope:** schema + Store API + admin create form.

1. New table `workspace_magic_link_rules` (per OQ-V2-2 recommendation):
   ```
   workspace_uri TEXT FK → workspaces.uri
   rule_type TEXT  -- "domain" | "user_list" | "invite_only"
   rule_value TEXT -- domain string OR JSON array of emails OR null
   created_at, updated_at
   ```
2. `Ezagent.Workspace.Store` gains `add_rule/3`, `list_rules/1`, `remove_rule/2`, `email_matches_rule?/2`.
3. `Ezagent.Workspace` gains `accepts_email?/2` (queries all rules; OR-combined).
4. `WorkspacesLive` create form adds rule-type + rule-value fields; admin-only.
5. Invariant test: 3-domain workspace accepts emails matching ANY of 3 rules + rejects others.

**Risk:** low. New table, new functions; existing code paths unchanged.

### PR-B — Registration flow: membership check + onboarding LV

**Depends on:** PR-A.

**Scope:**
1. `Ezagent.Registration.domain_allowed?/1` → `Workspace.accepts_email?/2` (queries workspaces). Migration removes `registration_domains` AppSetting.
2. `MagicLinkController.consume/2` after `route_by_email`: if the user has no workspace membership → redirect to `/onboarding/workspace` (new LV).
3. New `OnboardingWorkspaceLive`:
   - Shows: "Welcome — pick a workspace"
   - Form 1: join existing (text input → backend validates email matches workspace rule)
   - Form 2: create new (text input + rule-type + rule-value). Gated on OQ-V2-1 decision.
4. On submit → `Workspace.add_member(workspace_uri, user_uri)` + spawn user Kind with workspace-derived URI `entity://user/<workspace_name>/<slug>`.
5. Invariant test: register `alice@h2oslabs.com` → onboarding → join `h2oslabs` → user URI = `entity://user/h2oslabs/alice`.

**Risk:** medium. Touches the auth-boundary path that already has UX bugs; need to be careful with flash + back-button flows.

### PR-C — Delete `default` workspace + `operator` user seeds

**Depends on:** PR-B (registration flow no longer hard-codes `default`).

**Scope:**
1. `ezagent_domain_chat/application.ex:252-253` — remove `ensure_workspace("default", %{})`.
2. `ezagent_domain_identity/application.ex:227-284` — remove `ensure_default_non_admin_user/0`.
3. Test fixtures that depend on `default` workspace existing → swap to test-created workspace per setup.
4. Invariant test (post-PR): boot test env → `Workspace.list_all/0` returns exactly `[system]`.

**Risk:** medium-high. Many test fixtures assume `default` exists. Audit phase needed.

### PR-D — Admin "Promote to system" action

**Depends on:** PR-B (so we have a user listing UI).

**Scope:**
1. `admin_live.ex` (or a new sub-LV under `/admin/users`) — gain a "Promote to system" button per user row, admin-only.
2. Backend: `Ezagent.Workspace.add_member("workspace://system", user_uri)` + log to AuditAuthz.
3. Invariant test: non-admin user promoted to system → `cross_workspace?(user_uri, target_ws)` returns true → user can dispatch on other workspaces.

**Risk:** low. Single button + dispatch path; existing `cross_workspace?/2` already supports membership-derived authority.

### PR-E — Unify auth-boundary CSS

**Independent of all above** — ship any time.

Scope per v1 PR-2: extract 270-LOC CSS from `session_controller.ex` to a shared helper; rewrite `registration_controller.ex` to use it. Add visual regression test (snapshot of rendered HTML).

### PR-F — `default` cleanup sweep

**Depends on:** PR-C.

Scope: grep `default` across `apps/`, `docs/`, `test/`; categorize each reference; delete dead ones, update live ones to target user's actual workspace.

**Risk:** high but mechanical. Single PR with a big diff but small per-file changes.

---

## 4. Sequencing recommendation for Allen

**Immediate (no OQ blocked):**
- PR-E (auth CSS unify) — Allen's Q1 was about this; ship independently.

**After Allen confirms OQ-V2-1 + OQ-V2-2:**
- PR-A → PR-B → PR-C → PR-D → PR-F (strict order; ~2-3 sessions to ship all)

**Total scope:** 5 PRs (excluding PR-F which is mechanical cleanup) + 1 already-merged (PR #290).

---

## 5. What I'm asking Allen now

1. **OQ-V2-1:** non-admins create workspaces via onboarding? (A/B/C — I recommend A)
2. **OQ-V2-2:** magic_link_rule shape — column or table? (I recommend table)
3. **OQ-V2-3:** rule check at send-time only, or both send+click? (I recommend both)
4. **Sequencing:** ship PR-E independently NOW, or batch with PR-A?
5. **Other rule types:** is `{:user_list, [...]}` + `:invite_only` + `{:domain, ...}` enough, or do we want more (e.g. `:any_authenticated`, IP-range, github-org membership)?

Once 1-3 are answered, I implement PR-A → PR-B in one branch (they're tightly coupled) and PR-C as a follow-up.
