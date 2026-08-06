# Task 5 Report — Hello opt-in and journey coverage

## Implementation

Commit: `d04068c95 feat(hello): require LLM connection before session admission`.

- Declared `credential_admission: before_session_join` on the shipped Hello
  `llm` role only; `front-desk` remains immediate.
- Added the declaration-level `provider: deepseek` required by curl's normalized
  API-key connection descriptor, while retaining the existing `config.provider`
  for curl agent runtime configuration.
- Confirmed a template-level `llm_flavor` override retains
  `credential_admission: :before_session_join` through the existing
  `DefinitionEditor` composition path.
- Updated Hello session, member, migration, router, page integration, and
  shipped-manifest tests to assert a keyless LLM remains absent from members and
  is exposed as a pending DeepSeek API-key admission candidate.

## RED evidence

`mise exec -- mix test apps/ezagent_web/test/ezagent_web/hello_manifest_drift_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs`

- Failed before the YAML declaration: the manifest lacked the policy, LLM was
  immediately materialized, and a `cc-headless` flavor override returned
  `credential_admission: :immediate`.
- After adding the policy, the first run exposed `:unsupported_connection` for
  curl because the manifest stored `provider` only inside `config`; adding the
  declaration-level provider resolved that contract mismatch.

## GREEN evidence

- `mise exec -- mix test apps/ezagent_web/test/ezagent_web/hello_manifest_drift_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs`
  - `ezagent_web`: 3 tests, 0 failures.
  - `ezagent_plugin_hello`: 5 tests, 0 failures.
- `mise exec -- mix test apps/ezagent_web/test/ezagent_web/hello_manifest_drift_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/members_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/router_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/migrate_test.exs apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs apps/ezagent_domain_session/test/ezagent/socialware/installation_test.exs --seed 0`
  - `ezagent_domain_session`: 11 tests, 0 failures.
  - Hello test output contained no assertion failures; it includes pre-existing
    asynchronous `cross_workspace_denied` fire-and-forget log noise.
- `mise exec node@22.23.1 -- pnpm --dir apps/ezagent_plugin_world/assets test:e2e -- e2e/world.spec.ts`
  - 13 passed. The existing `sessions.join` public `world:dispatch` assertion
    remains green.

## Environment note

Plain `pnpm` selected Node 20.19.4 and failed before tests because pnpm 11
requires Node 22 (`node:sqlite`). The Node-22 command above is the valid
frontend test invocation.

## Follow-up review fix

Review found that the initial top-level Hello `llm.provider` was retained when
the template selected `cc-headless` or `codex`, allowing Curl-specific backend
metadata to reach a non-Curl spawn. The follow-up scopes provider lookup to
`role.config.provider` in the Curl adapter and removes the top-level manifest
field. New regressions prove Curl still derives its API-key descriptor from the
config and that both `cc-headless` and `codex` declarations retain admission
without a top-level provider.

- RED: the new nested-config credential test returned `:unsupported_connection`;
  the non-Curl declaration test found `provider: "deepseek"` at the top level.
- GREEN: `mise exec -- mix test apps/ezagent_domain_agent/test/ezagent/agent_flavor_resolver_durable_sandbox_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs apps/ezagent_web/test/ezagent_web/hello_manifest_drift_test.exs --seed 0` — 3/0, 5/0, 3/0.
- Full Task-5 focused run: `mise exec -- mix test … --seed 0` — domain-agent
  3/0, domain-session 11/0, Hello 26/0 with 1 skipped. The test environment
  continues to log pre-existing asynchronous `cross_workspace_denied` noise,
  without assertion failures.

## Browser dispatch journey

- RED: the new Playwright journey could not find the pending admission card in
  the generic conversation fixture.
- Added only the E2E contract fixture support required for the public flow:
  the three admission actions and a pending API-key admission row.
- GREEN: `mise exec node@22.23.1 -- pnpm --dir apps/ezagent_plugin_world/assets test:e2e -- e2e/world.spec.ts`
  — 14 passed. The browser invokes only `world:dispatch`, observes begin and
  complete payloads, then applies server-shaped `world:state` / `members:update`
  events to prove the exact provisional URI becomes a member and its card
  disappears. The existing `sessions.join` dispatch assertion remains green.

