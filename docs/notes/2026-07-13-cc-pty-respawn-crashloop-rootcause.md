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
| **G** | **exact prod cmd, real cwd** (so the transcript is fully in scope) | **exit 1**, same message |

Run D vs run E isolates the cause to a **single flag**.

Run G closes the remaining hole, and it matters for the shape of the fix. The agent
*does* carry a transcript — `projects/-data-…-test-zyli-cc-1/5271f2db-….jsonl`,
7 799 bytes, 7 records including a `user` and an `assistant` turn, with
`"cwd": "/data/default/cc-agents/ezagent/test-zyli-cc-1"` recorded inside. Run G was
executed with that **real cwd** (so both the project key and the transcript's own
recorded cwd match) and a copied `CLAUDE_CONFIG_DIR`, i.e. under conditions identical
to production. `claude --continue` **still** reports `No conversation found to
continue` and exits 1.

> An earlier run (F) placed the transcript under a *different* project key and was
> therefore inconclusive — the records carry the original cwd, so claude rejected it
> for the wrong reason. Run G supersedes it. Recorded here so the mistake is not
> repeated.

**Consequence for the fix: a transcript file existing on disk does NOT mean
`--continue` will succeed.** Any fix of the form "check whether a conversation file
exists, then pass `--continue`" would still pass the flag here, and would still crash.
There is also no healthy counter-example to calibrate a disk predicate against — see §7.
The guard therefore has to be a **fallback on failure**, not a pre-flight prediction.

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

An important mechanical detail shapes both fixes: **`DynamicSupervisor` freezes the
child spec.** `Ezagent.Domain.Pty.start/2` hands `DynamicSupervisor.start_child/2` a
`{Server, params}` spec, and every subsequent supervisor restart re-runs
`Server.start_link/1` with *those same params*. So the `--continue` argv was chosen
**once** by the cc plugin and is then replayed verbatim by the supervisor — 933 times
and counting. The cc plugin is never consulted again. The loop therefore cannot be
broken from the cc side alone; the spawn path itself has to be able to change its mind.

1. **Make the resume flag self-healing (`--continue` must never be able to prevent
   startup).** Because resumability cannot be predicted from disk (§3), the cc plugin
   supplies both the preferred argv (with `--continue`) and a **degraded fallback**
   argv (without it); when the preferred command fails to reach a healthy lifetime,
   the PTY spawn path retries with the fallback. Losing conversation context on a
   restart is a regression; never starting at all is fatal — the fallback trades the
   former to eliminate the latter. Correct the falsified comment at
   `spawn_plan.ex:31-37`; it is the origin of this bug.
2. **Make the respawn decision vetoable (Domain.Pty).** The handoff's structural
   instinct is right — only the trigger was wrong. Use a **cause-agnostic crash-loop
   breaker**: after K consecutive spawns that never reach a healthy lifetime (and with
   no fallback left to try), stop respawning and put the agent in a durable terminal
   halt state with a reason. `RespawnBackoff` already counts exactly this
   (`attempt_count/1`) — promoting it from "slow it down" to "trip a breaker" is a
   small change. This trigger catches *this* bug (which is not auth at all), plus the
   auth case, the OOM case, and the wrong-dialog-option case. The auth observer and
   `CredentialPrecondition` can feed the breaker as *faster* additional triggers, but
   must not be the only ones.
3. **Give a halted agent a way back.** See §7 — there is currently no operator control
   that can restart an agent, so a halt with no recovery path would only trade one
   dead end for another.

## 7. Gaps found on the way

* **Not one cc agent on canary has credentials.** All six config homes under
  `/data/default/cc-agents/ezagent/` report no `.credentials.json`, and the container
  exports no `ANTHROPIC_*`. This is independent of the crash loop, but it means the
  week's "the agent actually replies" goal is blocked on credential provisioning
  regardless of this fix. It also means there is **no healthy cc agent to calibrate a
  "is this conversation resumable?" disk predicate against** — reinforcing §6.1's
  fallback-not-prediction conclusion.
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
