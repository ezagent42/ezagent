defmodule EzagentPluginLoom.DeepSeek do
  @moduledoc """
  Shared DeepSeek chat-completion client for the Loom plugin (loom
  v0.2). The orchestrator (`Ezagent.Behavior.LoomOrchestrator`, G-D) and
  workers (`Ezagent.Behavior.LoomWorker`, G-E) reuse this SAME HTTP shell
  — per PRD §5.5 "复用 `deepseek()` 壳".

  Uses `:httpc` (the plugin declares `:inets`/`:ssl` in `mix.exs`);
  `DEEPSEEK_KEY` env var on the phx.server process (never hard-coded).
  Non-streaming (`stream: false`) — v0.2 pushes whole messages, no token
  streaming (PRD §8).

  Single shell for the whole plugin: `Ezagent.Behavior.Loom` (`:say` /
  `:receive`), `LoomOrchestrator` (dispatch + compose), and `LoomWorker`
  all call `chat/2` here — no duplicate `:httpc` copies.
  """

  @api_url "https://api.deepseek.com/chat/completions"
  @model "deepseek-v4-flash"
  @timeout_ms 60_000
  @connect_timeout_ms 10_000

  @doc """
  单次 `chat/2` 的墙钟上界(ms):连接超时 + 请求超时。DeepSeek 壳是单发非流式
  HTTP、无重试,所以上界就是 `connect_timeout + timeout`。与
  `EzagentPluginLoom.ClaudeCode.max_run_ms/1` 对齐(经 `EzagentPluginLoom.LLM`
  分发),供 loom 编排器推导 dead-worker 兜底超时。`opts` 为兼容签名而接受、暂忽略。
  """
  @spec max_run_ms(keyword()) :: pos_integer()
  def max_run_ms(_opts \\ []), do: @connect_timeout_ms + @timeout_ms

  @doc """
  Call DeepSeek chat completions (non-streaming).

  `messages` is the full `[%{"role" => _, "content" => _}]` list. Opts:
  - `:temperature` — float (omitted when nil)
  - `:thinking_disabled` — bool (adds `thinking: %{type: "disabled"}`)

  Returns `{:ok, content_string}` (trimmed) or `{:error, reason}`.
  """
  @spec chat([map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    case api_key() do
      nil ->
        {:error, :no_api_key}

      key ->
        body =
          %{model: @model, stream: false, messages: messages}
          |> maybe_put(:temperature, Keyword.get(opts, :temperature))
          |> maybe_thinking(Keyword.get(opts, :thinking_disabled, false))
          |> Jason.encode!()

        headers = [
          {~c"authorization", String.to_charlist("Bearer " <> key)},
          {~c"content-type", ~c"application/json"},
          {~c"accept", ~c"application/json"}
        ]

        request = {String.to_charlist(@api_url), headers, ~c"application/json", body}
        http_opts = [{:timeout, @timeout_ms}, {:connect_timeout, @connect_timeout_ms}]

        case :httpc.request(:post, request, http_opts, body_format: :binary) do
          {:ok, {{_, status, _}, _h, resp}} when status >= 200 and status < 300 ->
            decode_reply(resp)

          {:ok, {{_, status, _}, _h, resp}} ->
            {:error, {:http, status, truncate(resp, 240)}}

          {:error, reason} ->
            {:error, {:transport, reason}}
        end
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
  defp maybe_thinking(map, true), do: Map.put(map, :thinking, %{type: "disabled"})
  defp maybe_thinking(map, _), do: map

  defp decode_reply(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}}
      when is_binary(content) ->
        {:ok, String.trim(content)}

      {:ok, other} ->
        {:error, {:decode, {:unexpected_shape, other}}}

      {:error, reason} ->
        {:error, {:decode, reason}}
    end
  end

  defp api_key do
    case System.get_env("DEEPSEEK_KEY") do
      k when is_binary(k) and k != "" -> k
      _ -> nil
    end
  end

  defp truncate(b, n) when is_binary(b),
    do: if(byte_size(b) > n, do: binary_part(b, 0, n) <> "...", else: b)

  defp truncate(other, _), do: inspect(other)
end
