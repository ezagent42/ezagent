# Default workspace rename: `default` → `system` (final sweep)

> **Status:** SPEC, awaiting Allen review + codex adversarial-review (1 round).
> **Author:** subagent dispatched by main agent, Allen directive 2026-05-25.
> **Operational constraint:** Allen authorized DB wipe — no migration / back-compat (`feedback_let_it_crash_no_workarounds`, reaffirmed 2026-05-25).
> **Companion ZH:** `2026-05-25-workspace-default-to-system.zh_cn.md`.

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

One default workspace is `workspace://system` (the existing admin workspace). The canonical default session URI is `session://default/system/main`. No `workspace://default` literal exists anywhere in production lib code or tests; the legacy `Ezagent.WorkspaceRegistry.default_workspace_uri/0` now returns `workspace://system`. An invariant test forbids regression.

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

### 3.1 Load-bearing literals (production lib)

| File | Construct | Change |
|---|---|---|
| `apps/ezagent_core/lib/ezagent/workspace_registry.ex:87` | `def default_workspace_uri, do: {:ok, URI.new!("workspace://default")}` | Return `workspace://system` |
| `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:59` | `def default_uri, do: URI.new!("session://default/default/main")` | Return `URI.new!("session://default/system/main")` |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:55` | `@main_session_uri URI.new!("session://default/default/main")` | `URI.new!("session://default/system/main")` |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_caps_live.ex:116` | `URI.parse("workspace://default")` (fallback when assigns missing) | `URI.parse("workspace://system")` |
| `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex:175` | `Map.get(binding, "session_uri") \\|\\| "session://default/default/main"` | `... \\|\\| "session://default/system/main"` |

### 3.2 Wizard / user-visible copy

| File | What | Change |
|---|---|---|
| `apps/ezagent_web/lib/ezagent_web/live/home_live.ex:182` | `gettext("Creates")` line literally renders `session://default/default/<name>` bound to `workspace://default` | Update to `session://default/system/<name>` bound to `workspace://system`; update the `gettext` strings; sync `priv/gettext/zh_*/LC_MESSAGES/` entries (or `mix gettext.extract`) |
| `apps/ezagent_web/lib/ezagent_web/live/home_live.ex:31` | moduledoc "every new session lands on `workspace://default`" | Rename |

### 3.3 Mix tasks (operator-facing)

| File | Change |
|---|---|
| `apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex` | `@session_uri_str "session://default/default/main"` → `"session://default/system/main"`; update docstring + final help text |
| `apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.chat.bind.ex` | Update placeholder + example URIs in `@moduledoc` |

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

### 3.6 Migrations — historical, do NOT rewrite

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

## 5. Renaming map (canonical)

| Old | New | Rationale |
|---|---|---|
| `workspace://default` (production literals) | `workspace://system` | Sole boot-seeded workspace per SPEC v2 PR-C |
| `session://default/default/main` | `session://default/system/main` | Template `default` + workspace `system` + session `main` |
| `Ezagent.WorkspaceRegistry.default_workspace_uri/0` returns `workspace://default` | Returns `workspace://system` | Wizard's `create_session/2` reads this to compute the workspace segment |
| `entity://user/default/<name>` in tests | `entity://user/system/<name>` for admin-adjacent fixtures; `entity://user/tenant-a/<name>` (or similar) for non-admin fixtures requiring an explicit non-system workspace | The two semantics that `default` was conflating are split |
| `apps/ezagent_core/test/support/cap_helper.ex` `@default_workspace` | `@system_workspace`, value `workspace://system` | Naming follows usage |

Test references to "the deleted legacy workspace://default" in comments stay readable — we don't rewrite history; we rewrite live URIs.

---

## 6. Invariant test (the locking gate)

`apps/ezagent_core/test/invariants/no_default_workspace_test.exs` — fails CI if any of the following appear in `apps/*/lib/` (production) OR in load-bearing literals:

```elixir
# Grep targets (regression triggers):
#  1. "workspace://default"     (in any .ex / .exs under apps/*/lib/)
#  2. "session://default/default/" (URI literal anywhere — docstring or code)
#  3. "entity://user/default/admin" (legacy seed regression)
```

Implementation sketch:

