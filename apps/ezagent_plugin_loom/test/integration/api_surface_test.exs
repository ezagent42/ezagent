defmodule EzagentPluginLoom.Integration.ApiSurfaceTest do
  @moduledoc "前端 /api 面(editor 端,无 token):knowledge/workers/orchestrator/stitch-mode/user-schema/templates/save-as-template/stop。"
  use EzagentCore.DataCase, async: false
  use Plug.Test

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias EzagentPluginLoom.{Template.LoomSession, SavedTemplates, WebPlug}

  @opts WebPlug.init([])

  setup do
    ws = "loom-api-#{System.unique_integer([:positive])}"
    sid = "main-#{System.unique_integer([:positive])}"
    {:ok, _} = Workspace.create(ws, %{})

    {:ok, _, _} =
      LoomSession.instantiate(
        "loom-main",
        %{
          "class" => "session.loom",
          "session_name" => sid,
          "operator_uri" => URI.to_string(User.admin_uri())
        },
        Ezagent.URI.workspace(ws)
      )

    %{ws: ws, sid: sid}
  end

  defp post_json(ws, sid, path, body),
    do:
      conn(:post, "/api/#{ws}/#{sid}/#{path}", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)
      |> then(&Jason.decode!(&1.resp_body))

  defp get_json(path),
    do: conn(:get, path) |> WebPlug.call(@opts) |> then(&Jason.decode!(&1.resp_body))

  test "knowledge get/post", ctx do
    assert %{"ok" => true} = post_json(ctx.ws, ctx.sid, "knowledge", %{md: "# KB"})
    assert %{"ok" => true, "md" => "# KB"} = get_json("/api/#{ctx.ws}/#{ctx.sid}/knowledge")
  end

  test "workers get/post/delete", ctx do
    assert %{"ok" => true, "workers" => []} = get_json("/api/#{ctx.ws}/#{ctx.sid}/workers")

    assert %{"ok" => true, "workers" => [%{"key" => "policy"}]} =
             post_json(ctx.ws, ctx.sid, "workers", %{key: "policy", desc: "政策"})

    del =
      conn(:delete, "/api/#{ctx.ws}/#{ctx.sid}/workers?key=policy")
      |> WebPlug.call(@opts)
      |> then(&Jason.decode!(&1.resp_body))

    assert %{"ok" => true, "workers" => []} = del
  end

  test "orchestrator + stitch-mode get/post", ctx do
    assert %{"ok" => true, "instruction" => "拆细点"} =
             post_json(ctx.ws, ctx.sid, "orchestrator", %{instruction: "拆细点"})

    assert %{"ok" => true, "instruction" => "拆细点"} =
             get_json("/api/#{ctx.ws}/#{ctx.sid}/orchestrator")

    assert %{"ok" => true, "mode" => "stitch"} = get_json("/api/#{ctx.ws}/#{ctx.sid}/stitch-mode")

    assert %{"ok" => true, "mode" => "human"} =
             post_json(ctx.ws, ctx.sid, "stitch-mode", %{mode: "human"})
  end

  test "user-schema session ops get/post", ctx do
    assert %{"ok" => true, "ops" => []} = get_json("/api/#{ctx.ws}/#{ctx.sid}/user-schema")

    assert %{"ok" => true, "ops" => [%{"t" => "x"}]} =
             post_json(ctx.ws, ctx.sid, "user-schema", %{op: %{t: "x"}})

    assert %{"ok" => true, "ops" => []} = post_json(ctx.ws, ctx.sid, "user-schema", %{ops: []})
  end

  test "save-as-template(seed 页可存)+ templates 列 + 删", ctx do
    assert %{"ok" => true, "name" => "模板A"} =
             post_json(ctx.ws, ctx.sid, "save-as-template", %{name: "模板A"})

    assert %{"ok" => true, "items" => [%{"name" => "模板A"}]} = get_json("/api/#{ctx.ws}/templates")

    del =
      conn(:delete, "/api/#{ctx.ws}/templates/模板A")
      |> WebPlug.call(@opts)
      |> then(&Jason.decode!(&1.resp_body))

    assert %{"ok" => true} = del
    assert SavedTemplates.list(ctx.ws) == []
  end

  test "stop no-op ok", ctx do
    assert %{"ok" => true} = post_json(ctx.ws, ctx.sid, "stop", %{})
  end
end
