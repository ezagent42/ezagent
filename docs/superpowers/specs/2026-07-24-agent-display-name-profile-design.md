# Agent display-name persistence and uniqueness

## Problem

The World Agent directory renders `display_name`, then `name`, then the Agent URI.
New Agents receive UUID-backed URIs, while the generic template-spawn path does
not persist the template's `name` as an `Entity.Profile`. Consequently the
directory falls back to the UUID segment of the URI.

This affects all callers of the generic Agent template-spawn boundary, including
session role materialization and explicit Agent creation. It is not a React
rendering defect.

## Scope

- Persist a display name for newly spawned Agents when template content supplies
  a valid name.
- Ensure the persisted display name is unique among Agent profiles in the same
  workspace.
- Keep the World UI's existing display precedence unchanged.

Out of scope: changing Agent URIs, deriving identity from Session membership,
backfilling pre-release data, or changing the role-name vocabulary. The service
has not launched, so no data backfill is required. A forward migration is still
required because development databases may already have applied the initial
branch migration.

## Design

### New Agents

The generic `Ezagent.Entity.Agent.TemplateSpawn` success path will own display
profile persistence. After the Agent's template and runtime state have been
created successfully, it will derive the name from the validated template
content and create the `Entity.Profile`. This location covers every existing
creation caller without coupling the World surface to Agent internals.

If the requested name already belongs to another Agent profile in the same
workspace, the spawn boundary will assign the first available stable suffix
(`name-2`, `name-3`, and so on). A profile already attached to the same Agent
URI remains its own value, making retries idempotent. If a template has no
usable name, spawning retains its current behavior and the presenter continues
to fall back to the URI name. Profile persistence failures will follow the
spawn boundary's established error/rollback contract so a partially-created
Agent is never reported as successful.

The database constraint applies only when `entity_uri` is a bare canonical
`entity://<workspace>/agent/<name>` string. It must not infer Agent identity
from nullable profile fields such as `email`. The application API applies the
same Agent-only gate before reading or writing, validates the database's
255-character display-name limit, and truncates the base when reserving space
for a numeric suffix. No-email User profiles therefore remain free to share a
display name.

### UI impact

`EntityPresenter.display_many/1` already uses `Entity.Profile` before falling
back to the URI. `World.IdentityData` and the React Agent directory therefore
need no behavior change: newly spawned Agents automatically present their
profile display name.

## Error handling

- Invalid or absent template names are skipped, preserving current fallback
  behavior.
- A retry for the same Agent URI preserves its existing profile.
- Concurrent duplicate-name requests use independent database connections and
  resolve through the database-backed uniqueness check. Different Agent URIs
  allocate distinct suffixes; concurrent same-URI calls return one idempotent
  profile.
- Returned and raised profile failures are normalized inside the fresh-spawn
  obligation. Rollback removes the fresh worker, runtime and durable lineage,
  workspace binding, call-created ownership facts, config directory, grant,
  and profile while preserving any pre-start claim receipt.

## Verification

1. A red domain test proves a successful generic template spawn persists the
   template name as an Agent profile.
2. Domain tests prove duplicate requested names receive unique suffixes, while
   a retry for the same Agent preserves its profile. Separate unsandboxed
   owners prove both concurrency cases use independent database connections.
3. A World `IdentityData.list_entities/3` regression test proves the Agent row
   exposes the display name rather than its UUID URI suffix and that its
   respawn fixture retains the dynamically registered flavor.
4. Run focused test files, then the project `mix precommit` alias. Finally use
   the isolated manual-test database to verify the browser Agent list displays
   names for newly created Agents, including duplicate requested names.
