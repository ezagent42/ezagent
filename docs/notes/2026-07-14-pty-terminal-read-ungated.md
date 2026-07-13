# Any authenticated user can watch any agent's terminal (across workspaces)

**Status:** for Allen. **A security issue, not fixed in the current PR** — separate bug, separate evidence, separate PR.

**Nature:** confidentiality. **Writing** to a terminal is tightly CapBAC-gated. **Reading** one is not gated at all.

**How it surfaced:** while investigating "a creator cannot reach their own agent's PTY", a codex claim-verification pass pointed out I had the direction backwards. Confirmed line by line.

---

## In one sentence

> **Any logged-in user can type a URL and watch, live, the terminal of any agent in any workspace — and read its scrollback buffer.**
> No capability required. No workspace check.

What scrolls through a terminal: `claude /login` authorization codes, the agent's conversation, source code, command output, secrets echoed by commands.

## The chain (line by line, zero authorization)

| # | Where | What it does |
|---|---|---|
| 1 | `ezagent_web/router.ex:36-53` | `live "/identities/agents/:uri/terminal"`, behind `RequireEntity` only — **any authenticated entity** |
| 2 | `world/routes.ex:234-242` | regex-extracts `:uri` **from the URL** → `entity_uri: parse_entity_uri(encoded)`, **unchecked** |
| 3 | `world/identity_data.ex:207-213` | `component_state(%{component: "pty_terminal", entity_uri: agent_uri}, base, _workspace, _caller, _caps)` — **`_workspace` / `_caller` / `_caps` are all discarded** |
| 4 | `world/identity_data.ex:478-480` | `pty_initial_buffer(agent_uri)` → `Domain.Pty.Server.snapshot_buffer(agent_uri)` — **reads the scrollback** |
| 5 | `world_live.ex:859-866` | `PubSub.subscribe(Domain.Pty.Server.output_topic(agent_uri))` — **subscribes to the live output stream** |

Step 3 is the crux: those three underscored parameters are not "unused for now" — they are **authorization inputs being explicitly thrown away**.

## By contrast, the write path IS gated

`world_live.ex:284`'s `handle_event("pty_input", …)` → `Invocation.dispatch/1` → CapBAC step 5.5 → requires `cap(:agent, Pty, :write, <that agent>)`.

**So the state of the world is:**

| | gate | consequence |
|---|---|---|
| write to a terminal | ✅ CapBAC | **even the creator** cannot get in (see the authority-gap note) |
| watch a terminal | ❌ **none** | **anyone can watch, any agent, across workspaces** |

**The thing that should be locked is open, and the thing that should be open is locked.**

## Suggested fix

The `pty_terminal` branch of `component_state/5` must stop discarding `_caller` / `_caps` / `_workspace`:

1. **Capability check** — reading a terminal should require a cap. The natural shape reuses the write side's instance axis: you may watch an agent's terminal if you hold that agent's Pty cap (or its Manage cap).
2. **Workspace check** — `entity_uri` comes from the URL, so assert it belongs to `socket.assigns.current_workspace_uri` and refuse cross-workspace outright.
3. **Gate the subscription too** — `maybe_subscribe_pty/2` subscribes to the PubSub topic independently. **Fixing only the state path leaves this one open**; both are data exits.

Item 3 is the easy one to miss: they are two **independent** paths to the same output.

## Also: `WorkspaceUserAdmin.create_user` is a confused deputy

Raised by codex in the same review, confirmed here:

`workspace_user_admin.ex:145-154`, in `handle_create_user/2`:

```elixir
{:ok, caps} <- Ezagent.Capability.Parser.parse(caps_str || "", Ezagent.Entity.User.admin_uri()),
{:ok, decoded} <- Ezagent.Users.create(user_uri, password, caps) do
```

- `caps_str` is **arbitrary caller-supplied text**
- the granter is **hard-coded to `admin_uri()`** — regardless of who is actually calling
- it goes straight to `Users.create`, **bypassing `Cap.issue/3`** and therefore both `CapabilityRegistry` guards (`:wildcard_action_grant_requires_admin_authority` / `rule_cap_bounded?`)

→ **A holder of `workspace_user_admin.create_user` (a workspace-level admin, not necessarily a global one) can conjure a user holding arbitrary wildcard capabilities, stamped as granted-by-admin.** That is an escalation path.

One constraint does exist: `ensure_user_in_target_workspace/2` forces the new user into the target workspace. But **the caps themselves are unconstrained** (the parser defaults to `action: :any, workspace_uri: :any`).

---

**Not verified against production** — canary is read-only and no one else's terminal was accessed. Everything above is confirmed by reading the code.

**Related:**
- `docs/notes/2026-07-13-agent-creator-pty-authority-gap.md` — the creator cannot reach their own agent's PTY (the other half of the same investigation)
