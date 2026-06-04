# Plugin authoring contract — `Ezagent.Plugin`

> **Status**: DRAFT rev 2 — 2026-05-22. Author: Claude, per Allen
> Feishu 2026-05-22.
>
> - **rev 1**: initial design.
> - **rev 2**: `codex adversarial-review` fixes — 4 HIGH + 2 MEDIUM.
>   (a) enforcement was opt-in (a plugin that skips `use Ezagent.Plugin`
>   bypassed everything) → added a **non-optional app-level gate** (a
>   Mix compiler + CI invariant scanning every `ezagent_plugin_*` app);
>   (b) `boot/1` registered before starting the supervisor → **two-phase
>   boot** (children first, then publish); (c) `@after_compile` can't
>   see sibling modules reliably in an umbrella → it does plugin-local
>   checks only; cross-module checks moved to the app-level gate; (d)
>   `spawns/0` let a plugin register an arbitrary URI scheme →
>   reintroduces the forbidden `feishu://`-style plugin-owned scheme →
>   **scheme allowlist**; (e) the "6th plugin touches only its own
>   dir" claim was false — agent-flavor→kind mapping is hardcoded in
>   domain_instance_message → added a declarative `agent_flavors/0` + resolver
>   migration; (f) `:form` config surface promised a settings store
>   the SPEC deferred → `:form` is **rejected in V1**.

## 0. The problem

Allen Feishu 2026-05-22: *"当外部开发者编写 Plugin 的时候，要遵守哪些
规范？… 很多软件写 plugin 都要求继承一个 meta class，没有实现规定的
interface 会报错。请基于 elixir best practice 设计。"*

**Today, "plugin" is a convention, not an enforced contract.**

A plugin is just an OTP application under `apps/ezagent_plugin_<name>/`
whose `Application.start/2` **imperatively** calls four registry
families (`BehaviorRegistry`, `SpawnRegistry`, `TemplateRegistry`,
`RoutingRegistry`). What's wrong with that as a contract:

1. **Nothing is enforced.** No `@behaviour` at the plugin level. The
   "rules" live as prose in `docs/onboarding/adding-a-plugin.md` +
   SKILL.md invariant 8. Prose is not a compiler.
2. **Registration is imperative + scattered.** Each plugin hand-writes
   registry calls — the plugin author must know core registry APIs,
   exactly the "core knowledge" the plugin-isolation north star says
   they should NOT need.
3. **No metadata contract.** `plugins_live.ex` hardcodes
   `pretty_name/1` / `pretty_desc/1` / `primary_link/1` per slug — core
   UI that changes every time a plugin is added.
4. **No config/UI surface contract.** Feishu hand-writes
   `/plugins/feishu/bindings`; cc/curl/echo expose nothing. No
   declared "this plugin's config surface".

The building blocks already have behaviours — `Ezagent.Kind`,
`Ezagent.Behavior`, `Ezagent.Kind.Template`, `Ezagent.UI.Form`. The
**plugin itself** is the one layer with none. This SPEC adds it.

## 1. Design philosophy — declare, don't call

The codebase has a consistent **declarative** philosophy: `@interface`
→ CLI + CmdK auto-derive; `form_fields/0` → Template forms; auto-derive
→ generic Kind admin. `Ezagent.Plugin` extends the SAME pattern to the
plugin level: a plugin **declares** what it ships; the framework
**does** the registration + renders the UI. The plugin author writes
declarations, never touches a registry API, never edits core — the
plugin-isolation north star made structural.

## 2. The `Ezagent.Plugin` behaviour

