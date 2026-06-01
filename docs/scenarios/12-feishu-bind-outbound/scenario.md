# Scenario 12: Feishu chat ↔ session bind + outbound

**Category**: 4 — Feishu integration
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-27 (PR #420 cold-spawn fix verified by Allen)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Feishu sidecar process running + reachable (configured via `EZAGENT_FEISHU_*` env)
- Feishu app credentials configured (app_id, app_secret)
- A test Feishu chat available (dev chat: `oc_83a4f1ff0bf627ffe26aa60647e5b04a`)
- Admin logged in
- A session exists: `session://system/feishu-test`

## Actors

- **Caller**: admin (binding side); session member agent (outbound side)
- **Target**: external mirror binding `<chat_id, app_id> → session://system/feishu-test`
- **External systems**: Feishu sidecar; Feishu Open API

## Steps

### Bind

1. Open `/admin/sessions/<session-uri>/external-mirror` (or `/admin/external-mirror`).
2. Click "Bind Feishu chat"; provide `chat_id = oc_83a4f1ff0bf627ffe26aa60647e5b04a`, `app_id = <dev_app_id>`.
3. `Behavior.ExternalMirror :bind` action runs:
   - Cap check (admin has it)
   - Target-ownership check (admin owns the session)
   - Workspace-isolation check (binding's workspace matches session's workspace)
   - Persist `external_mirror_bindings` row
   - Spawn `ExternalMirrorWorker` for the binding (`Registry` keyed by `{chat_id, app_id}`)
4. The worker subscribes to the session publisher (`Ezagent.Session.PublisherPubSub`).

### Outbound

5. From `/admin/sessions/<session-uri>`, send: "hello from ezagent".
6. The session publisher emits the chat event.
7. The `ExternalMirrorWorker` receives the event + calls `FeishuAdapter.event_to_payload/1` to build the Feishu message JSON.
8. Worker POSTs to the Feishu sidecar via JSON-RPC; sidecar calls Feishu Open API.
9. Verify the message appears in the dev Feishu chat.

## Expected outcomes

- `external_mirror_bindings` row persists.
- Worker registered under `Registry.lookup({:via, Registry, {Ezagent.ExternalMirror.WorkerRegistry, {chat_id, app_id}}})`.
- `invocations` row for `bind`.
- Outbound: 1 Feishu API call recorded in sidecar logs.

## Failure modes to test

- Sidecar unreachable: outbound write retries N times; binding row persists; on sidecar recovery, missed events are NOT replayed (gap — see Notes).
- Duplicate bind for same `{chat_id, app_id}`: `:already_bound`.
- Bind to a session in a different workspace: `:cross_workspace_denied`.
- Bot has been kicked from the Feishu chat: outbound API returns an error; worker should auto-unbind (PR #418 partially covers).

## Cross-references

- Related PRs:
  - PR #312 — PR-EM-CORE (ExternalMirror infrastructure)
  - PR #418 — unbind projection sync + session routing nav
  - PR #420 — worker re-subscribes to session publisher on cold-spawn (task #49)
  - PR #334 — facade-audit IMPL
- Related SPECs:
  - `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  - `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md`
- Tests:
  - `apps/ezagent_domain_external_mirror/test/ezagent/external_mirror/facade_test.exs`
  - `apps/ezagent_domain_external_mirror/test/ezagent/external_mirror/binding_row_test.exs`
  - `apps/ezagent_domain_external_mirror/test/ezagent/behavior/external_mirror_reconcile_test.exs`
  - `apps/ezagent_domain_external_mirror/test/invariants/no_pubsub_bypass_in_external_mirror_test.exs`
  - `apps/ezagent_plugin_feishu/test/feishu_chat_binding_test.exs`
  - `apps/ezagent_plugin_feishu/test/feishu_adapter_test.exs`
- Open bugs / gaps (todo entries):
  - "AdapterRegistry / BindingRegistry `:public` ETS hardening" — CRIT deferred
  - "Facade-auth-model security audit" — META finding from PR-EM-3 5 rounds
  - "AdapterInstall ordering vs BindingRegistry atomicity" — split-brain on partial failure
  - "bind spawn-before-persist split-brain" — `:bind` spawns worker before persist

## Notes

- Per Allen 2026-04-XX `feedback_register_lookup_key_parity`, the `{chat_id, app_id}` key must be identical at register-time + lookup-time.
- Missed-event replay on sidecar recovery is the open gap — not currently engineered.
- The `feedback_plugin_external_integration_is_receiver_kind` (2026-05-17) rule was the lesson that drove this whole `ExternalMirror` domain extraction.
