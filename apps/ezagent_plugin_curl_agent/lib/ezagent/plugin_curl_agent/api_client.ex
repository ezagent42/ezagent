defmodule Ezagent.PluginCurlAgent.ApiClient do
  @moduledoc """
  Tiny OpenAI-compatible chat completion client.

  DeepSeek's API is OpenAI-shape (`POST /chat/completions` with
  `{model, messages, ...}`) so the same client serves both. To add
  a provider with a different schema, branch in
  `Ezagent.ActionSet.CurlAgent` on `:provider`.

  Uses the application's existing `Req` client. Read-only `:logger` keeps the
  adapter free of telemetry coupling.

  ## Public surface

      ApiClient.chat_completion(%{
        api_url:     "https://api.deepseek.com/chat/completions",
        api_key:     "sk-...",
        model:       "deepseek-chat",
        messages:    [%{role: "system", content: "..."},
                      %{role: "user",   content: "Hi"}],
        receive_timeout: :infinity  # optional; finite millisecond overrides allowed
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

  @default_receive_timeout :infinity

  @spec chat_completion(map()) ::
          {:ok, %{content: String.t(), usage: map(), raw: map()}}
          | {:error, term()}
  def chat_completion(
        %{api_url: api_url, api_key: api_key, model: model, messages: messages} = req
      )
      when is_binary(api_url) and is_binary(api_key) and is_binary(model) and is_list(messages) do
    body = %{model: model, messages: messages, stream: false}

    opts = [
      json: body,
      headers: [
        {"authorization", "Bearer " <> api_key},
        {"accept", "application/json"}
      ],
      connect_options: [timeout: 10_000],
      receive_timeout: receive_timeout(req),
      retry: false
    ]

    case Req.post(api_url, opts) do
      {:ok, %{status: status, body: resp_body}}
      when status >= 200 and status < 300 ->
        decode_success(resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        # Don't log key; log the URL + status + (truncated) body so
        # the operator can debug rate-limit / bad-model / etc.
        Logger.warning(
          "CurlAgent.ApiClient: HTTP #{status} from #{api_url} — " <>
            "body: #{truncate(resp_body, 240)}"
        )

        {:error, {:http, status, to_string(resp_body)}}

      {:error, %{__struct__: Req.TransportError, reason: reason}} ->
        Logger.warning(
          "CurlAgent.ApiClient: transport error contacting #{api_url}: #{inspect(reason)}"
        )

        {:error, {:transport, reason}}

      {:error, reason} ->
        Logger.warning(
          "CurlAgent.ApiClient: request error contacting #{api_url}: #{inspect(reason)}"
        )

        {:error, {:transport, reason}}
    end
  end

  @doc false
  @spec receive_timeout(map()) :: pos_integer() | :infinity
  def receive_timeout(req) when is_map(req) do
    configured =
      Application.get_env(
        :ezagent_plugin_curl_agent,
        :receive_timeout,
        @default_receive_timeout
      )

    case Map.get(req, :receive_timeout, configured) do
      :infinity -> :infinity
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> @default_receive_timeout
    end
  end

  defp decode_success(%{} = raw), do: decode_success_body(raw)

  defp decode_success(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        decode_success_body(decoded)

      {:error, reason} ->
        {:error, {:decode, reason}}
    end
  end

  defp decode_success_body(%{"choices" => [%{"message" => %{"content" => content}} | _]} = raw) do
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
  end

  defp decode_success_body(other), do: {:error, {:decode, {:unexpected_shape, other}}}

  defp truncate(b, n) when is_binary(b) do
    if byte_size(b) > n, do: binary_part(b, 0, n) <> "...", else: b
  end

  defp truncate(other, _), do: inspect(other)
end
