defmodule EzagentPluginAutoservice.FillerLoop do
  @moduledoc "FillerLoop — periodic soothing messages while waiting for slow cc agent. Phase D."

  use Task

  @default_interval_ms 10_000  # text: 10s
  @default_max_count 3
  @default_timeout_ms 45_000   # cc hard timeout

  @doc "Start a filler loop for a cc agent turn. Sends soothing messages until cc completes or timeout."
  def start(session_uri, fast_agent_uri, opts \\ []) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    max_count = Keyword.get(opts, :max_count, @default_max_count)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    Task.async(fn ->
      filler_loop(session_uri, fast_agent_uri, interval, max_count, timeout)
    end)
  end

  defp filler_loop(session_uri, agent_uri, interval, max, timeout) do
    start_time = System.monotonic_time(:millisecond)

    for i <- 1..max do
      elapsed = System.monotonic_time(:millisecond) - start_time
      if elapsed < timeout do
        Process.sleep(interval)
        send_soothing(session_uri, agent_uri, i)
      end
    end

    :ok
  end

  defp send_soothing(_session_uri, _agent_uri, _n) do
    # In production, this dispatches to the fast agent for a filler message.
    # For MVP: no-op — filler content is TBD after live latency measurement.
    :ok
  end

  @doc "Generate a static apology message when cc times out."
  def timeout_apology do
    "抱歉，查询需要更长时间。请稍候，我们的客服团队将尽快回复您。"
  end
end
