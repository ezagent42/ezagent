defmodule EzagentPluginKanban.E2E.KanbanRelayRoutingTest do
  @moduledoc """
  Phase 3 ② @路由/contract — **把 kanban 接力链经 routing 规则路由到下一棒 agent**。

  这是 ② 的 DoD 验收 gate：证明「kanban 接力公告 → 经 routing 规则 → 路由到下一棒
  agent」这条链是真路由（不是 hand-built 字符串、不是 stub）。**零 core 改动**——
  全程组合现有机制：

    1. **真接力输出**：`Ezagent.Behavior.Kanban.post_handle/4`（接力动作成功后框架
       runtime 调它，`@relay_actions`）产出真实的 `[kanban:<event>] by <caller>` 公告
       消息 + `{:dispatch}` 到绑定会话的 `session.send`。本测试直接调这个**生产函数**取
       它产出的真实 relay 消息（与 `relay_test.exs` 同范式，sanctioned）。
    2. **真规则持久化**：经 `EzagentPluginKanban.RelayRouting.wire_relay_rule/6` →
       `Ezagent.Routing.RuleStore.add/5`（SQLite 持久化）+ `load_into_registry/1`
       水合进 ETS。
    3. **真路由判定**：`Ezagent.Routing.Resolver.resolve/4`（`Behavior.Session.handle_send`
       内部驱动同一个 `Resolver` 判定收件人）对 relay 消息求解收件人，断言**下一棒
       agent 被解析为收件人**。

  ## 为什么在 Resolver 这一层断言（而非起 live Session GenServer）

  与 `category_10_scenarios_10_11_mention_routing_test.exs` /
  `scenario_32_*_test.exs` G2 同一**codebase 既有 gate 范式**：路由判定由 `Resolver`
  作出，钉住它即覆盖「公告被路由到下一棒」这一安全关键属性，无需 full Session
  GenServer + Audit writer。接力**注入**半边（`post_handle` → `session.send`）已由
  `relay_test.exs` 验收；本测试补**路由判定**半边（规则命中 → 下一棒）。两者合起来 =
  接力链经 routing 真路由到下一 agent。

  `handle_send` 在 `MessageStore.write/2` 后用带 `session_uri` 的 `stored_msg` 喂
  `Resolver`（session.ex 的 Plan B 注释），故本测试把 relay 消息 `stamp` 上
  `session_uri`（复刻那一行）后再喂 Resolver——忠实于生产路径。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.Kanban
  alias Ezagent.{Message, RoutingRegistry}
  alias Ezagent.Routing.{Resolver, RuleStore}
  alias EzagentPluginKanban.{BoardConfig, RelayRouting}

  @workspace URI.new!("workspace://relay-ws")

  setup do
    n = System.unique_integer([:positive])

    session = URI.new!("session://relay-ws/default/main-#{n}")
    other_session = URI.new!("session://relay-ws/default/other-#{n}")
    board = Ezagent.URI.agent("relay-ws", "kanban-board-#{n}")

    # 下一棒 agent —— ② 的 receiver（probe agent；只作路由判定的收件人 URI，不依赖任何
    # 具体 agent 实现）。pm 设计里日后由 cc-headless×dev-together role 充当，但本路由测试
    # 不需要它存在——只断言「接力公告经规则路由到这个 URI」。
    receiver = Ezagent.URI.agent("relay-ws", "relay-probe-#{n}")
    alice = URI.new!("entity://relay-ws/user/alice")

    # 每测试一张独立 routing 表 + 覆盖 routing_tables（ETS 全局，故隔离）——
    # 与 role_native_create_test / category_10 同范式。
    table = :"kanban_relay_routing_#{n}"
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
      board: board,
      receiver: receiver,
      alice: alice,
      table: table
    }
  end

  # 用生产函数 post_handle/4 取一条 register_pr 接力真实产出的 relay 消息。
  # 板已绑定 `session`（BoardConfig），故 post_handle 注入 {:dispatch} 到 session.send。
  defp produce_relay_message(board, caller, session, action \\ :register_pr) do
    :ok = BoardConfig.write(board, %{session_uri: URI.to_string(session)})
    ctx = %{self_uri: board, caller: caller}

    assert {:ok, %{}, effects} =
             Kanban.post_handle(action, %{}, [{:set, :tree, %{}}], ctx)

    assert [{:dispatch, cmd}] = Enum.filter(effects, &match?({:dispatch, _}, &1)),
           "接力动作 #{action} 应注入恰好一条 {:dispatch} 到 session.send"

    assert cmd.target.scheme == "session"
    assert cmd.action == :send

    cmd.args.message
  end

  # 复刻 handle_send 的 Plan B：用带 session_uri 的消息喂 Resolver（in_session matcher
  # 才能命中）。生产里这一步由 MessageStore.write 盖章 stored_msg。
  defp stamp(%Message{} = msg, %URI{} = session), do: %{msg | session_uri: session}

  defp resolve_recipients(msg, session) do
    Resolver.resolve(msg, session, [], workspace_uri: @workspace)
    |> Enum.map(&URI.to_string/1)
  end

  describe "② 接力链经 routing 路由到下一棒 agent" do
    test "register_pr 接力公告经 in_session+marker 规则路由到下一棒 receiver",
         %{session: session, board: board, receiver: receiver, alice: alice, table: table} do
      # seed 规则：{:and, [in_session(S), text_contains("[kanban:pr_registered]")]} → [receiver]
      assert {:ok, _rule} =
               RelayRouting.wire_relay_rule(table, session, :pr_registered, receiver, alice)

      :ok = RuleStore.load_into_registry(table)

      # 真接力输出（生产 post_handle）→ relay 消息（body=[kanban:pr_registered] by alice）
      relay_msg = produce_relay_message(board, alice, session) |> stamp(session)

      # sanity：relay 消息确实带 marker + sender=板自己（非 receiver/session）
      assert Message.Body.body_text(relay_msg.body) =~ RelayRouting.marker(:pr_registered)
      assert URI.to_string(relay_msg.sender) == URI.to_string(board)

      recipients = resolve_recipients(relay_msg, session)

      assert URI.to_string(receiver) in recipients,
             "kanban 接力公告必须经 routing 规则路由到下一棒 agent #{URI.to_string(receiver)}；" <>
               "实得 recipients=#{inspect(recipients)}"
    end

    test "in_session 锁定：同一条接力公告在**另一个会话**里不路由到 receiver",
         %{
           session: session,
           other_session: other_session,
           board: board,
           receiver: receiver,
           alice: alice,
           table: table
         } do
      assert {:ok, _} =
               RelayRouting.wire_relay_rule(table, session, :pr_registered, receiver, alice)

      :ok = RuleStore.load_into_registry(table)

      # 同样的 relay 消息，但 stamp 成 other_session → in_session(session) matcher 不命中。
      relay_msg = produce_relay_message(board, alice, session) |> stamp(other_session)

      recipients = resolve_recipients(relay_msg, other_session)

      refute URI.to_string(receiver) in recipients,
             "规则经 in_session(S) 锁定到本会话；其它会话的同名公告不得唤醒 receiver"
    end

    test "marker 门控：无 [kanban:pr_registered] 标记的普通消息不路由到 receiver",
         %{session: session, receiver: receiver, alice: alice, table: table} do
      assert {:ok, _} =
               RelayRouting.wire_relay_rule(table, session, :pr_registered, receiver, alice)

      :ok = RuleStore.load_into_registry(table)

      # 一条本会话内的普通消息（无 kanban 事件标记）→ text_contains 不命中。
      plain =
        Message.new(alice, %{text: "随便聊两句，没有事件标记", attachments: []}, mentions: [])
        |> stamp(session)

      recipients = resolve_recipients(plain, session)

      refute URI.to_string(receiver) in recipients,
             "只有携带 [kanban:<event>] 标记的接力公告才触发路由；普通消息不得唤醒 receiver"
    end

    test "claim_node / set_status 同样形状的规则各自路由到下一棒",
         %{session: session, board: board, receiver: receiver, alice: alice, table: table} do
      # 证明接力链对全部 @relay_actions 事件成立（不止 pr_registered）。
      for {action, event} <- [{:claim_node, :claimed}, {:set_status, :status}] do
        assert {:ok, _} = RelayRouting.wire_relay_rule(table, session, event, receiver, alice)
        :ok = RuleStore.load_into_registry(table)

        relay_msg = produce_relay_message(board, alice, session, action) |> stamp(session)

        assert Message.Body.body_text(relay_msg.body) =~ RelayRouting.marker(event)

        recipients = resolve_recipients(relay_msg, session)

        assert URI.to_string(receiver) in recipients,
               "#{action} 接力公告（marker #{RelayRouting.marker(event)}）应路由到下一棒；" <>
                 "实得 #{inspect(recipients)}"

        # 清表，下一事件独立验证（load_into_registry 是 replace 语义，但 add 累积 DB 行；
        # 这里两条规则不同 event、receiver 相同，互不冲突，累积即可）。
      end
    end
  end
end
