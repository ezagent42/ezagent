# Dead Code Audit — 2026-05-24

Audit run against `main` HEAD `18700b8` (Promote-to-system PR-D merged) + working tree on `cleanup/default-workspace-references` (mid-flight). Read-only — no production code modified.

## Summary

| Category | Count | Effort to clean |
|---|---|---|
| Compiler warnings (unused / never-called / unreachable) | **0** | LOW |
| True stub functions (no-op, no callers benefit from side effects) | **0** | — |
| Orphan mix tasks (no external invocation in code/docs/scripts) | **1** | LOW |
| Unrouted LVs | **0** | — |
| Unrouted controllers | **0** | — |
| Unregistered Behaviors / Kinds / Template Classes | **0** | — |
| TODO / FIXME placeholders | **4** | varies |
| Unused test fixtures | **0** | — |
| Unused third-party deps | **0** | — |
| **"Removed-from-production but still wired through UI"** (real find) | **1 cluster, ~80 LOC across 4 files** | **MED** |
| Suspect "legacy" markers still in production code | **6 mentions** (commentary, code already collapsed) | LOW (delete comments) |

**Headline finding**: the codebase is in unusually good shape. `mix compile --force` produces ZERO warnings across 14 apps (244 .ex files). The single substantive cleanup target is the `registration_domains` AppSetting cluster — explicitly marked "REMOVED from production path" in PR-C (PR #295, 2026-05-24), but the LV settings page, the magic-link CLI debug task, the migration that creates the column, and the underlying `Registration.domain_allowed?/1` function are all still wired and shippable. See Section 9 for the structural recommendation.

---

## Section 1 — Compiler warnings

`mix compile --force` (run 2026-05-24 against working tree):

```
==> ezagent_core
Compiling 80 files (.ex)
Generated ezagent_core app
==> ezagent_domain_pty        Compiling  4 files
==> ezagent_domain_python     Compiling  7 files
==> ezagent_domain_identity   Compiling 18 files
==> ezagent_domain_workspace  Compiling  8 files
==> ezagent_plugin_cc         Compiling  9 files
==> ezagent_domain_ui         Compiling 17 files
==> ezagent_domain_chat       Compiling 20 files
==> ezagent_plugin_feishu     Compiling 18 files
==> ezagent_plugin_liveview   Compiling 31 files
==> ezagent_plugin_echo       Compiling  4 files
==> ezagent_plugin_curl_agent Compiling  5 files
==> ezagent_web               Compiling 32 files
==> ezagent_plugin_np         Compiling  4 files
==> ezagent_cli               Compiling  8 files
```

**Zero warnings, zero unused-variable, zero unreachable, zero never-called.** `precommit` alias runs `compile --warning-as-errors`, so this is structurally enforced. The single CI signal that *did* catch dead code (`mix xref unreachable / deprecated`) is now folded into the compiler itself — Elixir 1.18 message: `"The unreachable check has been moved to the compiler and has no effect now"`. `mix deps.unlock --unused` produced no output → all entries in `mix.lock` are reachable from `mix.exs`.

---

## Section 2 — Stub functions

The `grep "do: :ok$"` sweep found **74 matches across all `apps/*/lib`**. Every match was inspected: each one is a legitimate guard / fallthrough / validation-clause pattern, NOT a PR-C-style stub. Examples of the patterns found (all keep):

| Pattern | Example | Why it's not dead |
|---|---|---|
| Validation fallthrough | `defp check_class(%{"class" => "cc.agent"}), do: :ok` | Multiple-clause function; the `:ok` is the success arm |
| Guard for missing optional | `defp grant_caps(_agent_uri, []), do: :ok` | Empty-list short-circuit before processing |
| Capability bypass for `:system` | `defp check_subscribe_cap!(%{caps: :system}, _kind, _uri), do: :ok` | Documented bypass for bootstrap principal |
| Telemetry handler no-op | `def handle_event(_event, _m, _meta, _cfg), do: :ok` | Telemetry handler ignores untargeted events |
| Lifecycle no-op | `def terminate(_reason, _state), do: :ok` | OTP callback contract |

The only function explicitly tagged "REMOVED from production path" — `Ezagent.Registration.domain_allowed?/1` — is NOT a `:ok` stub (it computes a real boolean against AppSettings). See Section 8.

**Conclusion**: **no true no-op stubs**. The PR-C `maybe_ensure_default_non_admin_user` precedent did NOT recur.

---

## Section 3 — Orphan mix tasks

Cross-reference of each Mix task's name against the entire repo (code + scripts + docs):

| Task | External invocations | Status |
|---|---|---|
| `ezagent.feishu.list` | **0** (only its own `@moduledoc`) | **Candidate for deletion** OR documentation in runbook — does work the LV `/plugins/feishu/bindings` page already does (`list_all/0`). 30 LOC. |
| `ezagent.auth.magic_link` | 2 (self + parity-audit doc) | KEEP — operator debug tool; intentionally diverges from HTTP path per P27 (see parity audit). |
| `ezagent.demo.seed_cc_agent` | 2 (self + runbook) | KEEP — demo seeder. |
| `ezagent.feishu.unbind` / `chat.unbind` | 2 each (self + 1 doc/test) | KEEP — admin tools; mirrored in LV. |
| `ezagent.snapshot.dump` / `list` / `clear` | 3–4 each | KEEP — operator tools; CLI/LV parity doc explicitly preserves them. |
| `ezagent.check_invariants` | 18 | KEEP — CI gate. |
| All other tasks | 6–15 | KEEP — bootstrap / DB / plugin / routing tooling, all referenced in scripts or runbooks. |

Detail on the single orphan:

```
$ grep -rn --include='*.{ex,exs,sh,md}' "mix ezagent.feishu.list" apps/ scripts/ docs/
apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.list.ex:6:      mix ezagent.feishu.list
```

`ezagent.feishu.list` (30 LOC) just enumerates `EzagentPluginFeishu.UserBinding.list_all/0` and pretty-prints. The same data is rendered by `/plugins/feishu/bindings` (`FeishuBindingsLive`). No script, doc, or runbook references it; the CLI/GUI parity audit (`docs/notes/2026-05-24-cli-gui-parity-audit.md`) does not list it as a parity case.

**Recommendation**: low-confidence delete. Per Allen's "production usability is selection criterion" (`feedback_production_usability_is_selection_criterion`), keep iff operators ever run it in incident response. Recommend asking before deleting; alternative is adding a one-liner in `docs/runbook/common-failures.md`.

---

## Section 4 — Unrouted LVs / controllers

Cross-referenced every LV module under `apps/*/lib/**/*_live.ex` and every controller under `apps/ezagent_web/lib/ezagent_web/controllers/*.ex` against `apps/ezagent_web/lib/ezagent_web/router.ex`.

**LVs (25 total)** — every one is routed:
- `HomeLive` (root), `AdminLive` (/sessions), `AdminDashboardLive` (/admin), `ObservabilityLive`, `EntitiesLive`, `SnapshotsLive`, `AdminTemplatesLive`, `AdminCapsLive`, `AdminAuthzAuditLive`, `SettingsLive`, `WorkspacesLive`, `WorkspaceDetailLive`, `RoutingLive`, `IdentitiesLive`, `UsersLive`, `EntityCapsLive`, `UserApiKeysLive`, `AgentNewLive`, `AgentDetailLive`, `AgentExtensionsLive`, `TerminalLive`, `PluginsLive`, `FeishuBindingsLive`, `AutoDeriveLive`, `ProfileLive`.

**Controllers (10 total)** — every one is routed:
- `FallbackController`, `UploadsController`, `RegistrationController`, `WorkspaceSwitchController`, `ApiV1Controller`, `SessionController`, `MagicLinkController`, `OnboardingController`, `CcEventsController`, `HealthController`.

**No orphans.**

---

## Section 5 — Unregistered Behaviors / Kinds / Template Classes

Enumerated every module implementing `@behaviour Ezagent.Behavior`, `@behaviour Ezagent.Kind`, `@behaviour Ezagent.Kind.Template`, `@behaviour Ezagent.Plugin` (excluding test/ paths). 35 implementations total. Each was traced to a registration site:

| Type | Module | Registered at |
|---|---|---|
| Behavior | Presence, Routing, Notifications | `ezagent_core/.../application.ex` |
| Behavior | Sandbox, Lifecycle, Chat, Template | `ezagent_domain_chat/.../application.ex` |
| Behavior | Identity, ApiKeys | `ezagent_domain_identity/.../application.ex` |
| Behavior | Pty | `ezagent_domain_pty/.../application.ex` |
| Behavior | Workspace | `ezagent_domain_workspace/.../application.ex` |
| Behavior | CurlAgent | `ezagent_plugin_curl_agent/.../application.ex` |
| Behavior | Echo | `ezagent_plugin_echo/.../application.ex` |
| Behavior | NpAgent | `ezagent_plugin_np/.../application.ex` |
| Behavior | FeishuOutbound | `ezagent_plugin_feishu/.../application.ex` (per-action loop) |
| Kind | System, Agent, Session, User, SessionTemplate, AgentTemplate, Workspace, CurlAgent, Echo, NpAgent | All registered via `SpawnRegistry.register` in their owning app's Application |
| Template Class | GenericSession, EzagentPluginEcho.Template.EchoAgent, EzagentPluginCurlAgent.Template, EzagentPluginCc.Template.CcAgent, EzagentPluginNp.Template.NpAgent | All registered via `TemplateRegistry.register` or plugin `template_classes/0` |

**No unregistered modules.** This is exactly what the plugin contract test (`plugin_contract_test.exs`) + the `:ezagent_plugin_check` Mix compiler gate guarantees structurally (P23).

---

## Section 6 — TODO / FIXME placeholders

```
apps/ezagent_domain_identity/lib/ezagent/identity.ex:91             ## TODO Phase 8d
apps/ezagent_domain_ui/lib/ezagent_domain_ui/ide_shell.ex:499       TODO Phase 8d: replace with proper cap:admin check
apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/profile_live.ex:87
                                                                    # TODO Phase 9 — wire through Ezagent.ApiKeys.list_for/1.
apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:1481
                                                                    # (Phase 7 PR 46 TODO), load_or_init loads from DB and
```

Four total. Each is a known-future-work pointer (Phase 8d / Phase 9 / Phase 7 PR 46), not abandoned dead code. No `FIXME` or `XXX` anywhere. No `@deprecated` annotations in production code.

**Status by item**:
- Identity:91 + ide_shell:499 — both reference "Phase 8d cap:admin check". With CapabilityRegistry now landed (PR #150-ish, late Phase 8), these may be resolvable. Worth a separate ~30 min look.
- profile_live:87 — wire `Ezagent.ApiKeys.list_for/1`. UserApiKeysLive already exists (`/identities/users/:uri/api-keys`); this is the personal `/profile` mirror. Low effort.
- admin_live:1481 — historical PR 46 marker; the surrounding logic resolves load_or_init from DB, so the TODO note may be stale.

**Recommendation**: triage TODOs as a separate follow-up; none look load-bearing or actively misleading.

---

## Section 7 — Unused test fixtures

Five test-support modules across all umbrella apps:

| Module | Referenced by |
|---|---|
| `EzagentWeb.ConnCase` | 11 test files |
| `Ezagent.Test.CapHelper` | 4 (self + 3 test files; `Phase 9 PR-3`, well-used) |
| `Ezagent.Test.TestBehavior` | 3 (self + Kind.Server / Invocation / Runtime tests) |
| `Ezagent.Test.FixturePlugin` | 2 (self + plugin boot test) |
| `Ezagent.PluginNp.Test.FakeCcAgent` | 3 (self + e2e + behavior test) |
| `Ezagent.PluginNp.Test.MockDeepSeek` | 2 (self + e2e) |

**No unused fixtures.**

---

## Section 8 — "Removed-from-production" cluster (the one real find)

PR-C (PR #295, "delete default workspace + seeds, SPEC v2 PR-C", merged 2026-05-24) explicitly removed `registration_domains` AppSetting from the production magic-link gate. The replacement is per-workspace `magic_link_rule` rows (PR-A / #292). However, the OLD path is still wired through several places:

| File:line | What it does | Status post-PR-C |
|---|---|---|
| `apps/ezagent_domain_identity/lib/ezagent/registration.ex:65-86` | `Registration.domain_allowed?/1` | Module doc explicitly says "REMOVED from production path … remains exported ONLY for tests / observability tools." Function is dead in production. |
| `apps/ezagent_domain_identity/lib/ezagent/app_settings.ex:8` | Documents `registration_domains` as a valid AppSetting key | Stale doc comment. |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/settings_live.ex:50, 143-167, 178-181, 484-516` | LV form to read/edit/save `registration_domains` allowlist (Task 4 section) | **Writes data nothing reads.** Operators can still enter a "registration domains" allowlist via the admin UI but production gate now ignores it. False signal. ~80 LOC + template chunk. |
| `apps/ezagent_web/lib/mix/tasks/ezagent.auth.magic_link.ex:123-128` | `send_allowed?/1` falls back to `Registration.domain_allowed?(email)` instead of new `Registration.email_allowed?(email)` | **CLI debug tool no longer matches production gate.** Violates "test commands before suggesting" if operator uses this to diagnose a real "no email received" report (`feedback_test_commands_before_suggesting` + P27). |
| `apps/ezagent_web/lib/mix/tasks/ezagent.auth.magic_link.ex:84-95` | "Common causes" diagnostic prints `registration_domains` advice | Stale advice. |
| `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex:348, 382` | Error message + comment still reference `registration_domains` "back-compat" | Stale strings; harmless but misleading. |
| `apps/ezagent_core/priv/repo/migrations/20260530000000_app_settings.exs:6` | Migration moduledoc lists `registration_domains` as a valid key | Migration is frozen by definition (cannot edit); only the comment is stale. |
| `apps/ezagent_domain_identity/test/ezagent/registration_test.exs:30-37` | Tests for `domain_allowed?/1` | Tests pass because the function still works; the function just isn't called in production anymore. |
| `apps/ezagent_domain_identity/test/ezagent/app_settings_test.exs:7-14` | Tests AppSettings round-trip with `registration_domains` as the key | Still valid as a generic AppSettings test; harmless. |

**Severity**: per Allen's P2 (let-it-crash; no workarounds / defaults / whitelists), the LV form + CLI debug task are **active misdirection** — they suggest configuration that no longer affects production. The legacy `domain_allowed?/1` + tests + AppSettings docstring are passive dead weight.

**Recommendation**: see PR-1 in Section 9.

---

## Section 9 — Recommended PR sequence

Sorted by risk (low → med) and effort (low → med):

### PR-1 (MED effort, MED-HIGH value): Finish PR-C — delete `registration_domains` everywhere

**Goal**: re-establish single-source-of-truth on per-workspace `magic_link_rule` (P3). Per Allen's `feedback_dont_defer_what_is_solvable_now` — PR-C left this cleanup behind; finish it.

**Files to modify** (~120 LOC net deletion):
1. `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/settings_live.ex` — remove Task 4 section: handler `save_registration_domains`, `load_registration_domains`, mount call, template form, status panel. ~80 LOC.
2. `apps/ezagent_web/lib/mix/tasks/ezagent.auth.magic_link.ex` — switch `send_allowed?` to call `email_allowed?/1`; rewrite the "common causes" section to point at `Ezagent.Workspace.any_workspace_accepts?` + per-workspace `magic_link_rule` admin UI.
3. `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex` — clean up the two `registration_domains` error strings/comments (lines 348, 382).
4. `apps/ezagent_domain_identity/lib/ezagent/registration.ex` — delete `domain_allowed?/1` (it's the canonical "kept for tests" anti-pattern Allen pushed back on with `feedback_let_it_crash_no_workarounds`).
5. `apps/ezagent_domain_identity/test/ezagent/registration_test.exs` — delete the two `domain_allowed?` tests.
6. `apps/ezagent_domain_identity/lib/ezagent/app_settings.ex:8` — remove `registration_domains` from the moduledoc list of valid keys.
7. `apps/ezagent_domain_identity/test/ezagent/app_settings_test.exs:7-14` — switch the round-trip test to use a different key (e.g. `smtp_config` or a fixture key) so the test still exercises put/get generically.

**Verification** (per `feedback_completion_requires_invariant_test` / P6):
- Add an invariant grep test in `apps/ezagent_web/test/integration/` that asserts the string `"registration_domains"` does NOT appear in any production .ex file under `apps/*/lib`. If it ever reappears, the test fails — proves the cleanup stays clean.
- Existing tests must still pass.
- Run the magic-link CLI against an email that's allowed by a workspace rule and confirm it sends; against an unallowed email confirm it diagnoses correctly (no more "registration_domains" advice).

### PR-2 (LOW effort, LOW value): Decide on `ezagent.feishu.list`

Either delete the 30-LOC mix task (if operators don't use it) OR add it to `docs/runbook/common-failures.md` under "How to inspect Feishu bindings without the admin UI." Recommend asking Allen — it's a 5-second decision he should make.

### PR-3 (LOW effort, varies): TODO triage

Walk the 4 TODOs in Section 6 and either resolve or convert to issues. None are dead code per se; they're forward-pointers some of which may already be obsolete (admin_live:1481, profile_live:87 with CapabilityRegistry landed).

### Not recommended

- **Delete `ezagent_plugin_np`**: it's a deliberate e2e test harness app for the cc/curl/python triad. Not wired into the running web app (intentional). The 4-agent comprehensive e2e is its sole consumer. Keep.
- **Delete legacy comments**: 15+ "legacy" / "PR #149" / "SPEC v2 §X" comments throughout. These are forensic breadcrumbs Allen explicitly wants kept (`feedback_study_mature_projects_first` — historical context helps future devs).
- **Touch any deleted-scheme references** in code (`user://`, `agent://`, `feishu://`, etc.). All remaining mentions are in moduledoc/comments explaining migration history. No code path constructs or parses them.

---

## Notes on methodology

- Compiler warnings: `mix compile --force 2>&1 | grep -iE "warning|unused|never called|unreachable"` → empty.
- Stub functions: `grep -rn "do: :ok$" apps/*/lib --include='*.ex'` → 74 hits, all triaged manually as legitimate guards.
- Mix tasks: per-task `grep -rn --include='*.{ex,exs,sh,md}' "mix <name>\b"` for invocation sites.
- LV/controller orphans: enumerated files, transformed snake_case → CamelCase module name, grep'd against `router.ex`.
- Behaviors/Kinds/Templates: `grep -rn "@behaviour ...\b"` for declarations; cross-ref against per-app `application.ex` registration call.
- Deps: per-app `mix.exs` deps list + `grep` for module-name usage across `apps/` + `config/`. Plus `mix deps.unlock --unused` (empty output).

Audit duration: ~30 min. Methodology described in `/Users/h2oslabs/Workspace/esr-ng/docs/notes/2026-05-24-dead-code-audit.md` (this file).
