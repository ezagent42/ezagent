# The terminal belongs to the creator — all three PTY authorities collapse onto the cap they already hold

**Status:** all implemented (this PR). **Read / write / restart** on an agent's terminal are all carried by the Manage cap its creator already receives at creation — **zero new caps, zero backfill**. The six agents already on canary work immediately.

**Allen, 2026-07-14: "Who may watch? The creator, obviously — the creator has the authority."**

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
| a `Pty` cap | ❌ `:unauthorized` | the contract moved to Manage; fails closed |

> Note: the test must use `workspace://team-alpha` (the production shape). My first version hard-coded an `entity://.../workspace/...` URI — a shape that does not exist in this system — and the test went red for that reason alone. **The red was a bad fixture, not a broken mechanism.**

---

## 2. `pty.write` (the `/login` hatch) — also fixed, also free

### What Allen decided on 2026-07-10

From `Ezagent.Agent.CredentialPrecondition`'s moduledoc:

> a user may deliberately create a credential-less cc agent and **run `claude /login` inside its PTY**

The automatic lane may hard-refuse a credential-less agent precisely *because* the explicit-creation lane has an escape hatch: the user goes into the terminal and logs in.

### The hatch did not exist

- at creation the creator receives **only** a Manage cap
- **every** `grant_initial_caps(...)` call site grants to **the agent itself**, not the creator
- **nothing in the whole repo ever mints an `ActionSet.Pty` cap** — zero mint sites, zero recipes requesting one
- the creator's Manage cap has two actions (`:delete` / `:reconfigure`) and **no cap-minting action** → no self-escalation

**None of the six cc agents on canary has credentials. Under Allen's model their creators are supposed to go in and fix that. They could not get in.**

### The fix (Allen, 2026-07-14 — **the terminal belongs to the creator**)

**Mint nothing. Let the authority the creator already holds carry the terminal.**

```elixir
# ActionSet.Pty.required_caps/0
manage = Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Manage, :any)
%{write: manage, restart: manage}
```

`Ezagent.World.PtyAccess` (the terminal **read** gate) checks the same cap. So:

> **Authority over an agent = its Manage cap. That authority carries the terminal: watch, type, restart.**

**Zero new caps, zero backfill, zero migration** — every agent that already exists works immediately, because its creator already holds the cap.

### Why not "mint a Pty cap for the creator" (my previous plan)

**Because the place that mints the cap is not allowed to name the `Pty` module.** Verified:

| app | may reference `ActionSet.Pty`? |
|---|---|
| `ezagent_core` (`CreatorGrant`) | ❌ core → domain is a dependency cycle |
| `ezagent_domain_workspace` (where agents are created) | ❌ domain_pty is **not** among its deps |
| `ezagent_plugin_world` (where the read gate lives) | ✅ it is |

Getting round that wall would mean inventing a new mechanism (e.g. a "which behaviors does a Kind's creator own" registry) — **new architecture**, which needs Allen. The Manage route needs no workaround at all: `ActionSet.Pty` lives in domain_pty and referencing core's `Manage` is the normal direction.

### The consequence, deliberately accepted

**A hand-provisioned `Pty` cap no longer authorizes `pty.write`.** Nothing in the repo mints one, so in practice nobody holds one; if someone does, it **fails closed** (`:unauthorized`, never silent access), and re-granting is a Manage cap on that instance.

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

| | gate before | now |
|---|---|---|
| **writing** to a terminal (`pty.write`) | ✅ CapBAC — but **the creator held no cap and could not get in** | ✅ the creator's Manage cap |
| **watching** a terminal (live output + scrollback) | ❌ **no gate at all — any authenticated user, any agent, across workspaces** | ✅ the same Manage cap |

**The thing that should be locked was open, and the thing that should be open was locked. Both are fixed in this PR.** See `docs/notes/2026-07-14-pty-terminal-read-ungated.md` (separate security note).

(Also: an admin **can** hand-provision a Pty cap via `WorkspaceUserAdmin.create_user`'s cap string at **user**-creation time. But that path cannot express "the agent I am going to create later" — the instance must be a concrete URI known when the user is created, or `:any`, meaning every agent in the system. So it is an admin back door, not the creator's hatch — and it has its own problem; see the same security note.)

---

**Related:**
- `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.md` — #1294's root cause (`--continue`, not auth)
- `docs/notes/2026-07-13-bridge-join-timeout-silent.md` — the silent bridge-join timeout (separate bug)
- `docs/notes/2026-07-14-pty-terminal-read-ungated.md` — **any authenticated user can watch any terminal (security)**
