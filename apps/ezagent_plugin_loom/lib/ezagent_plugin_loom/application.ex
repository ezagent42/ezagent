defmodule EzagentPluginLoom.Application do
  @moduledoc """
  Loom vertical plugin (socialware substrate).

  The loom vertical = 「多 agent 编排 + AI page-builder」: 访客对话驱动编排器拆解意图、
  fan-out 给主题 worker、聚合出 scene-card,同时 page-worker 实时生成一张页面。

  本 plugin 只贡献 Tier-3 声明 + materialization metadata; 运行时 session 是 domain-owned
  的 **统一** `Ezagent.Entity.Session` Kind,带 socialware `:kind_base` subset
  (`Ezagent.Entity.Session.socialware_behaviors/0` = {Session, Turn, Surface, Publisher})。
  对接 main 现成能力,**不修改 ezagent/socialware**(见
  `docs/loom/2026-06-16-loom-stitch-to-socialware-migration.md` 清单 A)。

  脚手架阶段(任务 1): 只落 `session.loom` Template Class + node/role 声明。agent 团队装配
  (orchestrator/worker/v0)、page-SDK adapter、Stitch 等按迁移文档后续任务推进。
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "loom",
      name: "Loom",
      description: "Socialware loom vertical — multi-agent orchestration + AI page-builder.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def template_classes, do: [EzagentPluginLoom.Template.LoomSession]

  @impl Ezagent.Plugin
  def config_surface, do: nil

  # 务实版 multi-agent wiring：per-session 编排进程的注册表 + 动态 supervisor。
  # loom session 起一个 OrchestratorServer 订阅 session 事件 → 真实 LLM 编排 → Turn。
  @impl Ezagent.Plugin
  def children do
    [
      EzagentPluginLoom.Materials,
      EzagentPluginLoom.Knowledge,
      EzagentPluginLoom.Stats,
      EzagentPluginLoom.UserSchema,
      EzagentPluginLoom.WorkerConfig,
      EzagentPluginLoom.FeishuMirror,
      {Registry, keys: :unique, name: EzagentPluginLoom.OrchestratorRegistry},
      {DynamicSupervisor, name: EzagentPluginLoom.OrchestratorSupervisor, strategy: :one_for_one}
    ]
  end

  # 同 advisor: customer feed + chat feed 两个 BARE `:pull` adapter(socialware 现成),
  # 安装 `allow_customer_feed` / `allow_chat_feed` cap subject,不 spawn Worker。
  @impl Ezagent.Plugin
  def adapters,
    do: [Ezagent.Socialware.CustomerFeedAdapter, Ezagent.Socialware.ChatFeedAdapter]
end
