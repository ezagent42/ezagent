# Can a creator reach their agent's PTY — half fixed, half still open

**Status:** `pty.restart` is **implemented** (this PR, zero new grants). `pty.write` — the `/login` escape hatch — is still a gap; the fix has converged and awaits Allen.

**⚠️ Three conclusions in v1 of this note were WRONG.** They are listed and retracted below rather than deleted — the wrong reasoning is itself informative. They were caught by a codex claim-verification pass and re-checked empirically.

---

## 1. Allen's 2026-07-13 decision: the creator may recover a dead agent

**Implemented — and it is free.**

`pty.restart` lives on `Ezagent.ActionSet.Pty` (which is in `ezagent_domain_pty` and can call `Ezagent.Domain.Pty.restart/1` directly — no layering problem), and it declares its required capability as **the agent's MANAGE cap**:

```elixir
restart: Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Manage, :any)
```

**The creator already holds exactly that cap** — `CreatorGrant.manage_cap/4` mints it at agent creation:
`cap(:agent, Manage, :any, instance: <this agent>, workspace: <this ws>)`.

So: **no new grant, no backfill, no migration. The six agents already on canary can use it today.**

### Why this is right, not smuggling

It is an **established idiom**, not an invention. All seven of `Ezagent.ActionSet.ConfigGovernance`'s CR actions do exactly this:

```elixir
manage = Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Manage, :any)
%{open_cr: manage, stage_item: manage, ..., rollback_cr: manage}
```

with the comment: **"the agent's MANAGE cap (lead decision OQ-4) — no separate publish/reviewer cap."** `ConfigEvolve` does the same. **Pty is the third.**

It is also semantically correct: **bringing a dead agent back up is a management act on that instance, not terminal typing.** And the Manage cap's own definition (`manage.ex`, #533 §3.3) is verbatim **"any management action on THIS instance"**.

### The authorization shape (pinned by three tests in `pty_test.exs`)

| Holder has | dispatching `pty.restart` | |
|---|---|---|
| the creator's Manage cap (**production shape**, `workspace://<ws>`) | ✅ authorized | this is the whole point |
| a Manage cap for **someone else's agent** | ❌ `:unauthorized` | instance stays exact |
| a `pty:write` cap | ❌ `:unauthorized` | no privilege creep |

> Note: the test must use `workspace://team-alpha` (the production shape). My first version hard-coded an `entity://.../workspace/...` URI — a shape that does not exist in this system — and the test went red for that reason alone. **The red was a bad fixture, not a broken mechanism.**

---

## 2. `pty.write` — this half is still a gap

### What Allen decided on 2026-07-10

From `Ezagent.Agent.CredentialPrecondition`'s moduledoc:

> a user may deliberately create a credential-less cc agent and **run `claude /login` inside its PTY**

The automatic-materialization lane is allowed to hard-refuse a credential-less agent precisely *because* the explicit-creation lane has an escape hatch: the user goes into the terminal and logs in.

### The hatch does not exist

- at creation the creator receives **only** a Manage cap (`grant_agent_creator_manage_cap`)
- **every** call site of `grant_initial_caps(...)` (RoleStep / world `agent_actions` / `agent.create --caps`) passes **`agent_uri`** as the holder — the caps go to **the agent itself**, not the creator
- no recipe anywhere requests a Pty cap
- the creator's Manage cap has exactly two actions (`:delete` / `:reconfigure`) and **no cap-minting action** → no self-escalation

`Capability.Match` compares field by field, and `Manage ≠ Pty` → **the creator cannot `pty.write`.**

**None of the six cc agents on canary has credentials. Under Allen's model their creators are supposed to go into the terminal and fix that. They cannot get in.**

### The fix (revised: a CONCRETE action, not `:any`)

At creation, next to `grant_agent_creator_manage_cap`, mint one more:

```elixir
Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Pty, :write, agent_uri, workspace_uri)
#                                                      ^^^^^^ concrete action, not :any
```

