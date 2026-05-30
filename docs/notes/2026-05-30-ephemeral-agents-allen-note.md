# Note for Allen: ephemeral agents shouldn't accumulate in session_templates

**Date:** 2026-05-30 · from the AutoService→ezagent customer-chat PoC.

## Problem
`Ezagent.Workspace.create_agent/3` for `flavor: "cc"` UNCONDITIONALLY
registers a `cc.agent.<name>` template in `workspaces.session_templates`
(behavior/workspace.ex:988, 1156-1170) and the boot loader replays every
entry (workspace/loader.ex:276-318). customer-chat spawns a per-CONVERSATION
cc agent per chat; these are ephemeral (recreated on demand) but their
permanent registration makes every conversation ever opened respawn its
claude PTY at boot — a "boot storm" that saturates spawn capacity and
blocks new conversations.

## PoC stopgap (shipped, plugin-local)
customer-chat now calls the existing `Workspace.remove_template/2` right
after `create_agent` to deregister its ephemeral `cc_cust_*` template
(commit on `poc/phase-2-customer-service`). `remove_template` only drops
the boot-restore registration — it does NOT terminate the running Kind,
so the agent keeps serving its conversation. Plus a
`mix ezagent.customer_chat.gc_ephemeral` task for already-accumulated
cruft (strips `cc.agent.cc_cust_*` from `session_templates` + deletes
orphaned `cc_cust_*` snapshots). No core/domain change.

## Proposed durable fix (B) — your call
Add `ephemeral: true` (or `persist: false`) to `create_agent` args that
(a) skips `Store.update_templates` and (b) makes the loader skip it (or
the agent never enters `session_templates`). This is the same direction as:
- the G-12 deprecation already on `session_templates` (store.ex:16-30,
  "retire session_templates once add_template also writes a real Template
  Kind"), and
- curl/np flavors, which already spawn directly via SpawnRegistry with
  NO template registration.

Ephemeral per-conversation/per-session agents (`cc_cust_*`, the per-session
orchestrator) should travel that non-persistent path. This touches the
core agent-create contract + the invariant test
`agent_create_single_path_test.exs`, so it's an architecture decision for
you, not implementation-phase work.

## Also unaddressed by the stopgap — CONFIRMED EMPIRICALLY (2026-05-30)
The deregister fixes the `session_templates` vector but there is a SECOND,
equally-unbounded restoration vector: the **per-conversation session
itself**. After deregister, opening 3 conversations (gcA/gcB/gcC) left
`session_templates` with zero `cc_cust_*` entries — yet a server restart
STILL respawned gcA + gcB (the two whose `ensure_agent_in_session` join
had completed); gcC (join not completed) did not come back. So the
persisted Session Kind restores its **member cc agent + per-session
orchestrator** at boot, independent of `session_templates`. This grows
one-session-per-conversation, same unbounded shape as the original bug.

The plugin stopgap cannot fix this: the cc agent MUST be a live session
member to receive `chat.receive` during the conversation (can't be
removed mid-conversation), and session persistence is a core
snapshot-on-change primitive (P22) a plugin can't bypass. The gc task
also deliberately does NOT delete session/orchestrator snapshots (a
`session://%` sweep would wipe the legitimate `session://default/system/main`
and other tenants).

**So B should make per-conversation sessions (and their member agents +
orchestrator) EPHEMERAL** — not just add `ephemeral:` to `create_agent`,
but also a `create_session(ephemeral: true)` / non-persistent session
path so an abandoned/old conversation's session does not resurrect its
members at boot. Same direction as the G-12 `session_templates`
retirement + curl/np's register-free spawn.

PoC empirical detail recorded in
`docs/superpowers/specs/2026-05-30-ephemeral-cc-agents-design.md` (§EMPIRICAL 验收结果).
