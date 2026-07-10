# gagameow track interpretation · 2026-07-10

## Main track

Today's main track is still #1294 canary verification:

- verify on canary that creating a session no longer hits the 5s timeout;
- verify `@orchestrator` actually replies in a newly created session;
- use real deployment evidence, not local tests only: agent-browser screenshot plus PTY/transport join logs;
- do not announce the create-session/orchestrator chain as fixed until canary proves it.

After that, `fix/install-transaction-silent-success` is the follow-up PR for silent-success cleanup:

- install must not treat unreadable declarations as success;
- `orchestrator_status: :ready` must not lie;
- stale comments in `conversation_actions.ex` should not mislead the next worker.

## Inserted hotfix

Before the main track, we are inserting a separate main-targeted PR:

- branch: `fix/default-session-no-orchestrator`;
- purpose: keep the stock default session template plain for now;
- behavior: default new sessions install only `chat`, not `orchestrator`;
- reason: current main still blocks/flakes around orchestrator startup during new-session tests, so default session creation should succeed without waiting for orchestrator readiness;
- non-goal: this does not fix orchestrator readiness and does not replace the #1294 canary verification.

Explicit templates and socialware manifests may still install orchestrator; this hotfix only changes the stock default path.

## Temporary-change restoration checklist

When orchestrator creation/readiness is fixed and canary proves `@orchestrator` replies reliably, compare this hotfix against the desired restored behavior before reverting:

- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex`: default seed currently writes `installs: ["chat"]`.
- `apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_actions.ex`: server-side world template fallback currently uses `["chat"]`.
- `apps/ezagent_plugin_world/assets/src/components/WorkspacePlugin.tsx`: client-side template builder fallback currently submits `["chat"]`.
- Tests currently assert the plain default in:
  - `apps/ezagent_domain_session/test/integration/default_session_template_seed_test.exs`;
  - `apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs`;
  - `apps/ezagent_domain_session/test/integration/repair_orchestrator_test.exs`;
  - `apps/ezagent_plugin_world/test/ezagent/world/save_session_template_public_scope_gate_test.exs`;
  - `apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`.

Do not blindly restore `["chat", "orchestrator"]`. First verify the restored default does not reintroduce session-create blocking and that orchestrator readiness is surfaced as a real intermediate/failure state instead of silent success.
