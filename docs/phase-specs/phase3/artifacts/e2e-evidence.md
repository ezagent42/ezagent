# Phase 3 e2e verification — evidence log

Date: 2026-05-16
Tester: Claude (autonomous, AFK-authorized by Allen on 2026-05-16)
Worktree: `.claude/worktrees/phase-2/` on branch `phase-3`
Server: `mix phx.server` on port 4002

## Automated demo (agent-browser + mix ezagent.routing.add_rule + sqlite)

### Setup

```
# Server boots, plugin chat declares MentionRouting + SessionRouting tables
# (visible in dev.log: RuleStore.load_into_registry/1 query)

# Bridge announces with agent_uri → Agent Kind spawns floating
curl -X POST localhost:4002/api/cc-bridge/announce \
  -d '{"bridge_id":"phase3d-demo","agent_uri":"agent://cc-builder",...}'
→ {"ok":true,"bridge_id":"phase3d-demo"}

# Admin adds routing rule via mix task
mix ezagent.routing.add_rule EsrPluginChat.Routing.MentionRouting \
    text_contains:urgent receivers:session://oncall
→ added rule id=1 to MentionRouting: {:text_contains, "urgent"} → ["session://oncall"]
```

### LV UX demo (agent-browser snapshots)

1. **Sessions sidebar** — initial: `session://main` (default). After
   "+ New session" form submit with "oncall":
   ```
   - button "session://main"
   - button "session://oncall"
   ```

2. **Floating agents** — `agent://cc-builder` (from bridge) +
   `agent://echo` (Phase 1 default).

3. **Add to session** — cc-builder dropdown → select "session://main" →
   agent leaves floating list, appears in main's Members panel as online.

4. **Cross-session routing fires** — admin in main compose sends:
   ```
   "server urgent down — investigate immediately"
   ```
   `text_contains:urgent` matcher fires → routes to session://oncall.

5. **Switch to oncall** (left sidebar click) → message visible in
   oncall chat stream (`[user://admin] · ... server urgent down ...`).
   Same message URI; landed in both sessions via `message_routings` join
   table (#P1-4 fix).

### SQLite evidence

```
$ sqlite3 ezagent_core_dev.db \
    "SELECT session_uri, message_uri FROM message_routings ORDER BY inserted_at DESC LIMIT 5"
session://main|message://967d34534ca9ec63
session://oncall|message://967d34534ca9ec63   ← SAME message_uri, different session
session://main|message://5deb8b611208f3ca     ← prior test run
```

Single `messages.uri` row preserved (Decision #40 identity invariant);
per-session presence in `message_routings`. Same envelope reused across
sessions per identity invariant.

### CapBAC hard flip evidence (runtime test)

`apps/ezagent_core/test/esr/kind/runtime_phase3d_test.exs`:
- "dispatch with empty caps → {:error, :unauthorized} + :denied telemetry"
  — passing
- "dispatch with admin caps → success + :granted telemetry" — passing
- These are the runtime gates (per memory
  `feedback_completion_requires_invariant_test`); grep-based invariant
  #10 is a tripwire only.

Invocations table after demo runs:
```
$ sqlite3 ezagent_core_dev.db \
    "SELECT authz, target FROM invocations ORDER BY id DESC LIMIT 5"
granted|session://oncall/behavior/chat/send  ← cross-session routed send
granted|session://main/behavior/chat/send     ← admin's original
granted|session://main/behavior/chat/join     ← admin auto-joined at boot
```

No `stub_grant` rows — Phase 3d hard flip enforced.

## Gate (all green at phase3 tag)

```
$ mix test
241 umbrella tests, 0 failures

$ mix ezagent.check_invariants
✓ #1 inbound via dispatch (no bare PubSub.broadcast)
✓ #2 use Ezagent.Kind lifecycle (only Kind.Server has def init)
✓ #3 :call to not-ready fail-fast (clause present)
✓ #4 put_new for unique-key (no bare Registry.register)
✓ #6 audit handler async (no direct Repo writes)
✓ #7 zero-match → DLQ :unroutable (API present)
✓ #9 :stub_grant atom not in code (Phase 3d hard flip enforced)
✓ #10 Capability.matches? present in dispatch path (real cap check)
```

## Phase 3 invariants per VERIFICATION.md

- [x] LV /admin agent-browser screenshot exists (`phase3-final.png`)
- [x] SQLite `routing_rules` table populated (1 admin rule + boot reload)
- [x] SQLite `messages` + `message_routings`: same message landing in 2
      sessions (cross-session routing visible)
- [x] mix ezagent.check_invariants 8 of 8 invariants pass (Phase 1+2 + #9 #10)
- [x] Phase 2 functionality preserved (Echo button + Manual Dispatch +
      Audit Log all reachable via Debug area; tests green)
- [x] `:stub_grant` atom GONE from runtime code (grep #9 enforcement)
- [x] `Capability.matches?` present in dispatch step 5.5 (#10 + runtime test)
- [x] Bridge attach leaves agent floating (per P3-D9); admin manually adds
      to session via LV dropdown

## Pending real-claude human verification (optional)

The simulated e2e covers the cap deny + multi-session routing flows
end-to-end. Real-claude validation flow:

1. `bash scripts/cc-bridge-attach.sh` (with `EZAGENT_AGENT_URI=agent://cc-builder`
   in `.local.sh`)
2. Open `http://100.64.0.27:4002/admin`
3. Click cc-builder's "Add to session" → main
4. Send chat from compose; verify claude TUI receives it
5. Claude calls `reply` tool with `session_uris=["session://main"], text=...`
6. Verify reply appears in main chat stream

Phase 3 e2e screenshot is `phase3-final.png` (this directory).
