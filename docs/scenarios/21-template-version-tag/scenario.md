# Scenario 21: Template version tag + instantiate

**Category**: 9 — Template + version tags
**Status**: ⏳ partially-implemented
**Last verified**: never (version-tag feature does not exist yet)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Admin logged in
- An existing cc.agent template in `workspace://system`

## Actors

- **Caller**: admin
- **Target**: template `template://system/my-cc-agent`

## Steps (intended — not yet wired)

### Tag

1. From `/admin/templates/my-cc-agent`, click "Tag version"; provide tag `v1.0.0` + a description.
2. The system snapshots the template's current content into a `template_versions` table.

### Instantiate from tag

3. From `/admin/workspaces/system`, click "Create agent from template"; pick template `my-cc-agent`, version `v1.0.0`.
4. Verify the spawned agent's config matches the v1.0.0 snapshot, not the current template content.

### Update + rollback

5. Edit the template (change `working_directory`); save.
6. Spawn a new agent: it uses the CURRENT template (not v1.0.0).
7. Tag a new version `v1.1.0`.
8. Spawn another agent from `v1.0.0` (the tag); verify it uses the older config.
9. Click "Rollback to v1.0.0"; verify the current template now matches v1.0.0.

## Expected outcomes (intended)

- `template_versions` table with rows per tag.
- Spawn with `version:` arg uses the tagged content.
- Spawn without `version:` uses current (latest) content.
- Rollback is non-destructive: previous "current" becomes a new tag (or is preserved as v1.1.0 in this case).

## Failure modes (intended)

- Tag a version with a duplicate tag name: `:already_exists`.
- Spawn from a deleted tag: `:version_not_found`.
- Rollback to a tag that no longer exists: `:version_not_found`.

## Cross-references

- Related PRs: none — version-tag feature is not yet shipped.
- Related SPECs: none yet.
- Tests:
  - `apps/ezagent_domain_workspace/test/integration/add_template_invokes_test.exs` (current template CRUD)
  - `apps/ezagent_domain_workspace/test/integration/update_agent_template_reconciler_test.exs` (current update path)
- Open bugs / gaps:
  - **Version tags as a feature do not exist**. Closest analogue: `AgentFlavorRegistry` template_class registration, which is compile-time, not runtime-versioned.
  - **No SPEC for version tags**. Will need to define: storage shape, tag-name constraints, instantiate-time resolution, rollback semantics.

## Notes

- This is the principal Category 9 gap. Blocks Phase 3 (production deployment with controlled template upgrades).
- Per `feedback_dont_defer_what_is_solvable_now`, a SPEC + minimal impl could land in 1-2 PRs once Phase 2 Behavior migration stabilizes.
- Marked ⏳ rather than ❌ because the underlying template CRUD works; only the version dimension is missing.
