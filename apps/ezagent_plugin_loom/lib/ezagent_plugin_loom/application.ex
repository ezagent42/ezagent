defmodule EzagentPluginLoom.Application do
  @moduledoc """
  Loom plugin OTP application — the `Ezagent.Plugin` contract module.

  Loom is a fixed-reply test bot flavor: every `loom_*` agent always
  answers "你好！我是测试机器人！". Modeled on the Echo plugin, minus the
  PTY opt-in.

  ## Plugin authoring contract

  Per the plugin authoring contract SPEC
  (`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`)
  this module `use`s **both** `Application` (OTP plumbing) and
  `Ezagent.Plugin` (the declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot/1`; the framework's two-phase boot reads the
  declaration callbacks below and performs every `*Registry` call — the
  plugin author never touches a registry API. The `:ezagent_plugin_check`
  Mix compiler (wired into `mix.exs`) is the non-bypassable gate.

  ## What this plugin declares

  - `behaviors/0` — `{Ezagent.Entity.Loom, :say|:receive}` →
    `Ezagent.Behavior.Loom`. `:say` is the programmatic-invoke action;
    `:receive` is the chat fan-out hook (without it the Loom agent
    silently drops chat messages).
  - `template_classes/0` — the `loom.agent` Template Class (minimal,
    pure-spawn; exists to satisfy the flavor declaration + gate).
  - `agent_flavors/0` — flavor `"loom"` → `{Ezagent.Entity.Loom,
    Ezagent.PluginLoom.Template.LoomAgent}`. Consumed by
    `Ezagent.AgentFlavorRegistry` so the New-agent form + `entity://`
    SpawnRegistry resolver map the `loom` prefix to this Kind.
  - `config_surface/0` — `:flavor` surface for the `/plugins` page.

  ## Default instance seeding — `after_boot/0`

  The default instance `entity://agent/system/loom_agent` is spawned in
  Phase 3 (`after_boot/0`), AFTER Phase-2 `publish/1` registered
  `agent_flavors/0` so the resolver can map the flavor. This plugin's
  dep on `ezagent_domain_chat` makes OTP boot chat first, so the
  `entity://` SpawnRegistry dispatcher is published by the time this
  runs. Idempotent: re-spawning an already-alive Kind is a no-op.
  """

  use Application
  use Ezagent.Plugin

  @default_uri URI.parse("entity://agent/system/loom_agent")

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "loom",
      name: "Loom",
      description: "Fixed-reply test bot — always answers 你好！我是测试机器人！",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    [
      {Ezagent.Entity.Loom, :say, Ezagent.Behavior.Loom},
      {Ezagent.Entity.Loom, :receive, Ezagent.Behavior.Loom},
      # loom v0.2 G-E — worker agent: chat fan-out hook that produces a
      # DeepSeek content fragment for an orchestrator subtask.
      {Ezagent.Entity.LoomWorker, :receive, Ezagent.Behavior.LoomWorker},
      # loom v0.2 G-D — orchestrator agent: decompose → fan out →
      # aggregate → compose, all on the session's chat fan-out hook.
      {Ezagent.Entity.LoomOrchestrator, :receive, Ezagent.Behavior.LoomOrchestrator}
    ]
  end

  @impl Ezagent.Plugin
  def template_classes,
    do: [
      Ezagent.PluginLoom.Template.LoomAgent,
      Ezagent.PluginLoom.Template.LoomWorker,
      Ezagent.PluginLoom.Template.LoomOrchestrator,
      # Session template: "create a loom session" auto-assembles the team
      # (orchestrator + 2 workers) instead of a bare session.
      Ezagent.PluginLoom.Template.LoomSession
    ]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "loom",
        kind: Ezagent.Entity.Loom,
        template_class: Ezagent.PluginLoom.Template.LoomAgent
      },
      # loom v0.2 G-E — `entity://agent/<ws>/loomworker_<name>`.
      %{
        flavor: "loomworker",
        kind: Ezagent.Entity.LoomWorker,
        template_class: Ezagent.PluginLoom.Template.LoomWorker
      },
      # loom v0.2 G-D — `entity://agent/<ws>/loomorch_<name>`.
      %{
        flavor: "loomorch",
        kind: Ezagent.Entity.LoomOrchestrator,
        template_class: Ezagent.PluginLoom.Template.LoomOrchestrator
      }
    ]
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :flavor, flavor: "loom", label: "Loom Agents"}
  end

  @doc """
  Phase 3 post-register hook — seed the default Loom agent.

  `Ezagent.Plugin.boot/1` calls this AFTER Phase-2 `publish/1` has
  registered `agent_flavors/0`, so `Ezagent.AgentFlavorRegistry` maps
  the `"loom"` flavor → `Ezagent.Entity.Loom`. Idempotent. A genuine
  failure is logged, not raised — `after_boot/0` must not abort boot.
  """
  @impl Ezagent.Plugin
  def after_boot do
    case Ezagent.SpawnRegistry.spawn(@default_uri) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "EzagentPluginLoom.after_boot/0: default loom agent spawn failed (#{inspect(reason)})"
        )

        :ok
    end
  end

  @doc "URI of the default Loom instance — seeded by `after_boot/0`."
  def default_uri, do: @default_uri
end
