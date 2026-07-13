# `pty.restart` — the operator lever a halted agent needs, and the cap decision it is blocked on

**Status:** OPEN — needs Allen. Implementation is ~65 lines and was written and then
reverted; the blocker is authorization, not code.

**Context:** PR #1366 adds a respawn breaker (`Ezagent.Domain.Pty.RespawnPolicy`). A
child that can never start is retried a bounded number of times and then HALTED: the
PtyServer stays alive but runs no child and will not spawn one again.

---

## The gap

A halt is TERMINAL by design — an agent that failed to start N times running needs a
human to look at it, not another retry. `Ezagent.Domain.Pty.restart/1` is that human's
lever: it clears the breaker (halt + failure history + backoff) and drives a fresh
spawn.

**But no human can reach it.** There is no operator surface that calls it:

| Surface | What it exposes |
|---|---|
| world UI (`Ezagent.World.AgentActions`) | `agents.create`, `agents.delete`, `agents.config.*` — no stop/restart |
| `mix ezagent` | `agent.create` only |
| PTY terminal LV (`TerminalSeam`) | `?action=pty.write` only |

So the breaker currently trades an **infinite respawn loop** for a **permanently dead
agent**, and the only way back is to delete and recreate. That is not an acceptable
resting place, and it is the last unmet item of the original #1294 handoff DoD
("人工恢复:operator「重启 agent」动作清除终态 + 重生").

## What the fix looks like

Add `action :restart` to `Ezagent.ActionSet.Pty` (~10 lines), a `handle_restart/2` that
calls the existing `Domain.Pty.restart/1` (~10 lines), and
`TerminalSeam.dispatch_restart/2` mirroring `dispatch_input/3` (~15 lines). Registration
is free — `SessionBehaviorRegistration` already walks `PtyB.actions()`, so a new action
is picked up with no registration change, and `mix ezagent` gets it for free through the
same dispatch path.

All of that was written, compiled, and dispatch-tested. **It works.** It is not the
problem.

## The blocker: which cap authorizes it?

The plan was to REUSE the `:write` cap — whoever may type raw bytes into this agent's
PTY can already type `exit` into it, so a restart is strictly *less* destructive than
the authority they already hold, and reusing it would mean zero new grants to
administer.

**That does not work, and the reason is worth recording** because the declaration reads
as though it should:

```elixir
def required_caps do
  %{
    write:   Ezagent.Capability.cap(:agent, __MODULE__, :write),
    restart: Ezagent.Capability.cap(:agent, __MODULE__, :write)   # ← looks like reuse
  }
end
```

Dispatching `?action=pty.restart` with a caller holding only the `:write` cap returns
`{:error, :unauthorized}`. Instrumenting `Ezagent.Kind.Runtime`'s authorization branch
shows why:

```
needed_action = :restart          # what the runtime demands
held   action = :write            # what the caller has
```

**The runtime derives the needed cap's `action` axis from the DISPATCHED ACTION NAME,
not from the `action` field of the capability the Behavior declared in
`required_caps/0`.** The `:write` in that declaration is simply ignored. A Behavior
cannot alias one action's authority onto another this way — every action carries its own
cap on the action axis, full stop.

(Empirically confirmed, not reasoned: `Capability.matches?/2` on the two structs in
isolation returns `true` — the mismatch appears only in the runtime's `needed` map. This
is exactly the class of thing that looks correct in review and fails in production.)

## So `:restart` is a NEW capability — and that is a product decision

`Ezagent.ActionSet.OrchestratorAdmin` already sets the precedent, and it made the same
call explicitly:

```elixir
action :restart, caps: [:restart], description: "restart this session's orchestrator agent (session-owner authority)"
def required_caps, do: %{restart: Ezagent.Capability.cap(:session, __MODULE__, :restart)}
```

A distinct `:restart` cap, with a deliberately-named authority scope. Shipping
`pty.restart` means answering the same question for the PTY, and it is **not a question
an implementer should answer unilaterally** (CLAUDE.md: 不要发明新 Decision):

**Who holds `Capability.cap(:agent, Ezagent.ActionSet.Pty, :restart)`?**

- **Everyone who can already type into the PTY** (i.e. every holder of `pty:write`)?
  Defensible — see the `exit` argument above — but it must then be granted explicitly
  wherever `pty:write` is granted today, and existing operators need a backfill or the
  lever ships dead on arrival.
- **Workspace admin only**? Safer, but the person watching a crash-looping agent in the
  terminal is often not an admin, and they are the one who can see what broke.
- **The agent's creator / owner**? Matches the `CredentialPrecondition` framing (Allen
  2026-07-10: a user who deliberately created a credential-less agent is expected to fix
  it themselves), and mirrors `OrchestratorAdmin`'s "session-owner authority".

Each answer implies a different grant path (`default_caps` / DB grant / role recipe) and
a different backfill for agents that already exist.

## Recommendation

Decide the holder, then the implementation is a small follow-up PR. Until then PR #1366
ships the breaker with the domain lever (`Domain.Pty.restart/1`, tested) but **no
operator surface**, and a halted agent is recovered by deleting and recreating it.

That is a real, named cost — recorded here rather than papered over.
