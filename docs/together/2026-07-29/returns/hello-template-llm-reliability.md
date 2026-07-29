# Together Return: Hello template LLM reliability

> **Task:** hello-template-llm-reliability
> **Branch:** `codex/hello-template-llm`
> **PR:** https://github.com/ezagent42/ezagent/pull/1576
> **Dev:** Codex
> **returned_at:** 2026-07-29 18:19 +0800
> **deadline:** not provided (direct request)
> **deadline_status:** out_of_scope

## What's done

- Restored the template role transaction: a role is successful only after its
  planned agent URI has converged into the current session member roster.
- Fresh failures record the skipped role, retire only the fresh agent through
  its spawn receipt, tombstone only that binding version, and remove pending
  membership state. Reused/session-external agents are not reused or retired.
- Added controlled repair/reinstall commands and CLI support for incomplete
  socialware sessions; persisted install config now carries the seed config.
- Kept Codex agent home/configuration isolated per agent, and preserved scoped
  Hello member configuration across the bridge and router paths.
- Made the World client use the server-authorized `hello_page` view registry,
  rather than matching `"/hello/"` in a session URI. Thus derived templates
  such as `hello-codex` render the Page preview as well.
- Switched development World assets to same-origin static files and rebuilt the
  bundle, so the Hello LLM flavor selector is not hidden behind a stale Vite
  asset on a remote browser.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | Each template role gets a new UUID agent URI; never reuse an agent from another session. | met | `definition_agents_materialize_test.exs` covers fresh retry and cross-session non-reuse. |
| 2 | Treat `session.join` as successful only once the current session member roster has been written. | met | `DefinitionAgents` waits for role-to-URI roster convergence; targeted integration suite passes. |
| 3 | On non-convergence return `membership_convergence_timeout`, mark role incomplete, and roll back the created agent. | met | Receipt-based `rollback_fresh_agent/2`, membership pending-facet cleanup, and regression coverage. |
| 4 | Creation is retryable/idempotent: joined roles skip; unjoined roles get new UUIDs; two roles converge to Admin + front-desk + llm. | met | `definition_agents_materialize_test.exs` delayed join/failure retry regression. |
| 5 | Add regression test with two fresh roles, first join delayed/failed, second attempt complete without cross-session reuse. | met | `apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs`. |
| 6 | Provide controlled reinstallation for existing incomplete sessions. | met | `ezagent.session.reinstall_socialware`, `ezagent.session.repair_template_config`, and CLI facade tests. |
| 7 | Derived Hello templates must show their generated Page preview. | met | `Conversation.source2.test.tsx` covers `session://system/hello-codex/codex-1` with authorized `hello_page`. |

**Method friction:** There was no written handoff/PR or deadline. The local
worktree also contains a broad, interdependent reliability change, so this
return records the directly verified suites; remote CI must still run after a
PR is opened.

## Proofs and gates

- Rebase base: `c4ec7b478c4d4c40f3a52f060ad8746718fc5193` (remote `main`,
  rebased before push).
- Local targeted Elixir verification:
  `POSTGRES_PORT=55442 mix test apps/ezagent_core/test/invariants/recipe_cap_binding_invariant_test.exs apps/ezagent_domain_agent/test/ezagent/agent/recipe_materializer_test.exs apps/ezagent_domain_agent_bridge/test/ezagent/agent_bridge/socket_channel_test.exs apps/ezagent_domain_session/test/ezagent/socialware/installation_test.exs apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs apps/ezagent_plugin_codex/test/ezagent/template/codex_agent_home_isolation_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/router_test.exs apps/ezagent_cli/test/ezagent_cli/session_socialware_facade_test.exs`.
- Local World verification: Vitest `WorkspacePlugin` + `Conversation` source
  suites: 9 passed; TypeScript `tsc --noEmit`: passed.
- `git diff --check`: passed before staging.
- `POSTGRES_PORT=55442 mix precommit`: started and completed the forced
  umbrella compilation, but did not terminate after approximately 11 minutes
  of local execution; it was stopped before a final pass/fail result. This is
  an open local-gate limitation, not a green result.
- CI run: pending on [PR #1576](https://github.com/ezagent42/ezagent/pull/1576).
  This return is not a claim of green remote CI.

## Follow-up notes

- Verification of the public preview minted anonymous user
  `entity://system/user/anon-R-OIwVPQgx7kIdDZos9OGA` in `codex-1`. It has not
  been removed because no deletion authorization was given.
- PR #1576 is open. Record its CI URL/status before merge.

## Merge request

PR #1576 targets `main` from `codex/hello-template-llm`. It is rebased on the
recorded remote `main`; rebase again if `main` advances before merge.
