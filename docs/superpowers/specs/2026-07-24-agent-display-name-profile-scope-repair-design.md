# Agent Display-Name Scope Repair Design

## Goal

Keep Agent display-name persistence, uniqueness, and World presentation while
removing the PR's changes to core lineage and provenance behaviour.

## Decision

`ezagent_core` retains exactly one responsibility for this feature: the
PostgreSQL migration that creates the final Agent-only unique display-name
index. The branch has not been deployed and has no legacy data, so it will
contain one final migration rather than a chain of corrective migrations.

`ezagent_domain_identity` owns name allocation and returns whether the profile
row was newly inserted or already existed. `ezagent_domain_agent` creates that
profile before starting a fresh named Agent. If later spawn work fails, it
deletes only a profile inserted by the same call. A profile write failure stops
the spawn before it can create lineage or provenance facts.

`ezagent_core` must not change `Ezagent.AgentLineage`,
`Ezagent.Provenance.DerivationEdges`, or their transaction semantics for this
feature.

## Data flow

1. `TemplateSpawn` reads and normalizes the requested name.
2. For a named candidate, it asks `Entity.Profile` to allocate a workspace-unique
   Agent profile and receives an insertion receipt.
3. If allocation fails, `TemplateSpawn` returns an error before calling the
   plugin Template Class.
4. The existing spawn path creates and binds the Agent using its unchanged core
   lineage/provenance APIs.
5. If the later spawn path fails, `TemplateSpawn` rolls back only the profile
   identified by its insertion receipt. Existing/same-URI profiles are retained.
6. World continues to use its existing profile-first presentation path.

## Constraints

- One final Agent-only partial unique index in `ezagent_core` migrations.
- No changes to Agent URI shape, core lineage semantics, or provenance
  transaction/savepoint semantics.
- Same-URI retries retain the original display profile.
- Concurrent distinct Agents requesting the same name receive deterministic
  suffixes (`name`, `name-2`, ...).
- Users remain outside the Agent display-name uniqueness constraint.
- Tests prove profile allocation, pre-spawn failure behaviour, post-spawn
  profile cleanup, and World display behaviour.

## Verification

- Run the focused identity profile and concurrency suites.
- Run the TemplateSpawn materialization suite, including profile cleanup cases.
- Run the World Agent display-name regression.
- Run `mix precommit`; if the known environment boot issue prevents a terminal
  result, record that separately without calling the gate green.
