# Any authenticated user can watch any agent's terminal (across workspaces)

**Status:** ✅ **fixed (this PR).** Allen, 2026-07-14: "Who may watch? The creator, obviously — the creator has the authority."

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

## The fix (implemented)

New `Ezagent.World.PtyAccess.may_read?/2` — it checks **that agent's Manage cap**:

```elixir
Capability.Authorization.authorizes?(caps, %{
  kind: :agent,
  behavior: Ezagent.ActionSet.Manage,   # exact
  action: :read,
  instance: agent_uri,                  # exact — only the agent you created
  workspace_uri: Capability.workspace_of(agent_uri)
})
```

**Both exits are wired to it** — the easy thing to miss, because they are two **independent** paths to the same bytes and gating one leaves the other serving them:

1. `IdentityData.component_state/5`'s `pty_terminal` branch — an unauthorized viewer gets no buffer, no liveness, no phase; nothing beyond the URI they typed themselves.
2. `WorldLive.maybe_subscribe_pty/2` — an unauthorized viewer does not subscribe to the output topic at all.

**Why the Manage cap and not a Pty cap:** the creator holds *only* a Manage cap (nothing in the repo ever mints a Pty cap), and `ActionSet.Pty`'s `:write` / `:restart` now hang off the same authority. **One authority covers the whole terminal — watch, type, restart. Zero new caps, zero backfill.**

The workspace axis closes itself: the cap's `instance` is an exact URI, so a Manage cap on someone else's agent cannot match — cross-workspace watching is refused as a consequence, not as a special case.

### Regression tests

`apps/ezagent_plugin_world/test/ezagent/world/pty_access_test.exs`:

- a viewer with no cap for this agent → **no buffer, no liveness** (remove the gate and this goes red — verified)
- the creator's Manage cap → may watch
- a Manage cap on **another** agent → may not
- a Pty cap → may not (the contract moved)
- admin's genesis cap → may watch

## ⚠️ Still open: `WorkspaceUserAdmin.create_user` is a confused deputy

**Not fixed in this PR — separate problem, separate PR.**

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
