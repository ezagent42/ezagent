# LOC Report — 2026-05-24

> Method: `find apps/*/lib -name '*.ex' -o -name '*.exs' -o -name '*.heex' | xargs wc -l` (no `cloc` on this box). Counts raw line counts (blank + comment + code; LOC, not SLOC). Per-app `lib/` and `test/` measured separately. Baseline = commit `a363a72` (closest commit 2-3 days ago, 2026-05-21).

## Per-umbrella-app totals (`lib/` only)

| App | Tier | LOC | Files |
|---|---|---:|---:|
| `ezagent_core` | Tier 1 (core) | 12,390 | 80 |
| `ezagent_domain_instance_message` | Tier 2 (domain) | 10,305 | 20 |
| `ezagent_domain_identity` | Tier 2 (domain) | 2,491 | 18 |
| `ezagent_domain_workspace` | Tier 2 (domain) | 1,579 | 8 |
| `ezagent_domain_ui` | Tier 2 (domain) | 3,829 | 17 |
| `ezagent_domain_pty` | Tier 2 (domain) | 898 | 4 |
| `ezagent_domain_python` | Tier 2 (domain) | 1,465 | 7 |
| `ezagent_plugin_cc` | Tier 3 (plugin) | 2,334 | 9 |
| `ezagent_plugin_liveview` | Tier 3 (plugin) | 11,366 | 31 |
| `ezagent_plugin_feishu` | Tier 3 (plugin) | 2,583 | 18 |
| `ezagent_plugin_curl_agent` | Tier 3 (plugin) | 850 | 5 |
| `ezagent_plugin_echo` | Tier 3 (plugin) | 724 | 4 |
| `ezagent_plugin_np` | Tier 3 (plugin) | 728 | 4 |
| `ezagent_web` | Web / presentation | 4,993 | 36 |
| `ezagent_cli` | CLI | 1,088 | 8 |
| **Total `lib/`** | | **57,654** | **269** |

### Per-tier roll-up (lib/)

| Tier | LOC | % of total | Files |
|---|---:|---:|---:|
| Tier 1 — core | 12,390 | 21.5% | 80 |
| Tier 2 — domain (6 apps) | 20,567 | 35.7% | 74 |
| Tier 3 — plugins (6 apps) | 18,585 | 32.2% | 71 |
| Web + CLI | 6,081 | 10.5% | 44 |

ARCH §14 LOC budget target for core was historically ~920 LOC (the "less invented more assembled" principle, P8). Current core is well above that — but core now includes the full URI parser, scheme registry, capability + capability registry, all 8 registries, dispatch runtime, ready-gate, pending-delivery, audit infra, snapshot infra, persistence, and reliability primitives. The ratio to be watched is "core grows because primitives multiplied," not "core grows because plugin logic leaked in."

## Test LOC per app

| App | LOC | Files |
|---|---:|---:|
| `ezagent_core` | 10,357 | 82 |
| `ezagent_domain_instance_message` | 12,650 | 41 |
| `ezagent_domain_identity` | 1,095 | 15 |
| `ezagent_domain_workspace` | 1,387 | 9 |
| `ezagent_domain_ui` | 1,620 | 13 |
| `ezagent_domain_pty` | 226 | 3 |
| `ezagent_domain_python` | 821 | 8 |
| `ezagent_plugin_cc` | 2,623 | 10 |
| `ezagent_plugin_liveview` | 3,570 | 25 |
| `ezagent_plugin_feishu` | 696 | 10 |
| `ezagent_plugin_curl_agent` | 246 | 4 |
| `ezagent_plugin_echo` | 604 | 5 |
| `ezagent_plugin_np` | 935 | 7 |
| `ezagent_web` | 2,428 | 24 |
| `ezagent_cli` | 609 | 7 |
| **Total `test/`** | **39,867** | **263** |

## Top 10 files by LOC (lib/ only)

| File | LOC |
|---|---:|
| `apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/tools.ex` | 1,792 |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex` | 1,711 |
| `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex` | 1,457 |
| `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` | 1,024 |
| `apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex` | 816 |
| `apps/ezagent_domain_ui/lib/ezagent_domain_ui/primitives.ex` | 811 |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/routing_live.ex` | 760 |
| `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex` | 733 |
| `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex` | 724 |
| `apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/mcp_server.ex` | 722 |

## Total

| Bucket | LOC |
|---|---:|
| Production (`apps/*/lib/`) | 57,654 |
| Tests (`apps/*/test/`) | 39,867 |
| Repo-root docs (md) | 4,982 (ARCHITECTURE + IMPLEMENTATION_ROADMAP + GLOSSARY + CLAUDE.md + AGENTS.md + README) |
| All `docs/` (md) | 33,456 |

**Test-to-production ratio**: 39,867 / 57,654 = **0.69x** (test code is 69% of production code by line). Reasonable for an OTP umbrella with heavy integration + invariant testing; the heaviest test apps (`domain_instance_message` 12,650 LOC, `core` 10,357 LOC) are the ones doing the most cross-Kind orchestration work, which makes sense.

## Comparison vs 2-day baseline (commit `a363a72`, ~2026-05-21)

| App | lib Δ | test Δ |
|---|---:|---:|
| `ezagent_core` | **+4,484** | +3,551 |
| `ezagent_domain_instance_message` | **+7,199** | +10,508 |
| `ezagent_domain_identity` | +167 | 0 |
| `ezagent_domain_workspace` | +407 | +485 |
| `ezagent_domain_ui` | +491 | +62 |
| `ezagent_domain_pty` | +64 | 0 |
| `ezagent_domain_python` | +1,304 | +764 |
| `ezagent_plugin_cc` | +1,067 | +1,994 |
| `ezagent_plugin_liveview` | +2,403 | +600 |
| `ezagent_plugin_feishu` | +164 | +128 |
| `ezagent_plugin_curl_agent` | +75 | +46 |
| `ezagent_plugin_echo` | +183 | +97 |
| `ezagent_plugin_np` | **+728** (new app) | +935 |
| `ezagent_web` | +903 | +400 |
| `ezagent_cli` | 0 | +3 |
| **Total** | **+19,639** | **+19,573** |

**Test-to-production growth ratio**: 19,573 / 19,639 = **1.00x** — the 2-day session added tests in lock-step with code. The heavy invariant-test discipline (P6) shows up here.

The biggest two-day movers:
- `domain_instance_message lib +7,199` — primarily PR1 fork lift, PR2 Sandbox wiring in `agent.ex`, PR3 `record_sandbox_state` + `sandbox.destroy` migration in orchestrator tools. Also includes earlier-in-window PRs (#280-#284 LiveView refactors) that are not in this audit scope.
- `core lib +4,484` — primarily PR2's `Behavior.Sandbox` (389 LOC) + `Kind.Template` callback declarations; PR-D's `Capability.cross_workspace?/2` membership branch; plus pre-audit-window primitives (Audit infra, ReadyGate hardening, etc).

Caveat on baseline: the `a363a72` baseline includes ~85 commits across 2 days, only the last 10 of which (PRs #287-#296) are in scope for this audit. The non-audit commits contribute significantly to the LOC delta (e.g. PR #275 — np plugin extraction, +1,500 LOC). The audit-scope PRs alone are roughly **+3,800 LOC production / +3,900 LOC test** (sum of PR additions per `gh pr view`).
