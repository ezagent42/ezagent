# Socialware Manifest E2E — create → publish → discover → install → use

Validates the pure-config **socialware manifest** lifecycle end-to-end. A socialware
is a config-only bundle (`Ezagent.Socialware.Definition`: name / version / `uses` /
`agents` / `views` / `visibility_policy`), authored as config, published through
governance, discovered across workspaces, installed from the sessions page, and used
as a running session — **no code commit** to author or ship one.

## What is UI-facing vs config/API

| Step | Surface | Why |
|---|---|---|
| Author manifest | **config / seed** | Pure-config authoring; no world UI editor yet. |
| Publish (open→stage→publish CR) | **governance API** (`ConfigGovernance.Socialware`) | Admin-gated for public scope; no world UI yet. |
| **Discover** | **world UI** (`/sessions` new-session flow) | `DefinitionRegistry.list/1` surfaces installable socialwares. |
| **Install + create** | **world UI** | Selecting a socialware ref installs a local template + opens the session. |
| **Use** | **world UI** | Session renders the socialware's views + materializes its agents. |

The config/API-only steps are covered programmatically by the acceptance integration
test `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:1175`. This scenario
drives the **UI-facing** half (discover → install → use) with a real browser, on a
seeded published socialware.

## Preconditions (seeded, not UI)

- A **published, public** pure-config socialware manifest exists — the `hello` dogfood
  manifest (`uses: ["hello"]`, a hello render view, one non-cc `py` agent). Authored as
  config, published via `ConfigGovernance.Socialware` under the admin gate
  (`visibility_policy.scope = :public`).
- **Owner workspace** (where it is published) and a distinct **installer workspace**
  (proves cross-workspace public discovery — installer sees the public definition
  read-only and materializes a local copy).
- An **admin** user (public publish requires `AdminAuthority.admin?`) and a regular
  installer-workspace user.

## UI steps (agent-browser, screenshot each)

1. **Discover** — sign in to world as the installer-workspace user; open the
   new-session / `/sessions` surface. The published public socialware appears in the
   installable list (visible because `object_ws == caller_ws or system_ws or public?`).
   → *screenshot: install list showing the socialware from another workspace.*
2. **Install + create** — select the socialware ref and create a session.
   `Ezagent.World.SocialwareInstall.prepare_create_template/4` writes a local
   `socialware-install-<ref>` template pointing at the definition, tags it `current`,
   and the normal `session.create` path consumes it.
   → *screenshot: session created from the socialware.*
3. **Use** — the session opens with the socialware's **hello render view** and its
   materialized **non-cc `py` agent** (config + readiness + role + requested caps +
   `session.join`, all via the unified `RecipeMaterializer` flavor path — no
   cc-hardcode). Confirm the view renders and the agent is a session member.
   → *screenshot: running session with the hello view + the py agent present.*

## Pass criteria

- Install list shows the **public** socialware **from a different workspace** (cross-ws
  read-only discovery).
- Session **creates + opens** from the socialware ref via the local install template.
- The manifest's **non-cc (`py`) agent** is materialized through the shared flavor
  pipeline (not the cc-only path).
- The manifest's **hello view renders** in the session.

## Evidence

Screenshots captured during the live run are attached to the acceptance report /
Feishu thread for this merge (per the project's agent-browser E2E standard). This doc
is the reusable test plan; re-run it on any socialware-manifest change.