`apps/ezagent_core/lib/ezagent/plugin.ex`:

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

  # rev 2 (codex HIGH-4): scheme is NOT a free string. A plugin may
  # only register a spawn fn for one of the SIX core SPEC v3 schemes.
  # It may NEVER introduce a new top-level scheme (SPEC v2 §5.8 — the
  # `feishu://` deletion). Validation rejects anything else.
  @core_schemes ~w(entity session template resource workspace system)
  @type spawn_decl :: {scheme :: String.t(), spawn_fun :: (URI.t() -> {:ok, pid} | {:error, term})}

  @type routing_decl :: {table_name :: atom(), opts :: keyword()}

  # rev 2 (codex MEDIUM-5): agent-flavor plugins declare their
  # flavor → {kind, template_class} mapping so the domain_instance_message spawn
  # resolver consumes it declaratively instead of a hardcoded map.
  @type agent_flavor_decl :: %{
          flavor: String.t(),               # "cc", "curl", "echo" — the entity-name prefix
          kind: module(),                   # the Agent Kind module
          template_class: module()          # the Template Class
        }

  # rev 2 (codex MEDIUM-6): V1 config surface is :route | :flavor | nil.
  # :form (auto-rendered settings persisted to a store) is V2 — the
  # validator REJECTS :form until the settings store ships.
  @type config_surface ::
          %{kind: :route, path: String.t(), label: String.t()}
          | %{kind: :flavor, flavor: String.t(), label: String.t()}
          | nil

  # --- REQUIRED ---
  @callback plugin_info() :: plugin_info()

  # --- OPTIONAL (default [] / nil via `use Ezagent.Plugin`) ---
  @callback kinds() :: [module()]
  @callback behaviors() :: [behavior_decl()]
  @callback spawns() :: [spawn_decl()]
  @callback template_classes() :: [module()]
  @callback agent_flavors() :: [agent_flavor_decl()]
  @callback routing_tables() :: [routing_decl()]
  @callback config_surface() :: config_surface()
  @callback children() :: [Supervisor.child_spec() | {module(), term()}]
  @callback after_boot() :: :ok

  @optional_callbacks kinds: 0, behaviors: 0, spawns: 0, template_classes: 0,
                      agent_flavors: 0, routing_tables: 0, config_surface: 0,
                      children: 0, after_boot: 0
end
```

Only `plugin_info/0` is mandatory.

## 3. Enforcement — TWO layers (codex rev 2 — HIGH-1, HIGH-3)

rev 1 relied on `use Ezagent.Plugin` + `@after_compile`. Codex showed
that is (a) opt-in — a plugin that never calls `use Ezagent.Plugin`
bypasses it entirely; and (b) unreliable — an `@after_compile` callback
on the plugin module cannot see sibling template/behavior modules that
the umbrella may compile later. So enforcement is split:

### 3.1 `use Ezagent.Plugin` — plugin-LOCAL checks

`use Ezagent.Plugin` injects `@behaviour Ezagent.Plugin`, the
`defoverridable` defaults for optional callbacks, and an
`@after_compile` that validates ONLY what is local to the plugin
module: `plugin_info/0` is implemented and returns a well-formed map
(slug is a non-empty URL-safe unique string, etc.). A failure here →
`raise CompileError`. Catches the common mistake fast.

It does NOT, in `@after_compile`, dereference declared kind/behavior/
template modules — those may not be compiled yet (codex HIGH-3).

### 3.2 The app-level gate — NON-optional, catches everything (codex HIGH-1)

A custom **Mix compiler** `:ezagent_plugin_check` (added to each
`ezagent_plugin_*` app's `mix.exs` `compilers:`) + a CI invariant test
`plugin_contract_test.exs`. After an `ezagent_plugin_*` app is fully
compiled, the gate verifies:

1. The app **declares a plugin module** — convention: the app's
   `mix.exs` `application/0` carries a new `:ezagent_plugin` app-env
   key naming the plugin module. The gate fails the build if absent.
2. That module `use`s `Ezagent.Plugin`.
3. Every declared kind / behavior / template / agent-flavor module
   **exists and implements its own behaviour** — the cross-module
   check `@after_compile` cannot safely do; it runs HERE, after the
   whole app compiled.
4. Every `spawns/0` scheme is in `@core_schemes` (codex HIGH-4).
5. The app does NOT call `*Registry.register` / `declare_table`
   directly anymore (grep gate — registration goes through `boot/1`).

Wired into the `ezagent_plugin_*` apps' compiler list, the gate is
**not opt-in** — a non-conforming plugin app fails to build. That is
Allen's "没实现接口就报错", made non-bypassable.

## 4. `Ezagent.PluginRegistry` — runtime plugin catalog

A new ETS registry (same shape as the other `*Registry` modules). Each
plugin self-registers during `boot/1` (§5) — runtime, NOT compile
time, so no compile-order race (codex HIGH-3). Answers "what plugins
are installed" — the data `plugins_live` renders from.

```elixir
@spec list_all() :: [module()]
@spec info(slug :: String.t()) :: Ezagent.Plugin.plugin_info() | nil
```

## 5. Two-phase declarative boot — `Ezagent.Plugin.boot/1` (codex rev 2 — HIGH-2)

rev 1 published registry entries before starting the plugin's
supervisor — so another process could call a spawn fn before the
plugin's `DynamicSupervisor` existed. rev 2 boot is **two-phase**:

```elixir
defmodule EzagentPluginCc.Application do
  use Application
  @impl true
  def start(_type, _args), do: Ezagent.Plugin.boot(EzagentPluginCc)
