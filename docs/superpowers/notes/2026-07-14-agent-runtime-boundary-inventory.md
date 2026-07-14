# AgentRuntime lifecycle-crossing inventory

**Date:** 2026-07-14

**Scope:** `apps/ezagent_domain_session/lib/**/*.ex` production sources

**Baseline:** `origin/main` fetched 2026-07-14; PR #1375 head is not an ancestor of
`origin/main` and remains pending.

This is the closed ARB-0 input to the ARB-1 AST classifier. Rows describe call
expressions, not prose or comments. `Path:line` is evidence for this baseline, not
the eventual gate key. The gate uses a unique source anchor. The one materializer
row has no line by design: PR #1375 changes that file, so its final anchor must be
regenerated after merge and rebase.

Allowed classes are exactly `agent_materialization`, `agent_ensure_live`,
`agent_executor_control`, `agent_destroy`,
`agent_config_or_credential_control`, `legal_session_lifecycle`, and
`legal_conversation_or_read`.

## Closed table

| Path:line | Resolved call | Class | Agent target proof | Disposition | Slice |
|---|---|---|---|---|---|
| `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex:409` | `Ezagent.SpawnRegistry.spawn/1` | `agent_materialization` | `demand_spawn_member/1` is invoked for declared session members before join | allowlisted debt | ARB-3 |
| `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_team.ex:205` | `Ezagent.Entity.Agent.spawn_from_template_content/5` | `agent_materialization` | explicit Agent module and `agent_uri` | allowlisted debt | ARB-3 |
| `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/rollback.ex:35` | `Ezagent.Session.SessionManager.stop/1` | `agent_executor_control` | argument is the orchestrator Agent URI | allowlisted debt | ARB-4 |
| `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/rollback.ex:48` | `Ezagent.Lifecycle.destroy/2` | `agent_destroy` | argument is `orchestrator_uri` | allowlisted debt | ARB-4 |
| `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/rollback.ex:73` | `Ezagent.Lifecycle.destroy/2` | `legal_session_lifecycle` | argument is explicitly `session_uri` | legal | none |
| `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/rollback.ex:80` | `Ezagent.Lifecycle.destroy/2` | `agent_destroy` | helper compensates `spawned_uris`, the freshly materialized Agent members | allowlisted debt | ARB-4 |
| `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex:anchor_pending_1375` | `Ezagent.Session.SessionManager.stop/1` | `agent_executor_control` | `evict_orchestrator_runtime/1` receives an orchestrator Agent URI | anchor_pending_1375 | ARB-4 |
| `apps/ezagent_domain_session/lib/ezagent/behavior/session/delivery.ex:286` | `Ezagent.SpawnRegistry.ensure_live/1` | `agent_ensure_live` | guarded by `receive_prefix == :agent`; argument is recipient Agent URI | allowlisted debt | ARB-3 |
| `apps/ezagent_domain_session/lib/ezagent/behavior/session/teardown.ex:151` | `Ezagent.Session.SessionManager.stop/1` | `agent_executor_control` | argument is the session's orchestrator Agent URI | allowlisted debt | ARB-4 |
| `apps/ezagent_domain_session/lib/ezagent/behavior/session/teardown.ex:245` | `Ezagent.Lifecycle.destroy/2` | `agent_destroy` | `reap_spawned_worker/3` receives a spawned worker Agent URI | allowlisted debt | ARB-4 |
| `apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex:562` | `Ezagent.Session.SessionManager.ensure_started/1` | `agent_executor_control` | options are built for `orchestrator_uri` and its executor transport | allowlisted debt | ARB-3 |
| `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex:280` | `Ezagent.Entity.Agent.spawn_from_template_content/5` | `agent_materialization` | explicit Agent module and `member_uri` | allowlisted debt | ARB-3 |
| `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/participants.ex:134` | `Ezagent.Entity.Agent.spawn_from_manifest/6` | `agent_materialization` | explicit Agent module and manifest-derived member URI | allowlisted debt | ARB-3 |
| `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/member_template.ex:246` | `Ezagent.Entity.Agent.spawn_from_template_content/5` | `agent_materialization` | explicit Agent module and replacement member URI | allowlisted debt | ARB-3 |
| `apps/ezagent_domain_session/lib/ezagent/behavior/template.ex:384` | `Ezagent.Entity.Agent.spawn_from_template_content/5` | `agent_materialization` | explicit Agent module; AgentTemplate instantiate path | allowlisted debt | ARB-3 |
| `apps/ezagent_domain_session/lib/ezagent/domain/agent.ex:82` | `Ezagent.KindRegistry.lookup/1` | `legal_conversation_or_read` | facade performs a non-activating status read | allowlisted debt | ARB-2 |
| `apps/ezagent_domain_session/lib/ezagent/domain/agent.ex:95` | `Ezagent.Domain.Pty.alive?/1` | `agent_executor_control` | explicit PTY sidecar probe for `agent_uri` | allowlisted debt | ARB-2 |
| `apps/ezagent_domain_session/lib/ezagent/domain/agent.ex:96` | `Ezagent.Domain.Pty.status/1` | `agent_executor_control` | explicit PTY sidecar status for `agent_uri` | allowlisted debt | ARB-2 |
| `apps/ezagent_domain_session/lib/ezagent/domain/agent.ex:204` | `Ezagent.ActionSet.Sandbox.read_persisted_state/1` | `agent_config_or_credential_control` | authorized public sandbox read for explicit Agent URI | allowlisted debt | ARB-2 |
| `apps/ezagent_domain_session/lib/ezagent/domain/agent.ex:266` | `Ezagent.ActionSet.Sandbox.read_persisted_state/1` | `agent_config_or_credential_control` | trusted credential-home read for explicit Agent URI | allowlisted debt | ARB-2 |
| `apps/ezagent_domain_session/lib/ezagent/domain/agent.ex:376` | `Ezagent.Domain.Pty.Server.phase/1` | `agent_executor_control` | explicit cc Agent executor phase probe | allowlisted debt | ARB-2 |
| `apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex:458` | `Ezagent.SpawnRegistry.spawn/1` | `legal_session_lifecycle` | scenario helper argument is a Session URI | legal | none |
| `apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex:552` | `Ezagent.SpawnRegistry.spawn_detailed/1` | `agent_materialization` | variable is explicitly `agent_uri` | allowlisted debt | ARB-3 |
| `apps/ezagent_domain_session/lib/ezagent/template/generic_session.ex:110` | `Ezagent.SpawnRegistry.spawn/1` | `legal_session_lifecycle` | argument is explicitly `session_uri` | legal | none |
| `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex:808` | `Ezagent.SpawnRegistry.spawn/1` | `legal_session_lifecycle` | target is the SessionTemplate's own template URI | legal | none |
| `apps/ezagent_domain_session/lib/ezagent/behavior/template.ex:648` | `Ezagent.SpawnRegistry.spawn/1` | `legal_session_lifecycle` | target is a SessionTemplate URI being rehydrated | legal | none |
| `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex:884` | `Ezagent.SpawnRegistry.spawn/1` | `legal_session_lifecycle` | target is explicitly `template_uri` | legal | none |
| `apps/ezagent_domain_session/lib/ezagent/entity/session.ex:386` | `Ezagent.SpawnRegistry.spawn/1` | `legal_session_lifecycle` | target is explicitly `template_uri` | legal | none |
| `apps/ezagent_domain_session/lib/ezagent/session/config_fork.ex:130` | `Ezagent.LocalRuntime.ensure_live/1` | `legal_session_lifecycle` | target is explicitly `session_uri` after config fork | legal | none |
| `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:1218` | `Ezagent.Behavior.Session.destroy/2` | `legal_session_lifecycle` | Lifecycle callback destroys the Session itself | legal | none |

