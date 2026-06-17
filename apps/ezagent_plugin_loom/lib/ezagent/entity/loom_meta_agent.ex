defmodule Ezagent.Entity.LoomMetaAgent do
  @moduledoc """
  Loom 团队管家 Kind(2026-06-01)— 接受用户的 @ 自然语言指令(如"加一个
  painter worker 帮我画背景图""把 painter 删了""列一下当前 worker"),
  调 DeepSeek 解析成结构化 op,然后:

  - `add` → `Ezagent.Kind.spawn(LoomWorker, ...)` + dispatch `chat.join`
  - `remove` → dispatch `chat.leave` + `Ezagent.Kind.terminate(...)`
  - `list` → chat.send 回复当前 worker roster
  - `unknown` → chat.send 把澄清问题发回去

  Behavior 跑在 `Ezagent.Behavior.LoomMetaAgent`,跟 `LoomBuilderWorker` 同样
  mention-gated:不 @ 它就不响应。

  跟 orchestrator 协作不是通过 dispatch action(那需要新 caps + 新
  action),而是**靠 chat.members 的 broadcast** —— orchestrator 的
  `discover_workers/1` 每次 user turn 都重读 chat.members,manager 增删
  worker 后下一次派单自动看到新 roster。

  `entity://agent/<workspace>/loommeta_<sid>` —— flavor `loommeta` 前缀。
  Lives under the chat domain's AgentSupervisor。Persistence 用 ephemeral:
  manager 自己几乎无状态(count 计数器不重要),不需要 snapshot。
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :loommeta

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.LoomMetaAgent]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.AgentSupervisor
end
