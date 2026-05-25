# Pointer index + current state

## Durable record

When you (or a future contributor) need authoritative answers:

| Source | What's there |
|---|---|
| `ARCHITECTURE.md` Decision Log Appendix B | #1-#144, full architectural history (Phase 7 ended at #144; PRs #140-#149 SPEC v2 migration documented in `docs/notes/uri-design.md` rather than new numbered entries) |
| `ARCHITECTURE.md` §17.6 | Cap delegation baseline → v1 evolution (Decision #137) |
| `ARCHITECTURE.md` §7 | CapBAC model, cap-for-action, default capability table |
| `ARCHITECTURE.md` §12.8 | CC Channel adapter design (meta schema invariant inline) |
| `GLOSSARY.md` | All Phase 7 terms + 100+ prior project terms; 易混淆词消歧; includes 2026-05-25 caps-cleanup terms (`SystemPrincipal.Catalog`, `required_caps/0`, `holds_cap?/2`) |
| `IMPLEMENTATION_ROADMAP.md` §9 | Phase 6 closeout delivery accounting |
| `IMPLEMENTATION_ROADMAP.md` §9b | Phase 7 delivery accounting (this is where v1 release is recorded) |
| `IMPLEMENTATION_ROADMAP.md` §9c | Phase 8 record-only (multimedia / streaming / Dyte) |
| `docs/notes/uri-design.md` | **URI SPEC v2 normative spec — §5 (11 subsections), §6 migration sequence (PRs #140-#147)** |
| `docs/notes/entity-agnostic-architecture-reflection.md` | 8 entity-agnostic load-bearers in §2; 10 proposals S-1..S-10 in §4; foundation for PRs #141-#149 |
| `docs/superpowers/specs/2026-05-19-phase-8-ide-shell-liveview.zh_cn.md` | Phase 8 IDE Shell spec (Activity Bar / Resource Panel / Main Window / Right Sidebar / Status Bar / CommandPalette IA) |
| `docs/superpowers/specs/2026-05-24-notification-architecture-v2.md` | Notifications v2 spec (single PubSub chokepoint + SubscriberFan) |
| `docs/superpowers/specs/notifications.md` | Notifications stable contract (public surface, invariants, cap model) |
| `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md` | Caps-cleanup SPEC (PR-CC-1 ambient authority removal + PR-CC-2-v2 boundary concern model) |
| `docs/phase-specs/phase7/SPEC.md` | Phase 7 design (LOCKED v3) |
| `docs/phase-specs/phase7/VERIFICATION.md` | V1-V5 acceptance criteria + e2e flows |
| `docs/phase-specs/phase7/PLAN.md` | 24-PR sequence + per-PR workflow + risk register |
| `docs/phase-specs/phase7/DECISIONS.md` | Implementation-time IMPL-7-N decisions |
| `docs/notes/phase-7-handoff.md` | Ezagent v1 release note + 3 trade-offs not to cargo-cult |
| `docs/superpowers/specs/2026-05-23-generator-reconciler.md` | Reconciler SPEC (rev 4) — `Session.spawn_from_template/2` as `converge(spec, current)` instead of atomic-saga + cleanup_partial. Supersedes Phase-7-completion §"Spawn phase" + §1.6/§1.6a. |
| `docs/notes/2026-05-23-generator-reconciler-retrospective.md` | Post-mortem of the 10-round saga-cleanup hardening (#239..#250) → reconciler dissolution (PR-A #259, PR-C #260). Canonical case study for P2 (let-it-crash) + P3 (single SoT). Numbered LESSONS for future devs. |
| `docs/notes/phase-6-architecture-closeout.md` | Phase 6 forensic record (meta schema fix + User default caps + InboundDispatcher mode) |
| `docs/notes/plugin-receiver-kind-contract.md` | Why Plugin X cannot PubSub.broadcast to Plugin Y (Decision #127) — note: SPEC v2 §5.8 supersedes the "Receiver Kind = own a scheme" framing; current pattern is "register a Behavior on the existing core Kind" |
| `docs/notes/phase-7-resume-state.md` | Per-PR live status table (resume any session mid-Phase-7) |
| `docs/notes/phase-8-deploy-notes.zh_cn.md` | Phase 8 branch verification + operator runbook |
| `apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex` moduledoc | **Authoritative source for cc agent sandbox/config** — `claude_config_dir` / `settings_path` / `mcp_config_path` / `api_key_helper`. The standalone `cc-agent-config` SPEC was retired 2026-05-23 and absorbed here. Operator companion: `docs/runbook/cc-agent-config.md` |
| `docs/futures/todo.md` | Durable TODO list (deferred items across sessions). The source of truth for in-flight + future work per `feedback_durable_todo_list`. |

## Current state awareness (Phase 8 / Phase 9 / Caps-cleanup batch)

- **v1 release shipped 2026-05-18** (Phase 7 closeout — Decision #144 captures the cross-PR invariant set; `docs/notes/phase-7-handoff.md` is the release note).
- **URI SPEC v2 migration shipped 2026-05-19** as PRs #140–#149:
  - #140 — SPEC v2 doc (this is the normative source)
  - #141 — `user://` + `agent://` → `entity://`; CLI tokens for any Entity; `current_user_uri` → `current_entity_uri`
  - #142 — scope hierarchy `global ⊂ workspace ⊂ session` + session-scoped rules + SessionTemplate fork replay
  - #143 — Feishu re-shape: `feishu://` scheme deleted; FeishuReceive Behavior moves to User Kind
  - #144 — synthetic singletons (`routing-admin://default`, `pty-input://default`) dissolved
  - #145 — `Ezagent.URI.SchemeRegistry` runtime ETS + `parse!/1` lockdown
  - #146 — query-string action syntax (`/behavior/X/Y` → `?action=X.Y`) everywhere
  - #147–#149 — polish, `Ezagent.AgentTypeRegistry` removal, `Message.uri` → `Message.id`, FeishuOutbound interface + lazy slice init
- **Phase 8 IDE Shell + Phase 9 tenant isolation — both shipped** (merged to main). The VS-Code-like shell + per-workspace entity URIs + tenant-aware auth are live.
- **V1 acceptance phase (2026-05-22) — shipped**: `uri_picker` component + `UriOptions` (PR-1), CmdK command palette (`CommandSource` + `CommandPaletteComponent`, PR-2/2b), member-panel redesign (PR-3), `@interface` `description:` key (PR-0). Spec: `docs/superpowers/specs/2026-05-22-v1-uri-pickers-and-cmdk.md`.
- **Nested shell refactor (2026-05-22) — shipped**: two sibling shells → one outer `ide_shell` + `workspace_shell`/`admin_shell` inner perspectives. Spec: `docs/superpowers/specs/2026-05-22-nested-shell-refactor.md`.
- **Caps-cleanup batch (2026-05-25) — shipped**:
  - **PR-CC-1** — ambient authority removed; `Ezagent.SystemPrincipal.Catalog` is the new closed allowlist (14 URIs) for system-internal principals; replaces inline `URI.parse("entity://system/...")` synthesis.
  - **PR-CC-2-v2** — caps cleanup: `Behavior.required_caps/0` declares per-action cap templates; `Kind.holds_cap?/2` is the chokepoint callback at dispatch step 5.5; cap-check is now a Behavior × Entity boundary concern (no scattered `Capability.matches?/2` calls in LV / controller / Behavior bodies).
  - New invariants gated: `lv_cli_parity`, `workspace_sot`, `no_admin_caps_fallback`, `cap_check_only_at_chokepoint`, `no_wildcard_system_principals`, `dispatch_uses_required_caps`.
  - New Behaviors: `Ezagent.Behavior.WorkspaceUserAdmin` (privileged `:create_user` carved from generic Workspace per PR #356 codex r1 CRIT), `Ezagent.Behavior.UserCredentials` (set_password), `Ezagent.Behavior.UserTokens` (mint/list/revoke), Feishu `UserBinding` + `SessionBinding` (per-Kind chokepoints from PR #355 case study).
