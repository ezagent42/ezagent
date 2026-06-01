# Handoff — "new session no reply" debug + demo recording (resume after compact)

> 2026-06-02. Mid-debug snapshot. PoC code is done + PRs are up; the open thread is
> **getting the 3 demos recorded**, blocked by a "new sessions don't reply" symptom.

## Where the PoC stands (done + pushed)
- Branch `poc/phase-2-customer-service`. PRs (all compile-green, review-focus + gap
  comments posted): **#511** Mode · **#525** PR-1 AI customer chat (base) · **#530**
  PR-2 soul-edit · **#532** PR-3 operator+takeover · **#512** eager-bridge. #446/#514/
  #524/#525-old/#526-old closed.
- Docs: `12` orchestrator-cant-replace · `13` split plan · `14` takeover-routing ·
  `15` corrected-minimal-PoC spec · `16` **Gaps & Blocks (G1–G7 + Meta-finding M1)** ·
  `17` demo-recording handoff · `18` manual-test-plan. Plan:
  `docs/superpowers/plans/2026-06-01-minimal-poc-customer-service.md`.
- Per-PR gap→requirement comments posted; `16` is the consolidated view (M1 groups
  G2/G6/G7 as facets of "ezagent lacks a CS/simple-service session profile").

## Verified working (don't re-litigate)
- **Backend works on claude 2.1.156.** A clean server + FRESH conv via the SSE
  endpoint returns a real, correct cc reply (soul-aware: "Laptops 18-month warranty…").
  Test: `curl -sN -X POST http://127.0.0.1:10142/api/customer/acme/chat -H 'content-type: application/json' -d '{"text":"...","customer_id":"ct1","conv_id":"<FRESH>"}'`
- **Single-page LiveView `/chat/acme` works** (user confirmed: a real user sees the AI answer).
- Code fixes committed+pushed: plain orchestrator-less session template
  (`bootstrap.ensure_session` + `ensure_plain_session_template`), **customer-agnostic
  routing rule** (`bootstrap.install_customer_routing`, matcher
  `{:and,[{:in_session,S},{:not,{:from,agent}}]}`), SSE controller routing wire-in,
  chat input text color, takeover→real Mode, `lookup_mode` durable read.

## The open symptom (what we're debugging)
User: the conversation opened BEFORE recording still replies, but **newly-opened
sessions send a message and get no reply**. User hypothesis: **agent storm** / too
many agents, esp. "every customer session spawns a useless orchestrator."

## Findings so far on the symptom
- The "17 claude processes" I first counted was a **red herring** — it was Claude
  Desktop's Electron helpers + other Claude Code CLI sessions + the self-matching
  grep. **Actual ezagent cc-agent procs ≈ 0–2.** NOT a cc-agent process storm.
- **claude CLI keeps auto-updating**: 2.1.92 → 2.1.150 → **2.1.156**.
- The **system orchestrator** `cc_orchestrator-main` (workspace://system, boot-seeded
  "default" template) spawns at every server boot and **gets stuck on the claude
  2.1.156 "Select login method" OAuth screen** (its isolated `claude_config_dir` has
  no creds) — it does NOT exit cleanly. This is **per-BOOT (one), not per-session**.
- `~/.claude` IS logged in (`~/.claude.json` has `oauthAccount`), so the **customer**
  cc agent (uses `~/.claude`, no `claude_config_dir`) authenticates fine — that's why
  the SSE/single-page tests reply.
- Likely real cause of the user's "no reply": the server they tested was a **churned
  recording-server** (many restarts) with **accumulated session history** (the FIXED
  conv id `chat-demo-acme` piled every prior run's messages → `load_history` rendered
  old random-customers' questions as green "客服" + muddied the turn) and/or a cold
  agent that hadn't bound. A CLEAN server + FRESH conv replies. **Needs the one
  confirming test below (was interrupted by compact).**

## EXACT NEXT STEP (the test that was interrupted)
A clean server is (was) running — bg task `b6bgy7kgk`, log `/tmp/poc-clean-test.log`.
Check `lsof -nP -iTCP:10142 -sTCP:LISTEN`; if down, restart (command below).
1. **New-session reply test**: SSE-POST a message with a FRESH `conv_id` → expect a
   real cc reply within ~110s. (Proves new sessions reply on a clean server.)
2. **Per-session orchestrator check** (answer the user's concern): after creating a
   customer session, verify it did NOT spawn its own orchestrator — only the boot-time
   system `cc_orchestrator-main` should exist. Check:
   `ps -eo command | grep -cE "[c]laude.*orchestrator"` (expect ~1 = system one),
   and grep the server log for an orchestrator tied to the customer session URI
   (`session://default/acme/<conv>`) — expect none (plain template → `orchestrator_template_uri: nil`).
   If confirmed: the plain-template fix holds; customer sessions are orchestrator-less;
   the user's "useless per-session orchestrator" no longer applies (only the 1 system
   boot orchestrator remains, itself OAuth-stuck — worth noting as the real remaining
   orchestrator waste, tied to M1/G7).

## Then: record the demos
- Recorder fixes already applied to `scripts/demo/record-scenario.js` (committed this
  handoff): **stable `cid` per conv** (prewarm + record = same customer) + **unique
  `conv` per run** (`RUN = Date.now()` suffix → fresh empty session, no accumulated
  "客服" history). These two were the demo blockers (NOT the backend).
- Re-record on a clean server: `DEMO_MODE=chat|operator|soul DEMO_TENANT=acme
  DEMO_OUTDIR=docs/assets/demo[-operator|-soul] scripts/demo/record-clean.sh`.
  After each, READ the screenshot (`docs/assets/demo*/0*.png`) to confirm a real AI
  answer renders (not duplicated questions). The recorder's "no agent bubble" log
  line can be a false-negative — trust the screenshot.
- **Known-unverified**: operator demo previously failed waiting for `#chat_text`
  (operator reply box) after take-over — re-check post-fixes; may be the same
  accumulated-state issue.
- Attach demos by category: chat→#529, soul→#530, operator→#532.
- ⚠️ record-clean.sh's cleanup may leak claude procs across runs / the OAuth-stuck
  system orchestrator accumulates — between runs, verify clean with the ps grep above;
  if churn builds up, restart clean.

## Env / invariants
- `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps` on every mix; **never `mix deps.get`**.
- `gh` always `--repo ezagent42/ezagent`. Admin login: `entity://user/system/admin` / `ezagent-dev` (recorder default).
- Server start:
  ```bash
  cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
  COOKIE=$(cat ~/.ezagent/poc-phase2/runtime/cookie)
  EZAGENT_PROFILE=poc-phase2 PORT=10142 EZAGENT_BRIDGE_WS_URL=ws://127.0.0.1:10142/agent_bridge/websocket \
    EZAGENT_RUNTIME_NODE=ezagent_runtime_phase2@127.0.0.1 MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps \
    env -u USE_LOCAL_OAUTH -u ANTHROPIC_API_KEY -u CLAUDE_CODE_DISABLE_CRON -u USE_STAGING_OAUTH \
    elixir --name "ezagent_runtime_phase2@127.0.0.1" --cookie "$COOKIE" -S mix phx.server > /tmp/poc-server.log 2>&1   # run_in_background
  ```
  Restart race: if start fails with "name … in use", the prior beam hasn't released the
  node name — wait, confirm `:10142` free + no `ezagent_runtime_phase2` beam, retry.