## Join layout transition follow-up

- RED: after a `sessions.join` dispatch but before a server reply, the
  conversation component correctly did not render.
- GREEN: the same browser test now emits the server-shaped `world:state` with
  its fixture layout, then asserts the conversation component replaces the
  sessions table. The admission journey was updated to use the current public
  `agent.api_key.put` save event; the server response auto-admits the candidate.
- `mise exec node@22.23.1 -- pnpm --dir apps/ezagent_plugin_world/assets test:e2e -- e2e/world.spec.ts`
  — 14 passed.

---

# Task 5 Report — Session ingress and front-desk removal

## Implementation

- The shipped Hello manifest now declares
  `HelloSessionActions.route_inbound` as ingress, protects only the `llm` role,
  and declares only that reusable LLM role.
- Hello registers the ingress action on the Session, routes owner messages to
  rebuild and all visitor messages to answer, and filters Session-authored and
  LLM-authored messages from re-entry.
- Generated narration, answers, share results, publish results, and Kanban
  receipts use the Session as both sender and authenticated caller with one
  target-specific `session.send` capability.
- Removed the production Hello flavor, front-desk recipe, orchestrator behavior,
  bridge adapter, boot migration, and their obsolete relay/migration tests.
  Existing `ensure_app/3` callers retain their return shape, with the Session in
  the compatibility sender position.

## RED evidence

Before the implementation, the focused manifest/registration/router run failed
six assertions: the manifest still declared `front-desk`, had no ingress, the
action set lacked `route_inbound`, and Session-authored messages were routable.

## GREEN evidence

- Focused manifest/registration/router run: Hello 15 tests, 0 failures; web 3
  tests, 0 failures.
- New Session-ingress integration: 3 tests, 0 failures, covering no front-desk,
  owner rebuild, visitor answer, and narration/share loop safety.
- Workspace ingress integration: 2 tests, 0 failures; the pass-after case now
  drives a genuine anonymous `session.send` through declared Session ingress.
- Updated stale member/template/page expectations: 4 selected tests, 0 failures.
- Fresh combined Task-5 verification: Hello 40 tests, 0 failures; web 3 tests,
  0 failures (`--seed 0`).

The test environment continues to emit pre-existing asynchronous
`cross_workspace_denied`/authorization log noise without assertion failures.

## Review correction — retired direct LLM relay

- `OfficialSiteSeed` still absence-gates the DeepSeek credential, but no longer
  installs or requires an `in_session → llm` delivery rule. On every ensure it
  removes seed-owned rows left by the retired `official-site-interim` workaround
  and reloads the routing registry, so user messages have one entry path: the
  manifest-declared Session ingress.
- Removed the deleted Hello flavor's `:hello_sync_result` branch from
  `Agent.Receive` and its stale capability-resolution example. A source-level
  architecture regression prevents either reference from returning.
- Upgraded the ingress integration to dispatch real `session.send` invocations
  with exact target-issued caps. It installs an actual `llm` member, observes
  successful authorization of the manifest-declared Session ingress, proves the
  protected LLM receives no direct `agent.receive`, and covers owner rebuild,
  visitor answer, and Session-authored loop rejection.

RED evidence:

- The architecture regression initially found
  `sync_result_action("hello") -> :hello_sync_result` and the stale cap comment.
- The updated seed contract initially found one seed-owned direct delivery row.

GREEN evidence:

- `MIX_ENV=test POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=5432 POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres mix test apps/ezagent_domain_agent/test/architecture/retired_hello_relay_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/official_site_seed_test.exs apps/ezagent_plugin_hello/test/integration/hello_session_ingress_test.exs --seed 0`
  - `ezagent_domain_agent`: 1 test, 0 failures.
  - `ezagent_plugin_hello`: 11 tests, 0 failures.

The focused run includes a simulated legacy `official-site-interim` row and
proves the next seed run deletes it without recreating direct delivery. The test
environment continues to emit pre-existing socialware-drift and asynchronous
authorization warnings without assertion failures.
