defmodule EzagentPluginKanban.RelayRouting do
  @moduledoc """
  Phase 3 ② @路由/contract — 把 kanban 接力链经 routing 规则路由到下一棒 agent。

  **零 core 改动 / 零新机制**：纯组合现有 core 公开模块
  `Ezagent.Routing.Matcher` + `Ezagent.Routing.RuleStore`。

  ## 接力链已有的一半（别处已建/已测）

  kanban 的接力动作（`claim_node` / `set_status` / `register_pr`）成功后，
  `Ezagent.Behavior.Kanban.post_handle/4` → `Kanban.Shared.session_dispatch/3`
  往本看板绑定的会话注一条公告消息（`relay_text/2`：`"[kanban:<event>] by <caller>"`），
  并以 `{:dispatch}` effect 重入 `session.send`（已由 `relay_test.exs` 验收）。

  ## 这个 helper 补的另一半（②）

  seed 一条**现有**路由规则，让上面那条公告被 `Ezagent.Routing.Resolver`
  匹配并路由到**下一棒 agent**——这就是「接力链经 routing 真路由到下一棒」的契约。

  规则形状（全部是 core 既有 matcher，无新增）：

      {:and, [in_session(session_uri), text_contains("[kanban:<event>]")]} → [receiver]

  - `in_session/1` 把规则**锁定到一个会话**（某看板的接力只唤醒**那个**会话的下一棒，
    不影响其它会话——见 `Matcher.in_session/1` 文档）。
  - `text_contains/1` 按机器可读的 `[kanban:<event>]` 标记触发（消息只做触发器，
    节点细节由被唤醒的 agent 经 `get_tree` 读真相源）。

  ## ③ pm coordinator 的生产路径

  pm（项目经理 cc 大脑）**生产环境**用 Orchestrator 现有 MCP 工具
  `define_rule_set_rule` 配同样形状的规则（见
  `docs/discuss/2026-06-26-kanban-flow-redesign/phase3-pm-coordinator.md §②`）。
  这个 helper 是**同一条规则的确定性 seed 入口**——供 ② 的 e2e gate 与 ③ 日后
  按需直接调用，避免重复表达规则形状。
  """

  alias Ezagent.Routing.{Matcher, RuleStore}

  # 镜像 `Ezagent.Behavior.Kanban` 的 `@relay_actions` 经 `relay_text/2` 映射出的事件名：
  # :claim_node → "claimed" / :set_status → "status" / :register_pr → "pr_registered"。
  @kanban_events [:claimed, :status, :pr_registered]

  @doc """
  某 kanban 事件的机器可读接力标记（与 `Kanban.relay_text/2` 一致）。

      iex> EzagentPluginKanban.RelayRouting.marker(:pr_registered)
      "[kanban:pr_registered]"
  """
  @spec marker(atom() | String.t()) :: String.t()
  def marker(event) when is_atom(event) or is_binary(event), do: "[kanban:#{event}]"

  @doc """
  接力规则键控的 matcher 元组：在**本会话**内 **且** 携带 `[kanban:<event>]` 标记。

  返回的是 core `Ezagent.Routing.Matcher` 既有元组（`:and` / `:in_session` /
  `:text_contains`）——零新增 matcher 类型。
  """
  @spec relay_matcher(URI.t() | String.t(), atom() | String.t()) :: Matcher.matcher()
  def relay_matcher(session_uri, event) do
    Matcher.all_of([
      Matcher.in_session(session_uri),
      Matcher.text_contains(marker(event))
    ])
  end

  @doc """
  把一条接力路由规则 seed 进 `table`（生产用
  `Ezagent.Routing.Resolver.default_routing_table()`）：当 `session_uri` 内出现
  `[kanban:<event>]` 公告时，路由到 `receiver`（下一棒 agent）。

  纯委托 `RuleStore.add/5`（现有持久化路径）。seed 后调用方需
  `RuleStore.load_into_registry(table)` 把 DB 规则水合进 ETS（Resolver 读 ETS）。

  规则为单接收者，故即便挂在某 `rule_set`（`opts[:rule_set]`）下也满足
  「rule-set 规则必须单接收者」不变式（`RuleStore.add/5` `:rule_set_requires_single_receiver`）。
  """
  @spec wire_relay_rule(
          atom(),
          URI.t() | String.t(),
          atom() | String.t(),
          URI.t() | String.t(),
          URI.t() | nil,
          keyword()
        ) :: {:ok, RuleStore.t()} | {:error, term()}
  def wire_relay_rule(table, session_uri, event, receiver, created_by, opts \\ [])
      when is_atom(table) do
    RuleStore.add(table, relay_matcher(session_uri, event), [receiver], created_by, opts)
  end

  @doc "会触发接力公告的 kanban 事件名（镜像 `Kanban` 的 `@relay_actions`）。"
  @spec kanban_events() :: [atom()]
  def kanban_events, do: @kanban_events

  # ====================================================================
  # ③ relay-BACK（dev→pm 自动接力 = 一条 sender-locked 路由规则）
  # ====================================================================
  #
  # 上面的 `wire_relay_rule` 走的是 **marker** 触发（`text_contains([kanban:<event>])`）
  # ——框架在接力**动作**成功后注入的机器可读公告。但「dev 干完活把产出交回 pm」这一棒
  # 没有框架公告：dev 的 return 是一条**自由文本** chat（经 `session send` 投递），它的
  # `@pm` 是否被 parse 成结构化 mention 不稳定（T11 surface F：dev 节点内发的 @mention
  # 解析为空 → pm 没被唤醒）。
  #
  # 正解 = **sender-locked 路由规则**（与 core E2E Scenario 34「传话游戏」同一已验原语
  # `{:from, X} → Y`）：消息的 **sender 字段由 transport 结构化写入**（不靠正文 parse），
  # 故 `from(dev)` 永远命中——这就是「不靠 @mention parse，靠路由规则」。
  #
  # 关系的方向性 = 配置先行：bind 建立 kanban-flow 会话时，pm（coordinator）+ dev-together
  # （它的 delegate）一起 materialize 进**这个**会话；此刻 wire 一条
  # `from(dev) AND in_session(session) → [pm]` 规则，把 dev 在本会话的任何产出/return
  # 路由回 pm。**人直接找 dev（没经 kanban-flow bind 建立这层关系）→ 没这条规则 → 不接力
  # 回 pm。** 规则是声明式配置，不是 dispatch 代码里的 special-case。

  @doc """
  relay-back matcher：在**本会话**内 **且** sender 是 `from_uri`（下一棒 agent，通常 = dev）。

  返回 core `Ezagent.Routing.Matcher` 既有元组（`:and` / `:in_session` / `:from`）——
  零新增 matcher 类型。`from` 读 `message.sender`（transport 结构化写入），不读正文，
  故不依赖 @mention 文本 parse（这正是相对 marker/mention 路的稳健性来源）。

      iex> m = EzagentPluginKanban.RelayRouting.relay_back_matcher(
      ...>   "session://ws/team-alpha/kbflow", "entity://team-alpha/agent/dev-together-kbflow")
      iex> match?({:and, [{:in_session, _}, {:from, _}]}, m)
      true
  """
  @spec relay_back_matcher(URI.t() | String.t(), URI.t() | String.t()) :: Matcher.matcher()
  def relay_back_matcher(session_uri, from_uri) do
    Matcher.all_of([
      Matcher.in_session(session_uri),
      Matcher.from(from_uri)
    ])
  end

  @doc """
  把一条 **relay-back** 路由规则 seed 进 `table`（生产用
  `Ezagent.Routing.Resolver.default_routing_table()`）：当 `session_uri` 内出现一条
  **sender = `from_uri`**（下一棒 agent / dev）的消息时，路由到 `receiver`（上一棒 /
  coordinator / pm）。

  纯委托 `RuleStore.add/5`（现有持久化路径，零 core 改动）。seed 后调用方需
  `RuleStore.load_into_registry(table)` 把 DB 规则水合进 ETS（Resolver 读 ETS）。

  规则为单接收者，故即便挂在某 `rule_set`（`opts[:rule_set]`）下也满足
  「rule-set 规则必须单接收者」不变式（`RuleStore.add/5` `:rule_set_requires_single_receiver`）。
  """
  @spec wire_relay_back_rule(
          atom(),
          URI.t() | String.t(),
          URI.t() | String.t(),
          URI.t() | String.t(),
          URI.t() | nil,
          keyword()
        ) :: {:ok, RuleStore.t()} | {:error, term()}
  def wire_relay_back_rule(table, session_uri, from_uri, receiver, created_by, opts \\ [])
      when is_atom(table) do
    RuleStore.add(table, relay_back_matcher(session_uri, from_uri), [receiver], created_by, opts)
  end
end
