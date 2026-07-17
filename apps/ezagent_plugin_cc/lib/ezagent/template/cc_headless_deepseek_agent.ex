defmodule Ezagent.PluginCc.Template.CcHeadlessDeepseekAgent do
  @moduledoc """
  DeepSeek-backed cc agent Template Class (HEADLESS transport) — the
  `"cc-headless-deepseek"` flavor.

  A thin PROVIDER shim over `Ezagent.PluginCc.Template.CcHeadlessAgent`: same
  Python `ClaudeSDKClient` sidecar, same behaviors
  (`Ezagent.Entity.Agent.cc_headless_behaviors/0`), same reply routing — the
  ONLY difference is the backend LLM. Exists as a distinct Template Class for the
  same 1:1 flavor↔template_class reason as `CcDeepseekAgent`; all DeepSeek
  behaviour lives in `Ezagent.PluginCc.Provider`.

  ## How the DeepSeek backend is applied (headless)

  `instantiate/3` injects `"provider" => "deepseek"`; `CcHeadlessAgent`'s
  `sdk_sidecar_params/2` threads the 8-var DeepSeek env block as the sidecar's
  `:cmd_env`, which the sidecar exports as `EZAGENT_CC_SDK_ENV` and the Python
  worker applies as the Claude Code SDK subprocess `env=` — so headless deepseek
  talks to the DeepSeek endpoint exactly like the pty path. The flavor
  `"cc-headless-deepseek"` is stored + persisted so cold restart re-resolves it.

  ## Credential contract

  Identical to `CcDeepseekAgent`: API-key via the env var the `"deepseek"`
  catalog profile names (see `Ezagent.PluginCc.ProviderCatalog`), no OAuth, no
  `.credentials.json`, host-login-adopt no-op, fail-fast launchability gate in
  `instantiate/3`. See `CcDeepseekAgent` + `Ezagent.PluginCc.Provider`.
  """

  alias Ezagent.PluginCc.Provider
  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.PluginCc.Template.CcHeadlessAgent

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.Agent.CredentialAdapter

  @flavor "cc-headless-deepseek"

  @impl Ezagent.Kind.Template
  def template_name, do: "cc_headless_deepseek.agent"

  @impl Ezagent.Kind.Template
  def config_dir_namespace, do: CcHeadlessAgent.config_dir_namespace()

  # --- CredentialAdapter (API-key, no OAuth) --------------------------------

  @impl Ezagent.Agent.CredentialAdapter
  def credential_env_var, do: CcAgent.credential_env_var()

  @impl Ezagent.Agent.CredentialAdapter
  def credential_relpaths, do: []

  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: []

  @impl Ezagent.Agent.CredentialAdapter
  def auth_failure_signals, do: CcAgent.auth_failure_signals()

  @impl Ezagent.Agent.CredentialAdapter
  def credential_status(_home, _opts \\ []), do: Provider.credential_status("deepseek")

  @impl Ezagent.Agent.CredentialAdapter
  def host_login_dir, do: nil

  # --- Template data / validation -------------------------------------------

  @impl Ezagent.Kind.Template
  def template_data_extra(content) when is_map(content) do
    content
    |> CcHeadlessAgent.template_data_extra()
    |> Map.put(Provider.provider_key(), "deepseek")
  end

  def template_data_extra(_), do: %{Provider.provider_key() => "deepseek"}

  @impl Ezagent.Kind.Template
  def compile(resolved, params),
    do: Ezagent.Kind.Template.compile_cc_agent_data(resolved, params, &template_data_extra/1)

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- CcHeadlessAgent.validate_after_class(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "cc_headless_deepseek.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  # --- instantiate (fail-fast API-key gate + provider injection) ------------

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
    with {:ok, agent_uri} <- parse_uri(uri_str),
         :ok <- Provider.ensure_api_key("deepseek", agent_uri) do
      tmpl =
        tmpl
        |> Map.put(Provider.provider_key(), "deepseek")
        |> Map.put("flavor", @flavor)

      CcHeadlessAgent.instantiate_for_flavor(__MODULE__, uri_str, tmpl, workspace_uri)
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  defp parse_uri(uri_str) do
    {:ok, Ezagent.URI.new!(uri_str)}
  rescue
    _ -> {:error, {:invalid_agent_uri, uri_str}}
  end

  @impl Ezagent.Kind.Template
  defdelegate ensure_subprocess_alive(agent_uri, respawn_data), to: CcHeadlessAgent
end
