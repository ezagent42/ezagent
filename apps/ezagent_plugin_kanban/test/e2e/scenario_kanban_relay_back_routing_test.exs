defmodule EzagentPluginKanban.E2E.KanbanRelayBackRoutingTest do
  @moduledoc """
  Phase 3 ③ T12 — **dev→pm 自动接力 = 一条 sender-locked 路由规则（配置优先）**。

  这是 T12 的 DoD 验收 gate：证明「dev-together 在会话发 return → 经 routing 规则自动
  路由回 pm（不靠 @mention parse，靠 sender-locked 规则）」。**零 core 改动**——全程
  组合现有原语（与 core E2E Scenario 34「传话游戏」`{:from,X}→Y` 同一已验机制）：

    1. **真规则持久化**：`EzagentPluginKanban.RelayRouting.wire_relay_back_rule/6` →
       `Ezagent.Routing.RuleStore.add/5`（SQLite）+ `load_into_registry/1` 水合进 ETS。
       规则 = `from(dev) AND in_session(session) → [pm]`。
    2. **真路由判定**：`Ezagent.Routing.Resolver.resolve/4`（`Behavior.Session.handle_send`
       内部驱动的同一个 `Resolver`）对一条 **sender = dev** 的会话消息求解收件人，断言
       **pm 被解析为收件人**（= dev 的 return 自动接力回 pm）。

  ## 为什么是 sender-locked（`from`），不是 @mention / marker

  消息的 `sender` 字段由 transport **结构化写入**（不读正文）。T11 surface F 的根因正是
  dev 节点内 `session send` 发出的 `@pm` **没 parse 成结构化 mention** → pm 没被唤醒。
  `from(dev)` 规则不看正文，故 dev 的 return 无论 `@pm` 文本是否 parse 都稳定命中 pm
  ——这就是「不靠 @mention parse，靠路由规则」。

  ## 「人直接找 dev → 不接力回 pm」怎么证

  relay-back 是**关系建立时 wire 的声明式规则**（bind 建立 kanban-flow 会话时，pm+dev
  一起 materialize，pm 是 coordinator、dev 是它的 delegate）。人直接找 dev（没经 bind
  建立这层关系）→ **没这条规则** → dev 的产出不路由回 pm。两条对照测试坐实：① 规则在 →
  dev return 解析含 pm；② 规则不在 → 不含 pm（证明是规则在起作用，不是硬编码 special-case）。
  另加 sender-lock 对照：规则在、但消息**不是 dev 发的**（人发的）→ 也不路由到 pm
  （`from(dev)` 只锁 dev 自己的产出）。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, RoutingRegistry}
  alias Ezagent.Routing.{Resolver, RuleStore}
  alias EzagentPluginKanban.RelayRouting

  @workspace URI.new!("workspace://relayback-ws")

  setup do
    n = System.unique_integer([:positive])

    session = URI.new!("session://relayback-ws/default/kbflow-#{n}")
    other_session = URI.new!("session://relayback-ws/default/other-#{n}")

    # pm（coordinator / 上一棒）+ dev（delegate / 下一棒）。本路由测试只需它们的 URI
    # （路由规则引用 URI，不调它们），不依赖任何 live agent。
    pm = Ezagent.URI.agent("relayback-ws", "pm-coordinator-kbflow-#{n}")
    dev = Ezagent.URI.agent("relayback-ws", "dev-together-kbflow-#{n}")
    alice = URI.new!("entity://relayback-ws/user/alice")

    # 每测试一张独立 routing 表 + 覆盖 routing_tables（ETS 全局，故隔离）——
    # 与 scenario_kanban_relay_routing_test / scenario_34 同范式。
    table = :"kanban_relay_back_#{n}"
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    original = Application.get_env(:ezagent_core, :routing_tables)
    Application.put_env(:ezagent_core, :routing_tables, [table])

    on_exit(fn ->
      if original do
        Application.put_env(:ezagent_core, :routing_tables, original)
      else
        Application.delete_env(:ezagent_core, :routing_tables)
      end
    end)

    %{
      session: session,
      other_session: other_session,
      pm: pm,
      dev: dev,
      alice: alice,
      table: table
    }
  end

  # 复刻 handle_send 的 Plan B：用带 session_uri 的消息喂 Resolver（in_session matcher
  # 才能命中）。生产里这一步由 MessageStore.write 盖章 stored_msg。
  defp stamp(%Message{} = msg, %URI{} = session), do: %{msg | session_uri: session}

  defp from_msg(sender, session) do
    Message.new(sender, %{text: "done — design 短文已产出，交回 coordinator", attachments: []},
      mentions: []
    )
    |> stamp(session)
  end

  defp resolve_recipients(msg, session) do
    Resolver.resolve(msg, session, [], workspace_uri: @workspace)
    |> Enum.map(&URI.to_string/1)
  end

  describe "③ dev→pm relay-back 经 sender-locked routing 规则" do
    test "dev 在会话发 return → 经 from(dev)+in_session 规则路由回 pm",
         %{session: session, pm: pm, dev: dev, alice: alice, table: table} do
      # wire relay-back 规则：from(dev) AND in_session(S) → [pm]
      assert {:ok, _rule} = RelayRouting.wire_relay_back_rule(table, session, dev, pm, alice)
      :ok = RuleStore.load_into_registry(table)

      # dev 发一条 return（sender = dev，本会话）—— 正文里**没有** @pm 结构化 mention，
      # 路由完全靠 sender-locked 规则（这正是稳健于 surface F 的点）。
      dev_return = from_msg(dev, session)
      assert dev_return.mentions == []

      recipients = resolve_recipients(dev_return, session)

      assert URI.to_string(pm) in recipients,
             "dev 的 return 必须经 relay-back 规则自动路由回 pm #{URI.to_string(pm)}；" <>
               "实得 recipients=#{inspect(recipients)}"
    end

    test "对照①（无规则）：dev 的 return 不路由到 pm（证明是规则在起作用，非硬编码）",
         %{session: session, pm: pm, dev: dev, table: table} do
      # 不 wire 任何 relay-back 规则（人直接找 dev 的会话 = 没建立 pm↔dev relay 关系）。
      # setup 的 table 此刻是空的（本测试没 wire），故 resolve 无收件人。
      :ok = RuleStore.load_into_registry(table)

      dev_return = from_msg(dev, session)
      recipients = resolve_recipients(dev_return, session)

      refute URI.to_string(pm) in recipients,
             "没 wire relay-back 规则时 dev 的 return 不得路由到 pm（接力是规则建立的，不是硬编码）"
    end

    test "对照②（sender-lock）：规则在，但消息是**人**发的（非 dev）→ 不路由到 pm",
         %{session: session, pm: pm, dev: dev, alice: alice, table: table} do
      assert {:ok, _} = RelayRouting.wire_relay_back_rule(table, session, dev, pm, alice)
      :ok = RuleStore.load_into_registry(table)

      # 人（alice）在同会话直接发消息（哪怕 @了 dev）—— sender = alice ≠ dev → from(dev) 不命中。
      human_msg =
        Message.new(alice, %{text: "@dev 帮我看下这个", attachments: []}, mentions: [dev])
        |> stamp(session)

      recipients = resolve_recipients(human_msg, session)

      refute URI.to_string(pm) in recipients,
             "relay-back 是 sender-locked（from dev）：只有 dev 自己的产出接力回 pm；" <>
               "人直接找 dev 的消息不得唤醒 pm。实得 #{inspect(recipients)}"
    end

    test "对照③（in_session 锁定）：dev 在**另一个会话**发 return → 不路由到 pm",
         %{
           session: session,
           other_session: other_session,
           pm: pm,
           dev: dev,
           alice: alice,
           table: table
         } do
      assert {:ok, _} = RelayRouting.wire_relay_back_rule(table, session, dev, pm, alice)
      :ok = RuleStore.load_into_registry(table)

      # 同一个 dev、同样的 return，但 stamp 成 other_session → in_session(session) 不命中。
      dev_return = from_msg(dev, other_session)
      recipients = resolve_recipients(dev_return, other_session)

      refute URI.to_string(pm) in recipients,
             "规则经 in_session(S) 锁定到本会话；dev 在其它会话的产出不得唤醒 pm"
    end
  end

  describe "relay_back_matcher/2 形状（core matcher 组合，零新增类型）" do
    test "= {:and, [{:in_session, S}, {:from, dev}]}", %{session: session, dev: dev} do
      assert {:and, [{:in_session, s}, {:from, d}]} =
               RelayRouting.relay_back_matcher(session, dev)

      assert s == URI.to_string(session)
      assert d == URI.to_string(dev)
    end
  end
end
