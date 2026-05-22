# Plugin authoring contract — `Ezagent.Plugin`

> **Status**: DRAFT rev 1 — 2026-05-22. Author: Claude, per Allen
> Feishu 2026-05-22. Will go through `codex adversarial-review` before
> implementation (per `feedback_spec_codex_adversarial_review`).

## 0. The problem

Allen Feishu 2026-05-22: *"当外部开发者编写 Plugin 的时候，要遵守哪些
规范？… 很多软件写 plugin 都要求继承一个 meta class，没有实现规定的
interface 会报错。请基于 elixir best practice 设计。"*

**Today, "plugin" is a convention, not an enforced contract.**

A plugin is just an OTP application under `apps/ezagent_plugin_<name>/`
whose `Application.start/2` **imperatively** calls four registry
families:

```elixir
def start(_type, _args) do
  :ok = Ezagent.BehaviorRegistry.register(SomeKind, :action, SomeBehavior)
  :ok = Ezagent.SpawnRegistry.register("scheme", fn uri -> ... end)
  :ok = Ezagent.TemplateRegistry.register(SomeTemplateClass)
  # ... routing ...
  Supervisor.start_link(children, ...)
end
```

What's wrong with this as a "contract for external developers":

1. **Nothing is enforced.** There is no `@behaviour` at the plugin
   level. Forget to register a Behavior, mis-spell a scheme, skip the
   supervision child — nothing complains at compile time. The "rules"
   live as prose in `docs/onboarding/adding-a-plugin.md` + SKILL.md
   invariant 8. Prose is not a compiler.
2. **Registration is imperative + scattered.** Each plugin hand-writes
   the registry calls. A new registry family (or a changed signature)
   means editing every plugin. The plugin author must KNOW the
   registry APIs — exactly the "core knowledge" the plugin-isolation
   north star says plugin authors should NOT need.
3. **No metadata contract.** `plugins_live.ex` hardcodes
   `pretty_name/1`, `pretty_desc/1`, `primary_link/1` per slug — core
   UI code that must change every time a plugin is added. The plugin
   does not *declare* its own name/description/version.
