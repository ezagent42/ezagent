# W0 — session-listing tenant isolation (login-landing leak)

Branch: `fix/w0-session-listing-capbac` · Date: 2026-07-03

## The bug (verified on `main`)

`EzagentWeb.HomeLive.mount_authenticated/2` used the **global**
`EzagentDomainInstanceMessage.list_sessions/0`
(`KindRegistry.list_all()` across every tenant) as the login-landing判据:

- `[]` → render the first-login wizard
- `[_ | _]` → redirect `/sessions` (returning-user path)

Because the list is global, a freshly-logged-in operator whose **own**
workspace has **zero** sessions was bounced to `/sessions` (and treated as a
returning user) merely because **some other tenant** had a session. Two
defects in one:

1. **Wrong landing** — the empty-workspace operator never sees the wizard.
2. **Cross-tenant existence leak** — the redirect reveals that *another*
   tenant owns at least one session.

A workspace-scoped `list_sessions/1` (filters the registry by the session
URI's workspace authority segment — Task #55, 2026-05-27) **already existed**;
`HomeLive` simply called the wrong (global) arity.

## Threat model

Multi-tenant. Tenant A must not learn that Tenant B has any session, and must
land on the wizard when A owns nothing in its own workspace.

## Approaches considered

| Option | What | Trade-off |
|---|---|---|
| **A. Workspace-scope (chosen)** | Scope the landing判据 to the caller's workspace via the existing `list_sessions/1`. | Minimal; reuses the proven isolating arity; landing matches exactly what `/sessions` renders (also workspace-scoped). Closes the security hole fully. |
| B. Per-entity membership | Count only sessions where THIS entity is a member. | Stronger, but (a) no such filter exists (would need a new entity-membership scan), (b) **diverges** from what `/sessions` shows → inconsistent landing, (c) the reported leak is cross-*tenant*, which workspace-scope already closes. |
| C. Cap-gate the listing | Make listing a CapBAC-gated read. | Inconsistent with the rest of the system: `world_live`/`admin_data` treat listing as a **structural workspace filter**, not a dispatch chokepoint. Heavier; no precedent; over-altitude for a landing判据. |

**Chosen: A.** Workspace = tenant boundary (invariants #4, #13, #14). The
security fix does **not** depend on the membership-vs-workspace product
question (see Open questions).

## The fix

`apps/ezagent_web/lib/ezagent_web/live/home_live.ex`:

- `mount_authenticated/3` now derives a **landing workspace** and calls
  `EzagentDomainInstanceMessage.list_sessions(workspace_uri)` (the `/1`
  overload) instead of `/0`.
- **Landing workspace** = the session's SELECTED `current_workspace_uri`
  when present (matches what `/sessions` renders — including a **system
  member who context-switched**, §6.5/§13.2), else the caller entity's home
  workspace via `Ezagent.Capability.workspace_of/1`.
- **Fail-closed**: a non-workspace result (`:any` for `system://`/unknown
  schemes, or a malformed cookie) yields `[]` → the wizard, never a global
  scan and never a crash (the caller guards on `%URI{scheme: "workspace"}`,
  so `list_sessions/1`'s workspace-only clause can never be hit with `:any`).

### CapBAC model

Listing stays a **structural workspace filter**, not a cap-gated dispatch —
consistent with `world_live`/`admin_data`, which already scope by workspace
without a per-item cap check. No new CapBAC surface was added.

## All callers of `list_sessions/0` (audited)

| Caller | Arity | Action |
|---|---|---|
| `home_live.ex` (login landing) | `/0` → **`/1`** | **FIXED** (this PR) |
| `presence_fanout.ex:107` (member-index bootstrap) | `/0` | **Left global** — internal system index, not user-facing; the moduledoc sanctions `/0` for batch/CI enumeration across tenants. |
| `admin_data.ex:158` (world overview) | `/1` | Already workspace-scoped (correct). |
| `world_live.ex` (session sidebar) | `/1` | Already workspace-scoped (correct). |
| Tests | `/0` and `/1` | Unchanged; new regression added. |

`list_sessions/0` is **kept** (still needed by `presence_fanout` + CI/batch).

## Regression test

`apps/ezagent_web/test/ezagent_web/live/home_live_test.exs` —
"GET / scopes the landing judgment to the caller's workspace (no cross-tenant
leak)": a tenant-`w0iso` operator (its workspace owns **zero** sessions) while
the boot-seeded `session://system/default/main` lives in the **distinct**
`system` workspace must land on the **wizard**.

- **On the old `/0` code**: the system seed makes the global list non-empty →
  `{:error, {:live_redirect, %{to: "/sessions"}}}` → the `{:ok, _lv, html}`
  match raises. **Verified failing** on the reverted code (gate proven).
- **On the fix**: workspace-scoped list is `[]` → wizard renders. Green.

Full `home_live_test.exs`: **5 tests, 0 failures**. Compiles clean under
`--warnings-as-errors`.

## Codex adversarial-review (static, read-only)

Ran `codex exec -s read-only` against the design + the two code locations +
threat model. Verdict and disposition:

| Finding (codex) | Severity | Disposition |
|---|---|---|
| `:any` (`system://`/unknown) not fail-closed → `list_sessions/1` crash | MEDIUM | **Folded in** — mount guards on `%URI{scheme: "workspace"}`, `:any`/nil → `[]` → wizard. |
| Landing scope should match `/sessions`' SELECTED workspace, not just entity home (system-member context switch) | MEDIUM | **Folded in** — prefer session `current_workspace_uri`, fall back to entity home. |
| `agent_live_sessions/1` preflight in `world/agent_actions.ex` leaks session count+names for a forged cross-workspace agent URI (no authz before preflight) | HIGH | **Reported, not fixed here** — adjacent surface (agent-delete authz), distinct fix; not a `/0` caller. See Follow-ups. |
| Malformed-cookie → `parse_entity_uri` admin fallback → `workspace://system` landing / wizard-as-admin | HIGH | **Reported, not fixed here** — **pre-existing** auth-model behavior (old code also admin-fell-back + redirected); belongs to `LiveAuth`, not this W0 fix. My change is fail-closed and no worse. |
| Anon (socialware) principal could land on `/` and see workspace peers | HIGH | **Not currently reachable** — anon uses a separate signed `socialware_anon` cookie and does **not** write the Phoenix `current_entity_uri` slot. My change strictly **improves** the hypothetical (old `/0` would leak ALL tenants' sessions to such an anon; scoped code leaks at most the anon's own workspace). Reported. |
| `/1` still global-scans then filters → timing/load side-channel proportional to all tenants | MEDIUM | **Reported, not fixed here** — closes the content/redirect leak (the actual W0 bug); a timing side-channel on existence needs a workspace-indexed registry query (a `KindRegistry` change). Hardening follow-up. |

## Follow-ups (not in this PR)

1. **`agent_live_sessions/1` preflight authz** (`world/agent_actions.ex`) —
   gate the caller's authority over `agent_uri` **before** the live-session
   preflight; today a forged cross-workspace agent URI can read session
   count + names. Own fix + regression.
2. **`HomeLive` malformed-cookie handling** — `HomeLive` is in the public
   live_session and treats any binary `current_entity_uri` as authenticated,
   with an admin fallback on parse failure. Consider routing malformed/stale
   cookies to `/login` in `LiveAuth` rather than tolerating them at `/`.
3. **Workspace-indexed `list_sessions/1`** — eliminate the global scan (and
   its existence timing side-channel) with a per-workspace registry index.

## Cross-domain login-cookie finding (report only — no code change)

`config/config.exs:50` sets `session_cookie_domain: ".ezagent.chat"`, so the
Phoenix session cookie is shared across **all** `*.ezagent.chat` subdomains
(`app.` / `world.` / `nightly.` / `beta.` / `stable.`). This is **deliberate**
for same-env `app.`↔`world.` operator SSO. Cross-*env* auth isolation
(login on `app` must NOT authenticate you on `nightly`) hinges entirely on
each env deploying a **distinct `SECRET_KEY_BASE`** — a cookie only verifies
where the signing secret matches.

Repo evidence:

- `config/runtime.exs:64` reads `SECRET_KEY_BASE` from env (raises if missing
  in `:prod`). Not committed.
- `docker/entrypoint.prod.sh:55-62` — if the env var is absent, it
  **auto-generates and persists** a secret at
  `${EZAGENT_HOME}/${EZAGENT_PROFILE}/runtime/secret_key_base`.
- `docker/docker-compose.yml` (the parameterized stack **shared** by
  nightly/beta/stable) sets `EZAGENT_HOME: /data`, `EZAGENT_PROFILE: default`
  → `PROFILE_DIR=/data/default`. The `home` volume is **per-CHANNEL**
  (`ezagent-<channel>_home`), and the DB is per-channel
  (`ecto://…/ezagent_${CHANNEL}`).
- `docker/deploy.sh:13` — each channel loads its **own** env file
  `${SECRETS_HOME}/.env.${CHANNEL}` and runs as its **own** compose project
  `ezagent-${CHANNEL}`.

**Conclusion:**

- **(a) Can it bleed given current config?** Structurally **NO** — each
  channel has its own `home` volume, so the auto-generated
  `secret_key_base` is **distinct per env**; a cookie signed by `stable`
  cannot verify on `nightly`. It would bleed **only** if two channels'
  `.env.<channel>` files pin the **same** literal `SECRET_KEY_BASE`, or if
  channels share the `home` volume / `SECRETS_DIR`.
- **(b) Ops-verifiable only?** **YES** — the deciding facts (`.env.<channel>`
  content, per-channel volume separation) live outside the repo. The repo
  config alone cannot prove it either way; it merely makes distinct-volume
  channels isolated **by construction**.
- **(c) Needs its own W0 code fix?** **NO clearly-correct in-repo change.**
  Narrowing the cookie domain to host-only would break the intended
  same-env `app.`↔`world.` SSO. The cross-env guarantee is correctly
  delegated to distinct secrets.

**Ops action (recommended, for the lead):** verify each channel's
`${SECRETS_HOME}/.env.{nightly,beta,stable}` either **omits**
`SECRET_KEY_BASE` (→ per-volume auto-gen, isolated) **or** sets a
**distinct** value per channel. One-line check:
`grep -H SECRET_KEY_BASE docker/.env.nightly docker/.env.beta docker/.env.stable`
— expect either no hits or three different values.

## Open questions for the lead / Allen

1. **Membership-scope vs workspace-scope** (product, not security). Within a
   single workspace with **multiple** human members, a new member currently
   lands on `/sessions` (sees teammates' sessions) rather than the wizard.
   That is within-tenant, not a cross-tenant leak — the security fix stands
   regardless. If the desired UX is "wizard until *you* own a session",
   that's a separate per-entity-membership change (needs a new filter).
2. **Cross-env cookie**: confirm the ops action above (distinct
   `SECRET_KEY_BASE` per channel). If any two channels share a secret, that
   IS a real cross-env auth bleed and needs an ops fix (rotate to distinct
   secrets), though still not an in-repo code change.
