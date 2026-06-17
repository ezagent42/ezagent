defmodule EzagentPluginLoom.LLM do
  @moduledoc """
  Loom LLM client — anthropic-兼容 messages 端点的非流式 HTTP 调用（curl-flavor 路径）。

  端点 + key 从进程环境读(同 cc-flavor 约定),**不硬编码 key**:
  - `ANTHROPIC_BASE_URL`(默认 `https://api.deepseek.com/anthropic`)
  - `ANTHROPIC_API_KEY`(必需,缺失 → `{:error, :no_api_key}`)

  用 stdlib `:httpc`(loom `extra_applications` 声明 `:inets`/`:ssl`),verify_peer + 系统 CA。
  比 `claude -p` 便宜得多(后者每次加载 ~30k context token);loom 编排侧的单次结构化调用走这里。
  """

  require Logger

  @default_base "https://api.deepseek.com/anthropic"
  @default_model "deepseek-chat"
  @default_max_tokens 4096
  @timeout_ms 120_000

  @type message :: %{role: String.t(), content: String.t()}

  @doc """
  调一轮 chat。`messages` = `[%{role: "user"|"assistant", content: "..."}]`;
  `opts`: `:system`(系统提示)、`:model`、`:max_tokens`、`:temperature`。
  返回 `{:ok, text}` | `{:error, reason}`。
  """
  @spec chat([message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    case flavor(opts) do
      :cc -> chat_cc(messages, opts)
      _ -> chat_curl(messages, opts)
    end
  end

  # flavor:opts[:flavor] > env LOOM_LLM_FLAVOR > :curl(默认便宜 HTTP)。
  defp flavor(opts) do
    case opts[:flavor] || System.get_env("LOOM_LLM_FLAVOR") do
      :cc -> :cc
      "cc" -> :cc
      _ -> :curl
    end
  end

  # cc-flavor:用本地 claude 二进制(-p headless),跟随本地登录态/ANTHROPIC env。
  # one-shot(非 PTY 常驻);完整 PTY 常驻 agent 待真实 agent Kind 化(项 3)。
  defp chat_cc(messages, opts) do
    case System.find_executable("claude") do
      nil ->
        {:error, :no_claude_binary}

      bin ->
        prompt = Enum.map_join(messages, "\n", &"#{&1.role}: #{&1.content}")

        args =
          ["-p", prompt, "--output-format", "json", "--max-turns", "6", "--exclude-dynamic-system-prompt-sections"]
          |> then(fn a -> if opts[:system], do: a ++ ["--system-prompt", opts[:system]], else: a end)

        # 不混 stderr(claude 的日志在 stderr;--output-format json 的 stdout 才是纯 JSON)。
        case System.cmd(bin, args, stderr_to_stdout: false) do
          {out, 0} -> parse_cc(out, opts)
          {out, code} -> {:error, {:claude_exit, code, String.slice(out, 0, 200)}}
        end
    end
  end

  defp parse_cc(out, opts) do
    case Jason.decode(out) do
      {:ok, %{"result" => result, "is_error" => false} = j} when is_binary(result) ->
        emit_cc_telemetry(j, opts)
        {:ok, result}

      {:ok, %{"is_error" => true}} ->
        {:error, :claude_error}

      _ ->
        {:error, :bad_cc_output}
    end
  end

  defp emit_cc_telemetry(%{"usage" => usage} = j, opts) when is_map(usage) do
    :telemetry.execute(
      [:ezagent, :loom, :llm, :call],
      %{input_tokens: usage["input_tokens"] || 0, output_tokens: usage["output_tokens"] || 0},
      %{model: j["model"], role: opts[:role], session: opts[:session_uri], flavor: :cc}
    )
  rescue
    _ -> :ok
  end

  defp emit_cc_telemetry(_, _), do: :ok

  defp chat_curl(messages, opts) do
    with {:ok, key} <- api_key() do
      base = System.get_env("ANTHROPIC_BASE_URL") || @default_base
      url = String.to_charlist("#{base}/v1/messages")

      body =
        %{
          model: opts[:model] || @default_model,
          max_tokens: opts[:max_tokens] || @default_max_tokens,
          messages: Enum.map(messages, &%{role: &1.role, content: &1.content})
        }
        |> maybe_put(:system, opts[:system])
        |> maybe_put(:temperature, opts[:temperature])
        |> Jason.encode!()

      headers = [
        {~c"x-api-key", String.to_charlist(key)},
        {~c"anthropic-version", ~c"2023-06-01"}
      ]

      request = {url, headers, ~c"application/json", body}
      http_opts = [ssl: ssl_opts(), timeout: @timeout_ms]

      case :httpc.request(:post, request, http_opts, body_format: :binary) do
        {:ok, {{_v, 200, _r}, _resp_headers, resp_body}} ->
          emit_telemetry(resp_body, opts)
          parse_text(resp_body)

        {:ok, {{_v, status, _r}, _resp_headers, resp_body}} ->
          Logger.warning("loom LLM HTTP #{status}: #{String.slice(to_string(resp_body), 0, 300)}")
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  defp api_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> {:error, :no_api_key}
      "" -> {:error, :no_api_key}
      key -> {:ok, key}
    end
  end

  # stats → telemetry(文档清单 A：emit :telemetry.execute [:ezagent,...] events,
  # 不落旁路 JSON,不进 customer feed)。每次成功 LLM 调用 emit token 用量。
  defp emit_telemetry(resp_body, opts) do
    with {:ok, %{"usage" => usage} = decoded} when is_map(usage) <- Jason.decode(resp_body) do
      :telemetry.execute(
        [:ezagent, :loom, :llm, :call],
        %{
          input_tokens: usage["input_tokens"] || 0,
          output_tokens: usage["output_tokens"] || 0
        },
        %{model: decoded["model"], role: opts[:role], session: opts[:session_uri]}
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp parse_text(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"content" => content}} when is_list(content) ->
        text =
          content
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("", & &1["text"])

        {:ok, text}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, {:bad_json, reason}}
    end
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