end
```

`Ezagent.Plugin.boot/1`:

**Phase 1 — start children.** `Supervisor.start_link/2` over the
plugin's `children/0` FIRST. Any `DynamicSupervisor` / Registry / ETS
the plugin's spawn fns or behaviors depend on is alive before anything
is published.

**Phase 2 — publish.** Only now register: `BehaviorRegistry` per
`behaviors/0`; `SpawnRegistry` per `spawns/0` (scheme allowlist
checked); `TemplateRegistry` per `template_classes/0`;
`AgentFlavorRegistry` per `agent_flavors/0` (§6.3); `RoutingRegistry`
per `routing_tables/0`; `PluginRegistry` self-registration.

**Phase 3 — post-register hook.** The optional `after_boot/0` callback
for work that must run once the plugin is fully published (e.g. the
existing cc-plugin pattern of re-running `Workspace.Loader.load_all/0`
so templates registered late still instantiate).

`boot/1` returns the Phase-1 supervisor's `{:ok, pid}` so OTP
application semantics are preserved.

## 6. Config surface + agent-flavor discovery

### 6.1 `config_surface/0` — what the `/plugins` config icon opens

- **`:route`** — the plugin owns a config LiveView. Feishu:
  `%{kind: :route, path: "/plugins/feishu/bindings", label: "Bindings"}`.
- **`:flavor`** — an agent-flavor plugin; the config icon routes to
  that flavor's agent surface. **§8 Q1** (Allen to confirm): the
  target is `/identities?filter=agent:<flavor>` (manage that flavor's
  agents) — OR an agent-creation entry. SPEC default: the filtered
  identities view.
- **`nil`** — no config surface.
- **`:form` is NOT in V1** (codex MEDIUM-6). It would auto-render
  settings + persist to a plugin-settings store that does not exist.
  The validator REJECTS a `:form` config_surface with a clear
  "plugin settings store is V2" `CompileError`. When a plugin first
  genuinely needs runtime settings, `:form` + the store + its
  authorization model + tests ship together in one PR.

### 6.2 `plugins_live` rendered from the registry

`plugins_live` enumerates `PluginRegistry`, renders one unified
`plugin_card` component (Allen #1) per plugin from `plugin_info/0`,
config icon wired from `config_surface/0`. The hardcoded
`pretty_name`/`pretty_desc`/`primary_link` in core UI are deleted.

### 6.3 `Ezagent.AgentFlavorRegistry` — declarative flavor→kind (codex MEDIUM-5)

Today the agent spawn resolver in `ezagent_domain_instance_message` has a
hardcoded flavor→{kind, template_class} map — that is why "add a 6th
agent-flavor plugin" actually requires editing a non-plugin file. rev
2 adds `Ezagent.AgentFlavorRegistry` (ETS); each agent plugin declares
`agent_flavors/0`; `boot/1` registers it; the domain_instance_message resolver is
migrated to consult the registry instead of its hardcoded map. After
this a new agent-flavor plugin truly touches only its own dir.

## 7. PR sequence

| PR | Scope |
|----|-------|
| 1 | `Ezagent.Plugin` behaviour + `use` macro (plugin-local `@after_compile`) + `Ezagent.PluginRegistry` + `Ezagent.AgentFlavorRegistry` + `Ezagent.Plugin.boot/1` (two-phase) + the `:ezagent_plugin_check` Mix compiler + `plugin_contract_test.exs`. Unit-tested with a fixture plugin AND a deliberately-broken fixture that must fail the gate. |
| 2 | Migrate echo + curl_agent to `use Ezagent.Plugin`; `start/2` → `boot/1`; declare `agent_flavors/0`. **Acceptance tests use the real echo/curl startup paths**, not only fixtures (codex next-step). |
| 3 | Migrate cc + feishu + liveview. Migrate the domain_instance_message agent resolver onto `AgentFlavorRegistry`. |
| 4 | `plugin_card` component + `plugins_live` rendered from `PluginRegistry` + `config_surface/0`; delete hardcoded `pretty_name`/`pretty_desc`/`primary_link`. Rewrite `docs/onboarding/adding-a-plugin.md` (its current Slack example uses a `slack://` scheme — the exact §5.8-forbidden pattern — and must be rewritten). |

