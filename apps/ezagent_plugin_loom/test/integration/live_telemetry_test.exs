defmodule EzagentPluginLoom.Integration.LiveTelemetryTest do
  @moduledoc """
  LIVE: stats → telemetry(文档清单 A)。每次成功 LLM 调用 emit
  `[:ezagent, :loom, :llm, :call]` 携带 token 用量 —— 替代旧 loom_stats.json,
  数据走 ezagent telemetry、不进 customer feed。

  需 `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY`,默认排除(`:live`)。
  """
  use ExUnit.Case, async: false
  @moduletag :live
  @moduletag timeout: 120_000

  alias EzagentPluginLoom.LLM

  test "a successful LLM call emits an [:ezagent, :loom, :llm, :call] telemetry event" do
    handler = "loom-telemetry-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ezagent, :loom, :llm, :call],
        fn _event, measurements, metadata, _cfg ->
          send(test_pid, {:llm_telemetry, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _text} =
             LLM.chat([%{role: "user", content: "reply with: OK"}], role: "test", max_tokens: 20)

    assert_receive {:llm_telemetry, measurements, metadata}, 60_000
    assert is_integer(measurements.input_tokens) and measurements.input_tokens > 0
    assert is_integer(measurements.output_tokens)
    assert metadata.role == "test"
  end
end
