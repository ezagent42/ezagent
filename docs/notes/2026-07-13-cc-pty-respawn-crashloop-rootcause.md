# cc PTY respawn crash-loop — root cause (canary, 2026-07-13)

**Status:** root cause reproduced verbatim on canary. Fixes land on this branch
(`fix/pty-crashloop-halt-and-continue-flag`); this note is the evidence record.

**Subject:** `entity://ezagent/agent/test-zyli-cc-1` respawns its `claude` child
every ~7 s without end (`.claude.json` `numStartups` 523 at report time).

**TL;DR — the incoming handoff's root cause was wrong, and the fix it prescribed
would have been a no-op.** The loop is not an authentication failure. It is
`--continue`, added by our own respawn path, failing permanently against a
config home that has no resumable conversation. The auth-failure OBSERVER the
handoff wanted to hook the halt decision to **never fires** in this scenario
(0 hits across 933 crashes).

---

## 1. Symptom

`EzagentDomainPty.Supervisor` restarts the PtyServer, `handle_continue(:spawn_pty)`
spawns a fresh `claude`, the child exits within a second, repeat. `RespawnBackoff`
correctly rate-limits it to ~7 s/cycle (so it never trips supervisor intensity and
never takes siblings down — that part works as designed), but nothing ever *stops*
the loop.

## 2. Evidence — canary, 2 h log window

Container `ezagent-canary-ezagent-1` (image `ezagent:canary`), `claude` **2.1.162**.

| Signal | Count in 2 h |
|---|---|
| `PtyServer spawned claude … test-zyli-cc-1` | **933** |
| `child process exited … test-zyli-cc-1` | **933** |
| `respawn backoff … test-zyli-cc-1` | **933** |
| **`AUTH FAILURE signal … matched`** | **0** |
| `parked` (ParkedDialogWatch) | **0** |

Every cycle has the same shape:

```
05:02:36.894  PtyServer spawned claude os_pid=31027
05:02:37.549  auto-prompt dev_channels_dialog matched — sending "1\r"    (655 ms after spawn)
05:02:37.586  child process exited: {:exit_status, 256}                  (37 ms after the keystroke)
```

`exit_status 256` = `1 << 8` = exit code 1.

The live command line (captured from the running process):

```
/usr/bin/claude --continue --dangerously-skip-permissions \
  --dangerously-load-development-channels server:esr-bridge \
  --settings /app/lib/ezagent_plugin_cc-0.1.0/priv/claude-pty-settings.json \
  --mcp-config /data/default/cc-agents/ezagent/test-zyli-cc-1/.mcp.json
```

## 3. Reproduction (isolated copy of the config home — production dir untouched)

The agent's `CLAUDE_CONFIG_DIR` was copied to `/tmp` inside the container and every
run below executed against the **copy**. The real config home, the DB and the BEAM
node were never written to.

| Run | Command | Result |
|---|---|---|
| **C** | prod cmd, trusted cwd, no keystroke | parks on the dev-channels dialog, alive at 18 s |
| **D** | prod cmd **minus `--continue`** + `"1\r"` | **boots the full TUI, alive at 22 s — no crash** |
| **E** | **exact prod cmd** + `"1\r"` | **exit 1**, screen reads `No conversation found to continue` |
| **F** | exact prod cmd + `"1\r"`, with the agent's **real transcript made resumable** | **exit 1**, same message |

Run D vs run E isolates the cause to a single flag. Run F closes the remaining
hole: the agent *does* carry a 7 799-byte transcript
(`projects/-data-…-test-zyli-cc-1/5271f2db-….jsonl`), but even when that transcript
is placed where `--continue` can find it, claude still reports **no conversation to
continue**. The transcript is a fragment left by a crashed session, not a resumable
conversation — and `sessions/` is empty.

## 4. Root cause

### Defect 1 — `--continue` on the respawn path (cc plugin). This is the loop.

`apps/ezagent_plugin_cc/lib/ezagent/template/spawn_plan.ex:31-37` adds `--continue`
to every respawn, resting on this comment:

> "Verified empirically: on a first spawn with no prior conversation `--continue`
> degrades gracefully to a fresh session (**it does not error**), so it is safe on
> the respawn path even if the very first spawn had crashed before persisting a
> transcript."

