defmodule EzagentPluginLoom.Integration.SwUseLogicTest do
  @moduledoc """
  Loom vertical 的 SW-USE 主链路验证（照 advisor sw_use_logic 范式）。

  loom 与 advisor 共享**同一套** socialware 主链路(`ezagent_domain_session` 的 Turn/Surface
  + `ezagent_domain_socialware` 的 CustomerFeed/CustomerAuth),都跑统一 `Entity.Session` 的
  `socialware_behaviors/0` subset。本测试锁定 loom session 的首版完成判据(迁移文档 B8):
  一个 settled turn 同驱 customer chat + approved surface;operator 批准前 customer 看不到;
  `:operator_only` 不泄漏;冷重启/二次访客只读 approved;跨域/过期 token 被拒。

  result_refs(`{:chat, :page}`)在此**直接喂入** Turn.compose——真实 orchestrator/worker/v0
  agent 自动产出 result_refs 是 loom 独有 vertical 填充物,走 live agent-browser 验证
  (同 advisor P5 边界,不在隔离单测内 spawn 真实 agent)。
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Workspace, WorkspaceRegistry}
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias EzagentPluginLoom.Template.LoomSession

  setup do
    workspace_name = "loom-use-#{System.unique_integer([:positive])}"
    session_name = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, :loom, session_name)

    {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

    assert {:ok, [^session_uri], %{fresh?: true, vertical: :loom}} =
             LoomSession.instantiate(
               "loom-main",
               %{
                 "class" => "session.loom",
                 "session_name" => session_name,
                 "operator_uri" => URI.to_string(User.admin_uri())
               },
               workspace_uri
             )

    assert {:ok, _pid} = KindRegistry.lookup(session_uri)
    assert {:ok, ^workspace_uri} = WorkspaceRegistry.lookup(session_uri)

    token = CustomerAuth.issue_token(session_uri, workspace_uri)

    %{
      workspace_uri: workspace_uri,
      session: session_uri,
      token: token,
      second_token: CustomerAuth.issue_token(session_uri, workspace_uri)
    }
  end

  test "one settled turn exposes customer chat and approved page in the same turn", ctx do
    page_tree = %{type: "services", props: %{title: "approved loom page"}}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, %{status: :composing, version: version, message_ids: [message_id]}} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{kind: :chat, text: "approved loom answer"},
                 %{kind: :page, tree: page_tree}
               ]
             })

    assert {:ok, before_settle} = CustomerFeed.snapshot(ctx.session, ctx.token)

    # instantiate 会 seed 一张初始欢迎页(占 baseline)。gating 关键 = 这个 NEW turn 的
    # 内容在 settle 前对 customer 不可见(message 不在 feed、page 仍是 seed 不是 page_tree)。
    refute message_id in Enum.map(before_settle.messages, & &1.id)
    assert before_settle.page != page_tree

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    snapshot =
      wait_for_customer_snapshot(ctx.session, ctx.token, "approved loom answer", page_tree)

    assert snapshot.page == page_tree

    assert {:ok, surface} = Ezagent.Kind.get_slice(ctx.session, :surface)
    assert surface.approved == version
    assert surface.versions[version] == %{tree: page_tree, by_turn: turn_id}

    assert {:ok, settlement} = Ezagent.Socialware.Settlement.get(turn_id)
    assert settlement.target_surface_version == version
    assert settlement.status == :committed
    assert message_id in Enum.map(snapshot.messages, & &1.id)
  end

  test "copilot claim holds all customer output until approval and operator-only never leaks",
       ctx do
    page_tree = %{type: "services", props: %{title: "held loom page"}}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m2"}, opened_at: 1})

    assert {:ok, %{message_ids: [message_id]}} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{kind: :chat, text: "held loom answer"},
                 %{kind: :page, tree: page_tree}
               ]
             })

    assert {:ok, %{status: :awaiting_human}} =
             dispatch(ctx.session, :turn, :claim, %{turn_id: turn_id, by: User.admin_uri()})

    assert {:ok, message} = Ezagent.MessageStore.by_id(message_id)
    assert message.visibility == :operator_only

    assert {:ok, held} = CustomerFeed.snapshot(ctx.session, ctx.token)

    # claim → operator_only:本 turn 内容对 customer 不可见(seed 初始页仍是 baseline)。
    refute message_id in Enum.map(held.messages, & &1.id)
    assert held.page != page_tree

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    approved =
      wait_for_customer_snapshot(ctx.session, ctx.token, "held loom answer", page_tree)

    assert approved.page == page_tree
  end

  test "second viewer and cold restart read only approved customer state", ctx do
    page_tree = %{type: "services", props: %{title: "restart-visible loom page"}}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m3"}, opened_at: 1})

    assert {:ok, _result} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{kind: :chat, text: "restart-visible loom answer"},
                 %{kind: :page, tree: page_tree}
               ]
             })

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    second_viewer =
      wait_for_customer_snapshot(
        ctx.session,
        ctx.second_token,
        "restart-visible loom answer",
        page_tree
      )

    assert second_viewer.page == page_tree

    {:ok, pid1} = KindRegistry.lookup(ctx.session)

    :ok =
      DynamicSupervisor.terminate_child(
        EzagentDomainInstanceMessage.SessionSupervisor,
        pid1
      )

    wait_until(fn -> KindRegistry.lookup(ctx.session) == :error end)

    {:ok, pid2} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: ctx.session,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    refute pid1 == pid2

    assert {:ok, after_restart} = CustomerFeed.snapshot(ctx.session, ctx.second_token)
    assert Enum.any?(after_restart.messages, &message_text?(&1, "restart-visible loom answer"))
    assert after_restart.page == page_tree
  end

  test "cross-session, cross-workspace, and expired tokens are denied", ctx do
    other_session =
      Ezagent.URI.session(
        Ezagent.URI.workspace_name!(ctx.workspace_uri),
        :loom,
        "other-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: other_session,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok = WorkspaceRegistry.bind(other_session, ctx.workspace_uri)

    cross_workspace_token = CustomerAuth.issue_token(ctx.session, "workspace://other")
    expired_token = CustomerAuth.issue_token(ctx.session, ctx.workspace_uri, expires_in_ms: -1)

    assert {:error, :unauthorized} = CustomerFeed.snapshot(other_session, ctx.token)
    assert {:error, :unauthorized} = CustomerFeed.snapshot(ctx.session, cross_workspace_token)
    assert {:error, :unauthorized} = CustomerFeed.snapshot(ctx.session, expired_token)
  end

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    Invocation.dispatch(%Invocation{
      target: target(session_uri, behavior, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp message_text?(message, text) do
    Map.get(message.body, "text") == text or Map.get(message.body, :text) == text
  end

  defp wait_for_customer_snapshot(session_uri, token, text, page_tree) do
    wait_until(fn ->
      case CustomerFeed.snapshot(session_uri, token) do
        {:ok, snapshot} ->
          Enum.any?(snapshot.messages, &message_text?(&1, text)) and snapshot.page == page_tree

        _ ->
          false
      end
    end)

    {:ok, snapshot} = CustomerFeed.snapshot(session_uri, token)
    snapshot
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
