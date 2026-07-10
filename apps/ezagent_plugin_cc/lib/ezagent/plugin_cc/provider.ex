defmodule Ezagent.PluginCc.Provider do
  @moduledoc """
  Backend/provider dimension for the cc flavor — ORTHOGONAL to transport
  (pty vs headless).

  A cc agent runs the same `claude` Claude Code binary regardless of which
  upstream LLM API it talks to. The *provider* selects that upstream:

    * `"anthropic"` (default) — claude uses its normal Anthropic endpoint and
      the host OAuth login (`~/.claude/.credentials.json`). No extra env.
    * `"deepseek"` — claude is pointed at DeepSeek's Anthropic-compatible
      endpoint purely via environment variables (the vendor's documented
      Claude Code integration, https://api-docs.deepseek.com — Claude Code
      agent integration). Crucially this uses an **API KEY**
      (`ANTHROPIC_AUTH_TOKEN`), NOT an OAuth login, so a deepseek agent has
      **zero dependency on the host `~/.claude` login** and needs **no
      `.credentials.json` on disk anywhere** — its only credential is the
      `DEEPSEEK_API_KEY` env var the deploy sets on the container.

  This module is the SINGLE source of truth for the DeepSeek env block and the
  DeepSeek credential contract, shared by both the pty launch path
  (`SpawnPlan.build_claude_cmd/3` merges `provider_env/1` into `cmd_env`) and
  the headless path (`CcHeadlessAgent.sdk_sidecar_params/2` threads it as the
  sidecar's `:cmd_env`, which the Python worker applies as the SDK subprocess
  `env=`). The thin per-transport deepseek Template Classes
  (`CcDeepseekAgent` / `CcHeadlessDeepseekAgent`) carry only the flavor wiring;
  all provider behaviour lives here.

  ## The DeepSeek env block (8 vars)

  Assembled by `deepseek_env/0`. `ANTHROPIC_AUTH_TOKEN` is read from
  `DEEPSEEK_API_KEY`; the base URL + model names default to DeepSeek's
  documented values but are overridable via `config :ezagent_plugin_cc`.
  """

  @provider_key "provider"

  @anthropic "anthropic"
  @deepseek "deepseek"

  # The env var the deploy sets on the container; the app only reads it.
  @api_key_env "DEEPSEEK_API_KEY"

  # DeepSeek Claude Code integration defaults (vendor-documented). Overridable
  # via app env so a deploy can retarget the endpoint / model tier without a
  # code change, but the defaults are the verbatim documented values.
  @default_base_url "https://api.deepseek.com/anthropic"
  @default_model "deepseek-v4-pro"
  @default_small_model "deepseek-v4-flash"
  @default_effort_level "max"

  @doc "The default (Anthropic) provider name."
  @spec anthropic() :: String.t()
  def anthropic, do: @anthropic

  @doc "The DeepSeek provider name."
  @spec deepseek() :: String.t()
  def deepseek, do: @deepseek

  @doc "The provider template-data key."
  @spec provider_key() :: String.t()
  def provider_key, do: @provider_key

  @doc "The env var name the DeepSeek API key is read from."
  @spec api_key_env() :: String.t()
  def api_key_env, do: @api_key_env

  @doc """
  Resolve the provider from template data. Reads the `"provider"` data key
  (atom or string), defaulting to `"anthropic"`. Any unrecognised value falls
  back to `"anthropic"` (fail-safe: an unknown provider must not silently
  inject the DeepSeek env).
  """
  @spec provider_of(map()) :: String.t()
  def provider_of(tmpl) when is_map(tmpl) do
    case Map.get(tmpl, @provider_key) || Map.get(tmpl, :provider) do
      p when p in [@deepseek, :deepseek] -> @deepseek
      _ -> @anthropic
    end
  end

  def provider_of(_), do: @anthropic

  @doc "True iff the template selects the DeepSeek provider."
  @spec deepseek?(map()) :: boolean()
  def deepseek?(tmpl), do: provider_of(tmpl) == @deepseek

  @doc "The raw DeepSeek API key from `DEEPSEEK_API_KEY`, or `nil`/`\"\"`."
  @spec api_key() :: String.t() | nil
  def api_key, do: System.get_env(@api_key_env)

  @doc "True iff `DEEPSEEK_API_KEY` is set to a non-empty value."
  @spec api_key_present?() :: boolean()
  def api_key_present? do
    case api_key() do
      k when is_binary(k) and k != "" -> true
      _ -> false
    end
  end

  @doc """
  The launch-time env map to MERGE into the claude launch env for `tmpl`.

    * anthropic (default) → `{:ok, %{}}` (no extra env; the normal cc path is
      byte-for-byte unchanged — no DeepSeek vars ever leak into it).
    * deepseek → `{:ok, deepseek_env}` when `DEEPSEEK_API_KEY` is set, else
      `{:error, :deepseek_api_key_missing}` so the caller fails fast with a
      clear error instead of launching a claude that 401s.
  """
  @spec provider_env(map()) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, :deepseek_api_key_missing}
  def provider_env(tmpl) when is_map(tmpl) do
    case provider_of(tmpl) do
      @deepseek -> deepseek_env()
      _ -> {:ok, %{}}
    end
  end

  @doc """
  The 8-var DeepSeek Claude Code env block, or `{:error, :deepseek_api_key_missing}`
  when `DEEPSEEK_API_KEY` is unset/empty.
  """
  @spec deepseek_env() ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, :deepseek_api_key_missing}
  def deepseek_env do
    case api_key() do
      key when is_binary(key) and key != "" ->
        {:ok,
         %{
           "ANTHROPIC_BASE_URL" => base_url(),
           "ANTHROPIC_AUTH_TOKEN" => key,
           "ANTHROPIC_MODEL" => model(),
           "ANTHROPIC_DEFAULT_OPUS_MODEL" => model(),
           "ANTHROPIC_DEFAULT_SONNET_MODEL" => model(),
           "ANTHROPIC_DEFAULT_HAIKU_MODEL" => small_model(),
           "CLAUDE_CODE_SUBAGENT_MODEL" => small_model(),
           "CLAUDE_CODE_EFFORT_LEVEL" => effort_level()
         }}

      _ ->
        {:error, :deepseek_api_key_missing}
    end
  end

  @doc """
  PTY-only bridge-topic env for a deepseek agent.

  A cc agent's esr-bridge sidecar joins the Phoenix topic
  `agent_bridge:<flavor>:<uri>`, and the channel validates the topic's flavor
  against the agent's RESOLVED flavor. The `ezagent_mcp_bridge.py` sidecar
  defaults to `agent_bridge:cc:<uri>` (correct for plain cc), so a `cc-deepseek`
  agent — whose resolved flavor is `"cc-deepseek"` — would be rejected with a
  topic-flavor mismatch and go mute. This returns
  `%{"EZAGENT_BRIDGE_TOPIC" => "agent_bridge:cc-deepseek:<uri>"}` (honored by the
  sidecar's `bridge_topic/0` override) so it joins the matching topic. Empty for
  anthropic (the sidecar default is already correct) and for headless
  (in-process, no WS topic).
  """
  @spec bridge_topic_env(map(), URI.t()) :: %{optional(String.t()) => String.t()}
  def bridge_topic_env(tmpl, %URI{} = agent_uri) when is_map(tmpl) do
    with true <- deepseek?(tmpl),
         flavor when is_binary(flavor) and flavor != "" <-
           Map.get(tmpl, "flavor") || Map.get(tmpl, :flavor) do
      %{"EZAGENT_BRIDGE_TOPIC" => "agent_bridge:#{flavor}:#{Ezagent.URI.stable_key(agent_uri)}"}
    else
      _ -> %{}
    end
  end

  @doc """
  Fail-fast launchability gate for a deepseek agent: `:ok` iff
  `DEEPSEEK_API_KEY` is set, else `{:error, {:deepseek_api_key_missing, uri}}`.

  A deepseek agent's ONLY credential is this env var (no OAuth, no
  `.credentials.json`), so this — checked at the top of the deepseek
  `instantiate/3` BEFORE any Kind spawn or transport-join wait — is the clear
  error the operator sees instead of an opaque bridge-join timeout.
  """
  @spec ensure_api_key(URI.t()) :: :ok | {:error, {:deepseek_api_key_missing, URI.t()}}
  def ensure_api_key(%URI{} = agent_uri) do
    if api_key_present?() do
      :ok
    else
      {:error, {:deepseek_api_key_missing, agent_uri}}
    end
  end

  @doc """
  The DeepSeek credential-status contribution (`#160` normalized enum) for the
  credential-status view. A deepseek agent's credential is the
  `DEEPSEEK_API_KEY` env, NOT a file — so the on-disk `config_dir` is ignored:

    * key set   → `%{status: :authenticated}`
    * key unset → `%{status: :missing, detail: ...}`

  Read-only, no network, no activation — same guarantees as cc's
  `CredentialFreshness`.
  """
  @spec credential_status() :: %{status: atom(), detail: String.t() | nil, expires_at: nil}
  def credential_status do
    if api_key_present?() do
      %{status: :authenticated, detail: nil, expires_at: nil}
    else
      %{
        status: :missing,
        detail:
          "DEEPSEEK_API_KEY not set — the deepseek agent has no credential; " <>
            "set DEEPSEEK_API_KEY in the deploy env.",
        expires_at: nil
      }
    end
  end

  # --- configurable defaults ------------------------------------------------

  defp base_url, do: get_env(:deepseek_base_url, @default_base_url)
  defp model, do: get_env(:deepseek_model, @default_model)
  defp small_model, do: get_env(:deepseek_small_model, @default_small_model)
  defp effort_level, do: get_env(:deepseek_effort_level, @default_effort_level)

  defp get_env(key, default) do
    case Application.get_env(:ezagent_plugin_cc, key, default) do
      v when is_binary(v) and v != "" -> v
      _ -> default
    end
  end
end
