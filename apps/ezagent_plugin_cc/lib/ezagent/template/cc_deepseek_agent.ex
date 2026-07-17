defmodule Ezagent.PluginCc.Template.CcDeepseekAgent do
  @moduledoc """
  DeepSeek-backed cc agent Template Class (PTY transport) — the `"cc-deepseek"`
  flavor.

  A thin PROVIDER shim over `Ezagent.PluginCc.Template.CcAgent`: same claude
  Claude Code binary, same PTY transport + bridge, same spawn/credential-cascade
  chokepoint (`CcAgent.Spawn`) — the ONLY difference is the backend LLM. This
  Class exists as a distinct Template Class purely because
  `Ezagent.AgentFlavorRegistry` enforces a 1:1 flavor↔template_class mapping (a
  second flavor reusing `CcAgent`'s class would make `flavor_for_template_class`
  ambiguous and silently mis-persist the flavor on cold restart). All DeepSeek
  behaviour lives in `Ezagent.PluginCc.Provider`; this module only carries the
  flavor wiring.

  ## How the DeepSeek backend is applied

    * `instantiate/3` injects `"provider" => "deepseek"` into the template data
      (also emitted by `template_data_extra/1`), which `SpawnPlan.build_claude_cmd/3`
      reads to merge `Ezagent.PluginCc.Provider.profile_env/1` (the profile's
      static env block + base URL + auth token) into the PTY `cmd_env`.
    * The flavor `"cc-deepseek"` is stored explicitly (`instantiate_for_flavor`)
      AND persisted into `respawn_template_data["flavor"]`, so a cold restart
      re-resolves the flavor → this Class → the DeepSeek env (the property the
      distinct Template Class exists to guarantee).

  ## Credential contract — API key, NOT OAuth

  DeepSeek authenticates via `ANTHROPIC_AUTH_TOKEN` (read from the env var the
  `"deepseek"` catalog profile names — see `Ezagent.PluginCc.ProviderCatalog`),
  so a deepseek agent has **no `.credentials.json` and no dependency on the host
  `~/.claude` OAuth login**. The CredentialAdapter therefore declares NO
  credential files (`credential_relpaths/0 == []`), NO host-login source
  (`host_login_dir/0 == nil`, so the #1201 host-login-adopt seam no-ops), and a
  `credential_status/2` that gates purely on the profile's API-key env var.
  Launchability is gated fail-fast in `instantiate/3` (a clear
  `:backend_api_key_missing` error before any Kind spawn / transport-join
  wait), not by an on-disk credential.

  The per-agent `config_dir` (for settings / skills / MCP) reuses cc's `"cc"`
  namespace so the shared `CcAgent.Spawn` config-home + destroy paths stay
  consistent — a deepseek agent still has a config home, it just holds no secret.
  """

  alias Ezagent.PluginCc.Provider
  alias Ezagent.PluginCc.Template.CcAgent

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.Agent.CredentialAdapter
  @behaviour Ezagent.UI.Form

  @flavor "cc-deepseek"

  @impl Ezagent.Kind.Template
  def template_name, do: "cc_deepseek.agent"

  # Reuse cc's config_dir namespace: the shared CcAgent.Spawn chokepoint
  # materializes + destroys the config home under the CcAgent identity, so a
  # divergent namespace here would mismatch the destroy-path check. deepseek
  # agents live in `cc-agents/<ws>/<name>` alongside cc agents (unique URIs, no
  # collision) and share the existing `cc-agents` resource type.
  @impl Ezagent.Kind.Template
  def config_dir_namespace, do: CcAgent.config_dir_namespace()

  # --- CredentialAdapter (API-key, no OAuth) --------------------------------

  @impl Ezagent.Agent.CredentialAdapter
  def credential_env_var, do: CcAgent.credential_env_var()

  # No on-disk login state — DeepSeek's credential is the profile's API-key env.
  @impl Ezagent.Agent.CredentialAdapter
  def credential_relpaths, do: []

  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: []

  # A bad API key surfaces as an Anthropic-shaped auth error on the wire; reuse
  # cc's signatures so the PTY auth observer still notifies the owner.
  @impl Ezagent.Agent.CredentialAdapter
  def auth_failure_signals, do: CcAgent.auth_failure_signals()

  # Credential = the "deepseek" profile's API-key env; config_dir is irrelevant here.
  @impl Ezagent.Agent.CredentialAdapter
  def credential_status(_home, _opts \\ []), do: Provider.credential_status("deepseek")

  # No host-login concept — the installer host-login-adopt seam no-ops (nil).
  @impl Ezagent.Agent.CredentialAdapter
  def host_login_dir, do: nil

  # --- Template data / validation -------------------------------------------

  @impl Ezagent.Kind.Template
  def template_data_extra(content) when is_map(content) do
    content
    |> CcAgent.template_data_extra()
    |> Map.put(Provider.provider_key(), "deepseek")
  end

  def template_data_extra(_), do: %{Provider.provider_key() => "deepseek"}

  @impl Ezagent.Kind.Template
  defdelegate config_schema, to: Ezagent.PluginCc.Template.CcAgent.ConfigSchema, as: :fields

  @impl Ezagent.Kind.Template
  def compile(resolved, params),
    do: Ezagent.Kind.Template.compile_cc_agent_data(resolved, params, &template_data_extra/1)

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- CcAgent.validate_after_class(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "cc_deepseek.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  # --- instantiate (fail-fast API-key gate + provider injection) ------------

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
    with {:ok, agent_uri} <- parse_uri(uri_str),
         # Launchability gate FIRST — a missing profile API key is a clear
         # error BEFORE any Kind spawn / config-dir materialize / transport-join
         # wait, never an opaque bridge-join timeout.
         :ok <- Provider.ensure_api_key("deepseek", agent_uri) do
      tmpl =
        tmpl
        |> Map.put(Provider.provider_key(), "deepseek")
        # Persist the flavor so Spawn's `Map.put_new("flavor", "cc")` no-ops and
        # cold-restart flavor resolution reads "cc-deepseek".
        |> Map.put("flavor", @flavor)

      CcAgent.instantiate_for_flavor(__MODULE__, uri_str, tmpl, workspace_uri)
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  defp parse_uri(uri_str) do
    {:ok, Ezagent.URI.new!(uri_str)}
  rescue
    _ -> {:error, {:invalid_agent_uri, uri_str}}
  end

  # --- Cold-restart + config-dir lifecycle (all shared with CcAgent) --------

  @impl Ezagent.Kind.Template
  defdelegate ensure_subprocess_alive(agent_uri, respawn_data), to: CcAgent

  @impl Ezagent.Kind.Template
  defdelegate list_extensions(config_dir), to: CcAgent

  @impl Ezagent.Kind.Template
  defdelegate toggle_extension(config_dir, extension_id, enabled?), to: CcAgent

  @impl Ezagent.Kind.Template
  defdelegate destroy_config_dir(agent_uri, config_dir), to: CcAgent

  # --- UI.Form ---------------------------------------------------------------

  @impl Ezagent.UI.Form
  defdelegate form_fields, to: CcAgent
end
