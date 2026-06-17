# dev demo:seed 一个 loom session + 打印 customer URL/token,保持 app 运行(含 HTTP endpoint)。
# 用法: PORT=10042 ANTHROPIC_BASE_URL=… ANTHROPIC_API_KEY=… mix run --no-halt scripts/loom_demo.exs
alias Ezagent.{Workspace, URI}

ws = "demo"
sid = "main#{System.unique_integer([:positive])}"
_ = Workspace.create(ws, %{})
wsuri = URI.workspace(ws)
suri = URI.session(ws, :loom, sid)

{:ok, [^suri], _} =
  EzagentPluginLoom.Template.LoomSession.instantiate(
    "loom-demo",
    %{
      "class" => "session.loom",
      "session_name" => sid,
      "operator_uri" => Elixir.URI.to_string(Ezagent.Entity.User.admin_uri())
    },
    wsuri
  )

token = Ezagent.Socialware.CustomerAuth.issue_token(suri, wsuri)
port = System.get_env("PORT") || "10042"
IO.puts("DEMO_WS=#{ws}")
IO.puts("DEMO_SID=#{sid}")
IO.puts("DEMO_TOKEN=#{token}")
IO.puts("DEMO_URL=http://localhost:#{port}/loom/app/#{ws}/#{sid}?token=#{token}")
