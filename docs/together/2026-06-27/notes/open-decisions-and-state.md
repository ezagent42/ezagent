# 2026-06-27 — Open decisions + work state (durable, lead-facing)

> Single durable record of in-flight work + pending lead decisions for this dev cycle.
> Was previously living only in the assistant's context + the Feishu thread — now persisted here. Keep updated.
> main HEAD at last update: `dc3bf4f1` (#1040).

## ✅ Merged to main today (14 PRs)
`#1018` py-agent P4b · `#1024` autoservice FP2 · `#1025` FP4+FP5 · `#1029` rh docs (was #1022, code stripped) · `#1030` stale-test fix · `#1032` ctx.caps permanent · `#1033` console QA F1–F6 · `#1034` delete advisor plugin · `#1035` render-card mechanism · `#1036` KB retrieval (kb role × native, sqlite FTS5) · `#1037` retire customer → external/anon-user · `#1038` agent.soul rename (was advisor.behavior) · `#1039` unified Domain.Agent.read_* + `no_surface_read_dispatch` gate · `#1040` agent-extension guidance → ezagent-developer skill.

## 🔨 In-flight implementations (subagents)
- **CI flake-fix** `fix/ci-flake-determinism` — #108 root cause (Ecto Sandbox shared-mode revert + loader-spawned Kinds outside `$callers`); Sandbox.allow + DataCase shared-mode + `mix ci.local` + rebuild corrupt shared test DB. **CRITICAL PATH** (flake now reddens real tests, e.g. #1039's AgentReadTest).
- **cr-governance** `feat/cr-governance` — minimal stage→preview→publish on ConfigStore.
- **autoservice-v3 → e2e scenario** `docs/autoservice-e2e-scenario`.
- **F7 redo** `docs/f7-remove-delete-spec` — session-ownership model + agent/user-isomorphic remove_participant + CLI/UI/cross-op audit.

## 📋 SPECs done, pushed, awaiting 立项/impl
- `docs/unify-comms-spec` — unify chat+external on ExternalMirror `:pull` substrate (multi-PR; AnonIngress folded; re-establish external).
- `docs/role-as-data-cr-spec` — role = ConfigObject, CR-as-role; OQ-1 = (b) scriptless-data-roles (decided). **Queued after cr-governance.**
- `docs/ci-flake-diagnosis`, `docs/comms-adapter-research`, `docs/roles-as-data-research`, `docs/autoservice-v3-reference` — analysis/reference docs.

## ⏳ Queued (dep order)
1. role-as-data-cr impl — after cr-governance lands.
2. comms-unify impl (multi-PR PR-1..4) — after the foundational pieces.
3. F7 impl — after the redo SPEC + lead confirm.

## 🟡 Pending lead decisions
1. **F7** — direction confirmed (session-ownership + agent/user isomorphic); awaiting the redo SPEC, then 立项 impl.
2. **comms-unify** — implementation 立项 + sequencing (multi-PR).
3. **autoservice-v3** — reframing to e2e scenario; decide whether the old `docs/futures/autoservice-v3-reference.md` is superseded or kept as capability appendix.
4. **AnonIngress** dedup — folded into comms-unify (not a separate PR).
5. **CustomerFeedAdapter / chat dead `:pull`** — addressed by comms-unify (revive both).

## 📌 Standing backlog (pre-existing tasks, not this cycle's focus)
`#88` inbound email · `#93` cap-gate config reads · `#96/#97` protocol-API naming / sidecar lifecycle · `#99` LocalRuntime migration · `#108` CI flakes (being fixed now) · `#110/#111` deploy testing / ezagent-deploy skill · `#112` OS sandbox for subprocess flavors · `#114` py-agent world e2e · `#55` doc-coverage audit.

## Architectural through-line this cycle
Recurring pattern surfaced + corrected: **business/vertical concepts leaking into the generic core** — salesperson (own-Kind → mechanism), advisor (dead session vertical → deleted), customer (→ anon-user + external visibility), and now F7 (orchestrator spawn-lineage authority → session-ownership). Plus the **config-as-data / CR-governance generalization**: config, role (role-as-data), and the CR `draft→review→publish→re-point` flow converging into one object-governance mechanism.
