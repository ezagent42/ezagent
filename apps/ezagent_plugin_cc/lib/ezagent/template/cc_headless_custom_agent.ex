defmodule Ezagent.PluginCc.Template.CcHeadlessCustomAgent do
  @moduledoc """
  Custom-backend cc agent Template Class (HEADLESS transport) — the
  `"cc-headless-custom"` flavor.

  The headless twin of `Ezagent.PluginCc.Template.CcCustomAgent`: ONE flavor
  for every custom backend over the headless SDK-sidecar transport. A thin
  shim over `Ezagent.PluginCc.Template.CcHeadlessAgent` (same Python
  `ClaudeSDKClient` sidecar, same behaviors
  (`Ezagent.Entity.Agent.cc_headless_behaviors/0`), same reply routing) — the
  ONLY difference from plain cc-headless is the backend LLM, selected by the
  REQUIRED `"provider"` template-data key naming a closed
  `Ezagent.PluginCc.ProviderCatalog` profile. This Class exists as a distinct
  Template Class purely because `Ezagent.AgentFlavorRegistry` enforces a 1:1
  flavor↔template_class mapping; all vendor behaviour lives in
  `Ezagent.PluginCc.Provider` + `Ezagent.PluginCc.ProviderCatalog`.

  Like its pty twin, this Class NEVER injects a `"provider"` — it is REQUIRED
  user input (the operator picks the backend), validated fail-closed:

    * absent → `{:error, :missing_backend_profile}`;
    * unknown name (including `"anthropic"`, which is NOT a catalog profile)
      → `{:error, {:unknown_backend_profile, name}}`;
    * non-string → `{:error, {:unknown_backend_profile, bad}}`.

  ## How the selected backend is applied (headless)

  `instantiate/3` re-checks the profile, gates launchability on the profile's
  API key (`Provider.ensure_api_key/2` BEFORE any Kind spawn / sidecar start),
  and stores `"flavor" => "cc-headless-custom"` so a cold restart re-resolves
  the flavor → this Class → the persisted profile's env.
  `CcHeadlessAgent.sdk_sidecar_params/2` then threads
  `Provider.provider_env/1` (the profile's static env block + base URL + auth
  token) as the sidecar's `:cmd_env`, which the sidecar exports as
  `EZAGENT_CC_SDK_ENV` and the Python worker applies as the Claude Code SDK
  subprocess `env=` — so a headless custom-backend agent talks to the vendor
  endpoint exactly like the pty path.

  ## Credential contract — profile API key, NOT OAuth

  Identical to `CcCustomAgent`: authenticates via the selected profile's
  API-key env var (`ANTHROPIC_AUTH_TOKEN` threaded through the sidecar env),
  so it has **no `.credentials.json` and no dependency on the host `~/.claude`
  OAuth login** — NO credential files (`credential_relpaths/0 == []`), NO
  host-login source (`host_login_dir/0 == nil`), a `credential_status/2`
  driven by the `backend_profile` opt (absent → `:unknown`, never an alarm),
  and the fail-fast launchability gate in `instantiate/3`. The per-agent
  `config_dir` (settings / skills / MCP) reuses cc-headless's `"cc-headless"`
  namespace so the shared config-home + sidecar paths stay consistent — the
  agent still has a config home, it just holds no secret.
  """

  alias Ezagent.PluginCc.Provider
  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.PluginCc.Template.CcHeadlessAgent

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.Agent.CredentialAdapter

  @flavor "cc-headless-custom"

  @impl Ezagent.Kind.Template
  def template_name, do: "cc_headless_custom.agent"

  # Reuse cc-headless's config_dir namespace: the shared config-home + SDK
  # sidecar paths materialize under the CcHeadlessAgent identity, so a
  # divergent namespace here would mismatch those paths (same reasoning as the
  # pty twin's reuse of cc's namespace).
  @impl Ezagent.Kind.Template
  def config_dir_namespace, do: CcHeadlessAgent.config_dir_namespace()

  # --- CredentialAdapter (profile API-key, no OAuth) -------------------------

  @impl Ezagent.Agent.CredentialAdapter
  def credential_env_var, do: CcAgent.credential_env_var()

  # No on-disk login state — the credential is the selected profile's API-key env.
  @impl Ezagent.Agent.CredentialAdapter
  def credential_relpaths, do: []

  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: []

  # A bad API key surfaces as an Anthropic-shaped auth error on the wire; reuse
  # cc's signatures so the auth observer still notifies the owner.
  @impl Ezagent.Agent.CredentialAdapter
  def auth_failure_signals, do: CcAgent.auth_failure_signals()

  # Credential = the SELECTED profile's API-key env; config_dir is irrelevant
  # here. The caller names the profile via the `backend_profile` opt; absent
  # (or unknown) → `:unknown`, never an alarm.
  @impl Ezagent.Agent.CredentialAdapter
  def credential_status(_home, opts \\ []),
    do: Provider.credential_status(Keyword.get(opts, :backend_profile))

  # No host-login concept — the installer host-login-adopt seam no-ops (nil).
  @impl Ezagent.Agent.CredentialAdapter
  def host_login_dir, do: nil

  # --- Template data / validation --------------------------------------------

  # Pass a non-empty content `provider` THROUGH (the curl-pattern content
  # seam) — NEVER inject one. Absent/empty leaves the key out so `validate/1`
  # fails it later (fail closed).
  @impl Ezagent.Kind.Template
  def template_data_extra(content) when is_map(content) do
    base = CcHeadlessAgent.template_data_extra(content)

    case Ezagent.Kind.Template.content_field(content, :provider) do
      p when is_binary(p) and p != "" -> Map.put(base, Provider.provider_key(), p)
      _ -> base
    end
  end

  def template_data_extra(_), do: %{}

  @impl Ezagent.Kind.Template
  def compile(resolved, params),
    do: Ezagent.Kind.Template.compile_cc_agent_data(resolved, params, &template_data_extra/1)

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    # Fail-closed profile gate (shared facade): "provider" is REQUIRED user
    # input naming a closed catalog profile — see Provider.check_backend_profile/1.
    with :ok <- check_class(tmpl),
         :ok <- Provider.check_backend_profile(tmpl),
         :ok <- CcHeadlessAgent.validate_after_class(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "cc_headless_custom.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  # --- instantiate (fail-closed profile gate + fail-fast API-key gate) -------

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
    with {:ok, agent_uri} <- parse_uri(uri_str),
         :ok <- Provider.check_backend_profile(tmpl),
         # Launchability gate FIRST — a missing profile API key is a clear
         # error BEFORE any Kind spawn / config-dir materialize / sidecar
         # start, never an opaque sidecar boot failure.
         :ok <- Provider.ensure_api_key(Map.fetch!(tmpl, Provider.provider_key()), agent_uri) do
      # Persist the flavor so cold-restart flavor resolution reads
      # "cc-headless-custom". The "provider" rides in tmpl already (required
      # user input — never injected here).
      tmpl = Map.put(tmpl, "flavor", @flavor)
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