**Why concrete now (this reverses the earlier "use `:any`" conclusion):**

1. **The only reason for `:any` has evaporated.** `:any` was needed so `restart` would ride along free — but `restart` now goes through Manage and never touches a Pty cap. The only verb left to grant is `write`. There is no longer any reason to open a wildcard.
2. **`:any` would hit an issuance guard.** `CapabilityRegistry` refuses a grant with an exact instance and `action: :any`: `:wildcard_action_grant_requires_admin_authority` (found by codex). A concrete action bypasses that guard cleanly (`action_of(cap) != :any -> :ok`).
3. Smaller authority surface, same satisfaction of Allen's decision.

Measured: a `cap(:agent, Pty, :write, <agent>, workspace://<ws>)` authorizes `pty.write` (`pty_test.exs`).

### Backfill

`CreatorGrant.manage_cap/4` records `granted_by: creator_uri`, and `Identity.list_caps_for/1` enumerates by holder → walk every `kind: :agent` Manage cap, its holder is the creator, mint the matching `Pty/:write` cap.

Suggested as a one-shot **`mix ezagent` task, not a migration**: this is an authorization-data backfill, and it wants to be run manually and observably on canary once, with evidence kept.

---

## 3. RETRACTED — three wrong conclusions from v1

### ❌ Retraction 1: "`required_caps/0` cannot alias one action's authority onto another"

**Wrong.** `Kind.Runtime` overwrites only the **action** axis; it **honours the declared behavior**:

```elixir
# apps/ezagent_core/lib/ezagent/kind/runtime.ex:468
%{
  kind: kind_axis,
  behavior: declared.behavior,   # ← from required_caps/0
  action: action,                # ← from the dispatch
  ...
}
```

My earlier experiment varied only the action axis (behavior was `__MODULE__` on both sides), and I over-generalized to "the behavior too". **That wrong conclusion is exactly what made me think a creator needed a Pty cap to restart.** Retract it and `pty.restart` becomes free.

### ❌ Retraction 2: "this contract is documented nowhere"

**Wrong — it is documented in at least two places, both with decision numbers:**

- `Ezagent.ActionSet.Manage`'s moduledoc (`manage.ex:32-37`) — **#533 §3.3**:
  > "dispatch overwrites the needed-cap action with the concrete dispatched action and `matches?` compares the cap's action to it"
- `Ezagent.ActionSet.ConfigGovernance`'s `required_caps` comment — **lead decision OQ-4**

It is not undocumented; it is documented **somewhere nobody would look** (one ActionSet's moduledoc, rather than the CapBAC / Behavior contract reference). **The thing actually worth doing is lifting it into the contract reference** — where the next person will look.

### ❌ Retraction 3: "today only an admin can open an agent's terminal"

**That sentence has it backwards.** Precisely:

| | gate |
|---|---|
| **writing** to a terminal (`pty.write`) | ✅ dispatch → CapBAC. **The creator holds no cap → cannot get in** (section 2 above) |
| **watching** a terminal (live output + scrollback) | ❌ **no capability gate at all — any authenticated user, any agent, across workspaces** |

**The thing that should be locked is open, and the thing that should be open is locked.** See `docs/notes/2026-07-14-pty-terminal-read-ungated.md` (separate security note).

(Also: an admin **can** hand-provision a Pty cap via `WorkspaceUserAdmin.create_user`'s cap string at **user**-creation time. But that path cannot express "the agent I am going to create later" — the instance must be a concrete URI known when the user is created, or `:any`, meaning every agent in the system. So it is an admin back door, not the creator's hatch — and it has its own problem; see the same security note.)

---

**Related:**
- `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.md` — #1294's root cause (`--continue`, not auth)
- `docs/notes/2026-07-13-bridge-join-timeout-silent.md` — the silent bridge-join timeout (separate bug)
- `docs/notes/2026-07-14-pty-terminal-read-ungated.md` — **any authenticated user can watch any terminal (security)**
