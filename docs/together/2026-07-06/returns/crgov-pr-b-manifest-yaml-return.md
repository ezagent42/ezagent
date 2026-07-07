# Manifest YAML PR-B Return

Branch: `work/crgov-manifest-yaml`
Commit: `feat(socialware): add manifest yaml interchange` (this return file is included in that commit)

## DoD Reconciliation

- Added `Ezagent.Socialware.ManifestYaml` content-only API:
  `parse/1`, `render/1`, `import/2`, `export/2`.
- YAML parsing uses `YamlElixir.read_from_string/1`; bases/shape module strings are resolved with `String.to_existing_atom/1`; unknown modules return tagged errors.
- `render/1` emits view ids by reverse-mapping registered `SessionViewRegistry` modules; unregistered view modules fail with `{:unrenderable_view, module}`.
- `import/2` runs parse -> `ManifestResolver.resolve/1` -> `Conformance.check_candidate/2` -> `ConfigGovernance.Socialware.publish_or_upgrade/2`.
- Added `Conformance.check_candidate/2`.
- Added lookup-aware `Installation.resolved_template_installs/3` and `Installation.behavior_set_for_template/3`, with arity-2 callers delegating through default registry lookup.
- Added operator tasks:
  `mix ezagent.socialware.import <file> [--workspace <ws>]` and
  `mix ezagent.socialware.export <name> [--workspace <ws>]`.
- File IO is limited to operator tasks and boot seed code; `ManifestYaml` library functions accept content, not paths.
- Added boot deploy-seed scan behind `:socialware_manifest_boot_scan`, default on in dev/prod and off in test.
- Boot scan imports `priv/socialware/*/manifest.yaml` through the same governed import chain and raises on broken manifests.
- Added canonical `apps/ezagent_domain_session/priv/socialware/autoservice/manifest.yaml`.
- Legacy `package.yaml` retained with a header pointing to `manifest.yaml`; persona/kb wiring remains out of scope.
- Added autoservice manifest e2e: import -> conformance -> publish -> registry discover -> install into a session -> declared agent materializes -> dispatch through routing path.
- Added negative case: unknown recipe is rejected at conformance and nothing is published.
- PR-C substrate rename not started.

## Evidence

- TDD red: manifest YAML tests initially failed on missing `ManifestYaml`, `ManifestSeed`, and `Conformance.check_candidate/2`.
- Focused PR-B suite passed:
  `mix test apps/ezagent_domain_session/test/ezagent/socialware/manifest_yaml_test.exs apps/ezagent_domain_session/test/ezagent/socialware/manifest_seed_test.exs`
  -> `9 tests, 0 failures`.
- `mix format --check-formatted` passed.
- `mix compile --warnings-as-errors` passed.
- `mix ezagent.socialware.check` passed and included `autoservice-tier1`, `chat`, `hello`, and `socialware`.
- `mix ezagent.socialware.export autoservice-tier1` passed and emitted YAML.
- `mix ezagent.socialware.import apps/ezagent_domain_session/priv/socialware/autoservice/manifest.yaml` passed with `exists`.
- `routing_traces` invariant categorization added after the full precommit exposed the runtime trace table; schema inspection showed `workspace_uri NOT NULL`.
- Post-rebase full gate: `mix precommit` passed.

## CI

- Branch pushed: `origin/work/crgov-manifest-yaml`.
- Remote checks: GitHub check suite queued for the pushed branch head; no check runs had materialized at handoff time.
