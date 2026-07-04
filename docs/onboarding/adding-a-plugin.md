# Adding a plugin to Ezagent

This walks you through writing a new plugin from scratch — concretely, a hypothetical **Slack adapter** (`ezagent_plugin_slack`). The same shape applies to any IM adapter (Discord, Telegram, etc.) or any plugin that adds new Kinds + Behaviors.

## What is a plugin in Ezagent?

A plugin is an OTP application under `apps/ezagent_plugin_<name>/` that:

1. Depends on `:ezagent_core` (and optionally domain apps like `:ezagent_domain_instance_message`).
2. Ships a **plugin module** that `use Ezagent.Plugin` and **declares** what it contributes — Behaviors, spawn fns, Template Classes, agent flavors, routing tables, a config surface.
3. Optionally ships its own Kinds, Behaviors, Template Classes.

Ezagent core never references any plugin module. This is the **plugin isolation north star** — adding a plugin doesn't recompile core; removing one doesn't break others.

## The contract — `Ezagent.Plugin`

Plugins follow a **declarative** contract (`apps/ezagent_core/lib/ezagent/plugin.ex`). You do **not** hand-write registry calls. You `use Ezagent.Plugin` and implement callbacks; the framework's `Ezagent.Plugin.boot/1` reads your declarations and does the registration for you. The plugin author writes declarations, never touches a `*Registry` API.

The contract is **enforced**, not prose:

- **`use Ezagent.Plugin`** injects `@behaviour Ezagent.Plugin`, `defoverridable` defaults for every optional callback, and an `@after_compile` that validates your `plugin_info/0` is implemented and well-formed. Omit it → **compile error**.
- The **`:ezagent_plugin_check` Mix compiler** (added to your `mix.exs` `compilers:` list) is the non-bypassable app-level gate. It verifies your app declares a plugin module, that module `use`s `Ezagent.Plugin`, every declared kind/behavior/template module exists and conforms, every `spawns/0` scheme is one of the six core schemes, and that the app does **not** call a `*Registry` directly. A non-conforming plugin app **fails to build**.

The callbacks:

| Callback | Required? | Declares |
|---|---|---|
| `plugin_info/0` | **yes** | `%{slug, name, description, version}` — identity metadata |
| `kinds/0` | no | `[module()]` — Kind modules the plugin ships |
| `behaviors/0` | no | `[{kind, action, behavior}]` — Behaviors to register on existing core Kinds |
| `spawns/0` | no | `[{scheme, spawn_fun}]` — spawn fns (`scheme` must be one of the six core schemes) |
| `template_classes/0` | no | `[module()]` — Template Classes |
| `agent_flavors/0` | no | `[%{flavor, kind, template_class}]` — agent-flavor → Kind mapping |
| `routing_tables/0` | no | `[{table_name, opts}]` — routing tables |
| `config_surface/0` | no | `:route` / `:flavor` / `nil` — what the `/plugins` config icon opens |
| `children/0` | no | `[child_spec]` — the plugin's supervision children |
| `after_boot/0` | no | post-register hook |

Only `plugin_info/0` is mandatory; every other callback has a default from `use Ezagent.Plugin`.

## Concrete walkthrough — `ezagent_plugin_slack`

### Step 1 — scaffold the OTP app

From repo root:

```bash
cd apps
mix new ezagent_plugin_slack --module EzagentPluginSlack --sup
```

The `--sup` flag generates a supervision tree (`EzagentPluginSlack.Application`).

### Step 2 — declare dependencies and the plugin-check gate

In `apps/ezagent_plugin_slack/mix.exs`:

```elixir
def project do
  [
    # ... standard umbrella keys ...
    # The non-bypassable app-level gate (SPEC §3.2). Add it to every
    # ezagent_plugin_* app's compilers list.
    compilers: Mix.compilers() ++ [:ezagent_plugin_check]
  ]
end

defp deps do
  [
    {:ezagent_core, in_umbrella: true},
    {:ezagent_domain_instance_message, in_umbrella: true},
    {:slack_sdk, "~> 0.5"}   # hypothetical
  ]
end

def application do
  [
    mod: {EzagentPluginSlack.Application, []},
    # The gate reads this key to find your plugin module. Here the
    # Application module IS the plugin module (it `use`s both
    # `Application` and `Ezagent.Plugin`).
    env: [ezagent_plugin: EzagentPluginSlack.Application]
  ]
end
```

### Step 3 — model the integration as a Behavior on an existing core Kind

**A plugin does NOT own a top-level URI scheme.** There are exactly six schemes — `entity, session, template, resource, workspace, system` — and a plugin may never add a seventh (SPEC §5.8; the old `feishu://` scheme was deleted for exactly this reason). When you think "I need a `slack://` scheme", you are actually describing a **Behavior on an existing core Kind**.

