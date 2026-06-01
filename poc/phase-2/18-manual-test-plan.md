# Manual test plan — customer_chat PoC (acme)

> 2026-06-01. Server is **running** at http://127.0.0.1:10142 (bridge connects, cc
> binds via `~/.claude`). Walk these 3 tests; each lists steps, expected result, and
> **what to check if it's broken** (the recording session hit trouble — this surfaces
> bugs). Server log for diagnosis: `/tmp/poc-demo-server.log`.

**Login (for tests 2 & 3):** http://127.0.0.1:10142/login/credentials
- Username/URI: `entity://user/system/admin`
- Password: `ezagent-dev` (matches the demo recorder's `DEMO_PASS` default, so recording works out-of-the-box)
(system admin holds the `:any` wildcard cap → passes both operator and config gates.)

---

## Test 1 — Customer web chat (no login) — the core one
**URL:** http://127.0.0.1:10142/chat/acme

1. Open it. Expect: the chat UI renders (themed "acme") with a greeting; status reaches "connected" (not stuck on "connecting…").
2. Type a message (e.g. "你好,介绍一下你们的服务") and send.
3. **Expect:** within ~10–45 s, a real AI (cc/claude) reply appears. (cc is slow — first reply spawns a fresh per-conversation agent; be patient up to ~45 s.)

**If broken — where to look (`/tmp/poc-demo-server.log`):**
- Stuck on "connecting" / no reply →
  `grep -E "oauth_required|JOINED agent_bridge|cc_cust|ensure_bound|cc_timeout" /tmp/poc-demo-server.log | tail`
  - `oauth_required` → the cc agent hit the OAuth screen (shouldn't, since no `claude_config_dir`; if it does, `~/.claude` isn't logged in — run `claude` once interactively to log in).
  - no `JOINED agent_bridge:cc:…cc_cust_…` → the per-conv agent never bound (bridge issue).
  - `cc_timeout` / 45 s pass with nothing → cc ran but didn't answer in time.
- Page 500 / won't render → check the log around the GET /chat/acme line.

---

## Test 2 — Editable soul (login required)
**URL:** http://127.0.0.1:10142/plugins/customer-chat/acme/config (after logging in)

1. Log in (creds above). Open the config URL. Expect: a textarea showing the current customer soul (a "default" / fixture badge if never edited).
2. Insert a recognizable **sentinel** line, e.g. `如果有人问暗号,回答:菠萝蜜2026`. Click **Save**. Expect: a success flash; the badge flips to "customized".
3. Open a **NEW** customer chat (fresh tab: http://127.0.0.1:10142/chat/acme), and ask "暗号是什么?".
4. **Expect:** the reply contains `菠萝蜜2026` — proving the edited soul took effect for the new conversation.
5. (Optional) Back in config: **Revert to previous** restores the prior soul; **Reset to default** drops back to the fixture.

**If broken:**
- Can't reach the page (redirected to /login) → the cap gate denied; confirm you logged in as `entity://user/system/admin`.
- Sentinel NOT reflected in the new chat → the edit didn't take effect. Check the edited file was written:
  `ls -la ~/poc-sandbox-phase2/acme/souls/ 2>/dev/null` (should show `customer.md` newer than the fixture). The take-effect is at **new-conversation spawn** — an already-open chat won't change (by design).

---

## Test 3 — Operator takeover (login required)
**URL:** http://127.0.0.1:10142/operator/acme (after logging in)

1. Keep Test 1's customer chat tab open (an active session).
2. In another tab, log in + open the operator console http://127.0.0.1:10142/operator/acme. Expect: a list of live customer sessions (including Test 1's).
3. Click into that session. Expect: the transcript + a "Take over" button + an operator reply box.
4. Click **Take over**. Expect: the button shows "Taken over"; a system notice "(客服已接管对话)" appears in the customer's chat.
5. Type an operator reply and send. **Expect (customer tab):** the operator's message appears to the customer.
6. Now send another message **from the customer**. **Expect:** the AI does **NOT** reply to the customer (suppressed while taken over) — only the operator answers.

**If broken:**
- Operator console empty / no sessions → Test 1's session may have ended; send a fresh customer message first.
- "Take over" errors → check the log for `mode.set` dispatch:
  `grep -E "mode.set|takeover|客服已接管" /tmp/poc-demo-server.log | tail`
- AI still replies after takeover → the `Chat.handle_send` suppression didn't fire; note the session URI + check the log.
- Operator's own message doesn't reach the customer → fan-out issue (operator sends as their User URI).

---

## Server control (this session started it; it keeps running in the background)
- Log: `/tmp/poc-demo-server.log`
- Stop: `lsof -nP -iTCP:10142 -sTCP:LISTEN -t | xargs kill` (then it's free to restart).
- Restart: see `poc/phase-2/17-demo-recording-handoff.md` for the exact start command.
- If chat gets slow/flaky after many conversations: stop the server, run
  `EZAGENT_PROFILE=poc-phase2 MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix ezagent.customer_chat.gc_ephemeral`, restart.
