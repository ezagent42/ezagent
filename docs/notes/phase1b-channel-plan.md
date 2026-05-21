# Phase 1b — Channel Server Plan (REV after channels-reference recon)

**Date**: 2026-05-15
**Status**: DRAFT for Allen sign-off
**Predecessor**: phase1b @ 508e1b2 (rolled back — single-direction MCP, not a channel)

## What I learned from https://code.claude.com/docs/en/channels-reference

The big surprise: **a "channel" IS just an MCP server with one extra capability flag**. It's not a separate process, not a separate protocol layer, not a websocket — same stdio MCP I already have. The doc says verbatim:

> "A channel is an MCP server that pushes events into a Claude Code session ... Claude Code spawns it as a subprocess and communicates over stdio. ... The only hard requirement is the `@modelcontextprotocol/sdk` package and a Node.js-compatible runtime."

(Node SDK is what the doc demos with. We're using raw JSON-RPC in Python — that's fine because MCP is just JSON-RPC and the channel additions are additional methods, not a new transport.)

### The 3 channel-specific additions on top of MCP

| Addition | Where | Direction |
|---|---|---|
| `capabilities.experimental['claude/channel'] = {}` | In `initialize` response | declares this is a channel |
| `notifications/claude/channel` method | Server → claude (JSON-RPC notification, no id) | **Ezagent push → claude as `<channel>` tag** |
| Standard MCP tool (e.g. `reply`) | Claude → server (`tools/call`) | **claude reply → Ezagent** |

That's it. No new transport, no WebSocket, no separate channel-server process.

### Launch flag

```bash
claude --dangerously-load-development-channels server:esr-bridge
```

During research preview this bypasses the channel-allowlist (with confirmation prompt). The `server:NAME` matches the MCP server name in `.mcp.json`. **Combined with `--mcp-config` for the actual server registration.**

### The optional permission-relay (NOT in Phase 1 v1_prototype)

`capabilities.experimental['claude/channel/permission']` + handler for `notifications/claude/channel/permission_request`. Out of scope for Phase 1.

## What changes from current 508e1b2

Current state:
- Python MCP server with `initialize`, `tools/list`, `tools/call reply` (no `esr_announce` — announce is implicit at init)
- HTTP `POST /api/cc-bridge/announce` for one-way claude→Ezagent proof
- LiveView shows connected bridges, no message flow

Channel-ready state:
1. **Python bridge** (~+50 LOC):
   - Add `experimental: {"claude/channel": {}}` to initialize response
   - Add `instructions` to initialize response telling Claude how to handle channel events
   - Add `reply` tool (announce stays implicit at init — no separate tool)
   - Add SSE subscription to `GET /api/cc-bridge/events?bridge_id=X` — pulls Ezagent-side messages
   - On SSE event arrival, emit `notifications/claude/channel` to claude over stdout
2. **ezagent_web** (~+40 LOC):
   - Add SSE endpoint `GET /api/cc-bridge/events?bridge_id=X` that subscribes to Phoenix.PubSub topic `esr:bridge_v1:to_claude:<bridge_id>` and streams events as SSE
   - Existing POST endpoint stays (claude → Ezagent path)
3. **LiveView /admin** (~+30 LOC):
   - Add "Send message" form per connected bridge → calls `Ezagent.Bridge.V1Prototype.Server.push_to_claude/2` → PubSub.broadcast → SSE → bridge → claude
   - Subscribe to `esr:bridge_v1:replies:<bridge_id>` topic to show claude's replies
4. **Server GenServer** (~+30 LOC):
   - Add `push_to_claude/2` (broadcasts on the per-bridge to_claude topic)
   - Add `record_reply/3` (called by the new `/api/cc-bridge/reply` POST endpoint when claude calls the reply tool)
5. **attach script** (~+1 LOC):
   - Add `--dangerously-load-development-channels server:esr-bridge` to the claude invocation

## Architecture diagram

```
  LV /admin (browser)
      ↓ form submit (mode=cast)
  Ezagent.Invocation.dispatch  (existing)
      ↓ behavior=channel/push  (NEW small Behavior)
  Ezagent.Bridge.V1Prototype.Server.push_to_claude(bridge_id, text)
      ↓ Phoenix.PubSub.broadcast esr:bridge_v1:to_claude:<bridge_id>
  ezagent_web SSE endpoint (subscriber)
      ↓ SSE stream
  Python bridge (SSE client)
      ↓ MCP notifications/claude/channel
  Claude Code TUI shows <channel source="esr-bridge" ...>
      ↓ claude responds, calls reply tool
  Python bridge tools/call handler
      ↓ HTTP POST /api/cc-bridge/reply
  EzagentWeb.CcBridgeAnnounceController.reply
      ↓ Ezagent.Bridge.V1Prototype.Server.record_reply
      ↓ Phoenix.PubSub.broadcast esr:bridge_v1:replies:<bridge_id>
  LV /admin shows reply in "messages with claude" panel
```

