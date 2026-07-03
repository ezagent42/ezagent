# Socialware Manifest — Design (2026-07-03)

**Status:** DRAFT for Allen review (brainstorm output). Not yet a build plan.
**Lineage:** T2 `Definition` (#1140) + #1125/#1126/#1136 收编 + jjkysy #1148 audit + this brainstorm.

## 1. Model (locked this session)

A **socialware = a config-only "app bundle"**; a **plugin = code**. Emacs/VSCode analogy:

| VSCode | ezagent | carries code? |
|---|---|---|
| Extension (`package.json` + `activate()`) | **plugin** (behaviors / views / recipes / kinds) | ✅ yes |
| **Extension Pack** (`extensionPack: [ids]`, no code) | **socialware** (a Definition: `uses` + `agents` + `views` + routing) | ❌ no |
| Marketplace | **app-center** (discover / publish / install) | — |
| workspace recommended extensions | **SessionTemplate** (which socialwares a session installs) | — |
| running window | **session** (instance) | — |

- A socialware is addressed by the opaque ConfigStore subject **`socialware:<name>`** (workspace is a separate field; `config://` is dead per T1). It is **NOT** a routable URI scheme — it is a catalog/data key. It only becomes running actors when installed into a session.
- **The manifest IS the socialware** (VSCode best practice: the `package.json` is the artifact; marketplace/install/activation all derive from it). Nail the manifest → publish/discover/install/use follow.

## 2. The manifest — field set

Grounded in the real precedent `apps/ezagent_domain_session/priv/socialware/autoservice/package.yaml`
(has `name/version/persona/kb/session/routing/roles/surface`) + the current 12-field `Definition`.

| field | VSCode analog | Definition today | change |
|---|---|---|---|
| `name` | `name` | ✅ | subject `socialware:<name>` |
| `version` | `version` (semver) | ❌ | **ADD** — publish/versioning needs it (autoservice has `version: 0`) |
| `title` / `description` | `displayName`/`description` | ❌ | **ADD** — catalog listing needs human text |
| `uses: [plugin-id]` | `extensionPack: [ids]` | ⚠️ implicit via `bases/shape` modules | **ADD explicit** — declare plugin deps; install checks they're present (fail-closed) |
| `agents: [{recipe, role_name, flavor}]` | `contributes` | ⚠️ has `{recipe, role_name}`, **no flavor** | **ADD `flavor`** (cc/codex/py/completion; default cc). Fixes the cc-hardcode (see §4). caps come ONLY from the recipe. |
| `views: [view-ref]` | `contributes.views` | ⚠️ `[module()]` | **name-ref** (see §3) — unique `<sw>_<action>`, cap-gated via `authorize_view` |
| `routing_rules` | `contributes` / activation | ✅ | receiver refs resolve to agents' `role_name` |
| `visibility_policy` (public_face) | marketplace visibility | ✅ | `{publish_policy, web_anon_access}` |
| `assets` (persona/kb/…) | packaged files | ⚠️ autoservice has `persona:`/`kb:` | **ADD** — data files the socialware ships (paths, ingested at install) |
| `members / prompt_templates / legends / adapters / orchestrator_template_uri` | — | ✅ | keep |

## 3. The load-bearing decision — code/config boundary (`module()` → name-ref)

Today `bases / shape / views` are **`[module()]`** — compile-time code references. A **runtime-authored, config-only** socialware cannot name a compiled module it didn't write. So the manifest must reference building blocks **by registered name/ID**, resolved at install against what the `uses` plugins provide:

- `views: ["hello_render"]` → resolved via the view/ActionSet registry (the plugin that `uses` lists registered it).
- `agents[].recipe: "guide"` → resolved via `RecipeRegistry` (already name-based, fail-closed #1116).
- `uses: ["ezagent_plugin_hello"]` → the plugin must be installed; install verifies.

**This is the one-way door that makes "create a socialware via ezagent, not via code commit" real**: the socialware author picks from *already-registered* pieces; anything new = ship a plugin (separate code channel). It also cleanly explains the code/config split the team must follow *today* (interim guide, separate PR).

**Open decision O-1:** do we (a) keep the struct fields as `module()` and add a *parallel* name-ref manifest that resolves to modules at load, or (b) change the fields themselves to name-refs (bigger, touches T2 code)? Recommendation: **(a)** — a manifest layer that resolves names → the existing Definition struct at install; least disruption, lets code+seed and runtime-authored socialwares converge on one resolved shape.

## 4. cc-flavor fix (from investigation, feeds `agents[].flavor`)

Root cause (verified): session materialization calls the **cc-pinned** `DefaultAgentSeed.template_content` (flavor = `"cc"` constant), and `Recipe` **deliberately forbids** a flavor field — so there is nothing to pass. The flavor-generic path `Recipe.Compose` exists and backs *world create-agent*, but `definition_agents.ex` bypasses it (deliberate T2 MVP shortcut, #1140).
**Fix:** add `flavor` to `agents[]` (author's choice) + route session materialization through `Recipe.Compose` (NOT a param on the cc seed — cc is the only flavor wiring role hooks; Compose makes skills-into-config_dir flavor-generic). Ties into the recipe/flavor split.

## 5. The lifecycle the manifest drives (jjkysy #1148 chain)

`create → publish → discover → install → use → govern`, all operating on the manifest:
- **create** = author a `socialware:<name>` ConfigObject (manifest). Via ezagent, not code.
- **publish** = CR-governance `stage → preview → publish_cr` (#1042) flips the pointer → materialization fires.
- **discover** = `DefinitionRegistry.list(workspace)` (❌ missing — add) → catalog / new-session checkboxes.
- **install** = SessionTemplate `installs: [name]` → `Installation` materializes into a session (agents via §4, views cap-gated).
- **use** = session runs; anon gated by `visibility_policy`, views by `authorize_view`.
- **govern** = ownership ACL on `write_definition` (jjkysy W1; coupled to runtime-upload, not W0).

## 6. Dogfood validation

Re-express **autoservice** (and/or hello) as a **pure-config manifest** referencing an `autoservice` plugin's registered pieces, and run `publish → discover → install → use` end to end. This proves the schema AND surfaces exactly which of today's code-baked bits (`Ezagent.Behavior.Kb`, personas, kb ingest) are declarable-config vs must live in a plugin.

## 7. Open questions for Allen
1. **O-1 (§3):** name-ref manifest resolving to the struct (a, recommended) vs changing struct fields to name-refs (b)?
2. **Manifest serialization:** YAML file (like autoservice `package.yaml`) as the authoring surface, resolved into the ConfigObject? Or author the ConfigObject directly (world editor)? (VSCode = a `package.json` file; autoservice already uses YAML.)
3. **`uses` granularity:** reference whole plugins, or individual contribution IDs (finer)? (VSCode packs reference whole extensions.)
4. **Scope for the FIRST build slice:** the create+manifest-schema (this doc) → then discover (`list`) → then the new-session UI? (matches jjkysy W1 + the 官网 page.)
