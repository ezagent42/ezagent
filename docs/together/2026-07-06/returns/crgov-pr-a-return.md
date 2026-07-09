# ConfigGovernance PR-A Return

Branch: `work/crgov-manifest-yaml`
Commit: `880334be6 refactor(config-governance): unify change request layering`

## DoD Reconciliation

- `Ezagent.Socialware.ConfigChangeStore` moved to `Ezagent.ConfigGovernance.Store`; substrate schemas remain under `Ezagent.Socialware.*` because PR-C is not authorized.
- Added neutral `Ezagent.ConfigGovernance` helpers for CR fetch/status/workspace checks.
- Added `Ezagent.ConfigGovernance.Agent` for agent/self policy checks.
- `Ezagent.Behavior.ConfigGovernance` still owns ActionSet lifecycle context, sibling reads, publish effects, and sandbox effect assembly.
- Socialware-specific governance lives in `Ezagent.ConfigGovernance.Socialware`.
- Existing error tuple behavior preserved; no existing test assertions were edited.
- Grep gate: `rg -n "Socialware\.ConfigChangeStore|Socialware\.ConfigGovernance\.Socialware" apps test` returned no hits.
- PR-C substrate rename not started.

## Evidence

- TDD red: `mix test apps/ezagent_domain_session/test/ezagent/config_governance/store_invariant_test.exs` initially failed with missing `Ezagent.ConfigGovernance.Store`.
- TDD green: same test passed, `1 test, 0 failures`.
- Existing PR-A narrow suite passed:
  `apps/ezagent_domain_identity/test/ezagent/behavior/config_governance_test.exs`,
  `apps/ezagent_domain_session/test/ezagent/socialware/config_governance_test.exs`,
  `publish_or_upgrade_test.exs`, `retract_test.exs`, `content_hash_install_test.exs`,
  and `store_invariant_test.exs`.
- `mix format --check-formatted` passed.
- `mix compile --warnings-as-errors` passed.
- `mix ezagent.check_invariants` passed.
- `mix ezagent.arch.scan` passed.
- `mix ezagent.doc.scan` passed.
- `mix ezagent.uri_query.scan --hard-fail` passed.
- Post-rebase full gate: `mix precommit` passed.

## CI

- Branch pushed: `origin/work/crgov-manifest-yaml`.
- Remote checks: GitHub check suite queued for the pushed branch head; no check runs had materialized at handoff time.
