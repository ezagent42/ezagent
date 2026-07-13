# An agent's creator cannot reach its PTY — Allen's 2026-07-10 decision is not implemented

**Status:** ready to implement, pending Allen's nod.

**Nature:** this is **not** a new permission invented for `pty.restart`. It is a **pre-existing,
silent authorization gap** — something one of Allen's own decisions assumes, and the code never
implemented. `pty.restart` merely rides along for free.

---

## What Allen decided on 2026-07-10

From `Ezagent.Agent.CredentialPrecondition`'s moduledoc, verbatim:

> **Explicit agent creation** by a user is untouched: a user may deliberately create a
> credential-less cc agent and **run `claude /login` inside its PTY** (Allen, 2026-07-10).
> That is why this check lives in the automatic lane and NOT in `Ezagent.Credential.HomeRuntime`,
> which both lanes share.

**The entire premise is that a creator can reach their agent's PTY.** The automatic-materialization
lane is allowed to hard-refuse a credential-less agent precisely *because* the explicit-creation
lane has an escape hatch: the user goes into the terminal and logs in.

## That escape hatch does not exist

### Evidence 1 — creation mints exactly one cap for the creator

`Ezagent.ActionSet.Workspace.AgentCreate` mints caps in exactly two places:

| Call | Granted to | What |
|---|---|---|
| `grant_agent_creator_manage_cap/3` | **the creator** | `behavior: Ezagent.ActionSet.Manage, action: :any, instance: <this agent>` |
| `RoleStep.mint_and_grant_caps/4` | **the agent itself** (`grant_initial_caps(agent_uri, …)`) | the role recipe's caps — and only when `params[:role]` is present |

**The only cap the creator ever receives is on `ActionSet.Manage`.**

### Evidence 2 — nothing anywhere grants a user an `ActionSet.Pty` cap

```
grep -rn "ActionSet.Pty" apps/ --include=*.ex | grep -iE "cap\(|grant|mint"
  → nothing (bar one historical sentence in pty.ex's own moduledoc)
```

### Evidence 3 — the terminal really is CapBAC-gated

`world_live.ex:284`'s `handle_event("pty_input", …)` → `dispatch_pty_input/3` →
`Ezagent.Invocation.dispatch/1` → CapBAC step 5.5.

### Evidence 4 — a Manage cap cannot match Pty

`Ezagent.Capability.Match.matches?/2` compares field by field; only `:any` **on the cap side** is a
wildcard:

```elixir
field_match?(cap.behavior, needed.behavior)   # Manage vs Pty → false
```

Measured:

```
creator holds:    behavior=ActionSet.Manage  action=:any  instance=<agent>
needs pty.write   → matches? = FALSE
needs pty.restart → matches? = FALSE
needs manage.*    → matches? = TRUE
```

## Conclusion

> **Today only an admin (the genesis wildcard) can open an agent's terminal.**
> **A normal user who creates an agent cannot open its terminal — and therefore cannot `/login` the
> way Allen's design says they should.**

None of the six cc agents on canary has credentials. Under Allen's model their creators are supposed
to go into the terminal and fix that themselves. **They cannot get in.**

---

## The fix

At agent creation, right next to the existing `grant_agent_creator_manage_cap`, mint one more cap
for the creator:

```elixir
Ezagent.Capability.cap(
  :agent,
  Ezagent.ActionSet.Pty,
  :any,
  agent_uri,          # instance — this ONE agent
  workspace_uri
)
```

### Why `action: :any`

Because what Allen's decision grants is "**you can use this terminal**", not "you can use one named
verb of it". `/login` requires `pty.write`; recovering from a respawn halt requires `pty.restart`.
Enumerating verbs means every new Pty action needs the grant to be revisited, and every omission is
a silent hole — exactly like this one.

**It is still bounded:**

| Axis | Value | Bound |
|---|---|---|
| `kind` | `:agent` | ✅ exact |
| `behavior` | `ActionSet.Pty` | ✅ **exact — not a wildcard** |
| `action` | `:any` | ⚠️ wildcard, but **only within the Pty behavior** |
| `instance` | `<this agent's URI>` | ✅ **exact — only the agent they created** |
| `workspace_uri` | `<this workspace>` | ✅ exact |

The creator gets **full control of the PTY of the one agent they created** — which is precisely the
shape of Allen's decision — and **cannot touch anyone else's agent, nor any behavior other than Pty**.

### Backfill (existing agents)

Agents that already exist (including `test-zyli-cc-1`) will not get the cap automatically. The
backfill is mechanical and auditable:

- `Ezagent.CreatorGrant.manage_cap/4` records `granted_by: creator_uri` — **the creator is derivable**
- `Ezagent.Identity.list_caps_for/1` enumerates by holder

→ Walk every `kind: :agent` Manage cap; its holder is the creator; mint the matching Pty cap.

Suggested as a one-shot **`mix ezagent` task rather than a migration**: this is a data/authorization
backfill, not a schema change, and it wants to be run **manually and observably** on canary once,
with evidence kept.

---

## Falls out of it: where `pty.restart` lives

Close this gap and the `pty.restart` placement problem **disappears**:

- `:restart` goes on `Ezagent.ActionSet.Pty` (which lives in `ezagent_domain_pty` and can call
  `Ezagent.Domain.Pty.restart/1` directly) — **no layering problem at all**
- the creator's new Pty cap is `action: :any` → **`:restart` is free, no extra grant**

The two alternatives, and why they are out:

| Option | Why not |
|---|---|
| Put `:restart` on `ActionSet.Manage` (which the creator's cap already matches) | `Manage` lives in `ezagent_core`, and **core → domain is a dependency cycle** — it cannot call `Domain.Pty.restart/1`. The only thing that would compile is core hard-coding the domain module name (`{:effect, {Module, :fun}}` is a runtime `apply`) — **passes the compiler, breaks the architecture** |
| `manage.restart` = terminate the Kind, let it rehydrate | **It is a no-op.** `Domain.Pty.stop/1` has exactly one caller in the whole repo (codex's `rollback_sidecars`); cc's Template Class has **no** `deactivate`/`destroy` hook that stops the PTY. After the Kind terminates the halted PtyServer is still alive and still registered, so `start/2` returns `{:already_started, pid}` and nothing happens |

---

## Byproduct: an implicit CapBAC contract worth writing down

Measured during this investigation and **documented nowhere**:

> **`required_caps/0` cannot alias one action's authority onto another.**
>
> The runtime derives the needed cap from **the dispatching behavior module and the dispatched
> action name**, and **ignores** the `behavior` and `action` fields of the capability the Behavior
> declared in `required_caps/0`. Only `kind` / `instance` / `workspace_uri` are honoured.

Measured: declaring `restart: Capability.cap(:agent, __MODULE__, :write)` to reuse `:write`'s
authority, then dispatching `pty.restart` as a caller holding `pty:write` → `{:error, :unauthorized}`.
Instrumenting `Ezagent.Kind.Runtime`'s authorization branch:

```
needed_action = :restart      ← what the runtime demands
held   action = :write        ← what the caller has
```

**The nasty part: calling `Capability.matches?/2` on those two structs in isolation returns `true`.**
The mismatch only appears in the `needed` map the runtime builds. **This is exactly the class of
thing that looks right in review and fails in production.** Without this note the next person walks
into it too.

---

**Related:**
- `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.md` — #1294's root cause (`--continue`, not auth)
- `docs/notes/2026-07-13-bridge-join-timeout-silent.md` — the silent bridge-join timeout (separate bug)
