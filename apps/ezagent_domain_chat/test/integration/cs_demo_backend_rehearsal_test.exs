defmodule EzagentDomainChat.Integration.CsDemoBackendRehearsalTest do
  @moduledoc """
  后端彩排 — 坐实 `docs/notes/2026-06-02-cs-team-demo-script.md` §3.3 的实测待确认项,
  纯 Tools + Resolver 层(P12「can this be reproduced via Invocation.dispatch/1 in
  ExUnit?」),不需要 claude login / 浏览器 / 录屏。

  覆盖三项(item 2「{:from} 成员 receiver 正常」已由
  `OrchestratorMemberTeamTest` 的「relay chain ... {:from, role→uri}」一例证明):

    * **GAP #4** — 对话里指不到具体人类成员:一个**已 join** 的 human member(无
      role_name)做 receiver,`define_rule_set_rule` 返回 `{:unknown_member_role}`;
      MCP 层映射为 `unknown_member_role` 结构化错误。对照:真成员 role_name 正常。
    * **§3.3 position 语义** — 同一消息命中多条规则(general entry + 条件升级)时,
      Resolver **扇出 union**,position 不做抑制 → 「仅退货才升级」做不到,退货消息
      同时投给售前+售后。
    * **§3.3 applies_to_users** — Resolver 真的按 sender 过滤 `applies_to_users`
      (`resolver.ex:268-270`),坐实 GAP #5「引擎已支持 per-user」。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Invocation, KindRegistry, Message, RoutingRegistry}
  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.Orchestrator.{McpServer, Tools}
  alias Ezagent.Routing.{Matcher, Resolver}

  defp uniq, do: System.unique_integer([:positive])

  @workspace_uri URI.new!("workspace://system")

  # ── shared fixtures (mirrors OrchestratorMemberTeamTest) ─────────────────

  defp terminate_child(sup, uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: DynamicSupervisor.terminate_child(sup, pid)
      :error -> :ok
    end
  end

  defp seed_agent_template(n) do
    uri = Ezagent.URI.new!("template://agent/system/cs-seed-#{n}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(uri)}?action=template.write"),
        mode: :call,
        args: %{
          content: %{
            flavor: "echo",
            working_directory: "/tmp",
            default_caps: [],
            created_by: User.admin_uri(),
            created_at: ~U[2026-06-01 00:00:00Z]
          }
        },
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    on_exit(fn -> terminate_child(EzagentDomainChat.AgentTemplateSupervisor, uri) end)
    uri
  end

  defp orchestrated_session(n) do
    session_uri = Ezagent.URI.new!("session://generic/system/cs-demo-#{n}")
    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    on_exit(fn -> terminate_child(EzagentDomainChat.SessionSupervisor, session_uri) end)

    orchestrator_uri = Ezagent.URI.new!("entity://agent/system/cc_orch-#{n}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)

    {:ok, mcp} =
      McpServer.new(
        orchestrator_uri: orchestrator_uri,
        session_uri: session_uri,
        workspace_uri: @workspace_uri,
        caps: orchestrator_caps(session_uri, orchestrator_uri)
      )

    {mcp, session_uri, orchestrator_uri}
  end

  defp orchestrator_caps(session_uri, orchestrator_uri) do
    MapSet.new([
      %Capability{
        kind: :session,
        behavior: :any,
        action: :any,
        instance: {:within_session, session_uri},
        workspace_uri: @workspace_uri,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      },
      %Capability{
        kind: :agent,
        behavior: :any,
        action: :any,
        instance: {:spawned_by, orchestrator_uri},
        workspace_uri: @workspace_uri,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      }
    ])
  end

  defp chat_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{chat: %{state: slice}}} = :sys.get_state(pid)
    slice
  end

  # Join a HUMAN user as a session member WITHOUT a role_name (the only path
  # a human gets in — no supported surface passes a role_name facet).
  defp join_human(session_uri, user_uri) do
    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=chat.join"),
        mode: :cast,
        args: %{member: user_uri},
        ctx: %{
          caller: user_uri,
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: :ignore
        }
      })

    Process.sleep(50)
  end

  # ── GAP #4 — 对话指不到具体人类成员 ──────────────────────────────────────

  describe "GAP #4 — a joined human member cannot be targeted by a rule via conversation" do
    test "human URI receiver → {:unknown_member_role}; a real member role_name works" do
      n = uniq()
      src = seed_agent_template(n)
      {mcp, session_uri, _orch} = orchestrated_session(n)

      # 售前 AI 是真成员(有 role_name)——做对照
      presale_role = "presale-#{n}"

      {:ok, presale_uri} =
        Tools.add_managed_member(src, presale_role, true, McpServer.tool_opts(mcp))

      on_exit(fn -> terminate_child(EzagentDomainChat.AgentSupervisor, presale_uri) end)

      # 人工 Alice 是 human member,但 join 不带 role_name(无面可设)
      alice_uri = Ezagent.URI.new!("entity://user/system/cs-alice-#{n}")
      {:ok, _} = Ezagent.SpawnRegistry.spawn(alice_uri)
      join_human(session_uri, alice_uri)

      slice = chat_slice(session_uri)
      assert Map.has_key?(slice.members, alice_uri), "Alice 必须确实是 session 成员"
      assert is_nil(Map.get(slice.members[alice_uri], :role_name)), "Alice 没有 role_name"

      # (A) 用 Alice 的 URI 字符串做 receiver → 被 M1 + role_name 查找堵死
      assert {:error, {:unknown_member_role, _}} =
               Tools.define_rule_set_rule(
                 Matcher.mention("转人工"),
                 URI.to_string(alice_uri),
                 [rule_set: "handoff_human-#{n}", position: 0] ++ McpServer.tool_opts(mcp)
               ),
             "GAP #4: 一个 joined human member 仍无法被 rule 定向(role_name 无面可设 + URI receiver 被 M1 堵)"

      # (B) 同样的失败经 MCP 对话层暴露为结构化错误 unknown_member_role
      mcp_result =
        McpServer.handle_tool_call(mcp, "define_rule_set_rule", %{
          "matcher_ast" => %{"type" => "mention", "arg" => "转人工"},
          "receiver_role_name" => URI.to_string(alice_uri),
          "rule_set" => "handoff_human-#{n}"
        })

      assert mcp_result["isError"] == true
      assert mcp_result["error"]["code"] == "unknown_member_role"

      # (C) 对照:真成员的 role_name 正常 → 证明机制可用,只是够不到人类
      assert {:ok, %{id: _}} =
               Tools.define_rule_set_rule(
                 Matcher.mention("找售前"),
                 presale_role,
                 [rule_set: "to_presale-#{n}", position: 0] ++ McpServer.tool_opts(mcp)
               )
    end
  end

  # ── §3.3 — Resolver 语义(独立小路由表,不碰 live MentionRouting) ─────────

  defp with_test_table do
    table = :"cs_demo_rehearsal_#{System.unique_integer([:positive])}"
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)
    original = Application.get_env(:ezagent_core, :routing_tables)
    Application.put_env(:ezagent_core, :routing_tables, [table])

    on_exit(fn ->
      if original,
        do: Application.put_env(:ezagent_core, :routing_tables, original),
        else: Application.delete_env(:ezagent_core, :routing_tables)
    end)

    table
  end

  defp customer_msg(sender, text),
    do: Message.new(sender, %{text: text, attachments: []})

  describe "§3.3 position 语义 — 多规则命中同一消息 = 扇出 union(非抑制)" do
    test "general entry + 条件升级 同时命中退货消息 → 售前与售后都收到(扇出)" do
      table = with_test_table()
      session = URI.new!("session://generic/system/cs-pos")
      presale = "entity://agent/system/presale"
      aftersale = "entity://agent/system/aftersale"

      # Rule A(general entry,position 1):任何咨询 → 售前
      :ok =
        RoutingRegistry.put(table, Matcher.always(), %{
          receivers: [presale],
          applies_to_users: [],
          workspace_uri: nil,
          rule_id: 1,
          rule_set: "cs",
          position: 1,
          prompt_template_ref: nil
        })

      # Rule B(条件升级,position 0):含退/换/退款 → 售后
      :ok =
        RoutingRegistry.put(table, Matcher.text_matches("退|换|退款"), %{
          receivers: [aftersale],
          applies_to_users: [],
          workspace_uri: nil,
          rule_id: 2,
          rule_set: "cs",
          position: 0,
          prompt_template_ref: nil
        })

      customer = URI.new!("entity://user/system/customer-1")

      # 退货消息命中两条规则 → 扇出 union(售前 + 售后),position 不抑制
      returns = Resolver.resolve(customer_msg(customer, "我要退货"), session)
      got = returns |> Enum.map(&URI.to_string/1) |> Enum.sort()

      assert got == Enum.sort([presale, aftersale]),
             "position 不做抑制:退货消息扇出给售前+售后,而非只给售后。got=#{inspect(got)}"

      # 非退货消息只命中 general entry → 只给售前
      plain = Resolver.resolve(customer_msg(customer, "这件有货吗"), session)
      assert Enum.map(plain, &URI.to_string/1) == [presale]
    end
  end

  describe "§3.3 applies_to_users — Resolver 按 sender 做 per-user 过滤(GAP #5 引擎已支持)" do
    test "applies_to_users:[A] 的规则只对 A 生效,对 B 静默跳过" do
      table = with_test_table()
      session = URI.new!("session://generic/system/cs-peruser")
      alice = "entity://user/system/cs-alice"

      customer_a = URI.new!("entity://user/system/customer-A")
      customer_b = URI.new!("entity://user/system/customer-B")

      # 「只对 customer-A 走人工 Alice」—— 用 applies_to_users 把规则锁到 A
      :ok =
        RoutingRegistry.put(table, Matcher.always(), %{
          receivers: [alice],
          applies_to_users: [URI.to_string(customer_a)],
          workspace_uri: nil,
          rule_id: 1,
          rule_set: "sticky_human",
          position: 0,
          prompt_template_ref: nil
        })

      # A 的消息命中 → 路由到 Alice(sticky 人工对 A 生效)
      from_a = Resolver.resolve(customer_msg(customer_a, "继续"), session)

      assert Enum.map(from_a, &URI.to_string/1) == [alice],
             "applies_to_users:[A] 必须对 A 生效"

      # B 的消息被 per-user 过滤掉 → 不路由到 Alice(证明引擎支持 per-user 隔离)
      from_b = Resolver.resolve(customer_msg(customer_b, "继续"), session)

      assert from_b == [],
             "applies_to_users 必须按 sender 过滤:B 的消息不该命中只对 A 的规则。got=#{inspect(from_b)}"
    end
  end
end
