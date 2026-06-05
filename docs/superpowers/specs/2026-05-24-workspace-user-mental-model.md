# Workspace + User mental model — gap analysis vs Allen's target

> **Status:** SPEC draft for Allen review. Do NOT implement before alignment.
> **Methodology:** `grill-with-docs` — every claim backed by `file:line` evidence; assumptions surfaced as open questions.
> **Author session:** 2026-05-24 (cc-openclaw chat, dispatched into esr-ng worktree).
> **Scope:** the 3 UI bug reports Allen filed today, mapped to the actual code, then evaluated against Allen's proposed mental model. Output is a PR-sized change list, NOT a code patch.

---

## 0. Allen's target mental model (paraphrased for evaluation)

1. **Boot** creates exactly two things: the `admin` User AND a single `system` workspace.
2. **Workspace creation = magic-link whitelist domain.** Workspace name == email domain. `h2oslabs.com` becomes `workspace://h2oslabs`. **There is no `default` workspace anywhere.**
3. **Cross-workspace invitation:** the admin can invite users from any workspace into the `system` workspace and grant them admin-equivalent caps there.

Evaluated against today's code, this is a structurally clean model that subsumes several inconsistencies the grill below surfaces. The gap is real but bounded — Phase 9 PR-8 (`workspace://system`) already moved the codebase about 60 % of the way; what remains is mostly **deleting `default`** and **wiring domain→workspace in the registration flow**, not building new primitives.

---

## 1. Current state — grounded reading of the code

### 1.1 Boot creates three things, not two

What Allen says: boot creates `admin` + `system`.

What the code does (`apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex:245-255`):

```elixir
defp ensure_default_workspace do
  if test_env?() do
    :ok
  else
    # Phase 9 PR-8 (SPEC v3 §13.4) — order matters: system workspace
    # is created first so admin's URI (`entity://user/system/admin`)
    # resolves its workspace; then default for regular users.
    :ok = ensure_workspace("system", %{visible: false})
    :ok = ensure_workspace("default", %{})
  end
end
```

And in `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:227-284`:

```elixir
defp ensure_default_non_admin_user do
  operator_uri = "entity://user/default/operator"
  workspace_uri = URI.parse("workspace://default")
  operator_caps = User.default_caps(workspace_uri)
  # … Users.create(operator_uri, nil, operator_caps)
```

So boot actually creates **four** things:

| Thing | URI | Where |
|---|---|---|
| admin User | `entity://user/system/admin` | identity application.ex:167 `ensure_admin_user/0` |
| system workspace | `workspace://system` (hidden) | chat application.ex:252 |
| **default workspace** | `workspace://default` (visible) | chat application.ex:253 |
| **operator User** | `entity://user/default/operator` | identity application.ex:236 (Allen seeded 2026-05-23 to "make CapBAC visible") |

Allen's mental model wants the two bolded rows GONE. The `default` workspace is a leftover from before Phase 9 PR-8 when admin lived in `workspace://default`; PR-8 split admin into `system` but kept `default` as the "regular user" home. Allen's model says regular users should live in their **email-domain workspace**, not in a generic `default` bucket.

### 1.2 `default` vs `system` — what's the relationship today?

