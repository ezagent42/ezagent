defmodule Ezagent.PluginCc.Template.CcCustomAgent do
  @moduledoc """
  Custom-backend cc agent Template Class (PTY transport) — the `"cc-custom"`
  flavor.

  ONE flavor for every custom backend: a thin shim over
  `Ezagent.PluginCc.Template.CcAgent` (same claude Claude Code binary, same PTY
  transport + bridge, same spawn/credential-cascade chokepoint
  `CcAgent.Spawn`) — the ONLY difference from plain cc is the backend LLM,
  selected by the REQUIRED `"provider"` template-data key naming a closed
  `Ezagent.PluginCc.ProviderCatalog` profile. This Class exists as a distinct
  Template Class purely because `Ezagent.AgentFlavorRegistry` enforces a 1:1
  flavor↔template_class mapping (a second flavor reusing `CcAgent`'s class
  would make `flavor_for_template_class` ambiguous and silently mis-persist
  the flavor on cold restart). All vendor behaviour lives in
  `Ezagent.PluginCc.Provider` + `Ezagent.PluginCc.ProviderCatalog`; this
  module only carries the flavor wiring + the fail-closed profile gate.

  Unlike the retired per-vendor shims it replaced, this Class NEVER injects a
  `"provider"` — it is REQUIRED user input (the operator picks the backend),
  validated fail-closed:

    * absent → `{:error, :missing_backend_profile}`;
    * unknown name (including `"anthropic"`, which is NOT a catalog profile)
      → `{:error, {:unknown_backend_profile, name}}`;
    * non-string → `{:error, {:unknown_backend_profile, bad}}`.

  ## How the selected backend is applied

    * `template_data_extra/1` passes a non-empty content `provider` through
      into the template data (leaving the key ABSENT otherwise, so
      `validate/1` fails it later — fail closed, never a silent default);
    * `instantiate/3` re-checks the profile, gates launchability on the
      profile's API key (`Provider.ensure_api_key/2` BEFORE any Kind spawn /
      transport-join wait), and stores `"flavor" => "cc-custom"` so a cold
      restart re-resolves the flavor → this Class → the persisted profile's
      env. `SpawnPlan.build_claude_cmd/3` then merges
      `Provider.profile_env/1` (the profile's static env block + base URL +
      auth token) and the `agent_bridge:cc-custom:<uri>` bridge topic into
      the PTY `cmd_env`.

  ## Credential contract — profile API key, NOT OAuth

  A cc-custom agent authenticates via the selected profile's API-key env var
  (`ANTHROPIC_AUTH_TOKEN` injected at launch), so it has **no
  `.credentials.json` and no dependency on the host `~/.claude` OAuth
  login**. The CredentialAdapter therefore declares NO credential files
  (`credential_relpaths/0 == []`), NO host-login source
  (`host_login_dir/0 == nil`, so the #1201 host-login-adopt seam no-ops), and
  a `credential_status/2` driven by the `backend_profile` opt (absent →
  `:unknown`, never an alarm). Launchability is gated fail-fast in
  `instantiate/3` (a clear `:backend_api_key_missing` error before any Kind
  spawn / transport-join wait), not by an on-disk credential.

  The per-agent `config_dir` (for settings / skills / MCP) reuses cc's `"cc"`
  namespace so the shared `CcAgent.Spawn` config-home + destroy paths stay
  consistent — a cc-custom agent still has a config home, it just holds no
  secret.
  """

  alias Ezagent.PluginCc.{Provider, ProviderCatalog}
  alias Ezagent.PluginCc.Template.CcAgent

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.Agent.CredentialAdapter
  @behaviour Ezagent.UI.Form

  @flavor "cc-custom"

  @impl Ezagent.Kind.Template
  def template_name, do: "cc_custom.agent"

  # Reuse cc's config_dir namespace: the shared CcAgent.Spawn chokepoint
  # materializes + destroys the config home under the CcAgent identity, so a
  # divergent namespace here would mismatch the destroy-path check. cc-custom
  # agents live in `cc-agents/<ws>/<name>` alongside cc agents (unique URIs, no
  # collision) and share the existing `cc-agents` resource type.
  @impl Ezagent.Kind.Template
  def config_dir_namespace, do: CcAgent.config_dir_namespace()

  # --- CredentialAdapter (profile API-key, no OAuth) -------------------------

  @impl Ezagent.Agent.CredentialAdapter
  def credential_env_var, do: CcAgent.credential_env_var()

  # No on-disk login state — the credential is the selected profile's API-key env.
  @impl Ezagent.Agent.CredentialAdapter
  def credential_relpaths, do: []

  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: []

  # A bad API key surfaces as an Anthropic-shaped auth error on the wire; reuse
  # cc's signatures so the PTY auth observer still notifies the owner.
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
    base = CcAgent.template_data_extra(content)

    base =
      case Ezagent.Kind.Template.content_field(content, :provider) do
        p when is_binary(p) and p != "" -> Map.put(base, Provider.provider_key(), p)
        _ -> base
      end

    case Ezagent.Kind.Template.content_field(content, :session_template_member) do
      true -> Map.put(base, "session_template_member", true)
      _ -> base
    end
  end

  def template_data_extra(_), do: %{}

  # F3/#1460 — cc's base fields + the REQUIRED provider enum, so the ad-hoc
  # `workspace create_agent` lane's FlavorConfig whitelist (sourced from
  # `config_schema/0`) accepts a backend profile. The value stays gated
  # fail-closed at `Provider.check_backend_profile/1` in `validate/1`.
  @impl Ezagent.Kind.Template
  def config_schema,
    do:
      Ezagent.PluginCc.Template.CcAgent.ConfigSchema.fields() ++
        [Provider.provider_config_field()]

  @impl Ezagent.Kind.Template
  def compile(resolved, params),
    do: Ezagent.Kind.Template.compile_cc_agent_data(resolved, params, &template_data_extra/1)

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    # Fail-closed profile gate (shared facade): "provider" is REQUIRED user
    # input naming a closed catalog profile — see Provider.check_backend_profile/1.
    with :ok <- check_class(tmpl),
         :ok <- Provider.check_backend_profile(tmpl),
         :ok <- CcAgent.validate_after_class(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "cc_custom.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  # --- instantiate (fail-closed profile gate + fail-fast API-key gate) -------

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
    with {:ok, agent_uri} <- parse_uri(uri_str),
         :ok <- Provider.check_backend_profile(tmpl),
         # Launchability gate FIRST — a missing profile API key is a clear
         # error BEFORE any Kind spawn / config-dir materialize / transport-join
         # wait, never an opaque bridge-join timeout.
         :ok <- ensure_api_key(tmpl, agent_uri) do
      # Persist the flavor so Spawn's `Map.put_new("flavor", "cc")` no-ops and
      # cold-restart flavor resolution reads "cc-custom". The "provider" rides
      # in tmpl already (required user input — never injected here).
      tmpl = Map.put(tmpl, "flavor", @flavor)
      CcAgent.instantiate_for_flavor(__MODULE__, uri_str, tmpl, workspace_uri, [])
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri,
        launch_context: launch_context
      ) do
    with {:ok, agent_uri} <- parse_uri(uri_str),
         :ok <- Provider.check_backend_profile(tmpl),
         :ok <- ensure_api_key(tmpl, agent_uri) do
      tmpl = Map.put(tmpl, "flavor", @flavor)

      CcAgent.instantiate_for_flavor(__MODULE__, uri_str, tmpl, workspace_uri,
        launch_context: launch_context
      )
    end
  end

  def instantiate(_tmpl_name, _tmpl, _workspace_uri, _opts),
    do: {:error, :invalid_launch_options}

  defp ensure_api_key(tmpl, agent_uri) do
    if Provider.session_template_member?(tmpl),
      do: :ok,
      else: Provider.ensure_api_key(Map.fetch!(tmpl, Provider.provider_key()), agent_uri)
  end

  defp parse_uri(uri_str) do
    {:ok, Ezagent.URI.new!(uri_str)}
  rescue
    _ -> {:error, {:invalid_agent_uri, uri_str}}
  end

  # --- Cold-restart + config-dir lifecycle (all shared with CcAgent) ---------

  @impl Ezagent.Kind.Template
  defdelegate ensure_subprocess_alive(agent_uri, respawn_data), to: CcAgent

  @impl Ezagent.Kind.Template
  defdelegate list_extensions(config_dir), to: CcAgent

  @impl Ezagent.Kind.Template
  defdelegate toggle_extension(config_dir, extension_id, enabled?), to: CcAgent

  @impl Ezagent.Kind.Template
  defdelegate destroy_config_dir(agent_uri, config_dir), to: CcAgent

  # --- UI.Form ----------------------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    CcAgent.form_fields() ++
      [
        %{
          name: "provider",
          type: :select,
          label: "Backend profile",
          required: true,
          options: ProviderCatalog.names()
        }
      ]
  end
end
