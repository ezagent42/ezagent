defmodule EzagentPluginLoom.Integration.ToolFetchTest do
  @moduledoc "page-SDK 工具 RPC + fetch 代理:内置工具 + 白名单拒绝逻辑(非 live)。"
  use EzagentCore.DataCase, async: false
  use Plug.Test

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.CustomerAuth
  alias EzagentPluginLoom.{FetchProxy, Template.LoomSession, Tool, WebPlug}

  @opts WebPlug.init([])

  setup do
    ws = "loom-tf-#{System.unique_integer([:positive])}"
    sid = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(ws)
    session_uri = Ezagent.URI.session(ws, :loom, sid)
    {:ok, _} = Workspace.create(ws, %{})

    {:ok, [^session_uri], _} =
      LoomSession.instantiate(
        "loom-main",
        %{"class" => "session.loom", "session_name" => sid, "operator_uri" => URI.to_string(User.admin_uri())},
        workspace_uri
      )

    %{ws: ws, sid: sid, token: CustomerAuth.issue_token(session_uri, workspace_uri)}
  end

  test "Tool.invoke builtin echo/now + unknown" do
    assert {:ok, %{"x" => 1}} = Tool.invoke("echo", %{"x" => 1})
    assert {:ok, %{iso: iso}} = Tool.invoke("now", %{})
    assert is_binary(iso)
    assert {:error, :unknown_tool} = Tool.invoke("nope", %{})
  end

  test "POST tool over HTTP", ctx do
    conn =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/tool", Jason.encode!(%{name: "echo", args: %{"hi" => "there"}, token: ctx.token}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 200
    assert %{"ok" => true, "result" => %{"hi" => "there"}} = Jason.decode!(conn.resp_body)
  end

  test "POST tool rejects bad token", ctx do
    conn =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/tool", Jason.encode!(%{name: "echo", args: %{}, token: "bogus"}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 401
  end

  test "FetchProxy enforces preset whitelist" do
    assert {:error, :unknown_preset} = FetchProxy.fetch("nope", "https://example.com")
  end

  test "FetchProxy rejects url outside an allowed preset" do
    Application.put_env(:ezagent_plugin_loom, :fetch_presets, %{
      gh: %{url: ~r{^https://api\.github\.com/}, methods: [:get]}
    })

    on_exit(fn -> Application.delete_env(:ezagent_plugin_loom, :fetch_presets) end)

    assert {:error, :not_allowed} = FetchProxy.fetch("gh", "https://evil.com/x")
  end
end
