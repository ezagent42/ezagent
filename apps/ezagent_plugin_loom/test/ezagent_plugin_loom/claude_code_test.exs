defmodule EzagentPluginLoom.ClaudeCodeTest do
  @moduledoc """
  单元测试 `EzagentPluginLoom.ClaudeCode` 里**不依赖真实 `claude` 二进制**的纯逻辑:
  中断派发(`stop/1`)与墙钟上界推导(`max_run_ms/1`)。

  `chat/2` 的真实 round-trip(spawn `claude -p` → JSON → `.result`)由 live e2e
  覆盖,不在这里(无二进制、不确定)。`stop/1` 的核心可测部分是**派发语义**:给同
  group 的在跑收集进程发 `:stop_requested`、不误伤其它 group —— SIGINT 本身
  (`:exec.kill/2`)需要真 os_pid,不在单测范围。
  """
  use ExUnit.Case, async: false

  alias EzagentPluginLoom.ClaudeCode

  # `stop/1` 内部用的 ETS 运行注册表(public named):{os_pid, group, collector_pid}。
  @runs_table :ezagent_loom_claude_runs

  # 确保注册表已建好(stop/1 对非空 group 会 ensure_registry),再让测试直接插桩。
  defp ensure_table, do: ClaudeCode.stop("__warmup__")

  describe "stop/1 guards" do
    test "空字符串 / nil → :ok 且不崩(无 group 可中断)" do
      assert ClaudeCode.stop("") == :ok
      assert ClaudeCode.stop(nil) == :ok
    end

    test "未知 group → :ok(没有匹配的在跑,什么也不发)" do
      ensure_table()
      assert ClaudeCode.stop("group-with-no-runs") == :ok
    end
  end

  describe "stop/1 中断派发" do
    test "给同 group 的在跑收集进程发 :stop_requested" do
      ensure_table()
      group = "session://system/run/s_stop_#{System.unique_integer([:positive])}"
      :ets.insert(@runs_table, {111, group, self()})

      assert ClaudeCode.stop(group) == :ok
      assert_receive :stop_requested, 200
    end

    test "同 group 多个在跑 → 全部收到 :stop_requested" do
      ensure_table()
      group = "session://system/run/s_multi_#{System.unique_integer([:positive])}"
      parent = self()
      c1 = spawn(fn -> relay(parent, :c1) end)
      c2 = spawn(fn -> relay(parent, :c2) end)
      :ets.insert(@runs_table, {201, group, c1})
      :ets.insert(@runs_table, {202, group, c2})

      assert ClaudeCode.stop(group) == :ok
      assert_receive {:got, :c1, :stop_requested}, 200
      assert_receive {:got, :c2, :stop_requested}, 200
    end

    test "group 隔离:只中断目标 group,不误伤其它 group 的在跑" do
      ensure_table()
      target = "session://system/run/s_target_#{System.unique_integer([:positive])}"
      other = "session://system/run/s_other_#{System.unique_integer([:positive])}"
      parent = self()
      other_collector = spawn(fn -> relay(parent, :other) end)
      :ets.insert(@runs_table, {301, target, self()})
      :ets.insert(@runs_table, {302, other, other_collector})

      assert ClaudeCode.stop(target) == :ok
      assert_receive :stop_requested, 200
      # 另一 group 的收集进程不应收到中断。
      refute_receive {:got, :other, :stop_requested}, 100
    end
  end

  describe "max_run_ms/1" do
    test "默认(attempts=2)= hard_cap*2 + backoff*1" do
      # @hard_cap_ms 600_000, @retry_backoff_ms 3_000, @max_attempts 2
      assert ClaudeCode.max_run_ms() == 600_000 * 2 + 3_000
    end

    test "attempts=1 → 单次 hard cap,无退避项" do
      assert ClaudeCode.max_run_ms(attempts: 1) == 600_000
    end

    test "随 attempts 单调递增(编排器 dead-worker 兜底据此推导等待上界)" do
      assert ClaudeCode.max_run_ms(attempts: 3) > ClaudeCode.max_run_ms(attempts: 2)
    end
  end

  # 转发收到的中断信号给测试进程,带上自己的标签,用于多进程/隔离断言。
  defp relay(parent, tag) do
    receive do
      msg -> send(parent, {:got, tag, msg})
    end
  end
end