Additive: PR-1 ships the contract; the `:ezagent_plugin_check` compiler
is added to a plugin app's `mix.exs` only in the PR that migrates that
app, so un-migrated plugins keep building until their turn.

## 8. Open questions for Allen

- **Q1** — agent-plugin `:flavor` config target: filtered agents view
  (`/identities?filter=agent:<flavor>`) vs an agent-creation entry.
  SPEC default: filtered view. Allen to confirm.
- **Q3** — is the plugin-contract module the OTP `Application` module,
  or separate (`EzagentPluginCc` vs `EzagentPluginCc.Application`)?
  SPEC default: separate — Application is OTP plumbing, the plugin
  module is the contract, `boot/1` bridges. Allen to confirm.

(Q2 enforcement-strictness + Q4 `:form` from rev 1 are now resolved by
the codex review — §3.2 app-level gate + §6.1 `:form`-is-V2.)

## 9. Verification

1. A module that `use Ezagent.Plugin` but omits `plugin_info/0` →
   **compile error**.
2. An `ezagent_plugin_*` app with NO plugin module, or whose plugin
   module skips `use Ezagent.Plugin`, or that still calls a `*Registry`
   directly → **build fails** at the `:ezagent_plugin_check` compiler
   (the non-bypassable gate — codex HIGH-1).
3. A plugin declaring a `spawns/0` scheme outside the 6 core schemes →
   build fails (codex HIGH-4).
4. A plugin declaring a non-existent / non-conforming kind module →
   build fails at the app-level gate, NOT compile-order-dependently
   (codex HIGH-3).
5. `boot/1` starts the plugin supervisor BEFORE publishing registry
   entries; a test spawns through a plugin scheme during simulated
   OTP-startup ordering and it does not fail (codex HIGH-2).
6. All 5 existing plugins migrated; each `start/2` is one line; no
   plugin calls a `*Registry` directly; migration tests exercise the
   real echo/curl/cc startup paths.
7. `AgentFlavorRegistry` drives the domain_instance_message resolver — a 6th
   agent-flavor plugin spawns through `entity://agent/<ws>/<flavor>_<n>`
   with ZERO non-plugin file edited.
8. `/plugins` renders entirely from `PluginRegistry` — `grep` finds no
   per-slug `pretty_name`/`pretty_desc` in core UI.
9. `ezagent_core` has zero compile-time reference to any
   `ezagent_plugin_*` module (the isolation invariant holds).
10. `docs/onboarding/adding-a-plugin.md` rewritten — no `slack://`
    plugin-owned-scheme example.
