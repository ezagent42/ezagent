defmodule Ezagent.Entity.LoomAgent do
  @moduledoc """
  Loom agent Kind —— loom 编排控制器的 Member 实例类型(组合 `Ezagent.Behavior.LoomAgent`)。

  spawn 在 `entity://<ws>/agent/loom<role>_<sid>`,supervisor 用 loom 自己的
  `EzagentPluginLoom.OrchestratorSupervisor`(DynamicSupervisor,无需新依赖)。
  `:ephemeral` —— team 是 per-session 运行时装配,随 session 起落,不持久。

  详见 `Ezagent.Behavior.LoomAgent`。
  """

  use Ezagent.Kind,
    pattern: :entity,
    type_name: :loom_agent,
    supervisor: EzagentPluginLoom.OrchestratorSupervisor

  @behaviour Ezagent.Kind

  attach(Ezagent.Behavior.LoomAgent)

  def behaviors, do: [Ezagent.Behavior.LoomAgent]

  def persistence, do: :ephemeral
end
