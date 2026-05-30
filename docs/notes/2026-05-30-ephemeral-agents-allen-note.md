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

## Also unaddressed by the stopgap
The per-session **orchestrator** (created by domain `create_session`)
restores via session snapshots, not `session_templates`, so the plugin
stopgap does not cover it — and the gc task intentionally does NOT delete
orchestrator/session snapshots (a `session://%` sweep would also wipe the
legitimate `session://default/system/main` and other tenants). If the
orchestrator independently storms at boot it belongs in this same B
(`create_session(orchestrator: false)` / ephemeral session members). The
PoC empirical verification result is recorded in
`docs/superpowers/specs/2026-05-30-ephemeral-cc-agents-design.md`.
