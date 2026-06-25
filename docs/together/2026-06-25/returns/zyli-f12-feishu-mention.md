> **Task:** F12 — Feishu @ → agent mention (split out of F9 for separate coordination)
> **Branch:** none shipped — investigation branch `feat/f12-feishu-mention-bridge` built, tested, then **dropped** (deleted local+remote; tip SHA `057a0bb4`, reflog-recoverable)
> **PR:** none (no code ships)
> **Dev:** zyli (agent: Claude Opus 4.8)
> **returned_at:** 2026-06-25 13:10 +0800
> **deadline:** 2026-06-25 23:59 +0800
> **deadline_status:** on_time

## Outcome (the headline)

**F12's user-facing capability — "a Feishu message can @-mention an agent and get a reply" — is verified WORKING, and it needs no new mention-parsing code.** The 2026-06-24 validation's `mentions: []` was an operator-usage / setup condition, not missing code: typing the agent name as **literal text `@<agent-name>`** resolves through the pre-existing text-grep (`MentionParser`, Allen 2026-05-17), routes via the global default rule `{:always}→[$session_users,$mentions]`, the agent replies, and the reply mirrors back to the Feishu group AND shows in the world conversation view.

The proposed **direction C** (rewrite Feishu native-@ placeholders `@_user_N` → `@<name>` so the picker case also resolves) was implemented + tested, then **dropped as unnecessary**: an ezagent agent has no Feishu identity (so it can never be native-@'d), and the Feishu bot is the whole app's single transport identity (`system://credentials/feishu.yaml`), not a per-agent handle. C's only effect is cosmetic (placeholder → readable name in stored text); it does not affect routing. Per zyli's call (2026-06-25), C is dropped.

## DoD reconciliation
| # | DoD line | status | proof / note |
|---|----------|--------|--------------|
| 1 | A Feishu @ of an agent routes to that agent and gets a reply | **met (by existing mechanisms)** | Live manual test: `@r3-echo-pty-1` in the bound `feishu-bing` group → echo agent replied → mirrored to Feishu + shown in world conversation. Evidence: `evidence/f12-feishu-@-agent.png`, `evidence/f12-feishu-@agent-world-ui.png` |
| 2 | Mention parsing handles the @ | **met (pre-existing text-grep)** | `MentionParser.extract_agent_mentions` resolves literal `@<agent-name>`; no new code needed |
| 3 | Native-@ placeholder bridge (direction C) | **dropped** | Built + tested (`mention_bridge_e2e_test.exs` green) but no real trigger (agent has no Feishu identity; bot ≠ agent). Cosmetic only → dropped per decision. Branch deleted (SHA `057a0bb4`). |

**Method friction:** the F12 gap was framed as "@ not parsed → no route", which read as a *code* gap. Two passes of real testing showed the parse path already existed (text-grep) and the actual enabler was operator usage (literal `@<name>` text) + the F9 binding I shipped today. The lesson: a validation finding stated as "feature missing" should be re-tested against existing mechanisms + correct operation BEFORE committing to new code — I built direction C before fully confirming it had a real trigger. Net code shipped for F12: zero (correct outcome), but ~1 build cycle was spent on C first.

## Deferred / handed off (NOT mention parsing, NOT my scope)
- **Default `$mentions` routing-rule seeding for certain session types.** The validation's protocol-api session had no `$mentions` rule; normal sessions route via the global default (the tested `feishu-bing` did, "ROUTING 0" notwithstanding). **Whether specific session types (e.g. protocol-api) get the default mention rule seeded** is the routing half — handed to **@林懿伦 (routing) / @张宁 (session-rule UI)** to confirm against their target session types. Tracked in `notes/f12-feishu-mention-coordination.md` §0.3.

## Merge request
- **Nothing to merge for F12.** No code ships. This return + the updated coordination note (`notes/f12-feishu-mention-coordination.md`) + the two evidence screenshots ride along on the F9 branch `feat/product-gaps-f9-f12` (already merge-ready) as the daily record.
- Operator documentation deliverable: **to target an agent from a bound Feishu group, type `@<agent-name>` as literal text** (the agent must be a session member). Folded into the coordination note §0.
