defmodule Mix.Tasks.Loom.Serve do
  @shortdoc "dev: 起 serving endpoint + seed 一个 loom demo session（打印 customer URL/token）"
  @moduledoc """
  开发/E2E 用:在 app 启动**前**把 endpoint 设为 serving(dev 默认 server:false),
  起完整 app(含 HTTP listener)→ seed 一个 loom demo session(经 instantiate,会起编排进程)
  → 打印 customer URL/token → 保持运行。

      PORT=10042 DEEPSEEK_API_KEY=sk-… mix loom.serve
      # provider/model/端点可选覆盖:LOOM_LLM_PROVIDER / LOOM_LLM_API_URL / LOOM_LLM_MODEL
      # cc flavor:LOOM_LLM_FLAVOR=cc(走本地 claude,不需要 key)

  非生产工具(prod 由 OTP release 起 endpoint)。
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    # app.start 前覆盖 endpoint 配置为 serving(dev runtime 默认 server:false)。
    ep = Application.get_env(:ezagent_web, EzagentWeb.Endpoint, [])
    Application.put_env(:ezagent_web, EzagentWeb.Endpoint, Keyword.put(ep, :server, true))

    Mix.Task.run("app.start")

    ws = "demo"
    sid = "main#{System.unique_integer([:positive])}"
    _ = Ezagent.Workspace.create(ws, %{})
    wsuri = Ezagent.URI.workspace(ws)
    suri = Ezagent.URI.session(ws, :loom, sid)

    {:ok, [^suri], _} =
      EzagentPluginLoom.Template.LoomSession.instantiate(
        "loom-demo",
        %{
          "class" => "session.loom",
          "session_name" => sid,
          "operator_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
        },
        wsuri
      )

    token = Ezagent.Socialware.CustomerAuth.issue_token(suri, wsuri)
    port = System.get_env("PORT") || "10042"

    IO.puts("DEMO_WS=#{ws}")
    IO.puts("DEMO_SID=#{sid}")
    IO.puts("DEMO_TOKEN=#{token}")
    IO.puts("DEMO_URL=http://localhost:#{port}/loom/app/#{ws}/#{sid}?token=#{token}")
    IO.puts("LOOM_SERVE_READY")

    Process.sleep(:infinity)
  end
end
