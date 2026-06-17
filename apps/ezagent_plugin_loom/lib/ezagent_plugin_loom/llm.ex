defmodule EzagentPluginLoom.LLM do
  @moduledoc """
  Loom LLM client — 对齐 socialware 现成约定,**不自造 HTTP 客户端、不用 anthropic 命名**。

  两条 flavor(对应现成 `Ezagent.AgentFlavorRegistry` 里的 `cc` / `curl`):

  - **`:cc`(默认)** — 本地 `claude` 二进制(headless `-p`),跟随本地登录态,**无需任何 key**。
  - **`:curl`** — provider HTTP 调用(设 `LOOM_LLM_FLAVOR=curl` 启用),**复用
    `Ezagent.PluginCurlAgent.ApiClient`**(OpenAI/DeepSeek-shape `/chat/completions`,跟 curl_agent
    共用一份客户端,不重复造)。配置按 **provider 语义**(同 `curl.agent` template):
      - `provider` — `opts[:provider]` > env `LOOM_LLM_PROVIDER` > `"deepseek"`
      - `api_url`  — `opts[:api_url]` > env `LOOM_LLM_API_URL` > provider 默认端点
      - `model`    — `opts[:model]` > env `LOOM_LLM_MODEL` > provider 默认 model
      - **API key** — env `<PROVIDER>_API_KEY`(如 `DEEPSEEK_API_KEY`),**只在用该 provider 时取该 provider 的 key**

  > ⚠️ 凭证只到「provider-named env」这层。绑定到 socialware **durable 凭证级联**
  > (`Ezagent.Credential.Resolver` + agent `:api_keys` slice)是 **agent-scoped** 的
  > (resolver 必须 `agent_uri`/`owner_uri`/grant),loom 编排器不是 agent →
  > 该绑定随真实 agent-Kind 落地(预留清单项 3),不在本层硬塞。
  """

  require Logger

  alias Ezagent.PluginCurlAgent.ApiClient

  @default_provider "deepseek"
  @timeout_ms 120_000

  # provider → {默认 /chat/completions 端点, 默认 model}。DeepSeek 是 OpenAI-shape,
  # 同 `Ezagent.PluginCurlAgent.ApiClient` 的 moduledoc 约定。
  @provider_defaults %{
    "deepseek" => {"https://api.deepseek.com/chat/completions", "deepseek-chat"},
    "openai" => {"https://api.openai.com/v1/chat/completions", "gpt-4o-mini"}
  }

  @type message :: %{role: String.t(), content: String.t()}

  @doc """
  调一轮 chat。`messages` = `[%{role: "user"|"assistant", content: "..."}]`;
  `opts`: `:system`、`:provider`、`:api_url`、`:model`、`:flavor`、`:role`、`:session_uri`。
  返回 `{:ok, text}` | `{:error, reason}`。
  """
  @spec chat([message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    case flavor(opts) do
      :cc -> chat_cc(messages, opts)
      _ -> chat_curl(messages, opts)
    end
  end

  # flavor:opts[:flavor] > env LOOM_LLM_FLAVOR > **:cc(默认,本地 claude,无需 key)**。
  # 设 LOOM_LLM_FLAVOR=curl 切到 DeepSeek(需 DEEPSEEK_API_KEY)。对应 AgentFlavorRegistry
  # 的 cc/curl;完整「走真实 flavor agent」是预留项 3。
  defp flavor(opts) do
    case opts[:flavor] || System.get_env("LOOM_LLM_FLAVOR") do
      :curl -> :curl
      "curl" -> :curl
      _ -> :cc
    end
  end

  # ── curl flavor:复用 curl_agent 的 ApiClient,provider 语义命名 ──────────────
  defp chat_curl(messages, opts) do
    provider = provider(opts)
    {default_url, default_model} = Map.get(@provider_defaults, provider, {nil, nil})
    api_url = opts[:api_url] || System.get_env("LOOM_LLM_API_URL") || default_url
    model = opts[:model] || System.get_env("LOOM_LLM_MODEL") || default_model

    with {:ok, key} <- api_key(provider),
         :ok <- require_url(api_url) do
      # 注:ApiClient 当前不透传 max_tokens(只 model/messages/stream),故不在 req 里塞无效字段。
      req = %{
        api_url: api_url,
        api_key: key,
        model: model,
        messages: openai_messages(messages, opts[:system]),
        timeout_ms: @timeout_ms
      }

      case ApiClient.chat_completion(req) do
        {:ok, %{content: text, usage: usage}} ->
          emit_telemetry(usage, model, opts)
          {:ok, text}

        {:error, _reason} = err ->
          err
      end
    end
  end

  defp provider(opts) do
    (opts[:provider] || System.get_env("LOOM_LLM_PROVIDER") || @default_provider)
    |> to_string()
    |> String.downcase()
  end

  # API key 按 provider 命名读:DEEPSEEK_API_KEY / OPENAI_API_KEY ...
  # **只在用该 provider 时取该 provider 的 key**(回应「命名应反映 provider」)。
  defp api_key(provider) do
    env = "#{String.upcase(provider)}_API_KEY"

    case System.get_env(env) do
      nil -> {:error, {:no_api_key, env}}
      "" -> {:error, {:no_api_key, env}}
      key -> {:ok, key}
    end
  end

  defp require_url(url) when is_binary(url) and url != "", do: :ok
  defp require_url(_), do: {:error, :no_api_url}

  # 把 loom 内部 `[%{role, content}]` + 可选 system 提示转成 OpenAI messages
  # (system 作为 role: "system" 首条;ApiClient 用的就是 OpenAI shape)。
  defp openai_messages(messages, nil), do: Enum.map(messages, &normalize_msg/1)

  defp openai_messages(messages, system) when is_binary(system) do
    [%{role: "system", content: system} | Enum.map(messages, &normalize_msg/1)]
  end

  defp normalize_msg(%{role: r, content: c}), do: %{role: to_string(r), content: c}

  # ── cc flavor:本地 claude 二进制(one-shot;PTY 常驻随项 3) ──────────────────
  defp chat_cc(messages, opts) do
    case System.find_executable("claude") do
      nil ->
        {:error, :no_claude_binary}

      bin ->
        prompt = Enum.map_join(messages, "\n", &"#{&1.role}: #{&1.content}")

        args =
          [
            "-p",
            prompt,
            "--output-format",
            "json",
            "--max-turns",
            "6",
            "--exclude-dynamic-system-prompt-sections"
          ]
          |> then(fn a ->
            if opts[:system], do: a ++ ["--system-prompt", opts[:system]], else: a
          end)

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

  # stats → telemetry(文档清单 A)。ApiClient usage = %{prompt, completion, total};
  # 映射到 loom 既有事件的 input_tokens/output_tokens。
  defp emit_telemetry(usage, model, opts) when is_map(usage) do
    :telemetry.execute(
      [:ezagent, :loom, :llm, :call],
      %{
        input_tokens: Map.get(usage, :prompt, 0),
        output_tokens: Map.get(usage, :completion, 0)
      },
      %{model: model, role: opts[:role], session: opts[:session_uri], flavor: :curl}
    )
  rescue
    _ -> :ok
  end

  defp emit_telemetry(_, _, _), do: :ok
end
