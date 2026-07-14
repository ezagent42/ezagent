# Any authenticated user can watch any agent's terminal (across workspaces)

**Status:** ✅ **fixed (this PR).** Allen, 2026-07-14: "Who may watch? The creator, obviously — the creator has the authority."

**Nature:** confidentiality. **Writing** to a terminal is tightly CapBAC-gated. **Reading** one is not gated at all.

**How it surfaced:** while investigating "a creator cannot reach their own agent's PTY", a codex claim-verification pass pointed out I had the direction backwards. Confirmed line by line.

> ### ⚠️ The first version of this fix gated 2 of the 4 exits
>
> I assumed there were two read exits (the terminal route's state, and its PubSub
> subscription), fixed those, and called it done. **A second codex pass and my own
> re-sweep independently found two more.** One of them is **live and directly
> client-triggerable** — the in-conversation `session.pty.open`, which takes an
> arbitrary client-supplied agent URI and subscribes to its output stream. **The
> first fix did nothing for it; the hole stayed open.**
>
> This is the sentence this very note already contained — *"they are two
> independent exits; gating one is the same as gating none"* — and I walked into
> it anyway.
>
> The lesson is now in the code: the policy moved out of `plugin_world` into
> **`Ezagent.Domain.Pty.Access`**, next to the thing it protects, and all four
> exits call it. `TerminalSeam` is gated **by construction** (you cannot subscribe
> without passing caps), so a future host LV cannot reopen the hole by forgetting
> a check.

---

## In one sentence

> **Any logged-in user can type a URL and watch, live, the terminal of any agent in any workspace — and read its scrollback buffer.**
> No capability required. No workspace check.

What scrolls through a terminal: `claude /login` authorization codes, the agent's conversation, source code, command output, secrets echoed by commands.

## Four read exits, all ungated

| # | Exit | Entry | Leaks |
|---|---|---|---|
| 1 | `IdentityData.component_state/5`'s `pty_terminal` branch | `/identities/agents/:uri/terminal` (URL-controlled) | **the scrollback** |
| 2 | `WorldLive.maybe_subscribe_pty/2` | same | **the live output stream** |
| 3 | **`ConversationActions.switch_to_pty/3`** | **the `session.pty.open` client event, arbitrary `"agent"` field** | **the live output stream** |
| 4 | `EzagentDomainUi.Pty.TerminalSeam` | reusable seam (no callers, but a footgun) | buffer + output stream |

**Exit 3 is the worst — it does not even need a crafted URL:**

```
client sends:  session.pty.open  { "agent": "entity://other-workspace/agent/theirs" }
server:        subscribes to that agent's PTY output stream
               no capability check, no workspace check
               `_session_uri` is explicitly ignored — it never even asks whether
               that agent belongs to that session
```

The chain for exits 1/2:

| # | Where | What it does |
|---|---|---|
| 1 | `ezagent_web/router.ex:36-53` | behind `RequireEntity` only — **any authenticated entity** |
| 2 | `world/routes.ex:234-242` | regex-extracts the agent URI **from the URL**, **unchecked** |
| 3 | `world/identity_data.ex:207` | `component_state(…, _workspace, _caller, _caps)` — **all three authorization inputs discarded** |
| 4 | `world/identity_data.ex:478` | reads the **scrollback** |
| 5 | `world_live.ex:859` | subscribes to the **live output stream** |

Step 3 is the crux: those underscored parameters are not "unused for now" — they are **authorization inputs being explicitly thrown away**.

## By contrast, the write path WAS gated all along

`world_live.ex:284`'s `handle_event("pty_input", …)` → `Invocation.dispatch/1` → CapBAC step 5.5. Before this PR that required `cap(:agent, Pty, :write, <that agent>)` — a cap **nothing in the repo ever minted**, so not even the creator held it.

**The state of the world before this PR:**

| | gate | consequence |
|---|---|---|
| write to a terminal | ✅ CapBAC | **even the creator** cannot get in (see the authority-gap note) |
| watch a terminal | ❌ **none** | **anyone can watch, any agent, across workspaces** |

**The thing that should be locked is open, and the thing that should be open is locked.**

## The fix (implemented)

New `Ezagent.Domain.Pty.Access.may_read?/2` — it checks **that agent's Manage cap**:

```elixir
Capability.Authorization.authorizes?(caps, %{
  kind: :agent,
  behavior: Ezagent.ActionSet.Manage,   # exact
  action: :read,
  instance: agent_uri,                  # exact — only the agent you created
  workspace_uri: Capability.workspace_of(agent_uri)
})
```

**All four exits are wired to it.** The policy lives in the PTY domain — next to the thing it protects — rather than in one caller, which is exactly what the first version got wrong:

1. `IdentityData.component_state/5` — an unauthorized viewer gets no buffer, no liveness, no phase; nothing beyond the URI they typed themselves.
2. `WorldLive.maybe_subscribe_pty/2` — an unauthorized viewer does not subscribe at all.
3. **`ConversationActions.switch_to_pty/3`** — unauthorized returns `error:unauthorized` and subscribes to **nothing**.
4. **`TerminalSeam.subscribe/2` + `push_initial_buffer/3`** — gated **by construction**: you cannot subscribe without passing caps, and insufficient caps return `{:error, :unauthorized}`. A future host LV cannot reopen this hole by forgetting a check.

**Plus a chunk binding.** PTY subscriptions accumulate and are never torn down (open A, then B, and the LV holds both), while `handle_info` ignored the chunk's agent URI and forwarded everything to the browser — so A's output bled into B's terminal, **and kept streaming after the viewer's authority over it changed**. Chunks are now bound to the agent actually on screen.

**Why the Manage cap and not a Pty cap:** the creator holds *only* a Manage cap (nothing in the repo ever mints a Pty cap), and `ActionSet.Pty`'s `:write` / `:restart` now hang off the same authority. **One authority covers the whole terminal — watch, type, restart. Zero new caps, zero backfill.**

The workspace axis closes itself: the cap's `instance` is an exact URI, so a Manage cap on someone else's agent cannot match — cross-workspace watching is refused as a consequence, not as a special case.

### Regression tests (each verified red with its gate removed)

`apps/ezagent_domain_pty/test/ezagent/domain/pty/access_test.exs` — the predicate:
the creator's Manage cap may watch · a Manage cap on **another** agent may not · a
Pty cap may not (the contract moved) · admin's genesis may · no cap may not ·
garbage input is refused rather than crashing.

`apps/ezagent_plugin_world/test/ezagent/world/pty_read_exits_test.exs` — the exits:

- **exit 1** with no cap → no buffer, no liveness
- **exit 3** with no cap → `error:unauthorized`, **and a PTY chunk broadcast to that
  agent's topic is never received** (proving it really did not subscribe, rather
  than merely returning an error)
- **chunk binding** → another agent's chunk does not reach this terminal

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
