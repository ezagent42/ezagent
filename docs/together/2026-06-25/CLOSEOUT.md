# dev-together closeout — 2026-06-25

Cycle goal (Allen /goal): complete role-foundation RF-2..9 + kanban-as-role
K1..5, cascade-merge, then wrap up. **Headline goal: DONE.**

## What landed on `main` (16990a29)

**Role-foundation RF-1..RF-9 (complete):**
- RF-1 #995 — per-instance behavior resolution + slice-filter generalization (keystone)
- RF-4 #998 — `roles/0` plugin callback + `RoleRegistry`
- RF-8 #999 — `native` flavor + CapMint cap-policy (fail-closed)
- RF-6 #1000 — passive-actor isolation (3 routing gates)
- RF-5a #1001 — role-driven create (direct-spawn) + durable passive persistence
- RF-7 #1002 — list-by-role read model (snapshot-sourced, cold-restart-safe)
- RF-2/3 #1003 — runtime per-instance behavior mount/detach on a live Kind
- RF-9 #1005 — OrchestratorRole via `roles/0` + unified Compose path

**kanban-as-role K1..K5 (complete):**
- K1-K3 #1004 — kanban plugin onto main as role×native (recipe + native dispatch + create + passive + per-node-owner)
- K4-K5 #1007 — world rewire to `list_by_role` + `entity://agent` dispatch (caller caps) + config_surface + frontend + Kanban Kind retired + `resource_kind_as_genserver` AST gate; live agent-browser e2e rendered the board

**Plus:** D-race fix #1006 (Kind-death-window `:noproc` → graceful `:no_such_actor`,
found mid-flight); agent console M1-M4 #994; flake-fix #997 (3 flakes); design/plan
docs #984/#988/#993.

## Review notes (dev-together review step)

- **Per-PR codex-review debt**: the RF/K *implementation* PRs were gated by
  design-level codex review (the RF + kanban specs/plans had 2-3 review rounds
  each) + my lead verification (subagent reports, targeted tests) + CI — NOT a
  per-PR codex adversarial review. This was a deliberate velocity trade
  (surfaced to Allen). The kanban backend PR (#1004) self-flagged its
  codex-review-at-open as not run. **Follow-up option**: post-hoc codex review of
  the merged RF/K PRs if desired.
- **CI flakes (#108)**: `PluginIsolationWorkspaceTest` (PHASE 4 INVARIANT/EXT) +
  `AnonUserGCTest` recur under full-umbrella DB-sandbox churn; #997's poll-fix
  insufficient. Verified-clean PRs were admin-merged on flake-only red (approved
  policy). The D-race fix (#1006) removed the `:noproc` crash class but not these.
- **Admin-merges this cycle**: #1003, #1005, #1007 (each verified clean locally;
  red was only the known unrelated flake). Documented per PR.

## Next plan

1. **py-agent (#107)** — design DONE (spec rev3, 2 adversarial rounds) + plan
   DONE (rev2, review-folded). `docs/together/2026-06-25/specs/py-agent-flavor-{spec,plan}.md`.
   Implementation-ready: P1 (script file-channel + `py` flavor + create route +
   security gate) → P2 (echo→py, delete `ezagent_plugin_echo`, dual parity gate
   incl `echo_default`) → P3 (world e2e) → P4 (role-script channel + retire
   own-Kind→native+role + np→py-role).
2. **Flake-hardening (#108)** — root-cause PluginIsolation + AnonUserGC.
3. **Backlog (pre-existing, not this cycle)**: #88 inbound email, #93 cap-gate
   config reads, #96/#97 (Allen-gated: Protocol API naming / sidecar lifecycle),
   #99 LocalRuntime migration, #55 doc-coverage ratchet-down.

## Tasks reconciled

Completed this cycle: #100-#106 (flake-fix, RF-1, console, kanban spec/plan,
RF-2..9, D-race) + #105 (kanban K1..5). Pending teed-up: #107 (py-agent,
plan-ready), #108 (flake-hardening). Pre-existing backlog unchanged.
