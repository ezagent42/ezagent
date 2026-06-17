defmodule EzagentPluginLoom.Integration.ForkTest do
  @moduledoc "fork:从源 session 的 approved page 派生新 loom session（合法 Turn seed，不撞红线 #3）。"
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Workspace, KindRegistry}
  alias Ezagent.Entity.User
  alias EzagentPluginLoom.{Fork, Template.LoomSession}

  setup do
    ws = "loom-fork-#{System.unique_integer([:positive])}"
    sid = "src-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(ws)
    session_uri = Ezagent.URI.session(ws, :loom, sid)
    {:ok, _} = Workspace.create(ws, %{})

    {:ok, [^session_uri], _} =
      LoomSession.instantiate(
        "loom-main",
        %{"class" => "session.loom", "session_name" => sid, "operator_uri" => URI.to_string(User.admin_uri())},
        workspace_uri
      )

    %{ws: ws, session_uri: session_uri}
  end

  test "fork copies the source's approved page into a new loom session", ctx do
    page_tree = %{"type" => "services", "props" => %{"title" => "forkable"}, "children" => []}

    # 给源 session seed 一个 approved page(合法 Turn)
    {:ok, %{turn_id: tid}} =
      dispatch(ctx.session_uri, "turn.open", %{trigger: %{message_id: "s"}, opened_at: 1})

    {:ok, _} =
      dispatch(ctx.session_uri, "turn.compose", %{
        turn_id: tid,
        result_refs: [%{kind: :page, tree: page_tree}]
      })

    {:ok, _} = dispatch(ctx.session_uri, "turn.settle", %{turn_id: tid})

    # settle → surface.approve 是异步 cast(turn deferred settlement),等 approved 落定再 fork
    # (生产里 fork 的是早已 settled 的发布物,无此竞态)
    assert eventually(fn ->
             match?({:ok, %{approved: a}} when not is_nil(a), Ezagent.Kind.get_slice(ctx.session_uri, :surface))
           end)

    # fork
    new_name = "forked-#{System.unique_integer([:positive])}"
    assert {:ok, new_uri} = Fork.fork(ctx.session_uri, new_name, URI.to_string(User.admin_uri()))
    assert {:ok, _pid} = KindRegistry.lookup(new_uri)
    refute URI.to_string(new_uri) == URI.to_string(ctx.session_uri)

    # 新 session 的 approved page == 源 page
    assert {:ok, surface} = Ezagent.Kind.get_slice(new_uri, :surface)
    refute is_nil(surface.approved)
    assert surface.versions[surface.approved].tree == page_tree
  end

  test "fork without an approved page errors", ctx do
    assert {:error, :no_approved_page} =
             Fork.fork(ctx.session_uri, "empty-#{System.unique_integer([:positive])}", URI.to_string(User.admin_uri()))
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false
  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp dispatch(session_uri, action, args) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{action}"),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end
end