Arity above is resolved from the AST argument count, including the final keyword
argument. It is deliberately not copied from stale nearby comments that still name
older `/4` or `/5` APIs.

## Closure search reconciliation

The primary search returned 76 textual hits. Thirty were call expressions and are
all represented above. The other 46 are aliases, moduledocs, comments, or deleted
API history; they have no executable lifecycle edge and therefore no table row.

The required closure search for `KindRegistry`, `LocalRuntime`,
`Invocation.dispatch`, and wrapper definitions returned 87 textual hits. It added
the executable calls explicitly listed above for `Domain.Agent.lifecycle_status/1`,
`Session.ConfigFork`, and `Session.destroy/2`. The remaining hits close into these
non-lifecycle families:

- `KindRegistry.list_all/0` and `lookup/1` in creator listing/resolution,
  membership, routing, presence, health, socialware editors and orchestrator tools
  are local enumeration, membership/readiness reads, or precondition checks. They
  do not spawn, rehydrate, stop, destroy, configure, or credential an Agent.
- `Invocation.dispatch/1` calls are member business dispatch, session membership,
  routing/config mutation, template actions, or session teardown intent. Dispatch
  is the legal command spine and none of these calls directly selects an Agent
  executor or lifecycle primitive.
- `ensure_template_alive/1`, `ensure_default_session_template/1`,
  `ensure_orchestrator_binding/2`, and `SessionManager.ensure_for_session/1` name
  Session/SessionTemplate state or bindings. Their bodies either perform legal
  template/session lifecycle or conversation-plane work.
- `compensate_spawned_members/1`, `demand_spawn_member/1`,
  `reap_spawned_worker/3`, and `ensure_orchestrator/…` are lifecycle wrappers whose
  underlying forbidden calls already have rows above. The ARB-1 classifier must
  retain wrapper fixtures so renaming or hiding a call does not erase the debt.
- `e2e/scenarios/agent_contract_g4.ex` is under `lib`, so its two runtime calls are
  intentionally inventoried rather than silently treated as test-only.

Thus no unexplained call in the closed lifecycle API family remains.

## Precision self-review

- Session destruction is legal (`rollback.ex:73`, `Behavior.Session.destroy/2`).
- SessionTemplate spawn/rehydration is legal (`entity/session_template.ex:808`,
  `behavior/template.ex:648`, and the template helper calls).
- Membership and liveness reads are legal conversation/read operations unless they
  make an Agent lifecycle decision. In particular, plain `KindRegistry.lookup/1`
  in membership is not debt.
- Member business dispatch through `Invocation.dispatch/1` is legal. Delivery's
  preceding Agent-targeted `SpawnRegistry.ensure_live/1` is the lifecycle debt;
  the subsequent dispatch is not.
- The Session-owned `Ezagent.Domain.Agent` reads are semantically non-activating,
  but remain ARB-2 ownership debt because the facade is in the wrong OTP app and
  directly names PTY/Sandbox details. Classification does not weaken their current
  CapBAC checks or move PTY policy.

## Upstream checkpoint

After `git fetch origin main`, PR #1375 head
`56da6c0caf2e86dd14751a6c8eca9c2bd95fcb8d` was not an ancestor of fetched
`origin/main`. No PR head was merged or cherry-picked. The materializer line is
therefore provisional and must be regenerated after #1375 lands; no final gate
line/source anchor is frozen here.
