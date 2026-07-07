# e2e seam 注入（gap ⑨：env 无 HELLO_LLM_API_KEY/DEEPSEEK_KEY，LLM 生成段用替身代跑）
# —— 只替换 ALT 已有的 app-env seam `:page_refresh_fun`（默认 &EzagentPluginHello.Generator.start/2）。
# 替身与真 Generator.start/2 同构：spawn supervised Task（EzagentPluginHello.TaskSupervisor）
# → 构造 catalog 合法 spec → **真** TurnDriver.drive（turn.open→compose→settle → Surface.put_version）。
# 被代跑的只有"LLM 产 spec"这一段；信号→dispatch→ALT handler→生成入口→TurnDriver→Surface 全为真。
# 用法: elixir --name probe@127.0.0.1 --cookie <cookie> fake_generator_inject.exs
node = :"ezagent_runtime@127.0.0.1"

code = ~S"""
require Logger

fake = fn %URI{} = session_uri, text ->
  Logger.warning(
    "[E2E-SEAM-FAKE-GENERATOR] invoked: session=#{URI.to_string(session_uri)} text=#{inspect(text)}"
  )

  Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
    spec = %{
      "type" => "Card",
      "props" => %{"title" => "DealScout 线索页（seam 代跑生成）", "maxWidth" => "42rem", "centered" => true},
      "children" => [
        %{"type" => "Heading", "props" => %{"text" => "爬取→自动刷新触发成功", "level" => 2}, "children" => []},
        %{"type" => "Text", "props" => %{"text" => "触发指令：#{text}"}, "children" => []},
        %{
          "type" => "Alert",
          "props" => %{
            "title" => "e2e seam 说明",
            "message" =>
              "本页由 fake generator 代跑 LLM 生成段（env 无 HELLO_LLM_API_KEY，gap ⑨）；" <>
                "信号→dispatch→ALT handler→生成入口→TurnDriver→Surface 链路全为真。",
            "type" => "info"
          },
          "children" => []
        }
      ]
    }

    {:ok, _} = EzagentPluginHello.Spec.validate(spec)
    result = EzagentPluginHello.TurnDriver.drive(session_uri, spec, "（seam）已根据新线索刷新页面")
    Logger.warning("[E2E-SEAM-FAKE-GENERATOR] TurnDriver.drive result: #{inspect(result)}")
  end)
end

Application.put_env(:ezagent_plugin_dealscout, :page_refresh_fun, fake)
{:injected, Application.get_env(:ezagent_plugin_dealscout, :page_refresh_fun) == fake}
"""

case :erpc.call(node, Code, :eval_string, [code, []], 30_000) do
  {result, _} -> IO.inspect(result, label: "inject")
  other -> IO.inspect(other, label: "unexpected")
end
