defmodule EzagentPluginAdvisor.Integration.SwUseLogicTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Workspace, WorkspaceRegistry}
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias EzagentPluginAdvisor.Template.AdvisorSession

  setup do
    workspace_name = "advisor-use-#{System.unique_integer([:positive])}"
    session_name = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, :advisor, session_name)

    {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

    assert {:ok, [^session_uri], %{fresh?: true, vertical: :advisor}} =
             AdvisorSession.instantiate(
               "advisor-main",
               %{
                 "class" => "session.advisor",
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

  test "one settled turn exposes customer chat and approved surface in the same turn", ctx do
    page_tree = %{type: "text", props: %{text: "approved advisor page"}}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, %{status: :composing, version: version, message_ids: [message_id]}} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{kind: :chat, text: "approved advisor answer"},
                 %{kind: :page, tree: page_tree}
               ]
             })

    assert {:ok, before_settle} = CustomerFeed.snapshot(ctx.session, ctx.token)
    assert before_settle.messages == []
    assert before_settle.page == nil

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    snapshot =
      wait_for_customer_snapshot(ctx.session, ctx.token, "approved advisor answer", page_tree)

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
    page_tree = %{type: "text", props: %{text: "held advisor page"}}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m2"}, opened_at: 1})

    assert {:ok, %{message_ids: [message_id]}} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{kind: :chat, text: "held advisor answer"},
                 %{kind: :page, tree: page_tree}
               ]
             })

    assert {:ok, %{status: :awaiting_human}} =
             dispatch(ctx.session, :turn, :claim, %{turn_id: turn_id, by: User.admin_uri()})

    assert {:ok, message} = Ezagent.MessageStore.by_id(message_id)
    assert message.visibility == :operator_only

    assert {:ok, held} = CustomerFeed.snapshot(ctx.session, ctx.token)
    assert held.messages == []
    assert held.page == nil

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    approved =
      wait_for_customer_snapshot(ctx.session, ctx.token, "held advisor answer", page_tree)

    assert approved.page == page_tree
  end

  test "second viewer and cold restart read only approved customer state", ctx do
    page_tree = %{type: "text", props: %{text: "restart-visible page"}}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m3"}, opened_at: 1})

    assert {:ok, _result} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{kind: :chat, text: "restart-visible answer"},
                 %{kind: :page, tree: page_tree}
               ]
             })

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    second_viewer =
      wait_for_customer_snapshot(
        ctx.session,
        ctx.second_token,
        "restart-visible answer",
        page_tree
      )

    assert second_viewer.page == page_tree

    {:ok, pid1} = KindRegistry.lookup(ctx.session)

    :ok =
      DynamicSupervisor.terminate_child(EzagentDomainSocialware.SocialwareSessionSupervisor, pid1)

    wait_until(fn -> KindRegistry.lookup(ctx.session) == :error end)

    {:ok, pid2} = Ezagent.Kind.spawn(Ezagent.Entity.SocialwareSession, %{uri: ctx.session})
    refute pid1 == pid2

    assert {:ok, after_restart} = CustomerFeed.snapshot(ctx.session, ctx.second_token)
    assert Enum.any?(after_restart.messages, &message_text?(&1, "restart-visible answer"))
    assert after_restart.page == page_tree
  end

  test "cross-session, cross-workspace, and expired tokens are denied", ctx do
    other_session =
      Ezagent.URI.session(
        Ezagent.URI.workspace_name!(ctx.workspace_uri),
        :advisor,
        "other-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.SocialwareSession, %{uri: other_session})
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
