# Handoff — record the 3 PoC demos + attach to their PRs (new session)

> 2026-06-01. **For a fresh session with a live environment.** Phases 0–4 of the
> minimal PoC are done; only Phase 5 (demos) remains. Record 3 demos on `acme`, then
> commit each to its capability's PR branch by category. Plan: `docs/superpowers/plans/2026-06-01-minimal-poc-customer-service.md` Phase 5.

## Goal
Record + attach, **by category**:
| Demo | Shows | PR | Branch to commit the demo to |
|---|---|---|---|
| chat | customer sends → real cc reply | **#529** | `feat/cs-chat` |
| soul | admin edits soul → new conversation reflects it | **#530** | `feat/cs-soul-edit` |
| operator | operator Take-over → customer sees operator, AI suppressed | **#532** | `feat/cs-operator` |

The integrated branch `poc/phase-2-customer-service` has all three capabilities + the
bridge fix, so **record from it**, then copy each demo file onto the matching PR
branch and push (e.g. `git checkout feat/cs-chat -- nothing`; rather: on each PR
branch, `cp` the demo into `docs/assets/…`, `git add`, commit, push; then reference
it in the PR body/comment). GitHub PR-comment image upload needs the web UI
(drag-drop) — committing to the branch under `docs/assets/` is the CLI-friendly path.

## Environment / constraints
- **Always** `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps` on every mix call. **NEVER `mix deps.get`.**
- `gh` always `--repo ezagent42/ezagent`.
- First time on a fresh checkout/after merge: `MIX_DEPS_PATH=… mix ecto.migrate` (dev + `MIX_ENV=test`).

## ⚠️ CRITICAL recording prereq — avoid the claude 2.1.92 OAuth screen
A fresh per-agent `CLAUDE_CONFIG_DIR` triggers the 2.1.92 OAuth login screen →
`EagerBridge` returns `{:error, :oauth_required}` and the cc agent never binds (web
chat hangs). Before recording, ensure the cc agent template **either** uses
`~/.claude` directly (do **not** set `claude_config_dir` in the agent template)
**or** has an `api_key_helper` configured. (See `docs/runbook/cc-agent-config.md` if
present.)

## Start the server (distributed)
```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
COOKIE=$(cat ~/.ezagent/poc-phase2/runtime/cookie)
EZAGENT_PROFILE=poc-phase2 PORT=10142 \
  EZAGENT_BRIDGE_WS_URL=ws://127.0.0.1:10142/agent_bridge/websocket \
  EZAGENT_RUNTIME_NODE=ezagent_runtime_phase2@127.0.0.1 \
  MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps \
  env -u USE_LOCAL_OAUTH -u ANTHROPIC_API_KEY -u CLAUDE_CODE_DISABLE_CRON -u USE_STAGING_OAUTH \
  elixir --name "ezagent_runtime_phase2@127.0.0.1" --cookie "$COOKIE" -S mix phx.server 2>&1 | tee /tmp/poc-demo-server.log
```
If many ephemeral agents accumulated: `EZAGENT_PROFILE=poc-phase2 MIX_DEPS_PATH=… mix ezagent.customer_chat.gc_ephemeral` (server stopped).

## Verify the bridge BEFORE recording (must both appear)
```bash
grep 'CONNECTED TO Ezagent.AgentBridge.Socket' /tmp/poc-demo-server.log   # MCP reached the bridge
grep 'JOINED agent_bridge' /tmp/poc-demo-server.log                        # agent JOINed
```
Plus: actually send a customer message at `/chat/acme` and confirm a real cc reply
before capturing.

## Record (browser-native, no screen-recording permission)
```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
DEMO_MODE=chat     DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo          scripts/demo/record-clean.sh
DEMO_MODE=operator DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo-operator scripts/demo/record-clean.sh
DEMO_MODE=soul     DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo-soul     scripts/demo/record-clean.sh
```

## Attach to PRs by category
For each demo, on its PR branch: `git checkout <branch>`, copy the demo dir into
`docs/assets/`, `git add docs/assets/<dir>`, commit (`docs(demo): <mode> demo`),
push, then `gh pr comment <pr> --repo ezagent42/ezagent --body "Demo: …"` linking the
committed file (`https://github.com/ezagent42/ezagent/blob/<branch>/docs/assets/<dir>/demo.gif`).
chat→#529/feat/cs-chat, soul→#530/feat/cs-soul-edit, operator→#532/feat/cs-operator.

## State recap (so the new session has context)
- Verdict + findings: `poc/phase-2/16-gaps-and-blocks.md` (G1–G6; migration feasible).
- Spec: `15-corrected-minimal-poc-plan`; plan: `docs/superpowers/plans/2026-06-01-minimal-poc-customer-service.md`.
- PRs: #529 (chat), #530 (soul), #532 (operator+takeover) — all compile-green; review-focus comments posted.
- Open coord: cc-bring-up PR ownership (hjj, #512); #511 (Mode) lands first then #532 rebases to drop bundled Mode.
