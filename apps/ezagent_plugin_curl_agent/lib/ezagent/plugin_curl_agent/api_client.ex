defmodule Ezagent.PluginCurlAgent.ApiClient do
  @moduledoc """
  Tiny OpenAI-compatible chat completion client.

  DeepSeek's API is OpenAI-shape (`POST /chat/completions` with
  `{model, messages, ...}`) so the same client serves both. To add
  a provider with a different schema, branch in
  `Ezagent.ActionSet.CurlAgent` on `:provider`.

  Uses `:httpc` (Erlang stdlib) — same choice as the Feishu plugin
  (Ezagent.PluginFeishu.Client) to avoid adding a top-level HTTP
  client dep. Read-only `:logger` so no telemetry coupling.

  ## Public surface

      ApiClient.chat_completion(%{
        api_url:     "https://api.deepseek.com/chat/completions",
        api_key:     "sk-...",
        model:       "deepseek-chat",
        messages:    [%{role: "system", content: "..."},
                      %{role: "user",   content: "Hi"}],
        timeout_ms:  30_000   # optional, default 30s
      })

  Returns:

      {:ok, %{content: String.t(), usage: %{prompt: int, completion: int, total: int}, raw: map}}
      | {:error, {:http, status :: integer(), body :: String.t()}}
      | {:error, {:transport, term()}}
      | {:error, {:decode, term()}}

  ## What the function does NOT do

  - Streaming (`stream: true`) — chunked decoding adds complexity;
    deferred to a follow-up if Allen wants real-time output in LV.
  - Retry on 429/5xx — caller decides retry policy.
  - Key redaction in errors — caller must scrub before logging.
  """

  require Logger

  @default_timeout_ms 30_000

  @spec chat_completion(map()) ::
          {:ok, %{content: String.t(), usage: map(), raw: map()}}
          | {:error, term()}
  def chat_completion(%{api_url: api_url, api_key: api_key, model: model, messages: messages} = req)
      when is_binary(api_url) and is_binary(api_key) and is_binary(model) and is_list(messages) do
    timeout = Map.get(req, :timeout_ms, @default_timeout_ms)

    body = %{model: model, messages: messages, stream: false} |> Jason.encode!()

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> api_key)},
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"application/json"}
    ]

    request = {String.to_charlist(api_url), headers, ~c"application/json", body}

    http_opts = [
      {:timeout, timeout},
      {:connect_timeout, 10_000}
    ]

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, resp_body}} when status >= 200 and status < 300 ->
        decode_success(resp_body)

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        # Don't log key; log the URL + status + (truncated) body so
        # the operator can debug rate-limit / bad-model / etc.
        Logger.warning(
          "CurlAgent.ApiClient: HTTP #{status} from #{api_url} — " <>
            "body: #{truncate(resp_body, 240)}"
        )

        {:error, {:http, status, to_string(resp_body)}}

      {:error, reason} ->
        Logger.warning("CurlAgent.ApiClient: transport error contacting #{api_url}: #{inspect(reason)}")
        {:error, {:transport, reason}}
    end
  end

  defp decode_success(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]} = raw} ->
        usage =
          case raw["usage"] do
            %{} = u ->
              %{
                prompt: Map.get(u, "prompt_tokens", 0),
                completion: Map.get(u, "completion_tokens", 0),
                total: Map.get(u, "total_tokens", 0)
              }

            _ ->
              %{prompt: 0, completion: 0, total: 0}
          end

        {:ok, %{content: content, usage: usage, raw: raw}}

      {:ok, other} ->
        {:error, {:decode, {:unexpected_shape, other}}}

      {:error, reason} ->
        {:error, {:decode, reason}}
    end
  end

  defp truncate(b, n) when is_binary(b) do
    if byte_size(b) > n, do: binary_part(b, 0, n) <> "...", else: b
  end

  defp truncate(other, _), do: inspect(other)
end