**That assertion is false on claude 2.1.162.** `--continue` with nothing resumable
prints `No conversation found to continue` and exits 1.

The result is a **self-sustaining deadlock**, and the flag is what sustains it:

```
claude crashes → no resumable conversation is persisted
  → respawn adds --continue
  → "No conversation found to continue" → exit 1
  → still no resumable conversation → repeat forever
```

The respawn path guarantees that a child which failed once can never succeed again.

### Defect 2 — the respawn decision is unconditional (Domain.Pty). This is why it never stops.

`Ezagent.Domain.Pty.Server.handle_continue(:spawn_pty)` always throttles and then
spawns. There is no notion of "this agent must not be brought up again", so *any*
permanently-failing child loops forever. `RespawnBackoff` slows the loop down; it
was never meant to terminate it.

### Not the cause — missing credentials (a real but independent defect)

The agent genuinely has no credentials: `.credentials.json` is absent, the container
exports no `ANTHROPIC_*`, and `claude -p "say OK" --settings <the real settings file>`
returns `Not logged in · Please run /login`.

This is real and will stop the agent from ever *replying* — but it does **not**
produce the crash loop. claude's TUI boots fine without credentials (run D) and only
fails when it tries to talk. The incoming handoff conflated the two: its repro
(`claude -p 'hi'`) omitted both `--settings` and `--continue`, so it missed the
actual killer and surfaced an unrelated (if genuine) symptom.

## 5. Why the prescribed fix would not have worked

The handoff asked to hook the halt decision to the existing #17 PR-C auth-failure
OBSERVER ("don't invent new detection — that's the halt trigger"). But the observer
matches PTY output against
`[~r/Please run \/login/, "API Error: 403", ~r/API Error: 401/, ~r/Invalid API key/]`
(`cc_agent.ex:220`), and **none of those strings is ever printed** in this failure —
confirmed by 0 hits across 933 crashes, and by runs C–F, in which no auth signal ever
appeared. Wiring halt to that observer yields a green unit test (which simulates the
observer firing) and a canary that keeps spinning at ~470 respawns/hour.

## 6. Fix plan

1. **Tighten `--continue` (cc plugin).** Only pass it when a resumable conversation
   actually exists, or fall back to a `--continue`-free retry when it fails. Correct
   the falsified comment at `spawn_plan.ex:31-37`; it is the origin of this bug.
2. **Make the respawn decision vetoable (Domain.Pty).** The handoff's structural
   instinct is right — only the trigger was wrong. Use a **cause-agnostic crash-loop
   halt**: after K consecutive spawns that never reach a healthy lifetime, stop
   respawning and move the agent to a terminal `:needs_login`/`:halted` state.
   `RespawnBackoff` already counts exactly this (`attempt_count/1`) — promoting it
   from "slow it down" to "trip a breaker" is a small change. This trigger catches
   *this* bug (which is not auth at all), plus the auth case, the OOM case, and the
   wrong-dialog-option case. The auth observer and `CredentialPrecondition` can feed
   the breaker as *faster* additional triggers, but must not be the only ones.

## 7. Gaps found on the way

* **There is no operator "stop"/"restart agent" control anywhere.** The world UI
  exposes `agents.create`, `agents.delete` and `agents.config.*` only
  (`apps/ezagent_plugin_world/lib/ezagent/world/agent_actions.ex`); `mix ezagent`
  exposes `agent.create` only. The handoff assumed manual recovery could "reuse the
  existing liveness/restart control" — that control does not exist, and fix (2) has
  to add it, otherwise a halted agent has no way back.
* **`claude -p` exits 0 when not logged in**, so a headless credential failure is
  silent to any exit-code check.
* `CredentialPrecondition.check_materialized/2` already returns
  `{:skip, {:config_home_without_credentials, flavor}}` for exactly this agent's
  on-disk shape, but it is only wired into the automatic-materialization lane
  (`session_creator/definition_agents.ex`). The PTY respawn path has no credential
  awareness at all.

## 8. Method

All canary access was read-only against production state. Reads: `docker ps`,
`docker logs`, `ls`/`cat` of the config home, `ps` for the live command line.
The reproduction runs executed `claude` against a **copy** of the config home under
`/tmp` inside the container (removed afterwards); the production config home, the
database and the running BEAM node were never mutated, and no RPC was used.
