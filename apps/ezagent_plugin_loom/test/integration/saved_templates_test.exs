defmodule EzagentPluginLoom.Integration.SavedTemplatesTest do
  @moduledoc "存为模板:HTTP 存当前 approved 页 → SavedTemplates → 新 session 复用 seed。"
  use EzagentCore.DataCase, async: false
  use Plug.Test

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.CustomerAuth
  alias EzagentPluginLoom.{SavedTemplates, Template.LoomSession, WebPlug}

  @opts WebPlug.init([])

  setup do
    ws = "loom-tmpl-#{System.unique_integer([:positive])}"
    sid = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(ws)
    session_uri = Ezagent.URI.session(ws, :loom, sid)
    {:ok, _} = Workspace.create(ws, %{})

    {:ok, [^session_uri], _} =
      LoomSession.instantiate(
        "loom-main",
        %{
          "class" => "session.loom",
          "session_name" => sid,
          "operator_uri" => URI.to_string(User.admin_uri())
        },
        workspace_uri
      )

    # seed = page_update span 消息,等它落进 session。
    assert eventually(fn -> page_files(session_uri) != nil end)

    %{ws: ws, sid: sid, session_uri: session_uri, wsuri: workspace_uri}
  end

  test "POST save-template 把当前页存为模板 → list 可见 → 新 session 复用", ctx do
    token = CustomerAuth.issue_token(ctx.session_uri, ctx.wsuri)

    resp =
      conn(
        :post,
        "/c/#{ctx.ws}/#{ctx.sid}/save-template",
        Jason.encode!(%{name: "我的模板", token: token})
      )
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert %{"ok" => true, "name" => "我的模板"} = Jason.decode!(resp.resp_body)

    # 落进 SavedTemplates(workspace 级,存的是 page_update 的 files map)。
    assert [%{name: "我的模板", tree: saved_files}] = SavedTemplates.list(ctx.ws)
    assert is_map(saved_files) and Map.has_key?(saved_files, "/App.jsx")

    # 新 session 用 saved_template 复用 → seed 的 page_update files == 存的 files。
    new_sid = "reuse-#{System.unique_integer([:positive])}"
    new_uri = Ezagent.URI.session(ctx.ws, :loom, new_sid)

    {:ok, [^new_uri], _} =
      LoomSession.instantiate(
        "loom-reuse",
        %{
          "class" => "session.loom",
          "session_name" => new_sid,
          "operator_uri" => URI.to_string(User.admin_uri()),
          "saved_template" => "我的模板"
        },
        ctx.wsuri
      )

    assert eventually(fn -> page_files(new_uri) == saved_files end)
  end

  test "save-template 拒绝坏 token", ctx do
    resp =
      conn(
        :post,
        "/c/#{ctx.ws}/#{ctx.sid}/save-template",
        Jason.encode!(%{name: "x", token: "bogus"})
      )
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert resp.status == 401
  end

  # 最近一条 page_update span 的 files(无 → nil)。
  defp page_files(session_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(50)
    |> Enum.find_value(nil, fn m ->
      text = (m.body || %{})["text"] || (m.body || %{})[:text] || ""

      with [_, json] <- Regex.run(~r/<span type="page_update">([\s\S]*?)<\/span>/, text),
           {:ok, %{"files" => files}} <- Jason.decode(json) do
        files
      else
        _ -> nil
      end
    end)
  end

  defp eventually(fun, n \\ 150)
  defp eventually(_f, 0), do: false

  defp eventually(f, n),
    do:
      if(f.(),
        do: true,
        else:
          (
            Process.sleep(20)
            eventually(f, n - 1)
          )
      )
end
