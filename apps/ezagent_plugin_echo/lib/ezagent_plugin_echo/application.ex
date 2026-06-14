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
    `Ezagent.AgentFlavorRegistry`; PR-3 migrates the domain_instance_message agent
    resolver onto it, replacing the hardcoded `kind_module_from_flavor`
    map.
  - `config_surface/0` — `:flavor` surface. The `/plugins` config icon
    routes to this flavor's agent surface (SPEC §6.1).
  - `children/0` — a per-Kind `DynamicSupervisor`. Kept for future
    per-plugin-supervisor migrations; echo Kinds currently land under
    `EzagentDomainInstanceMessage.AgentSupervisor` (chat's flavor-prefix resolver
    routes them there — see `Ezagent.Entity.Echo.supervisor/0`).

  ## Default echo agent seeding — `after_boot/0` (PR-5 codex HIGH-2)

  Echo's default instance is spawned in this plugin's `after_boot/0`
  (Phase 3 of `Ezagent.Plugin.boot/1`). It was previously seeded from
  `EzagentDomainInstanceMessage.Application.start/2`, but that was a boot-order
  race: chat's seed needs `Ezagent.AgentFlavorRegistry.lookup("echo")`
  — published by THIS plugin's `boot/1` — and `ezagent_domain_session`
  does not depend on `ezagent_plugin_echo`, so the seed could fire
  before echo's `agent_flavors/0` was registered and fail with
  `{:no_kind_module_for_agent, ...}`, never retried.

  `after_boot/0` runs in Phase 3 — AFTER this plugin's Phase-2
  `publish/1` registered `agent_flavors/0`, so the resolver can map
  the flavor. This plugin declares a dep on `ezagent_domain_session` (a
  pure boot-order constraint — no chat code is referenced), so OTP
  boots chat first and the `entity://` `SpawnRegistry` dispatcher is
  published by the time `after_boot/0` runs. The spawn therefore goes
  through the standard `entity://` resolver path.
  """

  use Application
  use Ezagent.Plugin

  # PR #141 (SPEC v2): `agent://` scheme deleted; merged into `entity://`.
  # Agent flavor moves to free-form name prefix (SPEC §5.14):
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

  @doc """
  Phase 3 post-register hook — seed the default Echo agent (PR-5
  codex HIGH-2).

  `Ezagent.Plugin.boot/1` calls this AFTER Phase-2 `publish/1` has
  registered `agent_flavors/0`, so `Ezagent.AgentFlavorRegistry`
  already maps the `"echo"` flavor → `Ezagent.Entity.Echo`. The seed
  spawns through `Ezagent.SpawnRegistry.spawn/1` — the standard
  `entity://` resolver path — and this plugin's dep on
  `ezagent_domain_session` guarantees the `entity://` dispatcher is
  published before this runs.

  Idempotent: `SpawnRegistry.spawn/1` returns the existing pid for an
  already-alive Kind (snapshot rehydration), and treats
  `{:already_started, _}` as `{:ok, _}`. A genuine failure is logged,
  not raised — `after_boot/0` must not abort the plugin's boot — but
  with the dep + Phase ordering above this path is no longer racy.
  """
  @impl Ezagent.Plugin
  def after_boot do
    default_uri = default_uri()
    :ok = Ezagent.AgentFlavorAttributes.put(default_uri, "echo")

    with {:ok, _pid} <- Ezagent.SpawnRegistry.spawn(default_uri) do
      :ok
    else
      {:error, reason} ->
        require Logger

        Logger.warning(
          "EzagentPluginEcho.after_boot/0: default echo agent spawn failed " <>
            "(#{inspect(reason)}); F1 echo round-trip tests will fail until the " <>
            "default echo agent is available"
        )

        :ok
    end
  end

  # --- public API -----------------------------------------------------

  @doc """
  URI of the default Echo instance — seeded by `after_boot/0`
  (PR-5 codex HIGH-2, see moduledoc).
  """
  def default_uri, do: Ezagent.URI.agent(:system, :echo_default)
end
