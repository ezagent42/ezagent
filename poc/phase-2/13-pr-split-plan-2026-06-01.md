# Task 3 — PR #446 split plan + divergence reconciliation

> 2026-06-01. Goal: turn the unreviewable umbrella PR #446
> (+12,616 / 100 files, base=main, CONFLICTING, draft) into a stack of small,
> dependency-ordered, compile-green PRs on `main`. FatNine already cut a partial
> split (#511-515) — this doc maps what exists, where it **diverges** from #446,
> and the per-PR action list. Owner of #511-515 = FatNine (= us), so we edit /
> close / rewrite them directly.

## Key reframe (not what the handoff assumed)
#511 / #512 / #514 are **NOT stale copies of #446**. All three forked from the
**same** commit `8ba5f0eb` (today 15:21) and were authored ~16:12-16:13 — a
**deliberate clean re-extraction**, parallel to #446's messy hand-merge. They
diverge from #446 in **both** directions (some slices are *better* than #446,
some are *missing* #446 features). So the job is **reconciliation**, not refresh.

## #446 surface (where the 12.6k lines are)
| Region | +adds / files | Split target |
|---|---|---|
| `poc/phase-2` + `docs/*` + `docs/assets` | **~7,550 / 49** | **stays in umbrella PR #446 — NOT split for review** (PoC docs + demo videos) |
| `apps/ezagent_plugin_customer_chat` | 2,217 / 22 | plugin layer (see DECISION) |
| `apps/ezagent_domain_chat` | 733 / 6 | #511 takeover-mode |
| `apps/ezagent_plugin_cc` | 463 / 4 | #512 eager-bridge + soul_path plumbing |
| `apps/ezagent_domain_pty` | 431 / 4 | #513 (merged) + NEW pty-theme PR |
| `apps/ezagent_web` | 386 / 7 | plugin-wiring PR |
| `scripts/demo` | 269 / 2 | stays in umbrella |
| `apps/ezagent_plugin_liveview` | 81 / 1 | core-fix PR (#419 pattern) |
| `apps/ezagent_domain_workspace` | 42 / 1 | soul_path plumbing PR |

**~60% of #446 is non-code PoC artifacts** → they should never be "split for
review." That alone shrinks the real review surface to ~5k lines.

## Divergence map (#446 vs the split branches)
| Slice | #446 (our HEAD) | Split PR | Canonical = |
|---|---|---|---|
| **Mode / takeover** | direct `Invocation.dispatch` from handler (**violates** Lifecycle DON'T rule) | **#511** effect-based `{:dispatch, %Cmd{}}` (0 direct dispatch) | **#511** — adopt it; backport over #446's mode.ex |
| **eager-bridge** | has `all_fired?` repeat fix | #512 was missing it → **FIXED & pushed** (`18d781fd`) | #512 (now current) |
| **pty theme-picker / UTF-8 scrub / fire_or_rearm** | present (431 adds) | **none** — #513 merged only env/trust/64KB | **NEW pty PR** (couple AFTER #512) |
| **plugin** | `customer_chat` (22 files; **has soul-edit scope#1**, themes, config_live, dashboard/session_view live) | #514 `autoservice` (11 files; customer_session/operator_live/roles/uris; **no soul-edit**) | **❓ DECISION — see below** |
| formatter | n/a | #515 (14/1) trivial | #515 fine as-is |

## Target stack (dependency-ordered, each compile-green on `main`)
**Generic / upstreamable (each its own PR):**
1. ✅ `#513` pty-hardening — MERGED.
2. 🔨 NEW `feat/pty-theme-picker` — theme-picker auto-prompt + `scrub_utf8` + `fire_or_rearm` (rest of domain_pty). **Coupling: must land with/after #512's repeat fix** or the bind gate freezes.
3. ✅ `#512` eager-bridge — repeat fix pushed; ready.
4. ✅ `#511` takeover-mode — Mode (effect-based) + Chat gating; verify tests green.
5. 🔨 small `feat/liveview-uri-fix` — entity_caps URI (#419 pattern, 81/1). Standalone or fold into a core-fixes PR.
6. 🔨 small `feat/agent-soul-path` — `Workspace.create_agent soul_path` (42/1) + `cc_agent` `--append-system-prompt-file` plumbing. **Prerequisite for the plugin.**
7. ✅ `#515` formatter — fine.

**Plugin layer (the vertical, stacked on generic):**
8. ❓ DECISION (below). Then: plugin PR stacked on #511 + #512 + #6; soul-edit scope#1 as its own stacked PR on top.
9. 🔨 `apps/ezagent_web` router/controller wiring for the chosen plugin.

**PoC artifacts (NOT split):** `poc/phase-2` docs, `docs/assets` demos,
`scripts/demo`, `poc/fixtures` → stay in umbrella draft PR #446.

## The one genuine DECISION — plugin canonical impl
Two real, architecturally-different implementations of the same vertical exist:

| | `customer_chat` (#446) | `autoservice` (#514) |
|---|---|---|
| age | earlier (EXT-T* extraction) | **today 16:13** (fresh re-extraction) |
| decomposition | LiveView-per-concern: `chat_live` / `dashboard_live` / `session_view_live` / `config_live` | domain-separated: `customer_session` (350) + `customer_live` / `operator_live` + `roles` / `uris` |
| **soul-edit scope#1** | ✅ `soul_store` + `config_live` + `config_auth` | ❌ absent |
| themes | ✅ `theme.ex` + `priv/customer_chat_themes` | ❌ |
| ephemeral GC | ✅ `gc_ephemeral` task | ❌ |
| size | 22 files / 2,217 | 11 files / 1,382 |

- **A — `customer_chat` canonical**: close/repurpose #514; cut the plugin PR from
  #446's customer_chat; soul-edit ships with it. *Keeps the soul-edit investment;
  bigger PR.*
- **B — `autoservice` canonical**: it's the newer, leaner, domain-separated
  re-extraction; port `SoulStore`/`ConfigLive`/`ConfigAuth` + themes + GC into it;
  retire the customer_chat line. *Cleaner target; needs porting work.*

**Recommendation: needs FatNine's intent** — autoservice is newer & cleaner but
lacks the soul-edit work that's the current focus (AE-BS tasks). If autoservice is
the intended standard, do **B** (port soul-edit in); else **A**.

## DECISION LOCKED (2026-06-01) — B (`autoservice`) canonical + 3-block split
FatNine chose **B**. Reasons (deep compare in `poc/phase-2/` agent report): B is the
cleaner, more ezagent-idiomatic skeleton; its **hot path is a `curl`/DeepSeek HTTP
agent (no PTY, no esr-bridge)** so it **sidesteps the bind blocker** and structurally
mirrors AutoService's pipeline_v2 three-color (deepseek-fast + cc-slow); soul-edit
ports onto it cleanly (editor+auth reusable; `curl_agent` already exposes a runtime
`configure` action → hot system_prompt update, *simpler* than A's file+respawn).
`curl_agent` is **already in `origin/main`** (dependency ready). `customer_chat` (A)
is **retired**; harvest its soul-edit + theming + tests onto B.

### #446 = three functional blocks → three reviewable PRs (the point of splitting)
Verified `operator_live` (takeover) is cleanly separable from `customer_live`/
`customer_session` (it depends only on `Behavior.Mode` + shared `ChatUI` + its own
session-list helper). So:

| Block | Scope (on B) | Source | Base / stack |
|---|---|---|---|
| **0 — takeover behavior** (generic) | `Behavior.Mode` + `Chat.handle_send` gating | **#511** (effect-based, keep) | `main` |
| **1 — AI customer service** | autoservice plugin core: `application`, `customer_session`, `customer_live`, `chat_ui` (shared), `roles`, `uris`, seed task, mix + web route | from #514 (minus operator) | `main` (dep: `curl_agent` ✅ in main) |
| **2 — human takeover console** | `operator_live` + `Mode.set` wiring | from #514 (operator part) | stacked on **#511 + Block 1** (needs `Mode` + `ChatUI`) |
| **3 — soul-edit** (NEW) | `ConfigLive` + `ConfigAuth` (port from A) + slice-backed store + `curl_agent` `configure` hot-update | new, harvest A | stacked on **Block 1** |

`#514` (currently CS+operator bundled, stacked on #511) gets **re-split** into Block 1
+ Block 2. `#515` formatter: keep. The cc-only generic fixes (**NEW pty-theme-picker**,
**#512 eager-bridge**, **liveview URI fix**, **agent soul_path**) are **no longer
prerequisites** for the B blocks (curl path needs no PTY/bridge) — they remain
independent upstreamable PRs for the cc/claude path generally.

### PoC artifacts (per user)
- **Demo videos: DELETE** — they were recorded while the bind was broken, unusable.
  Done this session (`git rm docs/assets`, 17 files / 5.2 MB). Re-record later only
  if needed, after the bind fix.
- **PoC docs: classify by block** — `poc/phase-2/*` were written per functional
  module; tag/group them under AI-CS / takeover / soul-edit so each block PR carries
  its own docs and the umbrella shrinks.

## #446's fate
Umbrella draft. Once Blocks 0-3 merge to `main`, #446 rebases (shrinking to docs +
leftover glue) or closes. It is the PoC demonstration, **not** a merge target.

## Done this session
- ✅ #512 eager-bridge: pushed the `all_fired?` repeat fix (`18d781fd`).
- ✅ Divergence map + deep A-vs-B compare → **DECISION: B canonical**.
- ✅ Deleted unusable demo assets from #446 (`docs/assets`, 17 files).
- ✅ **Re-split #514 → two compile-green stacked PRs** (#514 closed):
  - **#525** Block 1 — AI customer service (autoservice plugin, customer side), base `feat/takeover-mode`, +1081/10f.
  - **#526** Block 2 — human takeover operator console, base `feat/autoservice-cs`, +305/2f.
  - #511 kept as the generic Mode+Chat primitive both build on.
- ⏭ **Block 3 — soul-edit on B (NEW, design-first).** B changes the storage model
  vs A: A = soul *file* resolved at spawn (`--append-system-prompt-file`); B's fast
  agent = `system_prompt` *string* in the `curl.agent` template + slice, with a
  runtime `configure` action for **hot update (no respawn)**. So the port = reuse
  `ConfigLive` + `ConfigAuth` (agent-agnostic), rewrite the store backend
  (file→template/slice), dispatch `configure` to live agents on Save. Needs a short
  design pass (continues AE-BS brainstorm tasks). Optionally also feed the cc 'slow'
  agent a `soul_path` (B currently gives it none).
- ⏭ Classify poc docs by block (AI-CS / takeover / soul-edit).
- ⏭ Independent cc-path generic PRs (not B blockers): NEW pty-theme-picker,
  liveview URI fix, agent `soul_path` plumbing.
- ⏭ Follow-up (any block): write B's missing test suite; tenant-parameterize
  `customer_session.@fast_persona` (no hardcoded zh persona).
