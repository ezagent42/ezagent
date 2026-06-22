defmodule EzagentPluginHello.LLM.ApiClient do
  @moduledoc """
  Tiny OpenAI-compatible chat-completion client for the hello builder agent.

  DeepSeek's API is OpenAI-shape (`POST /chat/completions` with `{model,
  messages, ...}`) so the same client serves both. Uses `:httpc` (Erlang
  stdlib) to avoid a top-level HTTP dep — same choice as the curl-agent /
  feishu plugins. This is a near-verbatim hello-local copy of
  `Ezagent.PluginCurlAgent.ApiClient` (a plugin can't depend on another
  plugin, so the ~60-LOC client is duplicated, not shared).

  The hello builder asks the model for a single JSON `@json-render` page spec;
  this client is transport-only and returns the raw assistant `content` — spec
  extraction/validation lives in `EzagentPluginHello.Spec`.

  ## Public surface

      ApiClient.chat_completion(%{
        api_url:    "https://api.deepseek.com/chat/completions",
        api_key:    "sk-...",
        model:      "deepseek-chat",
        messages:   [%{role: "system", content: "..."}, %{role: "user", content: "Hi"}],
        timeout_ms: 60_000   # optional, default 60s (page gen is slow)
      })

  Returns `{:ok, %{content, usage, raw}}` | `{:error, {:http, status, body}}` |
  `{:error, {:transport, reason}}` | `{:error, {:decode, reason}}`.
  """

  require Logger

  @default_timeout_ms 60_000

  # A DEDICATED httpc profile so a configured proxy (below) routes ONLY hello's
  # LLM calls, never other plugins' httpc traffic on the default profile.
  @profile :ezagent_hello_httpc

  @doc """
  Call an OpenAI-shape chat-completions endpoint and return the assistant
  message content + token usage. Transport-only; no streaming, no retry, no
  key redaction (the caller scrubs before logging).
  """
  @spec chat_completion(map()) ::
          {:ok, %{content: String.t(), usage: map(), raw: map()}} | {:error, term()}
  def chat_completion(
        %{api_url: api_url, api_key: api_key, model: model, messages: messages} = req
      )
      when is_binary(api_url) and is_binary(api_key) and is_binary(model) and is_list(messages) do
    timeout = Map.get(req, :timeout_ms, @default_timeout_ms)
    body = %{model: model, messages: messages, stream: false} |> Jason.encode!()

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> api_key)},
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"application/json"}
    ]

    request = {String.to_charlist(api_url), headers, ~c"application/json", body}
    http_opts = [{:timeout, timeout}, {:connect_timeout, 10_000}]

    ensure_profile()

    case :httpc.request(:post, request, http_opts, [body_format: :binary], @profile) do
      {:ok, {{_, status, _}, _headers, resp_body}} when status >= 200 and status < 300 ->
        decode_success(resp_body)

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        Logger.warning(
          "hello.ApiClient: HTTP #{status} from #{api_url} — body: #{truncate(resp_body, 240)}"
        )

        {:error, {:http, status, to_string(resp_body)}}

      {:error, reason} ->
        Logger.warning(
          "hello.ApiClient: transport error contacting #{api_url}: #{inspect(reason)}"
        )

        {:error, {:transport, reason}}
    end
  end

  # Start the dedicated httpc profile (idempotent) and, if a proxy is configured
  # (`HELLO_LLM_PROXY` | `HTTPS_PROXY` | `https_proxy`, "host:port"), point this
  # profile's https_proxy at it — `localhost`/`127.0.0.1` stay direct. In some
  # environments the LLM endpoint (e.g. api.deepseek.com) is only reachable via a
  # local proxy; without one, direct egress times out.
  defp ensure_profile do
    case :inets.start(:httpc, profile: @profile) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      _ -> :ok
    end

    case proxy_config() do
      {host, port} ->
        :httpc.set_options(
          [{:https_proxy, {{host, port}, [~c"localhost", ~c"127.0.0.1"]}}],
          @profile
        )

      nil ->
        :ok
    end
  end

  defp proxy_config do
    raw =
      System.get_env("HELLO_LLM_PROXY") || System.get_env("HTTPS_PROXY") ||
        System.get_env("https_proxy")

    with value when is_binary(value) and value != "" <- raw,
         stripped <- value |> String.trim() |> String.replace_prefix("http://", ""),
         [host, port] <- String.split(stripped, ":", parts: 2),
         {port_int, ""} <- Integer.parse(port) do
      {String.to_charlist(host), port_int}
    else
      _ -> nil
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