## Verification (revised 1b-G2)

The empirical test for "really connected via channel":

**Step 1**: Allen runs `bash scripts/cc-bridge-attach.sh` interactively. TUI opens.

**Step 2**: Allen types `/mcp` in the claude TUI. He should see `esr-bridge` listed AND a channel indicator on it (per the docs, channels-as-MCP-servers show up in /mcp with the channel marker — verify in test).

**Step 3**: Allen opens browser to `/admin`. Sees `bridge-XXXX connected claude-code 2.1.142`.

**Step 4**: In LV /admin, Allen types "你好,告诉我你能听到吗?" in the new "Send to claude" form and submits.

**Step 5**: In claude TUI, Allen sees a `<channel source="esr-bridge" ...>你好,告诉我你能听到吗?</channel>` block appear as user input. Claude responds.

**Step 6**: Claude's response is captured (via the reply tool → POST /reply → PubSub → LV). LV shows "claude reply: ..." in real time.

**Step 7**: Screenshot showing both the LV form + the messages panel with claude's reply.

**This is the empirical proof of bidirectional channel.** If any step fails, we know exactly where because each piece is observable.

## File-level plan

| File | Action | ~LOC |
|---|---|---|
| `apps/ezagent_plugin_cc_bridge_v1_prototype/python/esr_mcp_bridge_v1_prototype.py` | add experimental capability + reply tool + SSE subscription + notification emit | +60 |
| `apps/ezagent_web/lib/ezagent_web/controllers/cc_bridge_announce_controller.ex` | add `events_sse/2` + `reply/2` actions | +50 |
| `apps/ezagent_web/lib/ezagent_web/router.ex` | add GET /api/cc-bridge/events + POST /api/cc-bridge/reply | +2 |
| `apps/ezagent_plugin_cc_bridge_v1_prototype/lib/esr/bridge/v1_prototype/server.ex` | add push_to_claude, record_reply, per-bridge topics | +30 |
| `apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex` | add Send-to-Claude form + replies panel | +60 |
| `scripts/cc-bridge-attach.sh` | add `--dangerously-load-development-channels` flag | +1 |
| `docs/phase-specs/phase1/SPEC.md` + `VERIFICATION.md` + `PLAN.md` | revise to channel mode | edit |
| `apps/ezagent_plugin_cc_bridge_v1_prototype/test/` | add channel-mode tests | +60 |

Total: ~263 LOC code + spec rev.

## Risks / unknowns

1. **SSE in Phoenix**: Phoenix is HTTP/2 friendly and SSE works via long-lived streams. Need to verify Bandit (our adapter) supports SSE cleanly. Fallback: HTTP long-poll.
2. **Bridge process lifetime**: when claude exits, the bridge subprocess gets SIGPIPE on stdin close → SSE connection in the bridge needs cleanup. Should be straightforward (close on EOF in main loop's finally block).
3. **`/mcp` TUI channel indicator**: docs don't show what the TUI shows for channel-capability servers. I'll empirically verify and write the test step around what we actually see.
4. **`--dangerously-load-development-channels` confirmation prompt**: doc says it prompts on first use. May require human key-press first time. Plan: I run interactive once to clear the prompt, then headless mode works.

## What this DOESN'T do (still v1_prototype boundary)

- ❌ Sender authentication (any HTTP POST to `/api/cc-bridge/reply` is accepted)
- ❌ Capability gating on the channel push path (LV uses admin caps)
- ❌ Multiple parallel claude sessions (bridge_id is unique but no enforcement)
- ❌ Permission relay (`claude/channel/permission`) — Phase 5
- ❌ Persistent message history (Phase 2 with Chat Behavior)
- ❌ Tool surface beyond `reply` (Phase 5 full MCP tool set)

## Estimated work

- Implementation: 4-6 hours
- Verification + screenshots: 1 hour
- Spec rev: 30 min

Total: ~half a working day.

## Status of phase1b tag

Current `phase1b = 508e1b2` will be rolled back when this plan is greenlit. New phase1b commit will replace it.

## Next step

Send this doc to Allen for review. After sign-off:
1. Roll back phase1b tag again
2. Implement per the file plan
3. Run verification
4. Re-tag + push
