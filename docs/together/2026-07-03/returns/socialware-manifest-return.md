# Socialware Manifest Track Return

Date: 2026-07-03
Branch: `integration/socialware-manifest`
Base: rebased onto `origin/main` at `5a6dd484`

## What Landed

- PR-1 `89442a9c` - `feat(socialware): resolve manifest name refs`
  - Added manifest metadata, `uses`, agent `flavor` defaults, and fail-closed manifest name-ref resolution for plugin/view references.
- PR-2 `d3b76846` - `feat(socialware): list definitions with write ACL`
  - Added visible definition listing and fail-closed definition writes requiring workspace, actor, and caller workspace ownership.
- PR-4 `0f22232a` - `feat(socialware): materialize manifest agent flavors`
  - Unified socialware/session role materialization with flavor-aware recipe materialization. Non-cc manifest agents now create config, readiness, role assignment, requested grants, and session join through the same core path.
- PR-3 `99b2bb3a` - `feat(socialware): govern manifest publishing`
  - Added `ConfigGovernance.Socialware` over the shared config change store with socialware manage caps, owner/private scope, admin-gated public scope, and cross-workspace public discovery.
- PR-5 `f8e5108e` - `feat(socialware): install manifests from sessions page`
  - Added sessions-page listing/install plumbing. Installing a visible socialware writes a local session template in the installer workspace and then uses the normal session create flow.
- PR-6 `69cb4ad0` - `feat(socialware): dogfood pure config manifests`
  - Added the pure-config hello dogfood manifest path, extended `mix ezagent.socialware.check`, and added the create/publish/discover/install/use E2E.
- Final gate fix `f8cb5c41` - `fix(socialware): close manifest gate regressions`
  - Closed post-rebase/final-gate issues: admin authority check for public listing, canonical `Ezagent.URI.new!/1`, PR5 helper extraction for arch limits, E2E registry setup, and updated existing KB expectations for default private scope.

No GitHub PR objects were opened for these increments; the track ran as direct commits on `integration/socialware-manifest`. The PR-comment payloads requested in the handoff are mirrored by the per-PR sections here.

## Acceptance E2E Transcript

Command:

```text
MIX_TEST_PARTITION=socialware_manifest_acceptance mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:1175
```

Result:

```text
Including tags: [location: {"test/ezagent_web/world_conversation_test.exs", 1175}]
.
Finished in 3.3 seconds (0.00s async, 3.3s sync)
1 test, 0 failures (35 excluded)
```

Behavior covered by that E2E:

- Authors a real pure-config socialware manifest using only config fields.
- Resolves the manifest through `ManifestResolver`, including `uses: ["hello"]` and the hello render view.
- Publishes through `ConfigGovernance.Socialware` with public visibility under the admin gate.
- Discovers it from another workspace through `DefinitionRegistry.list/1`.
- Installs it from the `/sessions` flow using `socialware_ref`.
- Creates a local installer-workspace session template and opens the session.
- Materializes a non-cc `py` agent with config metadata, readiness, role name, recipe requested caps, and `session.join`.
- Renders and uses the hello socialware views, including anonymous external feed visibility.

## PR-Level Gates

- PR-1 focused:
  - `MIX_TEST_PARTITION=socialware_manifest_pr1_rebase mix test apps/ezagent_domain_session/test/ezagent/socialware/definition_test.exs apps/ezagent_domain_session/test/ezagent/socialware/manifest_resolver_test.exs`
  - Result: 19 tests, 0 failures.
- PR-2 focused:
  - `MIX_TEST_PARTITION=socialware_manifest_pr2_rebase mix test apps/ezagent_domain_session/test/ezagent/socialware/definition_registry_test.exs`
  - Result: 4 tests, 0 failures.
- PR-3 focused:
  - `MIX_TEST_PARTITION=socialware_manifest_pr3_rebase mix test apps/ezagent_domain_session/test/ezagent/socialware/config_governance_test.exs`
  - Result: 4 tests, 0 failures.
- PR-4 focused:
  - `MIX_TEST_PARTITION=socialware_manifest_pr4_rebase mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs apps/ezagent_domain_agent/test/ezagent/agent/session_agent_materialize_test.exs`
  - Result: 16 tests total, 0 failures.
- PR-5 focused:
  - `MIX_TEST_PARTITION=socialware_manifest_pr5_rebase mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:565 apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:574`
  - Result: 2 tests, 0 failures.
- PR-6 focused:
  - `MIX_TEST_PARTITION=socialware_manifest_acceptance mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:1175`
  - Result: 1 test, 0 failures.

## Final Gates

All final gates were run after rebasing onto `origin/main`.

- `MIX_TEST_PARTITION=socialware_manifest_rebase mix ezagent.socialware.check`
  - Result: `chat` and `socialware` passed all 12 assertions; 2 definitions OK.
- `MIX_TEST_PARTITION=socialware_manifest_rebase mix ezagent.arch.scan`
  - Result: all counters PASS.
- `MIX_TEST_PARTITION=socialware_manifest_rebase mix ezagent.doc.scan`
  - Result: all counters PASS.
- `MIX_TEST_PARTITION=socialware_manifest_rebase mix ezagent.uri_query.scan`
  - Result: no URI-query scan violations.
- `MIX_TEST_PARTITION=socialware_manifest_rebase mix ezagent.check_invariants`
  - Result: all in-scope invariants clean.
- `MIX_ENV=test MIX_TEST_PARTITION=socialware_manifest_final_rebase mix precommit`
  - Result: exit 0. Full umbrella compile/format/test/precommit gate passed.

## Decisions and Defaults

- Public socialware listing is admin-gated with `Ezagent.Identity.AdminAuthority.admin?/2`, matching the settled design's core-team curation default.
- Private scope remains the default visibility scope for existing definitions and tests.
- Cross-workspace install is read-only against the source definition and writes only a local installer-workspace session template.
- Empty or whitespace `socialware_ref` is treated as no install, preserving normal session creation.
- Manifest agent `flavor` defaults to `"cc"`; recipes stay flavor-free.
- Full-suite tests reset enough registry state that the PR6 E2E explicitly registers the hello view and capability before exercising the manifest.
- The sessions-page install helper was extracted from `ConversationActions` to keep the arch fitness budget green without changing behavior.

## Open Questions and Risks

- The public review/moderation queue is not built. The interim default is the settled admin gate.
- No GitHub PR comments were posted because this track used direct branch commits rather than PR objects. This return doc is the authoritative mirror for decisions, proofs, and open questions.
- The final gate output includes existing test-suite warnings around Feishu credentials, sandbox ownership noise, and plugin-check negative fixtures. They did not produce failures.