```elixir
defmodule Ezagent.Invariants.NoDefaultWorkspaceTest do
  use ExUnit.Case, async: true

  @forbidden ~r/(workspace:\/\/default|session:\/\/default\/default\/|entity:\/\/user\/default\/admin)/
  @scan_roots ["apps"]
  # Lib-only — historical migrations + intentional "legacy" references in
  # docstrings explaining the rename are tolerated.
  @scan_dirs ["lib"]
  # Whitelist: the historical migration files (frozen) + this test itself.
  @whitelist [
    "apps/ezagent_core/priv/repo/migrations/20260601000000_phase9_pr6_workspace_uri_columns.exs"
  ]

  test "no production lib code references workspace://default or session://default/default/" do
    offenders =
      Path.wildcard("apps/*/lib/**/*.{ex,exs}")
      |> Enum.reject(&(&1 in @whitelist))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(@forbidden, line) end)
        |> Enum.map(fn {line, ln} -> "#{path}:#{ln}: #{String.trim(line)}" end)
      end)

    assert offenders == [],
           "Found legacy default-workspace references:\n" <> Enum.join(offenders, "\n")
  end
end
```

Note: scoped to `apps/*/lib/`. Test fixtures (`apps/*/test/`) are also rewritten in the impl PR but not invariant-gated — historic test-only reasoning ("Keycloak realm-admin model, not workspace://default") in moduledocs/comments remains readable.

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

### 7.3 Codex adversarial-review

Per `feedback_spec_codex_adversarial_review` + `feedback_codex_review_every_pr`:
- SPEC: 1 round at SPEC stage (before any code).
- Impl PR: 2 rounds max (`Round-2 cap`).

---

## 8. Open question

**OQ-1 (resolved-by-default):** Should there be a non-admin baseline workspace AT ALL post-merge?

Allen's directive: "如果default是另外一个workspace，可以把default删掉" — sounds like delete entirely.

Current code state (from grep): no production code seeds `workspace://default`. The only references are:
- `WorkspaceRegistry.default_workspace_uri/0` (fallback constant, used by wizard via `create_session/2`).
- Test fixtures (mostly meaning "an arbitrary workspace for this test").

**Default resolution (a):** All users go in `workspace://system`. Admin-equivalent caps are determined by **membership in `system`** via `Ezagent.Capability.cross_workspace?/2` (the existing path per SPEC v2 §1.2). No baseline non-admin workspace exists; tenant workspaces are created via the magic-link flow (`Ezagent.Workspace.create/2`).

Alternative (b): Keep a non-admin baseline workspace under a different name (e.g. `workspace://general`).

**Recommend (a)** per Allen's verbatim "可以把default删掉" and the SPEC v2 v2 mental model. **Send to Allen with the SPEC; default to (a) unless he pushes back within 1 round.**

**Side effect of (a):** `Ezagent.WorkspaceRegistry.default_workspace_uri/0` now returns `workspace://system`. Wizard-created sessions land in `system`. This is correct for first-time admin onboarding (admin IS in `system`). For multi-user post-onboarding, the per-user workspace selection happens via the workspace dropdown — already implemented in `WorkspaceSwitchController` (Phase 9 PR-8).

---

## 9. Implementation order (impl PR)

1. Rename `WorkspaceRegistry.default_workspace_uri/0` return value.
2. Rename `Session.default_uri/0` return value.
3. Rename admin_live.ex `@main_session_uri`.
4. Rename admin_caps_live.ex fallback.
5. Update wizard copy in home_live.ex + extract gettext.
6. Update mix task constants (cc demo seed, feishu bind).
7. Update plugin_feishu application.ex fallback.
8. Sweep docstrings in core (uri.ex, capability.ex, kind/runtime.ex, persistence.ex).
9. Sweep test fixtures (each test file's literal references).
10. Rename `cap_helper.ex` `@default_workspace` → `@system_workspace`.
11. Add invariant test `no_default_workspace_test.exs`.
12. Run `mix compile --warnings-as-errors && mix test` — fix any breakage.
13. Local E2E per §7.2.
14. Open PR, codex r1, address, codex r2, admin merge.

Estimated impl effort: 2-3 hours of mechanical sweep + 1 hour verification.

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
