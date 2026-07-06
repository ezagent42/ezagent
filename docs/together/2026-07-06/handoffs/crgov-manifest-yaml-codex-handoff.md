# Handoff — ConfigGovernance unification (#158) + Manifest YAML (Q2b) → codex

> **Task:** `crgov-manifest-yaml`
> **Spec (authoritative):** `docs/superpowers/specs/2026-07-06-config-governance-unify-and-manifest-yaml.md` (rev2, codex-adversarial-reviewed)
> **Dispatcher:** Allen · **Coordinator/validator:** Claude · **Dev:** codex
> **Branch:** codex owns `work/crgov-manifest-yaml` (branch off current `origin/main`); coordinator merges to main after gate validation.

## Goal (one line)

Close the manifest design's two remaining engineering items: (PR-A) honest
ConfigGovernance layering — one shared CR store symbol + per-subject policy, zero
behavior change; (PR-B) YAML as the manifest interchange format — content-only
parse/render/import/export, conformance-gated import, autoservice dogfood e2e.

## Read first

1. The spec — every `[R‑n]` tag is a HARD constraint from adversarial review; treat
   them as non-negotiable acceptance criteria, not suggestions.
2. `apps/ezagent_domain_identity/lib/ezagent/socialware/config_change_store.ex`
   (the store being renamed), the two governance modules it serves, and
   `apps/ezagent_domain_session/lib/ezagent/socialware/{manifest_resolver.ex,
   conformance.ex, demo/hello.ex}` (the import chain you are composing — you are
   wiring EXISTING stages together, not building new validation).

## Sub-step 1 — PR-A: governance layering refactor (behavior-preserving)

Scope: spec §3 (A1–A4). Pure refactor; **any existing-test assertion edit = spec
violation** (R-5).

DoD:
- [ ] `Ezagent.Socialware.ConfigChangeStore` → `Ezagent.ConfigGovernance.Store`
      (file `apps/ezagent_domain_identity/lib/ezagent/config_governance/store.ex`);
      repo-wide mechanical rename incl. tests; `git grep -l "Socialware.ConfigChangeStore" apps/` → empty.
- [ ] `Ezagent.ConfigGovernance` shared helpers (`fetch_cr/1`, `assert_status/2`,
      `assert_workspace/2`) return neutral tags; BOTH callers map back to their exact
      current error tuples (R-5; socialware.ex:250, config_governance.ex:270).
- [ ] `Ezagent.ConfigGovernance.Agent` = pure functions only (plain data in/out);
      ActionSet keeps module name, dispatched action names/caps, ALL ctx/sibling-slice
      reads, publish-in-ctx, and sandbox-effect assembly (R-6;
      config_governance.ex:45,209,340).
- [ ] New invariance test: agent-path AND socialware-path publish both land CR rows
      through `Ezagent.ConfigGovernance.Store`.
- [ ] Substrate modules (`ConfigChangeItem/ConfigChangeRequest/ConfigObject/ConfigStore`)
      NOT renamed (explicit non-goal, spec R-8).

Gates: full suite green · `mix compile --warnings-as-errors` · `mix format
--check-formatted` · `check_invariants` + arch gates · grep gate above.

## Sub-step 2 — PR-B: Manifest YAML (independent of PR-A; either order)

Scope: spec §4 (B1–B6). You are composing existing stages; the only genuinely new
logic is YAML (de)serialization + the view-id reverse-map.

DoD:
- [ ] `Ezagent.Socialware.ManifestYaml` (session app): `parse/1` (safe load, no atom
      minting — known-field whitelist + `String.to_existing_atom` for bases/shape
      module strings, rescued to error tuples; content-only), `render/1` (canonical
      YAML; views emitted as registry view ids via reverse-map,
      `{:error, {:unrenderable_view, module}}` when unregistered; bases/shape emitted
      as module-name strings, R2-2), `import/2` (parse → `ManifestResolver.resolve` →
      `Conformance.check_candidate` → `publish_or_upgrade`; R-1/R2-1, R-3),
      `export/2` (registry fetch → render).
- [ ] `Conformance.check_candidate/2` (R2-1) + lookup-aware `Installation` variants
      (R3-1): add `Installation.resolved_template_installs/3` and
      `behavior_set_for_template/3` taking `lookup_fun:` (default
      `&DefinitionRegistry.lookup/2`), threaded through `resolve_definitions/3` and
      unpinned `resolve_install/3` (installation.ex:58,:475); existing arity-2 heads
      delegate with the default (all current callers byte-compatible).
      `check_candidate/2` runs the same check list via the arity-3 variants with the
      candidate's own name resolving in-memory; other names hit the real registry;
      `check/2` post-publish semantics unchanged. Unit test: a valid UNPUBLISHED
      definition passes `check_candidate` and fails `check`.
      Completeness bar (R3-2): import enforces `check_candidate` ONLY — do NOT add
      `DefinitionEditor.validate_definition(complete: true)` (that's the form's UX
      contract; `publish_or_upgrade` never ran it for any caller).
- [ ] NO library function accepts a filesystem path (R-3).
- [ ] `mix ezagent.socialware.import <file> [--workspace <ws>]` + `export` twin:
      `File.read!` at task layer only; ctx = hello `admin_ctx/2` precedent
      (hello.ex:134-151, R-4); prints `:published | :upgraded | :exists` or the
      conformance failure list; non-zero exit on error.
- [ ] Round-trip property test incl. a views-authored-as-ids case (R-2).
- [ ] `apps/ezagent_domain_session/priv/socialware/autoservice/manifest.yaml` in
      canonical format (name/version/title/description/uses/roles/routing_rules/
      views/visibility_policy + bases/shape as module strings per R2-2 — include
      whatever the governed publish path's validation requires; verify against
      `publish_or_upgrade`'s actual validation at implementation). Legacy
      `package.yaml` untouched except a header comment pointing at `manifest.yaml`;
      persona/kb stay with the seed script (spec B6 non-goals).
- [ ] **Acceptance e2e (the completion gate):** import → conformance passes →
      publish → `DefinitionRegistry.list/1` shows it → install into a session →
      declared agents materialize → routing delivers per `routing_rules`. PLUS the
      negative case: unknown recipe → rejected at conformance, nothing published (R-1).

Gates: full suite green · warnings-as-errors · format · `check_invariants` +
`mix ezagent.socialware.check` · the acceptance e2e above.

## Process

- Per-PR return file under `docs/together/2026-07-06/returns/` (dev-together
  standard): DoD table with proof per line, deviations called out, CI run links.
- If a spec constraint proves wrong against reality mid-implementation: STOP that
  sub-step and hand back with the file:line evidence — do not improvise around an
  `[R‑n]` constraint.
- Known environment notes: `yaml_elixir ~> 2.9` already in umbrella (add to session
  app deps only); test DB per repo standard; do not touch prod/deploy.
