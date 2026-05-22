defmodule EzagentPluginEcho.Application do
  @moduledoc """
  Echo plugin OTP application — the `Ezagent.Plugin` contract module.

  ## Plugin authoring contract (PR-2)

  Per the plugin authoring contract SPEC
  (`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`,
  §3 / §8 Q3 — Allen confirmed: the OTP `Application` module IS the
  plugin contract module) this module `use`s **both** `Application`
  (OTP plumbing) and `Ezagent.Plugin` (the declarative contract).

  Registration is no longer imperative. `start/2` collapses to
  `Ezagent.Plugin.boot(__MODULE__)`; the framework's two-phase
  `boot/1` reads the declaration callbacks below and performs every
  `*Registry` call — the plugin author never touches a registry API
  (the plugin-isolation north star, made structural). The
  `:ezagent_plugin_check` Mix compiler (wired into `mix.exs`) is the
  non-bypassable gate that enforces this.

  ## What this plugin declares

  - `behaviors/0` — `{Ezagent.Entity.Echo, :say|:receive}` →
    `Ezagent.Behavior.Echo`. `:say` is the historical
    programmatic-invoke action (Phase 1 contract); `:receive` is the
    chat fan-out hook (Session's `chat.send` dispatches `chat.receive`
    to every Echo agent in members — without it the echo agent
    silently drops chat messages, the regression Allen flagged
    2026-05-20).
  - `template_classes/0` — the `echo.agent` Template Class, so
    operators can create echo agents (optionally with a `/bin/bash -i`
    PTY sidecar) via the standard add-template chain.
  - `agent_flavors/0` — flavor `"echo"` → `{Ezagent.Entity.Echo,
    Ezagent.PluginEcho.Template.EchoAgent}`. Consumed by
    `Ezagent.AgentFlavorRegistry`; PR-3 migrates the domain_chat agent
    resolver onto it, replacing the hardcoded `kind_module_from_flavor`
    map.
  - `config_surface/0` — `:flavor` surface. The `/plugins` config icon
    routes to this flavor's agent surface (SPEC §6.1).
  - `children/0` — a per-Kind `DynamicSupervisor`. Kept for future
    per-plugin-supervisor migrations; echo Kinds currently land under
    `EzagentDomainChat.AgentSupervisor` (chat's flavor-prefix resolver
    routes them there — see `Ezagent.Entity.Echo.supervisor/0`).

  ## PR-M (Allen 2026-05-20) — standardized creation

  Echo's default instance is NOT spawned here. The chat plugin (last
  app to boot) calls `EzagentPluginEcho.Application.default_uri/0` +
  `Ezagent.SpawnRegistry.spawn/1` post-boot via
  `EzagentDomainChat.Application.ensure_echo_default/0`, so the spawn
  goes through the standard `entity://` resolver path. Echo has no
  post-registration work of its own, so `after_boot/0` keeps the
  `use Ezagent.Plugin` default `:ok`.
  """

  use Application
  use Ezagent.Plugin

  # PR #141 (SPEC v2): `agent://` scheme deleted; merged into `entity://`.
  # Agent flavor moves to free-form name prefix (SPEC §5.14):
  # Echo's default instance is `entity://agent/default/echo_default`.
  @default_uri URI.parse("entity://agent/default/echo_default")

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "echo",
      name: "Echo",
      description: "Test stub — echoes back messages.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    [
      {Ezagent.Entity.Echo, :say, Ezagent.Behavior.Echo},
      {Ezagent.Entity.Echo, :receive, Ezagent.Behavior.Echo}
    ]
  end

  @impl Ezagent.Plugin
  def template_classes, do: [Ezagent.PluginEcho.Template.EchoAgent]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "echo",
        kind: Ezagent.Entity.Echo,
        template_class: Ezagent.PluginEcho.Template.EchoAgent
      }
    ]
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :flavor, flavor: "echo", label: "Echo Agents"}
  end

  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor, name: EzagentPluginEcho.InstanceSupervisor, strategy: :one_for_one}
    ]
  end

  # --- public API -----------------------------------------------------

  @doc """
  URI of the default Echo instance — spawned post-boot by the chat
  plugin (PR-M, see moduledoc) via
  `EzagentDomainChat.Application.ensure_echo_default/0`.
  """
  def default_uri, do: @default_uri
end
