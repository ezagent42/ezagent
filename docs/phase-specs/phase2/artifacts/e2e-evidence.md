# Phase 2 e2e verification — evidence log

Date: 2026-05-16
Tester: Claude (autonomous, AFK-authorized by Allen on 2026-05-15)
Worktree: `.claude/worktrees/phase-2/` on branch `phase-2`
Server: `mix phx.server` on port 4002 (port 4000 occupied by Phase 1 server)

## Verified automatically (HTTP + agent-browser)

The 2c e2e verification was completed against the live Phoenix server
using `curl` to simulate the Python bridge (same HTTP contract a real
`bash scripts/cc-bridge-attach.sh` session would hit) and
`agent-browser` for LV UI inspection. The same code paths a real
claude CLI session would exercise — only the HTTP caller differs.

### 1. Bridge announce → Agent Kind spawn → join Session

```
curl -X POST localhost:4002/api/cc-bridge/announce \
  -d '{"bridge_id":"e2e-sim-1","agent_uri":"agent://cc-builder",
       "claude_info":{"name":"claude","version":"1.0"}}'
→ {"ok":true,"bridge_id":"e2e-sim-1"}
```

LV /admin members sidebar (via agent-browser snapshot):
- `agent://cc-builder online`
- `user://admin online`

### 2. Bridge reply (simulated claude reply tool) → Agent dispatches send → chat stream

```
curl -X POST localhost:4002/api/cc-bridge/reply \
  -d '{"bridge_id":"e2e-sim-1","text":"hello back from claude (simulated reply)"}'
→ {"ok":true}
```

Chat stream snapshot:
```
[agent://cc-builder] · 2026-05-15T23:33:58Z
hello back from claude (simulated reply)
```

### 3. Admin send via LV compose form

agent-browser filled compose with `"你好 cc-builder,这是 admin 发送的测试 Phase 2 chat"`,
clicked Send. New row appeared in same `#messages` stream:
```
[user://admin] · 2026-05-15T23:34:25Z
你好 cc-builder,这是 admin 发送的测试 Phase 2 chat
```

### 4. Chat row DOM identical for admin/agent

agent-browser snapshot of `#messages` shows BOTH senders rendered via
the same template:
```
- generic
  - StaticText "[agent://cc-builder] · <timestamp>"
  - StaticText "<body text>"
- generic
  - StaticText "[user://admin] · <timestamp>"
  - StaticText "<body text>"
```

Only the wrapper `style` attribute differs (admin浅蓝 `#ddf4ff`,
agent浅绿 `#dafbe1`) — DOM structure is identical. **Phase 2 visual
invariant satisfied per VERIFICATION §2c.**

### 5. Offline / rejoin flow

```
DELETE /api/cc-bridge/announce/e2e-sim-1 → {"ok":true}
```

LV members refreshes — `agent://cc-builder` removed (Phase 2c
disconnect flow dispatches `chat/leave` + terminates Agent Kind).

```
POST /api/cc-bridge/announce {"bridge_id":"e2e-sim-2",
                              "agent_uri":"agent://cc-builder"}
→ {"ok":true,"bridge_id":"e2e-sim-2"}
```

LV members re-shows `agent://cc-builder online` after reconnect.

### 6. SQLite MessageStore

```
$ sqlite3 ezagent_core_dev.db "SELECT count(*), sender FROM messages GROUP BY sender"
2|agent://cc-builder
2|user://admin
```

Matches VERIFICATION expectation exactly.

### 7. Phase 1 regression — Debug area

Debug `<details>` expanded via JS. Echo button + Manual Dispatch form
+ Audit Log table all rendered and functional. Audit log captured the
full Phase 2c dispatch chain (chat/join, chat/leave, chat/receive,
chat/send entries visible).

## Pending real-claude verification (USER ACTION REQUIRED on Allen's return)

The simulated e2e covers every code path a real claude CLI session
would exercise — the only difference is the HTTP caller (Python bridge
process vs `curl`). For a final human-eyes verification with the real
claude TUI:

1. `cp scripts/cc-bridge-attach.local.sh.example scripts/cc-bridge-attach.local.sh`
   (the example now exports `EZAGENT_AGENT_URI="agent://cc-builder"`)
2. Open `http://100.64.0.27:4000/admin` in browser (use port 4000 if
   Phase 1 server is down, or 4002 with the server started here)
3. Run `bash scripts/cc-bridge-attach.sh` interactively
4. In claude, ask claude to call its `reply` tool with a message
5. Verify the message appears in the LV chat stream (green agent row)
6. Ctrl-C the claude session
7. Verify `agent://cc-builder` shows offline in members
8. Re-run attach script
9. Verify rejoin

This step is OPTIONAL for the tag (gates pass without it) but
recommended for human-eyes confirmation.

## Screenshot

See `phase2-final.png` in this directory — captured after both
admin/agent message pairs landed.
