# Default workspace rename: `default` → `system` (final sweep)

> **Status:** SPEC rev 2 — incorporates codex SPEC review (3 MUST-FIX + 3 nice-to-have findings, 2026-05-25). Awaiting Allen review.
> **Author:** subagent dispatched by main agent, Allen directive 2026-05-25.
> **Operational constraint:** Allen authorized DB wipe — no migration / back-compat (`feedback_let_it_crash_no_workarounds`, reaffirmed 2026-05-25).
> **Companion ZH:** `2026-05-25-workspace-default-to-system.zh_cn.md`.

> **Rev 2 changelog (codex review 2026-05-25):**
> - §8 OQ-1 resolution revised: tenant users CANNOT live in `workspace://system` (would grant cross-workspace bypass via `Capability.cross_workspace?/2` `home_is_system?` shortcut). New resolution: `default_workspace_uri/0` is DELETED; callers derive workspace from caller URI structurally or pass it explicitly. Admin's wizard session naturally lands in `workspace://system` because admin's home is system.
> - §3 expanded with 5 additional production literals codex found: `session_principal.ex` (bare-handle canonicalization), `session_controller.ex` (workspace_param fallback), `users_live.ex` (admin user create), `session_template.ex` (build_uri default), `echo_plugin/application.ex` (`@default_uri`).
> - §3.7 added: rename demo `echo_default` agent + wizard hook to `entity://agent/system/echo_default`.
> - §6 invariant regex broadened to cover `entity://(user|agent)/default/`, `template://(session|agent)/default/`, `session://[^/]+/default/`, plus a code-pattern check for `:workspace, "default"` Keyword defaults.

---

## 0. Allen's directive (verbatim 2026-05-25)

> "session://default/default/main 这个用不同的名字：默认应该是 session://default/system/main，模版的init叫做default，workspace的init叫做system（就是具有管理权限的那个，如果default是另外一个workspace，可以把default删掉），session的init叫做main"

