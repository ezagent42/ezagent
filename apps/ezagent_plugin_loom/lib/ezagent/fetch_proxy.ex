defmodule EzagentPluginLoom.FetchProxy do
  @moduledoc """
  White-listed HTTP proxy for AI-generated pages.

  Pages call `platform.fetch(preset, url, init?)` which lands at
  `POST /loom/api/:ws/:sid/fetch` with body `{preset, url, method?,
  headers?, body?}`. This module validates the request against
  `:ezagent_plugin_loom, :fetch_presets` config and (if valid) makes
  the call using `:httpc`.

  ## Preset config shape

      config :ezagent_plugin_loom, :fetch_presets,
        public: %{
          url: ~r{^https://(api\\.github\\.com|httpbin\\.org)/},
          methods: [:get, :post],
          max_body: 100_000,
          timeout_ms: 8_000,
          headers: %{}                       # injected on every request
        },
        weather: %{
          url: ~r{^https://api\\.openweathermap\\.org/},
          methods: [:get],
          max_body: 50_000,
          timeout_ms: 5_000,
          headers: %{"appid" => {:env, "OPENWEATHER_KEY"}}
        }

  - `url`: anchored regex; the request URL must match
  - `methods`: list of atom methods allowed (`:get`, `:post`, `:put`, `:delete`, `:patch`)
  - `max_body`: max bytes of returned body (truncated past)
  - `timeout_ms`: request + response timeout
  - `headers`: literal map (string→string) OR `{:env, "VAR_NAME"}`
    tuples — the latter is resolved at call time, so secrets stay
    out of compiled code

  ## Security notes

  - **No localhost / private IP access**: the preset's URL regex
    should enforce `https://` schemes. We do NOT additionally
    DNS-resolve and block RFC1918 — that's a TODO if you ever add a
    preset that's not a fully-qualified public hostname.
  - **No redirects followed**: avoids SSRF via redirect to internal.
  - **No streaming**: caps response body at `max_body` bytes; longer
    responses are truncated and a `truncated: true` flag is returned.
  - **Header allowlist**: caller-supplied headers are restricted to
    a small safe set (Content-Type, Accept, User-Agent). Preset
    headers override caller.

  ## Why httpc and not Finch / Mint?

  `:httpc` is part of OTP, no extra dep. The volume here is tiny
  (one-off page requests, not high-throughput). When `EzagentCore`
  standardizes on a single HTTP client we can swap this module's
  internals without touching the contract.
  """

  require Logger

  # Headers a caller may pass through; anything else is dropped.
  @caller_header_allowlist [
    "content-type",
    "accept",
    "accept-language",
    "user-agent"
  ]

  @type preset_name :: String.t() | atom()
  @type call_result ::
          {:ok, %{status: integer(), headers: map(), body: String.t(), truncated: boolean()}}
          | {:error, atom() | String.t()}

  @spec call(preset_name, String.t(), map()) :: call_result
  def call(preset_name, url, opts \\ %{})

  def call(preset_name, url, opts) when is_binary(url) and is_map(opts) do
    with {:ok, preset} <- lookup_preset(preset_name),
         :ok <- match_url(preset, url),
         {:ok, method} <- check_method(preset, opts),
         {:ok, headers} <- assemble_headers(preset, opts),
         body = Map.get(opts, "body", ""),
         :ok <- check_request_body_size(body) do
      do_request(method, url, headers, body, preset)
    end
  end

  def call(_, _, _), do: {:error, :bad_args}

  # --- internals -------------------------------------------------------

  defp lookup_preset(name) when is_binary(name) do
    lookup_preset(String.to_atom(name))
  rescue
    ArgumentError -> {:error, :unknown_preset}
  end

  defp lookup_preset(name) when is_atom(name) do
    presets = Application.get_env(:ezagent_plugin_loom, :fetch_presets, %{})

    case Map.get(presets, name) do
      nil -> {:error, :unknown_preset}
      preset when is_map(preset) -> {:ok, preset}
    end
  end

  defp match_url(%{url: %Regex{} = re}, url) do
    if Regex.match?(re, url), do: :ok, else: {:error, :url_not_allowed}
  end

  defp match_url(_, _), do: {:error, :preset_missing_url}

  defp check_method(preset, opts) do
    method = opts |> Map.get("method", "GET") |> to_string() |> String.downcase()

    method_atom =
      case method do
        "get" -> :get
        "post" -> :post
        "put" -> :put
        "delete" -> :delete
        "patch" -> :patch
        _ -> nil
      end

    allowed = Map.get(preset, :methods, [:get])

    cond do
      is_nil(method_atom) -> {:error, :bad_method}
      method_atom not in allowed -> {:error, :method_not_allowed}
      true -> {:ok, method_atom}
    end
  end

  defp assemble_headers(preset, opts) do
    caller =
      opts
      |> Map.get("headers", %{})
      |> Enum.flat_map(fn {k, v} ->
        key = k |> to_string() |> String.downcase()

        if key in @caller_header_allowlist and is_binary(v) do
          [{key, v}]
        else
          []
        end
      end)
      |> Enum.into(%{})

    preset_headers =
      preset
      |> Map.get(:headers, %{})
      |> Enum.flat_map(fn
        {k, {:env, var}} when is_binary(var) ->
          case System.get_env(var) do
            nil -> []
            "" -> []
            v -> [{to_string(k) |> String.downcase(), v}]
          end

        {k, v} when is_binary(v) ->
          [{to_string(k) |> String.downcase(), v}]

        _ ->
          []
      end)
      |> Enum.into(%{})

    {:ok, Map.merge(caller, preset_headers)}
  end

  defp check_request_body_size(body) when is_binary(body) do
    if byte_size(body) > 1_000_000 do
      {:error, :request_body_too_large}
    else
      :ok
    end
  end

  defp check_request_body_size(_), do: :ok

  defp do_request(method, url, headers, body, preset) do
    timeout = Map.get(preset, :timeout_ms, 8_000)
    max_body = Map.get(preset, :max_body, 100_000)

    httpc_headers =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    content_type =
      headers |> Map.get("content-type", "application/json") |> String.to_charlist()

    request =
      case method do
        :get -> {String.to_charlist(url), httpc_headers}
        :delete -> {String.to_charlist(url), httpc_headers}
        _ -> {String.to_charlist(url), httpc_headers, content_type, body}
      end

    http_opts = [
      timeout: timeout,
      connect_timeout: timeout,
      autoredirect: false
    ]

    opts = [body_format: :binary]

    case :httpc.request(method, request, http_opts, opts) do
      {:ok, {{_v, status, _r}, resp_headers, resp_body}} ->
        truncated? = byte_size(resp_body) > max_body
        body_out = if truncated?, do: :binary.part(resp_body, 0, max_body), else: resp_body

        {:ok,
         %{
           status: status,
           headers:
             resp_headers
             |> Enum.map(fn {k, v} -> {to_string(k) |> String.downcase(), to_string(v)} end)
             |> Enum.into(%{}),
           body: body_out,
           truncated: truncated?
         }}

      {:error, {:failed_connect, _}} ->
        {:error, :connect_failed}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        Logger.warning("FetchProxy: httpc error #{inspect(reason)} for url=#{url}")
        {:error, :request_failed}
    end
  end

  @doc """
  List configured presets (for the AI prompt). Returns `[{name,
  description}]` — description is best-effort derived from the URL
  pattern + allowed methods since presets are pure config.
  """
  def list_presets do
    Application.get_env(:ezagent_plugin_loom, :fetch_presets, %{})
    |> Enum.map(fn {name, p} ->
      methods =
        p
        |> Map.get(:methods, [:get])
        |> Enum.map(&(&1 |> Atom.to_string() |> String.upcase()))
        |> Enum.join("/")

      url = p |> Map.get(:url, ~r{}) |> inspect()

      %{name: to_string(name), methods: methods, url_pattern: url}
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Render the available-presets block for the page-generation prompt.
  """
  def prompt_block do
    case list_presets() do
      [] ->
        ""

      presets ->
        body =
          presets
          |> Enum.map(fn p -> "  - `#{p.name}` (#{p.methods}): URL 必须匹配 #{p.url_pattern}" end)
          |> Enum.join("\n")

        """
        可用 fetch preset(通过 `await platform.fetch(preset, url, init?)` 调用):
        #{body}
        """
    end
  end
end
