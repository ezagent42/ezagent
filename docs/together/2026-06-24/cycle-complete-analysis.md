# 2026-06-24 dev cycle — complete analysis (every PR, including out-of-scope)

> Requested by @林懿伦: "昨天还有好几个 out-of-scope 的任务，review 也都考虑到了吗？给我一个昨天工作的完整分析报告." The earlier `review.md` + audit-addendum covered the **named returns** (#931/#938/#918/zyli/#956/#958/official-site). This document accounts for **the entire cycle** — ~40 PRs (#922–#968) — under the four-property-DoD lens, and explicitly covers the out-of-scope work the review omitted.

## 0. Honest gap in the prior review
The prior `review.md` / audit-addendum analyzed the agent-authored returns and the two big incidents, but did **not** account for: the out-of-scope items (**#940 LOGO, #941 cf-container research, #942 containerize, #952 gaga plans**), the lead-track infra (**#922/#928 resource-type, #925, #947**), gaga's **#945**, and zyli's UI PRs (**#949/#950**). This report closes that gap.

## 1. Full inventory by track + scope

### A. Cycle scaffolding (lead, docs/process) — verified-at-merge
`#924` plan · `#926` team.md roster · `#929/#930` handoffs · `#927` core-bug handoff · `#932/#933/#936/#946` dev-together push/close · `#923` #84 finalize. **Complete** — these are the cadence artifacts; no code risk.

### B. Lead-track code (Claude) — all gated by precommit+check_invariants at merge
| PR | What | DoD lens |
|---|---|---|
| `#922`/`#928` | Plugin-owned `resource://` type registration PR-1 (core) + PR-2 (world adopter; raw_home_path 2→1) | ✅ gated; arch ratchet moved correctly |
| `#925` | `EZAGENT_NO_DISTRIBUTION` dev-infra skip | ✅ small, gated |
| `#937` | Bug B — resolver replays plugin resource types on Registry restart | ✅ regression test + codex MED fixed |
| `#939` | Bug A — observe silent pre-delivery cast loss (promote of #934) | ✅ E2E done (zyli batch), telemetry added |
| `#943` | #93 read cap-gate symmetric with writes | ✅ gated — **but** see #966: it left `delete_path`'s pre-auth read ungated (fixed tonight) |
| `#947` | workspace-locality gate (distributed-BEAM prep) | ✅ gated; default resolver = local no-op |
| `#948` | #92 umbrella sandbox owner-exit race | ✅ proven over multi-run |
| `#951` | #94 MentionFailedTest flake (unique URIs) | ✅ regression-targeted |
| `#954/#955/#957/#960` | #95 LocalRuntime facade + migrate cc/codex/echo/feishu/advisor + skill docs | ✅ gated; arch caps ratcheted down |
| `#959` | #98 F14 routing self-loop | ✅ regression test |
**Risk note:** these merged BEFORE the CI gate (#962) existed, so they were gated by the lead running `mix precommit` locally — not by CI. The #943→#966 miss (one ungated read path) shows local-gating can still miss a logic defect a test would catch; that's the verification-axis lesson the new DoD addresses.

### C. Agent-authored returns (the higher-risk set)
| PR | Dev | Verdict | Note |
|---|---|---|---|
| `#931` cc-headless SDK sidecar | gaga | ✅ **complete** | real Python `claude-agent-sdk` subprocess, real Claude turn proven (audit-addendum) |
| `#938` agent-config facade | gaga | ⚠️ **defect fixed** | `delete_path` existence leak → fixed tonight (#966); echo-no-config silent (→#918) |
| `#945` codex-remote roundtrip | gaga | ⚠️ **verify** | restores codex-remote session roundtrip; was gated at merge, but no audit ran — recommend a spot-check that the remote roundtrip has a live/E2E proof, not only a unit fix (same class as #931's "real path" question) |
| `#956`→`#961` hello official-site | zhaomato→lead | ⚠️ **was never-green; greened+landed** | 6 reds fixed by lead; **frontend renderer still desync'd from backend shadcn catalog** → the official-site rework task (separate) |
| `#958` agent-console CRUD | fatnine | ✅ **merged** | via #968 (integrated onto current main + CI-gated) → main `80ebce2f` (CI first run caught 1 **unrelated** flake; re-run green); backend solid; **0 UI/route tests** (deferred to gaga); fatnine branch intact, #958 closed |
| `#918` echo→Entity.Agent | fatnine | ⛔ **OPEN, stale** | goal-complete but 37 behind main + #957 LocalRuntime conflict → fatnine rebase + LocalRuntime-args decision |

### D. zyli (validation + product-UI fixes)
| PR | What | Verdict |
|---|---|---|
| `#944` | 全流程人肉验证 + rebase-batch verification | ✅ complete-with-evidence (7 legs; crux cleared) |
| `#949` | logout/switch-account UI (F3) | ✅ small UI; surfaced from the human-run |
| `#950` | store agent API key UI (F10) | ✅ small UI; surfaced from the human-run |
| `#953` | F14 doc re-attribution (UI-disable already correct → core) | ✅ docs |
**Surfaced but NOT yet built (new backlog):** F9 (Feishu chat→session bind UI), F12 (Feishu `@`→agent mention parse). L3/L4 of the run only passed via DB workarounds because of these.

### E. Out-of-scope work (the part the review missed) — were they justified + complete?
| PR | Dev | Scope call | Justified? | Complete? |
|---|---|---|---|---|
| `#940` LOGO.png | lead | out_of_scope | ✅ trivial asset, harmless | ✅ |
| `#941` CF Containers cost/suitability research | Claude | out_of_scope | ✅ feeds the #65 CF-Workers/deploy decision (a real weekly concern) | ✅ docs/notes; decision is Allen's |
| `#942` fully containerize the Mac stack (PG+mihomo+cloudflared) | Claude | out_of_scope | ⚠️ **questionable scope** — a full docker stack landed as out-of-scope work during a cycle whose goal was "team uses ezagent daily"; useful for disposable-E2E but the disposable stack was retired this week (plan standing rule). Worth confirming it's actually used vs speculative. | ✅ as docker/docs, but utility unconfirmed |
| `#952` protocol-api + sidecar lifecycle plans | gaga | out_of_scope (research) | ✅ feeds #96/#97 (your decisions) | ✅ docs; decisions pending you |

**Out-of-scope observation (process):** ~4 out-of-scope items landed in one cycle, mostly Claude-authored (#941/#942) + research. Individually justified-ish, but collectively they're scope-drift: a cycle nominally about 4 human-dev tracks also absorbed infra research + a docker stack. The new dev-together plan has an explicit "Off-plan (support, not human-dev tracks)" section for exactly this — but it should be **budgeted/declared**, not accreted. Recommend: out-of-scope work declares itself in `plan.md`'s off-plan section *before* doing it, so the cycle's real surface area is visible.

## 2. Net open items (consolidated, after tonight)
- **#958** ✅ merged (#968 → `80ebce2f`); LiveViewTest deferred to gaga.
- **#918** fatnine: rebase + LocalRuntime-args decision (shared with #99).
- **#945** recommend a live-roundtrip spot-check (codex-remote).
- **#942** confirm the docker stack is actually used (or note as speculative).
- **New backlog:** F9, F12 (zyli product-UI gaps).
- **Your calls:** #96/#97 (protocol/sidecar), `enforce_admins` flip, #99 go-ahead, F9/F12 prioritization.

## 3. Cycle health summary
- **Volume:** ~40 PRs; high throughput.
- **Quality signal:** of the 4 agent build-returns, **2 came back not-meeting-bar** (#956 never-green; #958 missing UI tests) and **1 cross-layer migration left half-done** (official-site frontend). That's the pattern that drove the dev-together overhaul (#965) + CI gate (#962).
- **Verification gap (now closed):** everything before #962 was lead-locally-gated; the #943→#966 miss shows why CI + the four-property DoD were needed.
- **Scope discipline:** out-of-scope/off-plan work was real and mostly useful but un-budgeted — flagged for the next plan.
