defmodule EzagentPluginLoom.LLM do
  @moduledoc """
  Loom LLM 后端分发层 —— 在 **本地 Claude Code**(`EzagentPluginLoom.ClaudeCode`)
  与 **DeepSeek HTTP**(`EzagentPluginLoom.DeepSeek`)之间二选一。

  后端由 **boot 时**的 app env `:llm_backend` 决定(`config/runtime.exs` 从
  `LOOM_LLM_BACKEND` 环境变量读取,默认 `:claude_code`)。**不是运行时热切换**:
  改 `.env`(或 `export LOOM_LLM_BACKEND=deepseek|claude_code`)后**重启 phx.server**
  才生效 —— "启动前切换"。

  两个后端 `chat/2` 签名一致(`{:ok, content} | {:error, reason}`),所以 behavior
  层只认 `LLM.chat/2`,不必知道底下是谁。CC 独有的两个钮在这里桥接:
  - `stop/1` —— 中断在跑的 `claude` 子进程;DeepSeek 是单发 HTTP 无持久进程,no-op。
  - `max_run_ms/1` —— 单次调用墙钟上界(orchestrator 用来推 dead-worker 兜底超时);
    DeepSeek 走自己的 HTTP 超时常数。
  """

  @type messages :: [map()]
  @type backend :: :claude_code | :deepseek

  @doc "当前生效的后端(boot 时由 `LOOM_LLM_BACKEND` 决定,默认 `:claude_code`)。"
  @spec backend() :: backend()
  def backend do
    case Application.get_env(:ezagent_plugin_loom, :llm_backend, :claude_code) do
      :deepseek -> :deepseek
      _ -> :claude_code
    end
  end

  @doc "出一条补全。委托给当前后端,签名与两个后端的 `chat/2` 完全一致。"
  @spec chat(messages(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    impl().chat(messages, opts)
  end

  @doc "单次 `chat/2` 的墙钟上界(ms);orchestrator 用它推导 dead-worker 兜底超时。"
  @spec max_run_ms(keyword()) :: pos_integer()
  def max_run_ms(opts \\ []) do
    impl().max_run_ms(opts)
  end

  @doc "中断某 group(通常=session 字符串)下在跑的调用。DeepSeek 无持久进程 → no-op。"
  @spec stop(String.t()) :: :ok
  def stop(group) do
    case backend() do
      :claude_code -> EzagentPluginLoom.ClaudeCode.stop(group)
      :deepseek -> :ok
    end
  end

  defp impl do
    case backend() do
      :deepseek -> EzagentPluginLoom.DeepSeek
      :claude_code -> EzagentPluginLoom.ClaudeCode
    end
  end
end