(Answers Allen's Q2: *"default 和 system workspace 是什么关系？"*)

**They are peer Workspace rows in the same SQLite table** (`apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex:55-68`). Structurally identical; the only data-shape difference is the `visible` boolean column added in Phase 9 PR-8.

Semantically, they have diverged into two different *concepts* the code does NOT cleanly separate:

| Concept | Today's home | What it represents |
|---|---|---|
| **Bootstrap / sysadmin authority sink** | `workspace://system` | Members hold cross-workspace authority by *membership* (no explicit cap grant needed) — `Ezagent.Capability.cross_workspace?/2` arity-2 in `apps/ezagent_core/lib/ezagent/capability.ex:221-238`. Keycloak realm-admin model. |
| **Catch-all tenant for "regular users"** | `workspace://default` | Default home for any user not explicitly bound to a tenant. Holds `entity://user/default/operator` (the seeded non-admin), and is what `Ezagent.Registration.create_principal/3` hard-codes at `apps/ezagent_domain_identity/lib/ezagent/registration.ex:94`: `"entity://user/default/" <> slug`. |

The system URI scheme `system://` (parsed in `apps/ezagent_core/lib/ezagent/uri.ex:215`) is a third related concept — it's the **URI scheme** for cross-cutting non-tenant resources like `system://routing/default` and `system://bootstrap/default`. The workspace `workspace://system` and the URI scheme `system://` share a name but are different layers. `Ezagent.Capability.workspace_of/1` returns `:any` for `system://` URIs (capability.ex:308), meaning system-scheme URIs are workspace-agnostic.

**Punchline for the grill:** `default` is not "the system workspace's user side." `default` is *historical residue* from when there was only one workspace and that workspace was called `default`. The `system` workspace was peeled off in Phase 9 PR-8 to host admin; the `default` workspace was *not* renamed or repurposed because doing so would have broken every persisted session URI of the form `session://*/default/*`.

### 1.3 Why linyilun sees BOTH workspaces in the dropdown

(Answers Allen's Q3: *"创建的新用户 linyilun，为什么同时可以看到 system 和 default 两个 workspace？"*)

There are **two distinct surfaces** showing workspaces, and they behave differently:

**Surface A — top-left workspace dropdown** (rendered by `EzagentDomainUi.IdeShell.workspace_dropdown/1` at `apps/ezagent_domain_ui/lib/ezagent_domain_ui/ide_shell.ex:269`):

Data source: `@workspaces` assign, populated in `apps/ezagent_web/lib/ezagent_web/live_auth.ex:236-274` via `Ezagent.Workspace.list_visible/0`. `list_visible/0` (workspace/store.ex:187-191) filters on `visible == true`, so `system` is correctly hidden here. **linyilun does NOT see `system` in the dropdown — only `default`.** This surface is correct.

**Surface B — `/workspaces` page** (`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/workspaces_live.ex:50-60`):

```elixir
defp list_workspaces do
  Ezagent.Workspace.list_persisted()      # <-- BUG
  |> Enum.map(fn ws -> …)
end
```

`Ezagent.Workspace.list_persisted/0` at `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:259-261` is defined as `def list_persisted, do: Store.list_all()` — it returns **every** row, including `visible: false`. This is the **`/workspaces` page leak**: any logged-in user, regardless of role, visits `/workspaces` and sees both rows in the table. linyilun is a fresh user with no admin cap, but `/workspaces` is in `live_session :require_entity` (router.ex:67) with no `is_admin?` gate at mount time — every authenticated user reaches it.

The mismatch is the bug Allen hit. The dropdown was fixed (PR-8 added `list_visible/0`); `/workspaces` was not updated to use the new helper.

**Sub-finding:** even the `Ezagent.Workspace.list_persisted/0` docstring is silent about the visibility caveat — it says *"List persisted Workspaces."* Callers reading the docstring alone would not know to switch to `list_visible/0` for operator-facing UI. The docstring on `list_all/0` (`workspace.ex:263-271`) is the only one that warns "callers rendering operator-facing UI should use `list_visible/0` instead." `list_persisted/0` and `list_all/0` currently return identical results but have different intended audiences — this is a P3 (single-source-of-truth) violation waiting to bite again.

### 1.4 Why the user-creation page looks unlike `/login`

(Answers Allen's Q1: *"创建用户的页面为什么和 login 等页面有明显区别，是不是没有装载在正确的 shell 里面？"*)

Allen's hypothesis (wrong shell) is **partially right but for the wrong reason**. Both pages are mounted in the SAME (zero) shell:

- `/login` → `EzagentWeb.SessionController.new` — `use Phoenix.Controller, formats: [:html], layouts: []` (session_controller.ex:16)
- `/register/complete` → `EzagentWeb.RegistrationController.complete_new` — `use Phoenix.Controller, formats: [:html], layouts: []` (registration_controller.ex:12)

Both are anonymous-accessible (router.ex:24-43 — first scope, no `RequireEntity`, no `live_session`). Both render raw heredoc HTML and skip the Phoenix root layout entirely (`layouts: []`). So "wrong shell" is misleading — there's no shell at all; both are auth-boundary pages explicitly built to dodge LV / WS deps.

The real reason they look different is the **CSS payload inside the heredoc**:

| File | Lines | CSS approach |
|---|---|---|
| `session_controller.ex:26-297` | ~270 LOC | Geist font import, full design-token palette (`--ink`, `--accent`, `--bg-page`), `data-theme="dark"` switch, `prefers-color-scheme` media query, `.card`, `.flash-mobile`, `.divider`, `.section-label` — visual parity with the admin LV chrome. |
| `registration_controller.ex:25-51` | ~25 LOC | `-apple-system, sans-serif`, hex `#1f883d` green button, no card, no palette, no dark mode, no Ezagent brand. The whole `form_html/0` is a stripped fallback that pre-dates the login page redesign. |

The asymmetry is mechanical: when the login page was redesigned (Phase 8c PR-D, visible from the `[data-theme="dark"]` + Geist additions), the same redesign was not applied to the registration page. Both are auth-boundary controllers that hand-render HTML — the natural place to fix this is **factor the shared CSS heredoc into a single helper that both controllers call**.

Note also that the magic-link controller (`magic_link_controller.ex`) renders nothing — it only redirects — so it doesn't contribute to the visual mismatch directly, but any future `/auth/magic/*` error page would inherit whichever pattern wins.

### 1.5 Registration hard-codes the workspace

`apps/ezagent_domain_identity/lib/ezagent/registration.ex:91-94`:

```elixir
# Phase 9 PR-2 (SPEC v3 §3): entity URIs carry a workspace
# segment; registration defaults to the `default` workspace
# until tenant-aware registration lands (PR-5).
uri_str = "entity://user/default/" <> slug
```

So every new user via magic link is parked in `workspace://default`. The comment explicitly acknowledges this is interim ("until tenant-aware registration lands (PR-5)") — Allen's target model IS that follow-up PR.

`Ezagent.Users.create/3` at `apps/ezagent_domain_identity/lib/ezagent/users.ex:58-95` then derives the workspace from the URI (line 76: `user_workspace = Ezagent.URI.entity_workspace_uri(URI.parse(uri_str))`) and grants `User.default_caps(user_workspace)` — workspace-scoped session caps in `workspace://default`. That's all linyilun has.

Why does linyilun then see `system` in `/workspaces`? Per §1.3, it's *not* via a cap — `/workspaces` is the leaky page. No cap check; the page just lists every persisted row.

### 1.6 `admin_uri` and the structural admin cap

`apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:29` defines:

```elixir
@admin_uri URI.parse("entity://user/system/admin")
```

`admin_caps/0` (user.ex:49-65) returns one capability with `kind: :any, behavior: :any, instance: :any, workspace_uri: :any, granted_by: system://bootstrap/default`. That cap is what makes admin work cross-workspace by *grant*. The `workspace://system` *membership* (capability.ex:221-238) is a SECOND, parallel cross-workspace-authority mechanism — defence-in-depth for the same property.

There are therefore **three layered admin paths today**, two structural + one membership-based, and only one of them (membership) is Allen's target. The other two are P2 (let-it-crash, no workarounds) candidates for deletion if Allen's mental model is adopted — they exist as belt-and-suspenders against a previous concern.

### 1.7 Magic-link domain whitelist already exists — but it's a flat global list

`apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex:594-633` `send_allowed?/1` calls `Ezagent.Registration.domain_allowed?/1`:

```elixir
# registration.ex:60-68
def domain_allowed?(email) when is_binary(email) do
  domains = AppSettings.get("registration_domains") || []
  case String.split(email, "@", parts: 2) do
    [_, domain] -> String.downcase(String.trim(domain)) in Enum.map(domains, &String.downcase/1)
    _ -> false
  end
end
```

So today there's a **single global list** of allowed registration domains. Allen's target is **the workspace IS this list — one row per domain, and registration into a domain creates the user inside that domain's workspace**. The mechanism is already half-built; what's missing is the indirection that ties "domain matched" → "this is the workspace name."

---

## 2. Gap analysis vs Allen's mental model

| # | Allen's target | Today's state | Gap classification |
|---|---|---|---|
| G1 | Boot creates `admin` + `system` only | Boot creates admin + system + default + operator | **Delete** `default` workspace + `operator` user seeds |
| G2 | Workspace name = email domain | Workspace name = arbitrary string typed in `/workspaces` create form | **Reshape** workspace-create: derived from domain, not free-form |
| G3 | `workspace://h2oslabs` is the home of `lin.yilun@h2oslabs.com` | `workspace://default` is the home of every new user | **Rewire** `Ezagent.Registration.create_principal/3` to derive workspace from email domain |
| G4 | `registration_domains` whitelist = list of workspaces | `registration_domains` is a flat AppSetting list; workspaces are separate Store rows | **Merge** the two — one Store row IS the registration entitlement for its domain |
| G5 | Admin can invite cross-workspace users into `system` and grant admin caps there | Admin can add any URI as a member of any workspace (no UI for cross-workspace promotion specifically) | **Add** "Promote to system member" admin action; surface `system` workspace explicitly in the admin tooling |
| G6 | linyilun (non-admin) sees ONLY her own workspace | linyilun sees `default` + `system` on `/workspaces` (leak); sees `default` only in dropdown (correct) | **Bug-fix** `WorkspacesLive` to use `list_visible/0` + add per-user filter |
| G7 | User-creation page visually consistent with login | Registration page has stripped legacy CSS, login page has full Geist + palette | **Refactor** shared auth-boundary CSS into a helper used by both controllers |
| G8 | No `default` referenced anywhere | `default` appears in 30+ files as session URI segment, fallback workspace, comment, doc | **Rename + migrate** — every existing `default` reference needs a target (some go to the user's domain workspace, some go to `system`, some are deleted) |

---

## 3. PR-sized change list

**Sequencing constraint:** Bugfix gates come first (G6, G7) — they're isolated, low-risk, and remove visible leaks Allen hit today. Mental-model migration (G1-G5, G8) comes second and needs SPEC alignment before any code lands. G8 (the `default` deletion sweep) is the big one and probably runs late as a single audit-and-clean PR.

### PR-1 — Hide `system` workspace from `/workspaces` page (G6)

**Files:** `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/workspaces_live.ex`, `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex`.

**Change:**
1. `workspaces_live.ex:51` — swap `Ezagent.Workspace.list_persisted()` for `Ezagent.Workspace.list_visible()`.
2. `workspace.ex:259-261` — either deprecate `list_persisted/0` (it's currently a misleading thin wrapper around `list_all/0`) OR make its docstring explicitly say "ADMIN ONLY — use `list_visible/0` for operator-facing UI." Per P3 (single source of truth), preferred is to delete `list_persisted/0` entirely and have callers pick `list_all/0` (admin) or `list_visible/0` (operator) consciously.

**Invariant test (P6):** add `test/workspaces_live_test.exs` that creates a `visible: false` workspace, mounts `WorkspacesLive` as a non-admin user, asserts the hidden workspace's name does NOT appear in the rendered HTML. Fails today.

**Risk:** low. The change is one function name in one LV. The deprecation of `list_persisted/0` may need to update other call sites — `grep -rn list_persisted apps/` first.

### PR-2 — Unify auth-boundary CSS between login + registration (G7)

**Files:** `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`, `apps/ezagent_web/lib/ezagent_web/controllers/registration_controller.ex`, new `apps/ezagent_web/lib/ezagent_web/auth_boundary.ex` (or similar shared helper).

**Change:**
1. Extract the 270-LOC CSS heredoc from `session_controller.ex:26-297` into a shared module that exposes `auth_boundary_html_head(title)` + `auth_boundary_card_open()` + `auth_boundary_card_close()`.
2. Rewrite `registration_controller.ex:25-51` `form_html/0` to use those helpers. The page-specific bits (`<h1>Complete your registration</h1>` + form fields) stay inline; the chrome (font, palette, card, dark mode) is shared.
3. Test that both pages render identically-styled cards in dark + light mode.

**Risk:** medium. The login page CSS is now also used by registration; any future style tweak must consider both. Tests should cover both routes' rendered HTML.

**Open question:** does the magic-link error page (currently just `put_flash + redirect to /login`) deserve a real rendered page too? If yes, it should use the same helper. Allen to decide whether to scope this in or defer.

### PR-3 — SPEC alignment session for Allen's mental model (no code)

Before any of PR-4 onwards, schedule a `grill-with-docs` session covering:

1. **The `default` workspace's fate.** Does it get renamed (and to what)? Or deleted (and where do its existing sessions go)? Both options have downstream churn.
2. **What happens to users without an email domain that maps to a workspace?** E.g. an operator creates an account via mix task, no email, no domain → which workspace?
3. **Reserved workspace names.** `system` is already reserved. Are common domain names (`gmail.com`) refused? If a user registers `foo@gmail.com`, do we create `workspace://gmail`, or refuse, or require an explicit operator opt-in?
4. **Workspace creation primitive.** Today: type a name in `/workspaces` form. Allen's model: workspaces auto-create when the first user from that domain registers. Is the `/workspaces` create form removed, or kept as an admin-only "pre-create / configure" surface?
5. **Cap propagation on cross-workspace invite.** When admin promotes linyilun to `workspace://system` member, does linyilun's existing `entity://user/h2oslabs/linyilun` URI stay (cross-workspace member by membership), or does she get a second URI `entity://user/system/linyilun`? Phase 9's structural decision suggests the former (membership-based); the URI doesn't move.
6. **Does `entity://user/system/admin` keep its URI?** Or does admin become `entity://user/<admin's-email-domain>/admin` with cross-workspace authority by `system` membership? The latter is structurally cleaner per Allen's mental model — admin is "just a user with system membership," no special URI host.

The SPEC document produced by PR-3 is the prerequisite for PR-4 onwards.

### PR-4 — Domain-derived workspace at registration (G2, G3)

**Files:** `apps/ezagent_domain_identity/lib/ezagent/registration.ex`, `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`, possibly `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex`.

**Change:**
1. `Ezagent.Registration.create_principal/3` — derive `workspace = email_domain_to_workspace_name(email)`. Build URI as `"entity://user/<workspace>/<slug>"`.
2. Add a `Ezagent.Registration.ensure_workspace_for_domain/1` helper — looks up or creates the workspace row corresponding to the email's domain. Idempotent (workspace creation is already idempotent via `unique_constraint` on name).
3. The magic-link allowlist (`AppSettings.get("registration_domains")`) becomes the SOURCE for which workspaces auto-create. Adding a domain to the allowlist provisions a workspace row.
4. `default` workspace stays seeded at boot for back-compat until G8 deletes it.

**Invariant test (P6):** registering `foo@h2oslabs.com` produces `entity://user/h2oslabs/foo` and a `workspace://h2oslabs` Store row. Fails today.

**Risk:** medium. Touches the registration happy path. Easy to break the slug-collision suggestion logic (Registration.suggest_slug/1 currently hard-codes `entity://user/default/<slug>`).

### PR-5 — Merge `registration_domains` AppSetting into Workspace rows (G4)

**Files:** `apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex` (schema migration), `apps/ezagent_domain_identity/lib/ezagent/registration.ex`, `apps/ezagent_domain_identity/lib/ezagent/app_settings.ex`.

**Change:**
1. Migration: add `domain TEXT` column to `workspaces` (or `domains TEXT` for multi-domain workspaces — see open question O5).
2. `Registration.domain_allowed?/1` reads from `Workspace.Store` rows, not `AppSettings`.
3. Settings UI `/admin/settings` — the "Allowed email domains" textarea writes Workspace rows instead of the AppSetting.
4. Migration script: import existing `registration_domains` AppSetting into Workspace rows.

**Open question O5:** does one workspace map to ONE domain (1:1) or multiple (1:N)? Allen's mental model implied 1:1 ("workspace name = email domain"), but real orgs use multiple domains (`@h2oslabs.com`, `@h2os-labs.com`). Defer to PR-3 SPEC session.

### PR-6 — Admin action: promote user into `workspace://system` (G5)

**Files:** `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/users_live.ex` (or a new admin sub-page), `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex` (`add_member/2` is already there).

**Change:**
1. Surface "system workspace membership" in the user-detail admin view. Today there is no UI for "make this user a system member"; admin would have to call `Ezagent.Workspace.add_member("system", uri)` from iex.
2. Add a confirmation step + audit log entry. System-membership grant is a high-impact action.
3. Make `workspace://system` visible in the admin tooling specifically (not the regular workspace list). Two paths considered: (a) admin-only chip in the existing list; (b) dedicated `/admin/system-members` page. Lean: (b) — it's a fundamentally different action than "edit team-alpha members."

**Risk:** medium. The action itself is one DB write + one dispatch; the UX needs care because the grant is irreversible-shaped.

### PR-7 — `default` workspace deletion sweep (G1, G8)

**Files:** ~30+ across the umbrella. This is the big PR.

**Change checklist (preview — actual list lives in the SPEC PR-3 produces):**
1. `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex:253` — remove `ensure_workspace("default", %{})`.
2. `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:236` — remove the `entity://user/default/operator` seed (or move it to `entity://user/<some-other-workspace>/operator`).
3. `apps/ezagent_domain_identity/lib/ezagent/registration.ex:42, 94` — `default` hard-coding gone (already handled by PR-4 if PR-4 lands first).
4. `apps/ezagent_web/lib/ezagent_web/live_auth.ex:266` — the `Always include default` fallback list deleted.
5. `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex:528, 535` — `workspace_param` default of `"default"` removed; require explicit workspace context.
6. Existing `session://*/default/*` URIs in production DBs — migration script renames them (to what? — needs SPEC alignment).
7. `cli_lv_same_server_invariant_test.exs` and other tests that hard-code `default` — update.

**Risk:** high. This is the migration PR. Should land last and be paired with a DB backup / restore drill in dev before prod. Per P2 (let-it-crash, no workarounds), no back-compat shim; URIs migrate atomically.

---

## 4. Open questions Allen must answer before PR-3+ proceeds

These are decision-required, not researchable from code:

- **OQ1:** Does `workspace://system` need a corresponding `entity://user/system/admin`, or can admin become a regular user in their email-domain workspace with `system` membership added on top? (Affects PR-6 + PR-7 scope dramatically.)
- **OQ2:** When `default` is deleted, what happens to existing `session://*/default/*` URIs in the DB? Three options: (a) drop on migration (Allen's typical "wipe + rebuild" pattern, uri-design §5.11), (b) rewrite to `session://*/system/*`, (c) rewrite to per-user-domain workspaces (only works for sessions whose owner email is known).
- **OQ3:** Reserved-name policy. Does `system` stay reserved? Is `default` blacklisted post-migration to prevent confusion? What about `admin`, `root`, `localhost`?
- **OQ4:** Public-email domains (`gmail.com`, `outlook.com`, `qq.com`). Auto-create per domain (one workspace per domain → could become hundreds), refuse, or require admin to pre-approve the domain?
- **OQ5:** Workspace ↔ domain cardinality. 1:1 (workspace name == domain), 1:N (one workspace can claim multiple domains), or N:1 (one domain can map to multiple workspaces — e.g. `h2oslabs.com` could route to `workspace://h2oslabs-prod` or `workspace://h2oslabs-staging`)? Allen's mental model said 1:1; verify before PR-5.
- **OQ6:** Magic-link path during migration. While PR-4 is rolling out, can a user with an email in a domain that has no Workspace row STILL register (falling back to `workspace://default`)? Or does PR-4 hard-require the workspace to exist first (chicken-and-egg risk on first deployment)?
- **OQ7:** UI label for the email-domain workspace. `workspace://h2oslabs` displays as `h2oslabs` in the dropdown — does that read as "the h2oslabs.com workspace"? Should the display name be the full domain (`h2oslabs.com`) with the URI segment stripped?
- **OQ8:** What about users created via `mix ezagent.user.create entity://user/foo/bar`? Today this skips the registration flow entirely. Post-PR-4, should the mix task verify the workspace exists, or auto-create it, or refuse?

---

## 5. What I deliberately did NOT investigate

To stay on scope:

- The `system://` URI scheme's interplay with `workspace://system` (these are different layers, mostly orthogonal, but a full audit would surface if any code conflates them).
- Feishu binding to system-workspace users (`apps/ezagent_plugin_feishu/...` — the binding policy at `feishu_bindings_live.ex:68` mentions system scope but is out-of-scope for this gap analysis).
- CLI behavior for non-default workspace operations. `apps/ezagent_cli` was glanced (one `Ezagent.Workspace.create` call site) but not deeply audited.
- Snapshot persistence path under workspace migration. Per P3 + uri-design §5.11, snapshots are keyed by URI; URI migration triggers snapshot rebuild. Worth confirming in PR-7 SPEC.

---

## 6. References (file:line, code-grounded)

- Router scopes — `apps/ezagent_web/lib/ezagent_web/router.ex:24-43, 51-62, 64-150`
- Login controller — `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex:16-297, 558-606`
- Registration completion controller — `apps/ezagent_web/lib/ezagent_web/controllers/registration_controller.ex:12, 25-51`
- Magic-link controller — `apps/ezagent_web/lib/ezagent_web/controllers/magic_link_controller.ex:1-112`
- Registration logic — `apps/ezagent_domain_identity/lib/ezagent/registration.ex:36-130`
- Users store (workspace_uri derivation) — `apps/ezagent_domain_identity/lib/ezagent/users.ex:58-95`
- User Kind admin_uri / admin_caps / default_caps — `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:29, 49-65, 105-116`
- Identity Application bootstrap (admin + operator seeds) — `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:104-285`
- Workspace facade — `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:259-283`
- Workspace Store — `apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex:55-68, 165-191`
- Chat Application boot-time workspace seeding — `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex:245-300`
- LiveAuth on_mount (workspaces assign) — `apps/ezagent_web/lib/ezagent_web/live_auth.ex:97-274`
- WorkspacesLive (the leak) — `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/workspaces_live.ex:39-60`
- workspace_dropdown component — `apps/ezagent_domain_ui/lib/ezagent_domain_ui/ide_shell.ex:160-188, 269-380`
- Capability.cross_workspace?/2 (system membership) — `apps/ezagent_core/lib/ezagent/capability.ex:221-238`
- workspace_of/1 (system:// → :any) — `apps/ezagent_core/lib/ezagent/capability.ex:308`
- ezagent-developer skill principles consulted — P1 (plugin isolation), P2 (let-it-crash no workarounds), P3 (single source of truth), P5 (UUID canonical), P6 (completion = invariant test), P17 (workspace via URI), P20 (URI shape allowlist), P27 (silent drop only for security).

---

## 7. Methodology note (grill-with-docs reflection)

This SPEC challenged Allen's framing in three places:

1. **"Wrong shell"** (Q1) was the user's hypothesis. The grill found that *both* pages use `layouts: []` — there's no shell at all on either side. The real defect is style-payload asymmetry in two parallel heredocs.
2. **"linyilun sees BOTH workspaces"** (Q3) sounded like a permissions bug. The grill found that the dropdown does NOT show system (correct), but `/workspaces` DOES (P3 violation between `list_visible/0` and `list_persisted/0`).
3. **"`default` vs `system` relationship"** (Q2) was open-ended. The grill found they are peer rows differing only by `visible`, and that `default` is historical residue from before Phase 9 PR-8 — confirming Allen's instinct that one of them shouldn't exist.

The biggest hidden assumption surfaced: Allen's model treats `default` as an obvious mistake to delete. The code treats `default` as a load-bearing fallback referenced in ~30 files including session URI segments in production DBs. The migration is non-trivial — that's why PR-7 is sized as a separate, late, audit-heavy PR rather than rolled into PR-4.