4. **No config/UI surface contract.** Feishu hand-writes a
   `/plugins/feishu/bindings` LiveView; cc/curl/echo expose nothing;
   auto-derive has `/plugins/auto/:kind`. There is no declared
   "this plugin's config surface" — so `/plugins` cannot render a
   consistent card-with-config-icon (Allen's #1).

The building blocks already HAVE behaviours — `Ezagent.Kind`,
`Ezagent.Behavior`, `Ezagent.Kind.Template`, `Ezagent.UI.Form`. The
**plugin itself** is the one layer with no behaviour. This SPEC adds
it.

## 1. Design philosophy — declare, don't call

The codebase already has a consistent **declarative** philosophy:

- `@interface` → CLI + CmdK auto-derive (a Behavior declares actions;
  the framework builds the surfaces).
- `Ezagent.UI.Form.form_fields/0` → Template forms auto-render.
- auto-derive `/plugins/auto/:kind` → generic Kind admin, no
  hand-written page per Kind.

`Ezagent.Plugin` extends the SAME philosophy to the plugin level: a
plugin **declares** what it ships (kinds, behaviors, templates,
routing, config surface, metadata); the framework **does** the
registration + renders the UI. The plugin author writes declarations,
never touches a registry API, never edits core.

This is the **plugin-isolation north star** made structural (memory
`feedback_north_star_plugin_isolation`): a plugin author works
entirely inside `apps/ezagent_plugin_<name>/`, implements one
behaviour, and the compiler tells them if they got it wrong.

## 2. The `Ezagent.Plugin` behaviour

A new behaviour in `ezagent_core`: `apps/ezagent_core/lib/ezagent/plugin.ex`.

```elixir
defmodule Ezagent.Plugin do
  @moduledoc "The contract every ezagent plugin must implement."

  @type plugin_info :: %{
          slug: String.t(),         # "cc", "feishu" — URL-safe, unique
          name: String.t(),         # "Claude Code" — human display
          description: String.t(),
          version: String.t()
        }

  @type behavior_decl :: {kind :: module(), action :: atom(), behavior :: module()}
  @type spawn_decl :: {scheme :: String.t(), spawn_fun :: (URI.t() -> {:ok, pid} | {:error, term})}
  @type routing_decl :: {table_name :: atom(), opts :: keyword()}

  @type config_surface ::
          %{kind: :route, path: String.t(), label: String.t()}
          | %{kind: :form, schema: module(), label: String.t()}  # module implements Ezagent.UI.Form
          | %{kind: :flavor, flavor: String.t(), label: String.t()}  # agent-flavor plugins
          | nil

  # --- REQUIRED ---
  @callback plugin_info() :: plugin_info()

  # --- OPTIONAL (default [] / nil via `use Ezagent.Plugin`) ---
  @callback kinds() :: [module()]
  @callback behaviors() :: [behavior_decl()]
  @callback spawns() :: [spawn_decl()]
  @callback template_classes() :: [module()]
  @callback routing_tables() :: [routing_decl()]
  @callback config_surface() :: config_surface()
  @callback children() :: [Supervisor.child_spec() | {module(), term()}]

  @optional_callbacks kinds: 0, behaviors: 0, spawns: 0, template_classes: 0,
                      routing_tables: 0, config_surface: 0, children: 0
end
```

Only `plugin_info/0` is mandatory. A plugin that ships nothing but a
config page declares just `plugin_info/0` + `config_surface/0`.

## 3. The `use Ezagent.Plugin` macro — enforced, like a "meta class"

Stock Elixir `@behaviour` only emits a *warning* for a missing
`@callback`. Allen wants a hard **error** ("没有实现会报错"). The
idiomatic Elixir way to upgrade a warning to a compile error is a
`use` macro + an `@after_compile` validation hook:

```elixir
defmodule EzagentPluginCc do
  use Ezagent.Plugin       # ← inherit the "meta class"

  @impl Ezagent.Plugin
  def plugin_info, do: %{slug: "cc", name: "Claude Code",
                         description: "Spawn Claude Code agents via PTY",
                         version: "0.1.0"}

  @impl Ezagent.Plugin
  def template_classes, do: [Ezagent.PluginCc.Template.CcAgent]
  # kinds/0, behaviors/0, … omitted → default []
end
```

`use Ezagent.Plugin` does, at the plugin module:

1. `@behaviour Ezagent.Plugin` — IDE + compiler `@impl` checking.
2. Default implementations of every OPTIONAL callback (`kinds/0 → []`,
   `config_surface/0 → nil`, …) made `defoverridable`.
3. `@after_compile {Ezagent.Plugin.Validator, :__validate__}` — after
   the module compiles, the validator checks: `plugin_info/0` is
   implemented and returns a well-formed map (slug is a non-empty
   URL-safe string, etc.); every declared kind/behavior/template
   module exists + implements its own behaviour. **Any failure →
   `raise CompileError`** with a precise message. This is the
   "报错" — a wrong plugin does not compile.
4. Registers the module into `Ezagent.PluginRegistry` (§4) at boot.

Naming: the plugin-contract module is the plugin's TOP module
(`EzagentPluginCc`), distinct from its OTP `EzagentPluginCc.Application`.
The Application's `start/2` becomes a one-liner (§5).

## 4. `Ezagent.PluginRegistry` — runtime plugin catalog

A new registry (ETS, same shape as the other `*Registry` modules):
every `use Ezagent.Plugin` module is registered at boot. It answers
"what plugins are installed" — the data source `plugins_live` renders
from, replacing the hardcoded `pretty_name`/`pretty_desc`/`primary_link`.

```elixir
@spec list_all() :: [module()]            # all plugin modules
@spec info(slug :: String.t()) :: Ezagent.Plugin.plugin_info() | nil
```

## 5. Declarative boot — `Ezagent.Plugin.boot/1`

The plugin's `Application.start/2` collapses to:

```elixir
defmodule EzagentPluginCc.Application do
  use Application
  @impl true
  def start(_type, _args), do: Ezagent.Plugin.boot(EzagentPluginCc)
end
```

`Ezagent.Plugin.boot/1` reads the plugin module's declarations and
does ALL the registration the plugin author used to hand-write:

1. `BehaviorRegistry.register/3` for each `behaviors/0` entry.
2. `SpawnRegistry.register/2` for each `spawns/0` entry.
3. `TemplateRegistry.register/1` for each `template_classes/0` entry.
4. `RoutingRegistry.declare_table/2` for each `routing_tables/0` entry.
5. `PluginRegistry` self-registration.
6. `Supervisor.start_link/2` over `children/0`.

The plugin author never names a registry module. A new registry
family later → change `boot/1` once, not every plugin.

## 6. Config surface — unifying Allen's #1 / #2 / #3

`config_surface/0` is what the `/plugins` page renders the config icon
from (Allen #1 — unified `plugin_card` with a config icon):

- **`:route`** — the plugin owns a hand-written config LiveView.
  Feishu: `%{kind: :route, path: "/plugins/feishu/bindings", label: "Bindings"}`.
- **`:flavor`** — an agent-flavor plugin (cc/curl/echo). The config
  icon routes to that flavor's agent management
  (`/identities?filter=agent:<flavor>` + a "create" entry). This is
  the decision pending from the earlier thread (Allen #2) — see §8 Q1.
- **`:form`** — the plugin has runtime-editable settings; `schema` is
  a module implementing `Ezagent.UI.Form`; the framework auto-renders
  the settings form (no hand-written LV) and persists to a
  plugin-settings store. (For plugins that genuinely have global
  settings; none do today — this is the extensible slot.)
- **`nil`** — no config surface (`liveview` plugin).

`plugins_live` becomes: enumerate `PluginRegistry`, render one
`plugin_card` (new unified component, Allen #1) per plugin from
`plugin_info/0`, with the config icon wired from `config_surface/0`.
Zero per-slug hardcoding in core UI.

URI fields inside any plugin config surface use `uri_picker` (Allen
#3) — and the `:form` schema can declare a field `type: :uri` that
auto-renders as `uri_picker`, closing the gap structurally rather
than per-page.

## 7. Migration — phase existing plugins

5 plugins exist: cc, curl_agent, echo, feishu, liveview. All migrate
to `use Ezagent.Plugin`. Additive phasing — `Ezagent.Plugin` +
`boot/1` ship first; plugins migrate one per PR; nothing in core
references a plugin.

| PR | Scope |
|----|-------|
| 1 | `Ezagent.Plugin` behaviour + `use` macro + `Ezagent.Plugin.Validator` (@after_compile) + `Ezagent.PluginRegistry` + `Ezagent.Plugin.boot/1`. No plugin migrated yet. Unit-tested with a fixture plugin. |
| 2 | Migrate echo + curl_agent (smallest) to `use Ezagent.Plugin`; their `Application.start/2` → `boot/1`. Proves the contract on real plugins. |
| 3 | Migrate cc + feishu + liveview. |
| 4 | `plugin_card` component + `plugins_live` rendered from `PluginRegistry` + `config_surface/0`; delete hardcoded `pretty_name`/`pretty_desc`/`primary_link`. |

## 8. Open questions (for Allen + the codex adversarial-review)

- **Q1** — agent-plugin config surface. `:flavor` routes the config
  icon to `/identities?filter=agent:<flavor>`. Is "see/manage this
  flavor's agents" the right target, or should it be "create an agent
  of this flavor"? (Earlier thread, Allen #2 — leaning "agent
  management view".) Allen to confirm.
- **Q2** — enforcement strictness. `@after_compile` raising
  `CompileError` makes a malformed plugin fail to compile. Should the
  validator ALSO verify deeper invariants (e.g. every declared
  behavior's kind actually lists that action) — or keep PR-1 to
  shape-validation and leave semantic checks to the existing
  per-registry CI gates? Proposed: shape only in PR-1.
- **Q3** — does the plugin-contract module = the OTP `Application`
  module, or stay separate (`EzagentPluginCc` vs
  `EzagentPluginCc.Application`)? Proposed: separate — the Application
  is OTP plumbing, the plugin module is the contract; `boot/1` bridges.
- **Q4** — `:form` config surface + a plugin-settings store: build it
  in this SPEC, or stub `:form` as "V2" since no current plugin needs
  runtime settings? Proposed: define the `:form` shape now, implement
  the store when the first plugin needs it.

## 9. Verification

1. A module that `use Ezagent.Plugin` but omits `plugin_info/0` →
   **compile error** with a precise message (the core "报错" promise).
2. A plugin declaring a non-existent kind module → compile error.
3. All 5 existing plugins migrated; each `Application.start/2` is a
   one-line `Ezagent.Plugin.boot/1`; no plugin calls a `*Registry`
   module directly anymore.
4. `Ezagent.PluginRegistry.list_all/0` returns the 5 plugins; `/plugins`
   renders entirely from it — `grep` finds no `pretty_name`/`pretty_desc`
   hardcoded per slug in core UI.
5. Dependency-boundary test: `ezagent_core` has zero compile-time
   reference to any `ezagent_plugin_*` module (the isolation invariant
   — `Ezagent.Plugin` must not break it).
6. The plugin-authoring onboarding doc (`docs/onboarding/adding-a-plugin.md`)
   rewritten to the `use Ezagent.Plugin` contract.
7. Adding a hypothetical 6th plugin requires touching ONLY
   `apps/ezagent_plugin_<new>/` — no core, no UI file edited.