A Slack channel is, conceptually, a per-room outbound surface. The core `Ezagent.Entity.Session` Kind already owns the per-room scope. So: model "send this message to Slack" as a Behavior registered on the **Session** Kind for a generic `:notify_external` action — exactly what the Feishu plugin does (`apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/feishu_outbound.ex`). The Slack channel ID is stored as metadata (a side binding table), not encoded into a new URI scheme.

Create `apps/ezagent_plugin_slack/lib/ezagent/behavior/slack_outbound.ex`:

```elixir
defmodule EzagentPluginSlack.Behavior.SlackOutbound do
  @moduledoc """
  Outbound to Slack. Registered on the existing `Ezagent.Entity.Session`
  core Kind — NOT a `slack://` scheme. The Slack channel ID is looked
  up from a per-session binding, not encoded in a URI.
  """
  @behaviour Ezagent.ActionSet

  @actions [:notify_external]
  def actions, do: @actions

  @impl Ezagent.ActionSet
  def state_slice, do: :slack

  @impl Ezagent.ActionSet
  def init_slice(_args), do: %{}

  @impl Ezagent.ActionSet
  def interface do
    %{notify_external: %{args: %{message: :map}, returns: %{}, modes: [:cast]}}
  end

  @impl Ezagent.ActionSet
  def invoke(:notify_external, slice, %{message: msg}, ctx) do
    # ctx.self_uri is a session:// URI — resolve the bound Slack channel.
    case EzagentPluginSlack.Bindings.channel_for(ctx.self_uri) do
      {:ok, channel_id} -> EzagentPluginSlack.Client.send_message(channel_id, body_text(msg))
      :error -> :ok   # session not bound to Slack — no-op
    end

    {:ok, slice}
  end

  defp body_text(%{body: %{text: t}}), do: t
  defp body_text(_), do: ""
end
```

### Step 4 — write the plugin module (declare, don't call)

This is the heart of the contract. Edit `apps/ezagent_plugin_slack/lib/ezagent_plugin_slack/application.ex`:

```elixir
defmodule EzagentPluginSlack.Application do
  @moduledoc "Slack adapter plugin — `use Ezagent.Plugin` contract."
  use Application
  use Ezagent.Plugin

  alias Ezagent.Entity.Session, as: SessionKind
  alias EzagentPluginSlack.Behavior.SlackOutbound

  # --- OTP Application: start/2 is ONE line ---------------------------
  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract — declarations only -------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "slack",
      name: "Slack",
      description: "Slack integration (outbound bot + inbound events).",
      version: "0.1.0"
    }
  end

  # Behaviors register on the EXISTING Session core Kind — no new
  # scheme. boot/1 translates each tuple into BehaviorRegistry.register/3.
  @impl Ezagent.Plugin
  def behaviors do
    for action <- SlackOutbound.actions(), do: {SessionKind, action, SlackOutbound}
  end

  # The /plugins config icon opens this plugin's own config LiveView.
  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :route, path: "/plugins/slack/bindings", label: "Bindings"}
  end

  # The plugin's supervision children. boot/1 starts these in Phase 1,
  # BEFORE publishing anything — so a behavior/spawn fn can never run
  # against a not-yet-started supervisor.
  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor, name: EzagentPluginSlack.ChatSupervisor, strategy: :one_for_one},
      EzagentPluginSlack.Client
    ]
  end
end
```

Notice what is **absent**: no `Ezagent.BehaviorRegistry.register/3` call, no `SpawnRegistry.register/2`, no `Supervisor.start_link` in `start/2`. You declared `behaviors/0` + `children/0`; `Ezagent.Plugin.boot/1` does the rest. `start/2` is one line. (Calling a `*Registry` directly is in fact rejected by the `:ezagent_plugin_check` gate.)

`boot/1` is two-phase: **Phase 1** starts `children/0` first; **Phase 2** publishes every declaration (behaviors, spawns, template classes, agent flavors, routing tables, plus self-registration into `Ezagent.PluginRegistry`); **Phase 3** runs the optional `after_boot/0` hook.

### Step 5 — set up routing

When Ezagent receives a message in a session and you want it forwarded to Slack, the `notify_external` Behavior fires opportunistically after chat fan-out (the same hook Feishu uses) — so for the common case you just bind a session to a Slack channel and there is nothing more to wire.

If you need an explicit routing rule, declare a routing table via `routing_tables/0` and add rules through the `/admin/routing` form or `mix ezagent.routing.add_rule`. Always pass `workspace_uri:` if the rule should be workspace-scoped (invariant 4 — see the `ezagent-developer` skill).

### Step 6 — handle inbound (if Slack → Ezagent is in scope)

For Slack → Ezagent (user types in Slack, Ezagent receives), you need:

1. An inbound transport (HTTP webhook or WS sidecar — see `EzagentPluginFeishu`'s WS client) listed in your `children/0`.
2. An inbound dispatcher that resolves the Slack sender → an Ezagent user URI and dispatches `Chat.send` to the **User** core Kind — again no new scheme; the Slack identity is stored as metadata on a binding table.

**Critical** (Decision #134): use `mode: :call` not `:cast` so cap denial returns synchronously, and your handler sends an error message back to the Slack channel + a reaction emoji. Silent drop on cap denial is the bug `feedback_explicit_stop_signal_after_feishu` was created to prevent.

Reference implementation: `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/inbound_dispatcher.ex`.

### Step 7 — the config surface

`config_surface/0` declares what the config icon on the plugin's `/plugins` card opens. V1 has three forms:

- **`:route`** — `%{kind: :route, path: "/plugins/slack/bindings", label: "Bindings"}`. The plugin owns a config LiveView; the icon links to it. (Add the route in `apps/ezagent_web/lib/ezagent_web/router.ex`.)
- **`:flavor`** — `%{kind: :flavor, flavor: "slack", label: "Slack Agents"}`. For agent-flavor plugins; the icon links to `/identities?filter=agent:<flavor>` (manage that flavor's agents).
- **`nil`** — the `use Ezagent.Plugin` default; no config surface.

`:form` (auto-rendered, persisted settings) is **not** in V1 — the validator rejects it until the plugin-settings store ships.

`/plugins` itself is 100% registry-driven: it enumerates `Ezagent.PluginRegistry` and renders one `<.plugin_card>` per plugin from your `plugin_info/0` + `config_surface/0`. There is **no** per-plugin code in the `/plugins` page — declaring your `plugin_info/0` is what makes your plugin appear.

### Step 8 — install + test

If the plugin compiles (the `:ezagent_plugin_check` gate passes), install it into a running Ezagent (no phx restart):

```bash
mix ezagent.plugin.install /path/to/ezagent/apps/ezagent_plugin_slack
```

You should see your plugin appear on `/plugins` as a card, and a Slack outbound dispatch fire when a message routes to a Slack-bound session.

## Common gotchas

### Gotcha: forgetting `use Ezagent.Plugin` or the `:ezagent_plugin_check` compiler

The plugin module **must** `use Ezagent.Plugin`, and the app's `mix.exs` **must** add `:ezagent_plugin_check` to `compilers:` and name the plugin module in the `application/0` `env: [ezagent_plugin: ...]` key. Skip either and the build fails at the gate — that is the contract being enforced, not a bug.

### Gotcha: trying to introduce a new top-level URI scheme

A `spawns/0` declaration whose scheme is not one of `entity, session, template, resource, workspace, system` is rejected — both at `boot/1` and by the gate. Model the integration as a Behavior on an existing core Kind (Step 3). There is no `slack://`.

### Gotcha: `Mix.env()` in `start/2` returns BUILD-time env

`mix ezagent.plugin.install` reads the plugin's compiled `.app` file. `Mix.env()` reflects the env the plugin was COMPILED with, not the host's runtime env. Use `System.get_env("MIX_ENV")` (runtime read) instead, or use `after_boot/0` and avoid env-dependent boot logic.

### Gotcha: side-effects in boot must be idempotent

`children/0` and `after_boot/0` run at install time. If they have side-effects (HTTP calls to set up webhooks, DB seeds), make them idempotent — installing twice should be a no-op.

### Gotcha: TemplateRegistry strict-duplicate

If a Template Class you declare in `template_classes/0` claims a name another plugin already registered, `boot/1` raises with `{:duplicate, ...}`. Pick a unique name (project convention: prefix with your plugin name, e.g. `"slack.channel.standard"`).

### Gotcha: PubSub.broadcast bypass

Tempted to `Phoenix.PubSub.broadcast(EzagentCore.PubSub, "slack:incoming", msg)` from your WS handler? **Refuse this temptation.** That bypasses dispatch + CapBAC + audit. Register a Behavior on the core Session/User Kind and route through `Ezagent.Invocation.dispatch/1` instead.

## Reference plugins to study

- `apps/ezagent_plugin_echo/` — smallest, simplest. Read this first to see the bare `use Ezagent.Plugin` shape.
- `apps/ezagent_plugin_feishu/` — fullest production plugin, and the canonical "external integration" — `FeishuOutbound` registered on the Session Kind, no owned scheme, inbound + outbound + WS sidecar + user binding + react path + cap delegation. The closest model for a Slack adapter.
- `apps/ezagent_plugin_cc/` — non-IM plugin (terminal PTY). Different shape but same plugin contract; shows `agent_flavors/0` + a `:flavor` config surface.

## When you're done

- Run your invariant test (write one — see `docs/onboarding/adding-kind-behavior-template.md` §"How to write an invariant test").
- Run the cross-PR invariants (see `docs/onboarding/first-30-days.md` §week-4), including `plugin_contract_test.exs`.
- SPEC_REVIEW 8-item checklist (per `docs/phase-specs/phase7/SPEC.md` §SPEC_REVIEW walkthrough).
- Open PR with the checklist in the body.

Welcome to the team.
