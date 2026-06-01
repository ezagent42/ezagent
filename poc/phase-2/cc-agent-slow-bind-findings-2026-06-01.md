# cc-agent slow / failed bind on claude 2.1.92 — findings (2026-06-01)

Investigation of why, on the **work machine** (Apple Silicon, macOS 26.5,
**claude 2.1.92**), spawning a per-conversation cc agent takes minutes and
often never binds its `esr-bridge` — whereas the original **home Mac**
(2017, older claude) felt fast. The web customer chat shows "connecting…"
forever because the composer only enables once the agent's bridge joins.

TL;DR — **three stacked, independent root causes**, all consequences of a
newer claude + an accumulated dev DB. Two are fixed in code here, one is an
operational cleanup. A fourth symptom (0 bridge joins across a heavily
churned session) is still open and looks environmental — see "Still open".

## Where the time goes

Server boot is fast (~9 s). The entire cost is the **cc-agent bring-up**:
`PtyServer spawned claude` → claude first-run screens → auto-prompts →
claude MCP init → `JOINED agent_bridge`. The wall-time + hangs were all in
that chain.

## Root cause 1 — boot-storm from accumulated persisted sessions (operational)

Every per-conversation chat persists a session + cc agent. On **every server
restart the server re-spawns all of them at once**. This machine had **33
claude agents spawning at boot** (accumulated `cc_cust_e2e_*`,
`cc_cust_postmerge_*`, `cc_cust_takeover_*`, … from months of e2e runs). 33
claude processes booting simultaneously saturate CPU and starve any *new*
agent's bind.

The home Mac felt fast because at the time it had **few accumulated
sessions** — the pile grew across all the testing since.

**Fix (operational):** `mix ezagent.customer_chat.gc_ephemeral` (run with
server stopped) → removed 25 template registrations + 28 snapshot rows →
boot dropped **33 → 8**. Re-run whenever boot feels slow. The durable fix is
the `ephemeral:` session flag tracked for Allen
(`docs/notes/2026-05-30-ephemeral-agents-allen-note.md`).

## Root cause 2 — claude 2.1.92 theme picker blocks bring-up (FIXED)

claude ≥ ~2.1 shows a **first-run theme picker** ("Let's get started /
Choose the text style that looks best with your terminal / ❯ 1. Dark mode")
whenever it starts in a fresh `CLAUDE_CONFIG_DIR` — which **every per-agent
cc sandbox is**. It blocks *before* the trust + dev-channels dialogs that the
auto-prompt scanner already handles, so claude hung on the theme menu, never
reached MCP init, and `esr-bridge` never bound. The older claude on the home
Mac had no theme picker → no hang.

**Fix:** added a `:theme_picker_dialog` auto-prompt
(`apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex
::default_auto_prompts/0`). Two subtleties, both load-bearing:

- It is **`repeat?: true`** (not one-shot). The picker renders ~1 s in,
  *before* claude's TUI is ready for input, so a single keystroke is silently
  eaten (the same "calling too early eats the \r" hazard as the bridge kick).
  A one-shot prompt would mark itself fired and never retry → stuck. The
  scanner now re-fires repeat prompts, rate-limited to once / 1.2 s, until the
  menu clears.
- It sends a **bare `\r`** (accept the pre-highlighted "Dark mode" default),
  not `1\r`: Enter is harmless if a re-fire leaks onto the next dialog (trust
  / dev-channels both default-highlight their safe option), whereas a stray
  `1` could land as text in the chat input.

Captured a real 2.1.92 theme-picker PTY buffer as a regression fixture in
`server_auto_prompts_test.exs`.

## Root cause 3 — Unicode banner crashes the PTY-stderr logger (FIXED)

claude 2.1.92 paints a Unicode welcome banner (block art `░▓█`, ellipsis
`…`). Those multi-byte codepoints get **split across PTY read chunks**, so a
single chunk can hold a *partial* UTF-8 sequence (e.g. lead byte `0xE2` of
`…` with no trailer). `server.ex` logged the raw stripped chunk at `[debug]`;
interpolating that invalid binary **crashed the Logger formatter** ("bad
return value from Logger formatter, got <<226, 10>>") *inside the PtyServer's
`handle_info`*, and OTP then force-removed the failing log handler —
collateral damage to the process that runs the auto-prompt scanner.

**Fix:** `scrub_utf8/1` drops invalid/partial UTF-8 before logging (valid
codepoints pass through). Verified: formatter crashes went from many → **0**.

## Still open — 0 bridge joins on this session (likely environmental)

After fixes 1–3 (theme prompts fire, UTF-8 crashes gone), agents still did
**not** bind: across ~6 server restarts there were **0 `JOINED agent_bridge`
events on any agent** — except the very first boot of the session, which
bound once. The one boot that bound was the only **non-distributed** one
(epmd empty); every distributed boot since had 0 joins. Mechanistically the
bridge is a WebSocket (`EZAGENT_BRIDGE_WS_URL`, port 10142), not Erlang
distribution, so the correlation is suspect — more likely the machine
degraded after dozens of claude spawns this session (stale state / resource
exhaustion), and/or there is a further 2.1.92 MCP-init step after dev-channels
that produces no PTY output.

Suggested next steps (fresh session / fresh boot):
1. Re-run `gc_ephemeral`, restart **once**, and try a single agent — confirm
   whether a clean boot binds now that fixes 1–3 are in.
2. If still 0 joins: spawn one cc agent and watch its PTY *live* (the
   `/tmp/claude_*_probe.py` PTY harnesses here capture claude's screens with
   a fresh config dir + the cc flags) to see what comes after dev-channels —
   is there another dialog, or does the esr-bridge MCP connection hang?
3. Compare a non-distributed vs distributed boot directly to settle the
   correlation.

## Demo recording (blocked on the bind above)

New tenant-parameterized recorder (fixes the old passive-mode demos that were
static): `scripts/demo/record-scenario.{js,sh}` (modes: `chat` multi-turn /
`operator` 2-context live takeover / `soul` edit before-after, with cold-start
prewarm + reload-retry) and `scripts/demo/record-clean.sh` (clean-restart +
GC-respecting one-demo cycle). Once an agent binds reliably:

```bash
DEMO_MODE=chat     DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo          scripts/demo/record-clean.sh
DEMO_MODE=operator DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo-operator scripts/demo/record-clean.sh
DEMO_MODE=soul     DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo-soul     scripts/demo/record-clean.sh
```

(Recorded on `acme`, not `cinnox`: keeps the PoC repo free of the real
tenant's content, and the features shown are tenant-agnostic.)
