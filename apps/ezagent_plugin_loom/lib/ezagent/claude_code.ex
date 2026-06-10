defmodule EzagentPluginLoom.ClaudeCode do
  @moduledoc """
  本地 Claude Code 聊天补全客户端 —— loom 插件的 LLM 壳，替代
  `EzagentPluginLoom.DeepSeek`(后者保留但不再被调用)。

  跟 DeepSeek 壳 **完全同签名**(`chat/2` → `{:ok, content}` | `{:error, reason}`),
  这样 `Loom` / `LoomWorker` / `LoomOrchestrator` / `LoomMetaAgent` 四个
  Behavior 只需把 `DeepSeek.chat` 换成 `ClaudeCode.chat`,其余逻辑不动。

  ## 调用方式

  调本地 `claude` 二进制的 **headless 打印模式**(2026-06-01 实测 v2.1.160):

      claude -p <prompt> --output-format json --max-turns 6 \
        --setting-sources "" --strict-mcp-config \
        --exclude-dynamic-system-prompt-sections --system-prompt <sys+别用工具指令>

  - `--output-format json` → stdout 是单个 JSON 对象,取 `.result`、看 `.is_error`。
  - `--system-prompt` **覆盖** claude 默认系统提示,让它当纯响应器;`build/1` 还会追加
    `@no_tools_directive`("别调工具/读写文件,直接写在回复里")降低工具尝试概率。
  - `--max-turns 6`:headless 下 claude 仍会"尝试"调内置工具(占一回合,随后被自动
    拒绝),`--allowedTools`/`--disallowedTools`/`--permission-mode` 都挡不住"尝试"
    (只管执行)。回合给够让它从拒绝里恢复成文本,避免 `error_max_turns`(2026-06-02 实测)。
  - **隔离 flag(2026-06-02 —— 修 loom 串戏)**:默认 `claude -p` 会加载运行用户的
    全局 `~/.claude/CLAUDE.md`(个人开发偏好)+ MCP + settings,污染回答(loom 会
    跑偏去答开发相关内容)。`--setting-sources ""`(不加载 user/project 设置 +
    CLAUDE.md 记忆)+ `--strict-mcp-config`(禁用全部 MCP)+
    `--exclude-dynamic-system-prompt-sections`(去 cwd/env/git 段)把它降级成
    干净 LLM。登录态来自默认 config 目录的 `.credentials.json`,不受影响。
  - **不传 `--model`**:跟随本地 claude 当前登录/配置的默认模型(2026-06-01 决策)。
  - **auth**:用本地 claude code 自己的登录态(订阅/login),**不再需要 `DEEPSEEK_KEY`**。
  - 输出可能被 ```json 代码块包裹 —— loom 的 `Span.extract_first_json_object/1`
    会自动剥 fence,无需在此处理。

  `-p` 模式不需要 PTY(实测管道运行即可)。

  ## 进程管理 + 空闲超时(erlexec 异步流式)

  用 `:exec.run/2`(项目唯一 OS-process 库)**异步**读 `stream-json` 事件流:
  - **不设总超时**(那会误杀慢/长思考 model)。`collect_stream` 的 `receive ... after
    idle` 在**收到任意 stdout/stderr 事件时重置** → 只有"完全静默 @idle_timeout_ms"
    才判 `:stalled`(真卡死)kill。claude 工作时 thinking/正文 token 每 <3s 一个事件,
    所以慢/长思考永不误超时。
  - 完成信号来自流里的 `{"type":"result"}` 事件(**不依赖 `:DOWN`** —— 实测异步退出
    通知不可靠);收到即解析返回。
  - 整个收集放进 `Task.async`,外层只用 `@hard_cap_ms` 作绝对兜底(防极端不结束);
    Task 隔离阻塞,不冻结调用方(Kind GenServer)mailbox。
  - BEAM 死 → exec-port 自动 reap 子进程;拿到 result / stalled 后 `:exec.stop` 清理。
  """

  require Logger

  # 不用"总超时"(那会误杀慢/长思考的 model)。改用**空闲超时**:claude 工作时
  # stream-json 事件持续(thinking_tokens / 正文 token 实测每 <3s 一个),只有
  # **完全静默 @idle_timeout_ms** 才判卡死。慢 model / 长思考永不误超时。
  # opts `:idle_timeout_ms` 可覆盖。
  @idle_timeout_ms 90_000

  # 单次调用的**绝对兜底上限**(防极端不结束 / 流永不收尾)。正常由 idle / result
  # 事件提前结束;这个只在异常时兜底。orchestrator 用 `max_run_ms/0` 推导自己的
  # dead-worker 兜底,所以这是唯一"总时长"旋钮。
  @hard_cap_ms 600_000

  # 临时性错误(Anthropic 过载/限流/5xx)自动重试:总尝试次数 + 退避。
  # 过载是 Anthropic 服务端容量波动(529 Overloaded),不是代码 bug;重试一次
  # 常能成功。退避给服务端一点喘息。opts `:attempts` 可覆盖。
  @max_attempts 2
  @retry_backoff_ms 3_000

  @doc """
  单次 `chat/2` 调用的**绝对墙钟上界**(ms),含重试。

  调用方(如 loom 编排器的 dead-worker 兜底)用它**推导**自己的等待上界,而不是手猜
  一个跟 model 速度赛跑的常数。正常调用由"空闲超时 / result 事件"提前结束,与 model
  多慢无关;这个上界只在 worker 进程真异常(永不结束)时才相关。
  """
  @spec max_run_ms(keyword()) :: pos_integer()
  def max_run_ms(opts \\ []) do
    attempts = Keyword.get(opts, :attempts, @max_attempts)
    @hard_cap_ms * attempts + @retry_backoff_ms * (attempts - 1)
  end

  @doc """
  调本地 Claude Code 出一条补全。

  `messages` 是完整的 `[%{"role" => _, "content" => _}]` 列表(同 DeepSeek 壳):
  - 所有 `"system"` 角色 → 合并成 `--system-prompt`;
  - 其余(`user`/`assistant`)→ 拼成 `-p` 的 prompt(多轮带角色标签)。

  Opts(为兼容 DeepSeek 签名而接受,claude `-p` 不支持的会被忽略):
  - `:idle_timeout_ms` — **空闲**超时(默认 #{@idle_timeout_ms};完全无事件这么久判卡死)
  - `:attempts` — 临时错误重试总次数(默认 #{@max_attempts})
  - `:temperature` / `:thinking_disabled` — **忽略**(claude headless 无对应 flag)

  返回 `{:ok, content_string}`(trimmed)或 `{:error, reason}`。
  """
  @spec chat([map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    case claude_bin() do
      {:error, _} = err ->
        err

      {:ok, bin} ->
        {system, prompt} = build(messages)
        idle = Keyword.get(opts, :idle_timeout_ms, @idle_timeout_ms)
        attempts = Keyword.get(opts, :attempts, @max_attempts)
        # group(通常=session 字符串):用于"停止"——同 group 的在跑 claude 会被
        # `stop/1` 一起中断。nil → 不注册(行为同前)。
        group = opts[:group]
        run_with_retry(bin, prompt, system, idle, attempts, group)
    end
  end

  @runs_table :ezagent_loom_claude_runs

  @doc """
  中断某个 group(通常=session 字符串)下**所有在跑的 claude**:给收集进程发
  `:stop_requested`(它会 SIGINT 子进程并返回 `{:error, :stopped}`)。用户点"停止"
  时由 web_plug 调用。被中断的调用返回 `:stopped` → 上层丢弃,不写文件。
  """
  @spec stop(String.t()) :: :ok
  def stop(group) when is_binary(group) and group != "" do
    ensure_registry()

    @runs_table
    |> :ets.match_object({:_, group, :_})
    |> Enum.each(fn {_os_pid, _group, collector} -> send(collector, :stop_requested) end)

    :ok
  end

  def stop(_), do: :ok

  # ETS 运行注册表(public,幂等创建):{os_pid, group, collector_pid}。
  defp ensure_registry do
    case :ets.whereis(@runs_table) do
      :undefined ->
        try do
          :ets.new(@runs_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end

  defp register_run(nil, _os_pid, _collector), do: :ok

  defp register_run(group, os_pid, collector) do
    ensure_registry()
    :ets.insert(@runs_table, {os_pid, group, collector})
    :ok
  end

  defp deregister_run(nil, _os_pid), do: :ok

  defp deregister_run(_group, os_pid) do
    if :ets.whereis(@runs_table) != :undefined, do: :ets.delete(@runs_table, os_pid)
    :ok
  end

  # --- claude 二进制解析 ----------------------------------------------

  # argv 元素 0 必须是绝对路径(no-shell exec 不走 $PATH 搜索 —— 同 cc 插件
  # build_claude_cmd 的硬化结论)。找不到 → 明确错误,不静默回退 shell。
  defp claude_bin do
    case System.find_executable("claude") do
      nil -> {:error, :claude_not_found}
      path -> {:ok, path}
    end
  end

  # --- messages → (system_prompt, prompt) -----------------------------

  # 全局追加到 system 的工具使用指引(2026-06-02 放开联网):允许 WebFetch / WebSearch
  # 联网查参考资料(配合 build_argv 的 `--allowedTools "WebFetch,WebSearch"` 自动执行);
  # 但不要读/写/编辑本地文件、不要执行命令——最终结果(jsx 等)直接写进回复。
  # 这样既能让它按需取参考,又不会变成乱写文件的编码 agent。
  @tools_directive "（你可以用 WebFetch 抓取网页、WebSearch 搜索来获取参考资料；但不要读/写/编辑本地文件、不要执行 shell 命令——把完整结果（如 jsx 代码块）直接写在你的回复里。）"

  defp build(messages) do
    {sys_msgs, turns} = Enum.split_with(messages, &(role(&1) == "system"))

    system =
      (sys_msgs |> Enum.map(&content/1) |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")) <>
        "\n\n" <> @tools_directive

    prompt = render_prompt(turns)

    {system, prompt}
  end

  defp render_prompt([single]), do: content(single)
  defp render_prompt([]), do: ""

  defp render_prompt(many) do
    Enum.map_join(many, "\n\n", fn m ->
      case role(m) do
        "assistant" -> "[assistant]\n" <> content(m)
        _ -> "[user]\n" <> content(m)
      end
    end)
  end

  defp role(%{"role" => r}), do: to_string(r)
  defp role(%{role: r}), do: to_string(r)
  defp role(_), do: "user"

  defp content(%{"content" => c}), do: to_string(c)
  defp content(%{content: c}), do: to_string(c)
  defp content(_), do: ""

  # --- 执行 -----------------------------------------------------------

  # 临时性错误(Anthropic 过载/限流)自动重试,其它错误直接返回。
  # `:stopped`(用户中止)永不重试。
  defp run_with_retry(bin, prompt, system, idle, attempts, group) do
    case run(bin, prompt, system, idle, group) do
      {:error, reason} when attempts > 1 ->
        if transient?(reason) do
          Logger.warning(
            "ClaudeCode: 临时错误 #{inspect(reason)},#{@retry_backoff_ms}ms 后重试(剩 #{attempts - 1} 次)"
          )

          Process.sleep(@retry_backoff_ms)
          run_with_retry(bin, prompt, system, idle, attempts - 1, group)
        else
          {:error, reason}
        end

      other ->
        other
    end
  end

  # Anthropic 服务端临时性错误 → 值得重试(过载/限流/5xx)。代码类错误不重试。
  defp transient?({:claude_error, msg}) when is_binary(msg) do
    String.contains?(msg, [
      "Overloaded",
      "overloaded",
      "API Error",
      "rate limit",
      "429",
      "503",
      "529"
    ])
  end

  defp transient?({:exit, _status, out}) when is_binary(out) do
    String.contains?(out, ["Overloaded", "overloaded", "rate limit", "529", "503"])
  end

  defp transient?(_), do: false

  # 异步流式跑 claude:不设总超时(慢/长思考 model 不被误杀),只在内部用**空闲
  # 超时**判卡死。外层 Task 仅用 @hard_cap_ms 作绝对兜底(防极端不结束)。
  defp run(bin, prompt, system, idle, group) do
    task = Task.async(fn -> exec_stream(bin, prompt, system, idle, group) end)

    case Task.yield(task, @hard_cap_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :hard_cap}
    end
  end

  # `--output-format stream-json` 异步读 stdout。**任意事件(thinking_tokens /
  # 正文 token / status / ping)到达都重置空闲计时**(`collect_stream` 的 `after`);
  # 见到 `{"type":"result"}` 事件即完成。不依赖 `:DOWN`(实测异步退出通知不可靠) —
  # 完成信号来自 stream 里的 result 事件。
  defp exec_stream(bin, prompt, system, idle, group) do
    ensure_exec_started()

    argv = build_argv(bin, system)

    opts = [
      :stdin,
      :stdout,
      :stderr,
      :monitor,
      {:cd, String.to_charlist(System.tmp_dir!())},
      {:kill_timeout, 3}
    ]

    case :exec.run(argv, opts) do
      {:ok, _pid, os_pid} ->
        # 注册 os_pid + 本收集进程(self),供 stop/1 中断;结束必注销。
        register_run(group, os_pid, self())

        # prompt 走 **stdin**(不再作为 argv)。改页请求会把整页源码(数百 KB)拼进
        # prompt;作为 argv 传会超 erlexec 端口/OS `ARG_MAX` 限制,`:exec.run` 的
        # 30s gen_server.call 超时 → :exec 崩溃(2026-06-09 实测根因)。`claude -p`
        # 无位置参数时从 stdin 读 prompt,大小无上限。写完发 :eof 收口。
        write_stdin(os_pid, prompt)

        try do
          collect_stream(os_pid, "", "", idle, group)
        after
          deregister_run(group, os_pid)
        end

      {:error, reason} ->
        {:error, {:spawn, reason}}
    end
  end

  # 把 prompt 写进子进程 stdin 后发 :eof 关闭(claude 读到 EOF 才开始处理)。
  # erlexec `:exec.send/2`:二进制写入,原子 `:eof` 关 stdin。失败吞掉(子进程
  # 可能已退出)。
  defp write_stdin(os_pid, prompt) when is_binary(prompt) do
    :exec.send(os_pid, prompt)
    :exec.send(os_pid, :eof)
    :ok
  catch
    _, _ -> :ok
  end

  # 收集 NDJSON 事件流。`after idle` 每次收到任意消息都重置 → 只有"完全静默 idle"
  # 才 fire(= 真卡死)。stdout 行里出现 result 事件 → 完成。
  # 2026-06-09:每个 stdout chunk 里的 partial-message token(text/thinking delta)
  # 抽出来**广播到进度 topic**(group=session 字符串),供编辑页实时显示 v0 生成过程。
  defp collect_stream(os_pid, buf, errbuf, idle, group) do
    receive do
      # 用户中止(stop/1 发来):SIGINT 子进程 + 立即返回 :stopped,上层据此丢弃。
      :stop_requested ->
        interrupt(os_pid)
        {:error, :stopped}

      {:stdout, ^os_pid, chunk} ->
        {lines, rest} = split_lines(buf <> chunk)
        publish_progress(group, extract_progress(lines))

        case scan_result(lines) do
          {:done, result} ->
            safe_stop(os_pid)
            result

          :continue ->
            collect_stream(os_pid, rest, errbuf, idle, group)
        end

      {:stderr, ^os_pid, chunk} ->
        # stderr 也算"活着";留尾部供报错。
        collect_stream(os_pid, buf, truncate(errbuf <> chunk, 500), idle, group)

      {:DOWN, ^os_pid, :process, _pid, _reason} ->
        # 进程退出且 stdout 分支没截到 result → 最后再扫一遍 buf,否则报错。
        finalize(buf, errbuf)
    after
      idle ->
        safe_stop(os_pid)
        {:error, :stalled}
    end
  end

  # 进度广播(**出站观测**,非 Kind 间分发):把 v0 流式 token 推给本 session 的进度
  # topic;编辑页 SSE 订阅它实时显示。group=nil(无 session)→ 不广播。
  defp publish_progress(nil, _text), do: :ok
  defp publish_progress(_group, ""), do: :ok

  defp publish_progress(group, text) when is_binary(group) and is_binary(text) do
    # 诊断:每次生成只打一次(collector 是 per-run 进程,进程字典 flag 即可)。
    unless Process.get(:loom_progress_logged) do
      Process.put(:loom_progress_logged, true)
      Logger.info("[loom] gen progress streaming → #{group} (first #{byte_size(text)}B)")
    end

    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      "loom:gen_progress:" <> group,
      {:loom_gen_progress, text}
    )
  catch
    _, _ -> :ok
  end

  # 从完整 NDJSON 行里抽 partial-message 的增量文本(正文 text_delta + 思考
  # thinking_delta),按出现顺序拼接。没有则空串。
  defp extract_progress(lines) do
    lines
    |> Enum.map(&progress_text_of/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("")
  end

  defp progress_text_of(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"type" => "stream_event", "event" => %{"delta" => %{"text" => t}}}}
      when is_binary(t) ->
        t

      {:ok, %{"type" => "stream_event", "event" => %{"delta" => %{"thinking" => t}}}}
      when is_binary(t) ->
        t

      _ ->
        ""
    end
  end

  # 在已完整的行里找 stream-json 的 result 事件;找到 → {:done, decode结果}。
  defp scan_result(lines) do
    Enum.reduce_while(lines, :continue, fn line, _acc ->
      case result_event(line) do
        nil -> {:cont, :continue}
        obj -> {:halt, {:done, decode_result(obj)}}
      end
    end)
  end

  defp result_event(line) do
    case String.trim(line) do
      "" ->
        nil

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, %{"type" => "result"} = obj} -> obj
          _ -> nil
        end
    end
  end

  # stream-json 的 result 事件 → {:ok, text} | {:error, reason}。
  defp decode_result(%{"is_error" => false, "result" => result}) when is_binary(result),
    do: {:ok, String.trim(result)}

  defp decode_result(%{"is_error" => true} = m),
    # 优先 `result`(如 "API Error: Overloaded")—— `subtype` 常是无信息量的 "success"。
    do: {:error, {:claude_error, m["result"] || m["subtype"]}}

  defp decode_result(other),
    do: {:error, {:decode, {:unexpected_shape, other}}}

  defp finalize(buf, errbuf) do
    {lines, last} = split_lines(buf)

    case scan_result(lines ++ [last]) do
      {:done, result} -> result
      :continue -> {:error, {:no_result, truncate(errbuf, 240)}}
    end
  end

  # 按 \n 切:返回 {完整行列表, 未完成残段}。
  defp split_lines(s) do
    case String.split(s, "\n") do
      [only] -> {[], only}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp safe_stop(os_pid) do
    :exec.stop(os_pid)
  catch
    _, _ -> :ok
  end

  # 用户中止:发 SIGINT(中断,比 SIGKILL 温和),让 claude 自己收尾退出。
  # 我们本就丢弃这次结果,所以拿不到干净部分结果也无所谓。
  defp interrupt(os_pid) do
    :exec.kill(os_pid, 2)
  catch
    _, _ -> :ok
  end

  # argv 用 charlist 列表(no-shell exec)。**prompt 不在 argv 里**——它走 stdin
  # (见 exec_stream/write_stdin):改页 prompt 含整页源码可达数百 KB,作为 argv 会
  # 超 ARG_MAX/erlexec 端口限制致 :exec 崩溃。`claude -p` 无位置参数 ⇒ 读 stdin。
  # 空 system 时不传 --system-prompt(避免 claude 对空串报错)。
  #
  # 隔离 flag(2026-06-02 —— 修 loom"串戏"回答开发内容的 bug):loom 要的是
  # 纯 LLM,不是带用户环境的编码 agent。默认 `claude -p` 会加载运行用户的全局
  # `~/.claude/CLAUDE.md`(个人开发偏好)+ MCP + settings,污染回答。下面三个
  # flag 把它降级成干净 LLM(登录态来自默认 config 目录的 .credentials.json,
  # 不受影响):
  #   --setting-sources ""              不加载 user/project 设置 + CLAUDE.md 记忆
  #   --strict-mcp-config               不加 --mcp-config ⇒ 禁用所有 MCP server
  #   --exclude-dynamic-system-prompt-sections  去掉 cwd/env/memory/git 等机器相关段
  #
  # --max-turns 6(2026-06-02 实测修 error_max_turns):headless `-p` 下 claude
  # 仍会"尝试"调内置工具(占一个回合,然后被 headless 自动拒绝);`--allowedTools ""`
  # / `--disallowedTools` / `--permission-mode plan` 都**挡不住"尝试"**(只管执行,
  # 不管尝试)。`--max-turns 1` 下尝试一次就没回合 → error_max_turns。给到 6 个回合
  # 让它从拒绝里恢复成文本输出(配合系统提示里的 @no_tools_directive,绝大多数情况
  # 1 回合就出文本,6 只是兜底)。
  defp build_argv(bin, system) do
    base = [
      String.to_charlist(bin),
      ~c"-p",
      # stream-json + partial messages:边生成边吐事件(thinking/正文 token),
      # 作为"活性"信号驱动空闲超时;stream-json 需要 --verbose。
      ~c"--output-format",
      ~c"stream-json",
      ~c"--include-partial-messages",
      ~c"--verbose",
      ~c"--max-turns",
      ~c"6",
      # 放开联网(2026-06-02):白名单 WebFetch/WebSearch + Skill → headless 下
      # **自动执行**(不弹权限、不被拒)。Skill 让模型能调用下面 --plugin-dir 挂上的
      # 设计 skill。其余工具(Bash/Write/…)不在白名单 → 仍被自动拒绝,靠 --max-turns
      # 6 从拒绝里恢复成文本。
      ~c"--allowedTools",
      ~c"WebFetch,WebSearch,Skill",
      ~c"--setting-sources",
      ~c"",
      ~c"--strict-mcp-config",
      ~c"--exclude-dynamic-system-prompt-sections"
    ]

    base = base ++ skill_plugin_args()

    if system == "" do
      base
    else
      base ++ [~c"--system-prompt", String.to_charlist(system)]
    end
  end

  # 把 `~/.ezagent/<profile>/claude-skills/` 下每个 plugin 目录(含 .claude-plugin/)
  # 用 `--plugin-dir` 挂上 —— 加载设计 skill 而**不**动 --setting-sources(不引入
  # 用户全局 CLAUDE.md 污染)。skill 根不存在 / 为空 → 返回 []。
  defp skill_plugin_args do
    root = Ezagent.Home.path("claude-skills")

    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?(Path.join(&1, ".claude-plugin")))
        |> Enum.flat_map(fn dir -> [~c"--plugin-dir", String.to_charlist(dir)] end)

      _ ->
        []
    end
  end

  # --- erlexec 起停 ---------------------------------------------------

  defp ensure_exec_started do
    case :exec.start() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp truncate(b, n) when is_binary(b),
    do: if(byte_size(b) > n, do: binary_part(b, 0, n) <> "...", else: b)

  defp truncate(other, _), do: inspect(other)
end
