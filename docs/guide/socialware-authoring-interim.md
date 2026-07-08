# Guide: Authoring a socialware (interim — code + seed)

> **Operational how-to** for the period BEFORE the runtime-upload channel and the
> socialware market exist (future W1, post-官网). Today you author a socialware in
> **code + seed**. Do it with a forward-compatible discipline so migration to the
> future manifest/market is *mechanical*, not a rewrite. Authority for the split:
> [`docs/together/contributing/socialware-data-deployment-boundary.md`](../together/contributing/socialware-data-deployment-boundary.md).
> Deeper author flow: `.claude/skills/ezagent-socialware/SKILL.md`.

## Mental model: socialware = extension-pack, plugin = extension

A socialware carries **no code of its own**. It is a config-only *bundle* that
names the plugins it uses and composes their pieces into an app. Think VSCode:

| VSCode | ezagent | Contains |
|---|---|---|
| **Extension** | **plugin** (`ezagent_plugin_*`) | CODE: behaviors / views / recipes / kinds |
| **Extension pack** | **socialware** (`Ezagent.Socialware.Definition`) | DATA only: which plugins to `use`, + `agents` / `views` / `routing_rules` / `visibility_policy` |

A socialware is a **`Definition` persisted as a ConfigObject** at the opaque
subject `socialware:<name>` (workspace is a separate ConfigStore field). It holds
zero logic — only references to the plugin's pieces plus their composition.

## The three discipline rules

### 1. All code goes in a plugin — never inlined in the socialware

New behaviors, views, recipes, or kinds live in a plugin the socialware
references. If authoring an app makes you want to write an `.ex` module *for that
app*, that module belongs in a plugin (`apps/ezagent_plugin_<x>`), and the
socialware just names it. The socialware carries **zero code**. (Boundary doc:
"the seed or integration branch is the product" ⇒ stop and split.)

### 2. The socialware is a `Definition` expressed as DATA, not bespoke logic

Author it as a `%Ezagent.Socialware.Definition{}` value that only *references*
the plugin's pieces and *configures* composition. Use the **current `Definition`
field shape** (12 fields): `name, bases, shape, views, agents, members,
routing_rules, prompt_templates, legends, orchestrator_template_uri, adapters,
visibility_policy`.

- Agents go in **`agents: [%{recipe, role_name, flavor}]`**, not the older
  `roles:`/`members:` shape. `recipe` = a `RecipeRegistry` name (the plugin owns
  it); `role_name` = the per-session-unique routing id.
- **Caps come ONLY from the recipe.** The `Definition` never declares, appends,
  or overrides `requested_caps`. If an agent needs a cap, add it to its recipe in
  the plugin.
- **Declare intended `flavor`** (e.g. `:cc`) even though only `cc` is wired today
  — the target is `%{recipe, role_name, flavor}` routed through `Recipe.Compose`.
  `flavor` is **forward-declared**: it is NOT yet a validated `Definition`
  `agent_spec` field, so keep it in your design/skeleton but expect current
  `Definition.new/1` to ignore it until the flavor gap lands.

### 3. Persist through the existing config path — don't hand-roll a publisher

- **The Definition itself** persists via `Ezagent.Socialware.DefinitionRegistry`
  (`write_definition/2` → `ConfigStore.write_and_point`, or
  `seed_definition_if_absent/2` / `builtin_definitions/0` for boot seed). Do NOT
  write a parallel writer that pokes ConfigStore directly.
- **Agent config *inside* the socialware** (souls / cascade layers), where
  applicable, moves through the existing **CR-governance** path in
  `apps/ezagent_domain_identity/lib/ezagent/behavior/config_governance.ex`
  (`open_cr → stage_item → preview_cr → publish_cr`, #1042). Note v1 CR-governance
  is **agent-subject-only** (self-binding) — it governs an agent's own config,
  not the whole Definition. Use it for that; use `DefinitionRegistry` for the
  Definition.
- Both sit on the same `ConfigStore` pointer primitive, so authoring-as-data
  stays migration-ready when Definition-level CR / the market publish path lands.

## Skeleton (autoservice, modernized)

The shipped example is
`apps/ezagent_web/priv/socialware_seed/autoservice/package.yaml` (moved out of
domain_session priv by deploy-seed SPEC §6; the deployment directory is now the
canonical socialware home). It still
uses the OLD shape (`roles:` with inline `requested_caps`, and the pre-T1 Behavior-namespaced Kb module — now `Ezagent.ActionSet.Kb`).
Modernized to the `Definition` field shape it reads as data:

```yaml
# socialware DEFINITION (data only — references plugin pieces, carries no code)
name: autoservice-tier1

# agents this socialware brings in. recipe = plugin-owned RecipeRegistry name;
# role_name = per-session-unique routing id; flavor = forward-declared (cc today).
# CAPS LIVE IN THE RECIPE — the Definition declares none.
agents:
  - { recipe: autoservice-support, role_name: autoservice, flavor: cc }

# render ActionSets (views-as-behavior). Reference the plugin's view module;
# each declares a UNIQUE <sw>_render cap-only read action.
views: []            # e.g. [Ezagent.ActionSet.Autoservice.CustomerView]

# routing: customer's bare in-session message → the autoservice agent
routing_rules:
  - { match: in_session, receiver: autoservice }

# coarse openness gate (anon minting). fine gate is the per-view render cap.
visibility_policy: { publish_policy: auto, web_anon_access: true }
```

The `autoservice-support` **recipe** (in the KB/autoservice plugin, NOT here) is
where the caps live, e.g. `requested_caps: [{Ezagent.ActionSet.Kb, :query}]`
(module `Ezagent.ActionSet.Kb`, action `:query`). The KB corpus and persona
become plugin/package fixture data, not seed-script Elixir.

Today this materializes as a `%Definition{}` added to
`DefinitionRegistry.builtin_definitions/0` (or seeded via
`seed_definition_if_absent/2`) — the same data shape the future manifest/market
will upload. When you write the seed, use `%Ezagent.Socialware.Definition{}`
with `bases`/`shape` pointing at the plugin's ActionSet modules.

## What NOT to do yet

- **Don't build the runtime-upload channel or a market path.** That is future W1.
  Author via code + seed for now.
- **Don't inline code in the socialware.** Any `.ex` you write for the app goes in
  a plugin (rule 1).
- **Don't invent a new publish/writer mechanism.** Persist via `DefinitionRegistry`;
  govern agent config via CR-governance (rule 3).
- **Don't put caps on the Definition.** They come only from the recipe (rule 2).
- **Don't treat a seed script as the product.** A seed is an installer / E2E
  harness; the product is the `Definition` data (boundary doc, "PR Rule").

## Why

Following these three rules keeps every socialware a **pure `Definition` value +
plugin references**. When the runtime-upload channel and market land, migrating a
today-authored socialware is a mechanical lift of that same data into the manifest
— no code to disentangle, no bespoke publisher to retire, no caps to re-home.