Translation:
- The 3 segments of the default session URI mean different things and should not all be called `default`:
  - **template name** = `default` (Session template's init name — unchanged)
  - **workspace name** = `system` (the admin workspace; rename from `default`)
  - **session name** = `main` (Session's init name — unchanged)
- Canonical default session URI: **`session://default/system/main`** (was `session://default/default/main`).
- If a separate `workspace://default` workspace exists (i.e. not the admin one), delete it.

---

## 1. Goal

**The only structural "default workspace" is `workspace://system`, and it is reserved for admin.** No global `default_workspace_uri/0` fallback exists; tenant code paths must pass workspace explicitly or derive it from the caller's URI (Phase 9 PR-2 made workspace structural in entity URIs — `entity_workspace_uri/1` already exists for this).

After this SPEC's impl PR lands:
- Admin's wizard-created session lands in `workspace://system` because admin's URI is `entity://user/system/admin` (workspace derived structurally).
- The canonical "first session" URI for fresh-DB onboarding is `session://default/system/main`.
- Tenant users (from magic-link onboarding) land in their own workspace (`workspace://<their-tenant>`), created at magic-link time per SPEC v2 PR-A (`magic_link_rule` field on workspace creation).
- No `workspace://default` literal exists in production lib code; tests rewrite the same.
- No code path silently defaults the workspace name to `"default"` (the 5 production sites flagged by codex review get explicit workspace parameters or fail-fast).
- The demo echo agent moves to `entity://agent/system/echo_default` (admin's workspace) — joined to admin's first session as a same-workspace demo.
- An invariant test forbids regression (broader regex than rev 1).

## 2. Scope

In-scope:
- Production lib code (`apps/*/lib/`).
- Test fixtures / tests (`apps/*/test/`).
- Mix tasks + plugin code.
- Documentation strings (`@moduledoc`, wizard copy in `home_live.ex`).
- Migration of any stray `workspace://default` row at runtime (DB wipe is the supported path; migration is **not** ridden — see §4).

Out-of-scope (untouched per orchestrator instruction):
- `apps/ezagent_domain_external_mirror/` (PR-EM-* in flight).
- `apps/ezagent_plugin_feishu/` lifecycle changes (PR-EM-6 deferred) — we DO touch the two `workspace://default` / `session://default/default/main` literals in `application.ex` + the bind mix task; these are pure-string rename, not lifecycle.
- `apps/ezagent_core/lib/ezagent/notifications.ex` + admin_live notifications (PR-N3) — we touch admin_live.ex's `@main_session_uri` constant only (pure rename).

If any conflict surfaces during impl, flag in Feishu before merging.

---

## 3. Affected files

Discovery method: `grep -rn "session://default/default/main\\|workspace://default" --include="*.ex" --include="*.exs"` against `origin/main` (f15fb98). Counts:
- 182 references to `workspace://default`
- 160 references to `session://default/default/main` (overlap with the above)
- 5 functionally-load-bearing URI literals (the rest are docstrings, examples, test fixtures)

### 3.1 Load-bearing literals (production lib) — rev 2 expanded

| File | Construct | Change |
|---|---|---|
| `apps/ezagent_core/lib/ezagent/workspace_registry.ex:87` | `def default_workspace_uri, do: {:ok, URI.new!("workspace://default")}` | **DELETE the function entirely.** Add `@deprecated` removal note in commit. Audit + replace all callers (see §3.1a). |
| `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:59` | `def default_uri, do: URI.new!("session://default/default/main")` | Return `URI.new!("session://default/system/main")` |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:55` | `@main_session_uri URI.new!("session://default/default/main")` | `URI.new!("session://default/system/main")` |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_caps_live.ex:116` | `URI.parse("workspace://default")` (fallback when assigns missing) | **Fail-fast** — raise `ArgumentError` instead of silently defaulting. LV should never mount without `current_workspace_uri` assign present per PR-N3 pattern. |
| `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex:175` | `Map.get(binding, "session_uri") \|\| "session://default/default/main"` | Remove the `\|\|` fallback — bindings without `session_uri` should fail-fast (the table is FK-style and per SPEC v2 §5.8 every binding row has a target). If a real backwards-compat row exists, write a per-environment seed; do not silently route to `system/main`. |
| `apps/ezagent_web/lib/ezagent_web/session_principal.ex:121` | `workspace = Keyword.get(opts, :workspace, "default")` (bare-handle login fallback) | Remove the `"default"` literal default. Callers MUST pass `:workspace`. Bare-handle login (Phase 9 PR-2 SPEC v3 §6.2 option A) is admin-only; force `"system"` from the `magic_link_controller` admin path and raise otherwise. |
| `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex:276` | `Map.get(...) \|\| "default"` workspace fallback | Same fix pattern: admin login → `"system"`; tenant login → require the workspace param (raise if missing); legacy clients without the param hit the onboarding redirect (Phase 9 PR-8 path). |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/users_live.ex:281` | Admin "create user" flow falls back to `entity://user/default/<name>` for legacy 2-segment input | Add explicit workspace dropdown to admin create-user form (SPEC v3 §3 pending UX item flagged by SPEC v2 PR-F #297 comment). MUST be tracked + done — admin creating a user without a workspace is a fail-fast in rev 2. |
| `apps/ezagent_domain_chat/lib/ezagent/entity/session_template.ex:177` + `:489` | `workspace = Keyword.get(opts, :workspace, "default")` (template URI build) | Same as session_principal — remove silent `"default"` default. All callers pass workspace explicitly (`AgentNewLive`, `Workspace.add_template`, mix tasks). Raise `ArgumentError` on missing `:workspace`. |
| `apps/ezagent_plugin_echo/lib/ezagent_plugin_echo/application.ex:71` | `@default_uri URI.parse("entity://agent/default/echo_default")` | Rename to `entity://agent/system/echo_default` — the demo echo agent lives in admin's workspace. Confirm: echo is admin-owned (`User.admin_uri()` is its creator), so its home workspace IS system. |

### 3.1a `default_workspace_uri/0` caller audit

`grep -rn "default_workspace_uri" --include="*.ex" apps/*/lib/` (excluding tests). Each call replaced:

| Caller | Current | Replacement |
|---|---|---|
| `apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:50` (`create_session/3`) | `{:ok, default_workspace_uri} = Ezagent.WorkspaceRegistry.default_workspace_uri()` | Derive from `creator_uri` structurally: `Ezagent.URI.entity_workspace_uri(creator_uri)`. Wizard calls `create_session(short_name, admin_uri)` → admin's URI is `entity://user/system/admin` → workspace structurally is `workspace://system`. |
| `apps/ezagent_core/lib/ezagent/persistence.ex` (audit + snapshot writer fallback) | Uses for cross-cutting URIs | Drop the fallback; pass `system://` URIs through with `workspace_uri = "workspace://system"` literal (consistent with existing audit-writer pattern for `system://` cross-cutting schemes). Audit table's `workspace_uri` is denormalized + NOT FK so this is safe. |

Any caller not in this table is a bug — the SPEC says "if grep finds more, list them in impl PR and decide site by site; do NOT add a new global fallback to plaster over them."

### 3.2 Wizard / user-visible copy

| File | What | Change |
|---|---|---|
| `apps/ezagent_web/lib/ezagent_web/live/home_live.ex:182` | `gettext("Creates")` line literally renders `session://default/default/<name>` bound to `workspace://default` | Update to `session://default/system/<name>` bound to `workspace://system`; update the `gettext` strings; sync `priv/gettext/zh_*/LC_MESSAGES/` entries (or `mix gettext.extract`) |
| `apps/ezagent_web/lib/ezagent_web/live/home_live.ex:31` | moduledoc "every new session lands on `workspace://default`" | Rename |

### 3.3 Mix tasks + LV placeholders (operator-facing)

| File | Change |
|---|---|
| `apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex` | `@session_uri_str "session://default/default/main"` → `"session://default/system/main"`; update docstring + final help text |
| `apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.chat.bind.ex` | Update placeholder + example URIs in `@moduledoc` |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/feishu_bindings_live.ex:401` (codex finding) | Form placeholder `placeholder="session://default/default/main"` → `placeholder="session://default/system/main"` |

### 3.4 Pure docstring / comment renames (no behavior change)

`apps/ezagent_core/lib/ezagent/uri.ex`, `capability.ex`, `kind/runtime.ex`, `persistence.ex` — every `workspace://default` / `session://default/default/main` in `@moduledoc` / `@doc` / `# ...` updates to `system`. Mechanical sweep; no `URI.new!` / `URI.parse` impact.

### 3.5 Tests + fixtures

~50 test files reference `workspace://default` or `session://default/default/main`. Each gets the literal rewrite. We do NOT introduce a `@default_workspace` module attribute — keeping the literal strings makes the invariant test (§6) trivial. Categories:

| Category | Example | Action |
|---|---|---|
| Invariant tests | `apps/ezagent_core/test/invariants/system_workspace_membership_test.exs` | Confirm `workspace://default` references already meant "deleted/legacy"; rewrite remaining literal mentions to `workspace://system` or rephrase as "the deleted legacy default" |
| URI parser tests | `apps/ezagent_core/test/ezagent/uri_test.exs` | Rewrite fixture strings; assertion semantics unchanged |
| Cap helpers | `apps/ezagent_core/test/support/cap_helper.ex` (`@default_workspace`) | Update module attribute to `workspace://system` + rename to `@system_workspace`; update doc-comments |
| Test fixtures | `apps/ezagent_domain_identity/test/ezagent/users_test.exs`, etc. | Literal rewrite |
| Integration tests | `apps/ezagent_domain_chat/test/integration/*.exs` | Literal rewrite + verify they still pass against renamed `Session.default_uri/0` |

### 3.6 Echo demo agent rename (codex finding)

`home_live.ex:105` currently joins `entity://agent/default/echo_default` to the wizard-created session. If the session moves to `workspace://system` but the agent stays in `workspace://default` (which no longer exists), the chat round-trip fails on cross-workspace isolation.

Resolution: echo demo agent moves to `entity://agent/system/echo_default`.

| File | Change |
|---|---|
| `apps/ezagent_plugin_echo/lib/ezagent_plugin_echo/application.ex:71` | `@default_uri URI.parse("entity://agent/default/echo_default")` → `"entity://agent/system/echo_default"` |
| `apps/ezagent_web/lib/ezagent_web/live/home_live.ex:105` | `echo_uri = URI.parse("entity://agent/default/echo_default")` → `"entity://agent/system/echo_default"` |
| Plus all test fixtures referencing `echo_default` literal | Update to match |

Note: this couples the echo plugin's seed location to `workspace://system`. That's correct for V1 (echo is admin's demo); when a tenant wants their own echo, they spawn `entity://agent/<their-ws>/echo_<name>` via the existing template flow.

### 3.8 Migrations — historical, do NOT rewrite

The `apps/ezagent_core/priv/repo/migrations/20260601000000_phase9_pr6_workspace_uri_columns.exs` file contains `'workspace://default'` SQL string literals as backfill defaults. Per `feedback_let_it_crash_no_workarounds` + Allen's DB-wipe authorization, we **do not edit historical migrations** (would re-run on existing DBs). DB wipe is the supported path; the migration files stay frozen for reproducibility.

---

## 4. Migration (greenfield)

Allen authorized DB wipe (2026-05-24, reaffirmed 2026-05-25). The impl PR ships **without** a backfill migration. Operators wipe their `~/.ezagent/<profile>/db/ezagent_core.db` and re-run `mix ezagent.bootstrap`.

Rationale:
- The DB row for `workspace://default` (if present from a pre-PR-C boot) is orphaned — no boot code re-seeds it. A migration to delete it adds complexity for a one-time scenario.
- Any session row with `session://default/default/<name>` would have to be either re-mapped (binding to `workspace://system`, but the URI itself encodes `default` per Phase 9 PR-7 3-segment shape — so rewrite isn't a metadata patch, it's a URI string rewrite) or dropped. A migration that rewrites session URIs touches half a dozen tables (kind_snapshots, message_routings, audit, etc.); not worth it for greenfield.
- Pre-impl Feishu message will explicitly call out the wipe step.

If, post-merge, an operator's DB has stray `workspace://default` data, the symptom is: a hidden orphaned workspace row in `/workspaces` listing (filtered out by `list_visible/0` since `default` row would not have been seeded in PR-C-and-after boots anyway). Documented in the merge announcement; not a blocker.

---

## 5. Renaming map (canonical) — rev 2

| Old | New | Rationale |
|---|---|---|
| `workspace://default` (admin-context production literals) | `workspace://system` | Admin's workspace is `system`; only admin-context paths use this |
| `workspace://default` (tenant-context test fixtures) | `workspace://tenant-a` (or `team-alpha` — choose per test intent) | Tenants get explicit names; `default` no longer is a workspace |
| `session://default/default/main` | `session://default/system/main` | Template `default` + workspace `system` + session `main` |
| `Ezagent.WorkspaceRegistry.default_workspace_uri/0` exists | **Deleted.** Callers derive from caller URI via `Ezagent.URI.entity_workspace_uri/1` or pass workspace explicitly | A global fallback hides "no workspace passed" bugs and was the rev 1 security risk source |
| `entity://user/default/<name>` in admin-adjacent tests | `entity://user/system/<name>` | Admin-adjacent fixtures |
| `entity://user/default/<name>` in tenant-context tests | `entity://user/tenant-a/<name>` | Tenant fixtures need explicit non-system workspace |
| `entity://agent/default/echo_default` | `entity://agent/system/echo_default` | Demo echo agent lives in admin's workspace |
| `apps/ezagent_core/test/support/cap_helper.ex` `@default_workspace` | `@system_workspace`, value `workspace://system`. Add a parallel `@tenant_workspace` for non-admin fixtures | Naming follows usage; tests get two helpers |
| `Keyword.get(opts, :workspace, "default")` (production lib) | Remove default — raise `ArgumentError, "workspace is required"` on missing key | Force explicitness; tenant + admin paths must each pass their own |

Test references to "the deleted legacy workspace://default" in comments stay readable — we don't rewrite history prose; we rewrite live URIs + the silent fallback patterns.

---

## 6. Invariant test (the locking gate) — rev 2 broadened

`apps/ezagent_core/test/invariants/no_default_workspace_test.exs` — fails CI if any of the following appear in `apps/*/lib/` (production):

```elixir
# Regression triggers (regex alternation):
#  1. workspace://default                              # any workspace URI
#  2. session://<template>/default/<name>              # session-segment default
#  3. entity://(user|agent)/default/<name>             # per-tenant entity default
#  4. template://(session|agent)/default/<name>        # template URI default
#  5. resource://<type>/default/<name>                 # resource URI default
#  6. :workspace, "default"                            # Keyword.get fallback
#  7. workspace: "default"                             # keyword in opts list
```

Implementation sketch:

```elixir
defmodule Ezagent.Invariants.NoDefaultWorkspaceTest do
  use ExUnit.Case, async: true

  @forbidden [
    # URI literals across all per-tenant schemes
    ~r/workspace:\/\/default(?![a-zA-Z0-9_-])/,
    ~r/session:\/\/[^\/\s"']+\/default\//,
    ~r/entity:\/\/(?:user|agent)\/default\//,
    ~r/template:\/\/(?:session|agent)\/default\//,
    ~r/resource:\/\/[^\/\s"']+\/default\//,
    # Keyword default for "workspace" naming the string "default"
    ~r/:workspace,\s*"default"/,
    ~r/workspace:\s*"default"/
  ]

  @whitelist [
    # Historical migrations are frozen (Allen DB-wipe policy).
    "apps/ezagent_core/priv/repo/migrations/20260601000000_phase9_pr6_workspace_uri_columns.exs",
    # This test itself contains the forbidden patterns as data.
    "apps/ezagent_core/test/invariants/no_default_workspace_test.exs"
  ]

  test "no production lib code references default workspace literals or string fallbacks" do
    offenders =
      Path.wildcard("apps/*/lib/**/*.{ex,exs}")
      |> Enum.reject(&(&1 in @whitelist))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, ln} ->
          if Enum.any?(@forbidden, &Regex.match?(&1, line)) do
            ["#{path}:#{ln}: #{String.trim(line)}"]
          else
            []
          end
        end)
      end)

    assert offenders == [],
           "Found legacy default-workspace references:\n" <> Enum.join(offenders, "\n")
  end
end
```

Notes:
- Scoped to `apps/*/lib/`. Test fixtures (`apps/*/test/`) are rewritten in the impl PR but not invariant-gated.
- Pattern (1) uses negative lookahead `(?![a-zA-Z0-9_-])` so `workspace://default-tenant` (a plausible future tenant name) does not false-positive.
- Pattern (2) intentionally matches `session://<any-template>/default/`, not only `session://default/default/`, because tenant sessions in any template that hardcode `default` as workspace are equally wrong.
- Patterns (6) + (7) are the code-pattern check codex flagged: silent `"default"` fallbacks in `Keyword.get(opts, :workspace, "default")` and `[workspace: "default"]` opts lists.
- Comment-only docstrings using "the legacy default workspace" prose without the URI literal are tolerated (they don't match these regexes).

---

## 7. Verification

### 7.1 Build + tests

```bash
mix deps.get
mix compile --warnings-as-errors
mix test
mix test --only invariant   # the new gate
```

Expected: all green. Test count unchanged ±1 (the new invariant test).

### 7.2 End-to-end smoke

> **USER-ASSIST STEP** (per `feedback_flag_user_assist_steps`): the agent will wipe its OWN local DB. Allen does not need to act unless the agent reports a failure.

```bash
rm ~/.ezagent/default/db/ezagent_core.db*
mix ezagent.bootstrap
mix phx.server &
```

Then via agent-browser (per `feedback_open_terminal_first_when_debugging`):
1. Navigate to `http://100.64.0.27:10042/` (Tailscale IP per `feedback_remote_browser_ip`).
2. Log in as admin.
3. Submit the wizard with default short_name `main`.
4. Screenshot the resulting `/sessions` page; URL should show `session://default/system/main`.
5. Screenshot `/workspaces` showing only `system` (hidden from regular users — confirms `list_visible/0` returns `[]` for non-system members; admin sees `system` since `visible: false` is filtered by `list_visible/0` but admin uses `list_all/0`).

Acceptance criteria:
- Wizard's preview text reads `session://default/system/<name>` and `workspace://system`.
- After submit, the LV redirects to `/sessions` with `session://default/system/main` in the URL.
- No `workspace://default` artifacts in any DB query (`select uri from workspaces` returns only `workspace://system`).
- Echo demo agent appears at `entity://agent/system/echo_default` and replies in the session (same-workspace, no cross-workspace bypass needed).

### 7.4 Security smoke (codex MUST-FIX #1 mitigation)

After E2E, manually verify the `home_is_system?` security path is NOT regressed:
1. Create a tenant workspace via the magic-link flow (`mix ezagent.workspace.create tenant-a --magic-link-rule "domain:tenant-a.com"`).
2. Register a tenant user via magic-link (`tenant-a@tenant-a.com` → URI becomes `entity://user/tenant-a/tenant-a`).
3. Confirm via `iex -S mix` that `Ezagent.Capability.cross_workspace?(some_cap, URI.parse("entity://user/tenant-a/tenant-a"))` returns `false`.
4. Confirm same call with `URI.parse("entity://user/system/admin")` returns `true`.

If step 3 returns `true` for a tenant user, we have a regression — block the merge and fix.

### 7.3 Codex adversarial-review

Per `feedback_spec_codex_adversarial_review` + `feedback_codex_review_every_pr`:
- SPEC: 1 round at SPEC stage (before any code).
- Impl PR: 2 rounds max (`Round-2 cap`).

---

## 8. Open question — rev 2 (codex MUST-FIX #1 resolved)

**OQ-1 (resolved-correctly in rev 2):** What happens to code paths that currently default the workspace to `"default"`?

### Rev 1 (WRONG) resolution

Rev 1 said: "All users go in `workspace://system`. Admin-equivalent caps are determined by membership in `system` via `Capability.cross_workspace?/2`."

This is **unsafe**. Codex review caught: `Ezagent.Capability.cross_workspace?/2` (`apps/ezagent_core/lib/ezagent/capability.ex:236-253`) grants cross-workspace bypass via `home_is_system?/1`, which checks the caller's STRUCTURAL workspace (i.e. the `<workspace>` segment of the URI), not just membership. Putting tenant users at `entity://user/system/<name>` would silently grant them cross-workspace operator authority.

### Rev 2 (CORRECT) resolution

**`workspace://system` is admin-only.** Tenant users land in tenant workspaces (`workspace://<tenant>`), created at magic-link time per SPEC v2 PR-A's `magic_link_rule` field. The wizard's first session is admin-only — its workspace is `system` because admin's home structurally IS `system`.

Concrete consequences:
- `Ezagent.WorkspaceRegistry.default_workspace_uri/0` is **deleted** (not just renamed). A global fallback would mask the "no workspace passed" bug.
- All callers of the deleted function are updated to derive workspace from the caller URI (`Ezagent.URI.entity_workspace_uri/1`) or fail-fast.
- The 5 `:workspace, "default"` Keyword default sites (codex MUST-FIX #2) are updated to raise on missing `:workspace` rather than silently fall back to `"default"`.
- Demo `echo_default` agent moves to `workspace://system` (it's admin's demo; lives in admin's workspace). When tenants want echo, they create their own at `entity://agent/<their-ws>/echo_<name>` via the template flow.

### What if a non-admin user calls into a path that needed a default?

Fail-fast with `{:error, :workspace_required}` or `ArgumentError`. The 5 production sites flagged by codex are all admin-only paths (wizard, admin user-create LV, admin-only mix tasks) OR have the caller URI in scope to derive structurally. If a previously-untested non-admin path is found in the impl PR, that's a bug — fix it inline (provide explicit workspace), not by re-adding a global fallback.

### Send to Allen for confirmation

Rev 2 makes the SPEC larger (~5 more file changes + the deleted-function audit). The expanded scope is correct, not bloat — the original rev 1 SPEC would have shipped a security regression. Allen has 1 round to push back on either (a) deleting `default_workspace_uri/0` outright vs renaming it to `workspace://system` and treating the security note above as a follow-up, or (b) the echo demo move to `system`.

---

## 9. Implementation order (impl PR) — rev 2 expanded

1. **Delete** `Ezagent.WorkspaceRegistry.default_workspace_uri/0`. Compile; every caller is now an error.
2. Fix each caller per §3.1a — derive from caller URI or pass workspace explicitly.
3. Rename `Session.default_uri/0` return value to `session://default/system/main`.
4. Rename admin_live.ex `@main_session_uri`.
5. Fix admin_caps_live.ex `current_workspace_uri/1` — fail-fast on missing assign (raise `ArgumentError` with mount-discipline message).
6. Fix plugin_feishu `application.ex:175` — remove `|| "session://default/default/main"` fallback; bindings without `session_uri` field are a DB-corruption signal, raise.
7. Fix `session_principal.ex:121`, `session_controller.ex:276`, `session_template.ex:177` + `:489` — remove `:workspace, "default"` Keyword defaults; raise `ArgumentError`.
8. Add admin workspace dropdown to `users_live.ex` admin create-user form OR explicitly require workspace param (block admin from creating users without picking a workspace).
9. Update wizard copy in `home_live.ex` + extract gettext + sync zh_*.
10. Update `home_live.ex:105` echo_uri to `entity://agent/system/echo_default`.
11. Update `echo_plugin/application.ex:71` `@default_uri` to match.
12. Update mix task constants (cc demo seed, feishu bind).
13. Update LV placeholders (`feishu_bindings_live.ex:401`).
14. Sweep docstrings in core (uri.ex, capability.ex, kind/runtime.ex, persistence.ex).
15. Sweep test fixtures (each test file's literal references). Categorize: admin-fixture → `system`; non-admin-fixture → `tenant-a` (or similar).
16. Rename `cap_helper.ex` `@default_workspace` → `@system_workspace`.
17. Add invariant test `no_default_workspace_test.exs` (broadened regex per §6).
18. Run `mix compile --warnings-as-errors && mix test` — fix any breakage.
19. Local E2E per §7.2.
20. Open PR, codex r1, address, codex r2, admin merge.

Estimated impl effort (rev 2): 4-5 hours of careful sweep + 1 hour verification. Larger than rev 1's 2-3 hours because deleting `default_workspace_uri/0` is a real audit (~10 production callers) rather than a literal swap.

---

## 10. Risks + mitigations

| Risk | Mitigation |
|---|---|
| Stray test failure from a fixture asserting on `workspace://default` membership of admin (admin now in `system`) | Sweep includes ALL test fixtures; CI will catch any missed file |
| Operator has stale DB row `workspace://default` | Pre-merge Feishu announcement includes the `rm db && mix ezagent.bootstrap` step |
| Snapshot rows reference old URIs (kind_snapshots table) | Same wipe step; per Allen DB-wipe authorization |
| A test references `workspace://default` for the EXPLICIT purpose of "a workspace that is not system" | Rewrite to `workspace://tenant-a` (or `workspace://team-alpha`) — see §5 |
| Gettext extraction churn for renamed wizard copy | `mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy` handled in impl PR |

---

## 11. References

- `feedback_let_it_crash_no_workarounds` — no backfill / no compat shim.
- `feedback_completion_requires_invariant_test` — §6 is the gate.
- `feedback_codex_review_every_pr` + `feedback_spec_codex_adversarial_review` — review cadence.
- `feedback_open_terminal_first_when_debugging` + `feedback_remote_browser_ip` — verification via agent-browser at `100.64.0.27`.
- `feedback_flag_user_assist_steps` — §7.2 wipe step flagged.
- SPEC v2 `2026-05-24-workspace-user-mental-model-v2.md` — the broader mental model this PR completes.
- Allen 2026-05-25 directive (verbatim) — §0.

EOF
