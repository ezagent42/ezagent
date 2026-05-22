defmodule Ezagent.PluginCurlAgent.Template do
  @moduledoc """
  Template Class `curl.agent` — declares a CurlAgent instance in a
  Workspace.

  Form fields (auto-derived UI via `Ezagent.UI.Form`):

  - `agent_uri` — `entity://agent/default/curl_<name>` (PR #141 SPEC v2)
  - `provider` — `"deepseek"` / `"openai"` / ... (matches the key
    provider stored on the owner User's `api_keys` slice)
  - `api_url` — full URL of the OpenAI-compatible
    `/chat/completions` endpoint
  - `model` — provider-specific model id
  - `system_prompt` — optional textarea
  - `max_history` — int, default 20
  - `owner_uri` — `entity://user/<name>` whose api_key the agent uses
    (admin can set; LV pre-fills to caller_uri)

  ## On instantiate

  Spawns the CurlAgent Kind at `curl-agent://<name>` with the
  config as `init_slice` args. Idempotent against KindRegistry —
  re-instantiate skips if already alive.

  `instantiate/3` returns the 3-element `{:ok, [agent_uri],
  %{fresh?: boolean()}}` form (codex round-6 HIGH-1) — `fresh?` is
  `true` iff THIS call's `DynamicSupervisor.start_child` started the
  worker. The signal lets `update_agent_template`'s rollback-safe swap
  refuse adopting a worker another process created.

  ## What this template does NOT validate

  - Whether the owner User has a `provider` key set today —
    `:receive` will surface a chat-visible error at the first
    message if the key is missing. This matches the cc.pty
    pattern: instantiate-time validation only covers structural
    correctness; runtime errors are surfaced via the chat itself.
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "curl.agent"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_provider(tmpl),
         :ok <- check_api_url(tmpl),
         :ok <- check_model(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "curl.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  # PR #141 (SPEC v2 §5.14): strict `entity://agent/default/curl_<name>` shape.
  # The legacy `agent://curl/<name>` and `curl-agent://` schemes are
  # both rejected — clean rebuild per SPEC §5.11.
  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    case URI.new(uri_str) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} when rest != "" ->
        # Phase 9 PR-2 (SPEC v3 §3): entity URIs are 3-segment:
        # /<workspace>/<entity_name>. Flavor lives in entity_name prefix.
        with [_workspace, entity_name] when entity_name != "" <-
               String.split(rest, "/", parts: 2),
             [flavor, suffix] when flavor != "" and suffix != "" <-
               String.split(entity_name, "_", parts: 2) do
          if flavor == "curl" do
            :ok
          else
            {:error, {:wrong_agent_flavor, flavor, expected: "curl"}}
          end
        else
          _ ->
            {:error,
             {:missing_flavor_prefix, uri_str,
              "agent URIs must be `entity://agent/<workspace>/curl_<name>` (Phase 9 PR-2)"}}
        end

      {:ok, %URI{scheme: "entity"}} ->
        {:error,
         {:invalid_agent_uri, uri_str,
          "agent URIs must be `entity://agent/<workspace>/curl_<name>` (Phase 9 PR-2)"}}

      _ ->
        {:error, {:bad_agent_uri, uri_str}}
    end
  end

  defp check_agent_uri(_), do: {:error, :missing_agent_uri}

  defp check_provider(%{"provider" => p}) when is_binary(p) and p != "", do: :ok
  defp check_provider(_), do: {:error, :missing_provider}

  defp check_api_url(%{"api_url" => u}) when is_binary(u) and u != "" do
    if String.starts_with?(u, "http://") or String.starts_with?(u, "https://") do
      :ok
    else
      {:error, {:bad_api_url, u}}
    end
  end

  defp check_api_url(_), do: {:error, :missing_api_url}

  defp check_model(%{"model" => m}) when is_binary(m) and m != "", do: :ok
  defp check_model(_), do: {:error, :missing_model}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => agent_uri_str} = tmpl, _workspace_uri) do
    agent_uri = URI.parse(agent_uri_str)

    init_args = %{
      uri: agent_uri,
      provider: tmpl["provider"],
      api_url: tmpl["api_url"],
      model: tmpl["model"],
      system_prompt: nil_if_empty(tmpl["system_prompt"]),
      max_history: parse_int(tmpl["max_history"], 20),
      owner_uri: parse_owner_uri(tmpl["owner_uri"])
    }

    # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
    # CurlAgent declares EzagentPluginCurlAgent.InstanceSupervisor via
    # supervisor/0 — destination preserved.
    #
    # codex round-6 HIGH-1 — `Ezagent.Kind.spawn/2` returns the raw
    # `DynamicSupervisor.start_child` outcome, which atomically
    # distinguishes `{:ok, pid}` (THIS call started the worker) from
    # `{:error, {:already_started, pid}}` (it pre-existed). Thread that
    # ground truth out as `%{fresh?: _}` so `update_agent_template`'s
    # swap can refuse adopting a worker it did not create.
    case Ezagent.Kind.spawn(Ezagent.Entity.CurlAgent, init_args) do
      {:ok, _pid} ->
        {:ok, [agent_uri], %{fresh?: true}}

      {:error, {:already_started, _pid}} ->
        {:ok, [agent_uri], %{fresh?: false}}

      {:error, reason} ->
        Logger.warning(
          "curl.agent Template instantiate failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  defp nil_if_empty(nil), do: nil
  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s) when is_binary(s), do: s

  defp parse_int(nil, default), do: default
  defp parse_int(n, _) when is_integer(n) and n > 0, do: n

  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  defp parse_owner_uri(nil), do: URI.parse("entity://user/system/admin")
  defp parse_owner_uri(""), do: URI.parse("entity://user/system/admin")

  defp parse_owner_uri(s) when is_binary(s) do
    case URI.new(s) do
      {:ok, %URI{scheme: "entity", host: "user"} = u} -> u
      _ -> URI.parse("entity://user/system/admin")
    end
  end

  # --- Ezagent.UI.Form ---------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "agent_uri",
        type: :uri,
        label: "Agent URI (entity://agent/default/curl_<name> — appears in mention/floating dropdowns)",
        required: true,
        placeholder: "entity://agent/default/curl_my-deepseek"
      },
      %{
        name: "provider",
        type: :text,
        label: "Provider (selects which api_keys entry to use)",
        required: true,
        placeholder: "deepseek"
      },
      %{
        name: "api_url",
        type: :text,
        label: "API URL (OpenAI-compatible /chat/completions endpoint)",
        required: true,
        placeholder: "https://api.deepseek.com/chat/completions"
      },
      %{
        name: "model",
        type: :text,
        label: "Model",
        required: true,
        placeholder: "deepseek-chat"
      },
      %{
        name: "system_prompt",
        type: :text,
        label: "System prompt (optional)",
        required: false,
        placeholder: "You are a concise, helpful assistant."
      },
      %{
        name: "max_history",
        type: :text,
        label: "Max history turns",
        required: false,
        placeholder: "20"
      },
      %{
        name: "owner_uri",
        type: :uri,
        label: "Owner user URI (whose api_key gets used)",
        required: false,
        placeholder: "entity://user/system/admin"
      }
    ]
  end
end
