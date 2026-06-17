defmodule EzagentPluginLoom.Integration.DashboardTest do
  @moduledoc "Dashboard 后端:telemetry 聚合 + materials/knowledge 摘要(operator UI 见前端阶段)。"
  use EzagentCore.DataCase, async: false

  alias EzagentPluginLoom.{Dashboard, Knowledge, Materials, Stats}

  test "summary aggregates llm telemetry, materials, and knowledge" do
    session_uri = Ezagent.URI.session("loom-dash-#{System.unique_integer([:positive])}", :loom, "main")

    # 模拟两次 LLM 调用的 telemetry(经 Stats handler 累计)
    :telemetry.execute([:ezagent, :loom, :llm, :call], %{input_tokens: 100, output_tokens: 20}, %{
      session: session_uri,
      role: "orchestrator"
    })

    :telemetry.execute([:ezagent, :loom, :llm, :call], %{input_tokens: 50, output_tokens: 10}, %{
      session: session_uri,
      role: "worker"
    })

    # 素材 + 知识
    Materials.register(session_uri, Ezagent.URI.new!("resource://uploads/ws/x-a.png"), "a.png")
    Knowledge.put(session_uri, "知识库内容")

    # Stats 累计(handler 同步执行,但稳妥起见轮询)
    assert eventually(fn -> Stats.get(session_uri).calls == 2 end)

    summary = Dashboard.summary(session_uri)
    assert summary.tokens.input == 150
    assert summary.tokens.output == 30
    assert summary.tokens.total == 180
    assert summary.calls == 2
    assert summary.materials == 1
    assert summary.knowledge_bytes == byte_size("知识库内容")
  end

  defp eventually(fun, n \\ 50)
  defp eventually(_f, 0), do: false
  defp eventually(f, n), do: if(f.(), do: true, else: (Process.sleep(20); eventually(f, n - 1)))
end
