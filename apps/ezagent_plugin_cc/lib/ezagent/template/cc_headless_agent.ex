defmodule Ezagent.PluginCc.Template.CcHeadlessAgent do
  @moduledoc """
  CC Headless agent Template Class — headless Claude Code SDK (no PTY/TUI).

  Registers the `"cc-headless"` flavor with the same CredentialAdapter as
  `"cc"` (CLAUDE_CONFIG_DIR + .credentials.json). Runtime is a plugin-local
  Python `ClaudeSDKClient` sidecar supervised per agent.
  """

  @behaviour Ezagent.Kind.Template

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "cc_headless.agent"

  @impl Ezagent.Kind.Template
  def config_dir_namespace, do: "cc-headless"

  # Credential adapter — delegates to CcAgent (same CLAUDE_CONFIG_DIR, .credentials.json).
  @behaviour Ezagent.Agent.CredentialAdapter

  @impl Ezagent.Agent.CredentialAdapter
  def credential_env_var, do: Ezagent.PluginCc.Template.CcAgent.credential_env_var()

  @impl Ezagent.Agent.CredentialAdapter
  def credential_relpaths, do: Ezagent.PluginCc.Template.CcAgent.credential_relpaths()

  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: Ezagent.PluginCc.Template.CcAgent.secret_relpaths()

  @impl Ezagent.Agent.CredentialAdapter
  def auth_failure_signals, do: Ezagent.PluginCc.Template.CcAgent.auth_failure_signals()

  # #1309 — the node's HOST claude login home, SAME source as `cc` (cc-headless
  # inherits the host login identically to cc-pty; the whole point is parity).
  # `host_login_dir/0` is an OPTIONAL CredentialAdapter callback, so its omission
  # produced NO compiler warning — yet `CredentialAdapter.host_login_source_dir/1`
  # gates on `function_exported?(mod, :host_login_dir, 0)`, so without this delegate
  # the gate resolved to `:none`, #1209's installer host-login adoption chain
  # (`DefinitionAgents` → `HostLoginAdopt.ensure_installer_source`) silently no-oped,
  # and the materialized cc-headless config home never got `.credentials.json` → 401.
  @impl Ezagent.Agent.CredentialAdapter
  def host_login_dir, do: Ezagent.PluginCc.Template.CcAgent.host_login_dir()

  @impl Ezagent.Agent.CredentialAdapter
  def refresh_test_credentials(source, home, opts \\ []) do
    Ezagent.PluginCc.Template.CcAgent.refresh_test_credentials(source, home, opts)
  end

  # #160 — credential-status view. Same CLAUDE_CONFIG_DIR/.credentials.json as cc.
  @impl Ezagent.Agent.CredentialAdapter
  def credential_status(home, opts \\ []),
    do: Ezagent.PluginCc.Template.CcAgent.credential_status(home, opts)

  # template_data_extra — delegates to CcAgent.
  @impl Ezagent.Kind.Template
  def template_data_extra(content),
    do: Ezagent.PluginCc.Template.CcAgent.template_data_extra(content)

  @impl Ezagent.Kind.Template
  def compile(resolved, params) do
    Ezagent.Kind.Template.compile_cc_agent_data(
      resolved,
      params,
      &Ezagent.PluginCc.Template.CcAgent.template_data_extra/1
    )
  end

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- validate_after_class(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  # Every cc_headless.agent validation check AFTER the class-string check, shared
  # with the custom-backend provider shim (`CcHeadlessCustomAgent`) so its
  # `validate/1` reuses the exact rules while accepting its own
  # `"cc_headless_custom.agent"` class.
  @doc false
  @spec validate_after_class(map()) :: :ok | {:error, term()}
  def validate_after_class(tmpl) when is_map(tmpl) do
    with :ok <- check_agent_uri(tmpl),
         :ok <- check_cwd(tmpl),
         :ok <- check_optional_config_dir(tmpl),
         :ok <- reject_stale_config_dir_data_key!(tmpl) do
      :ok
    end
  end

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
    instantiate_for_flavor(__MODULE__, uri_str, tmpl, workspace_uri, [])
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri,
        launch_context: launch_context
      ) do
    instantiate_for_flavor(__MODULE__, uri_str, tmpl, workspace_uri,
      launch_context: launch_context
    )
  end

  def instantiate(_tmpl_name, _tmpl, _workspace_uri, _opts), do: {:error, :invalid_launch_options}

  # Flavor-parameterized instantiate body, shared with the custom-backend
  # provider shim (`CcHeadlessCustomAgent`) so the STORED launch flavor is the
  # caller's flavor (`cc-headless` vs `cc-headless-custom`) while the SDK-sidecar
  # spawn path stays this single module. The provider dimension rides in `tmpl` as a
  # `"provider"` data field (read by `sdk_sidecar_params/2` → the sidecar's
  # `EZAGENT_CC_SDK_ENV` passthrough → the Python worker's SDK `env=`).
  @doc false
  @spec instantiate_for_flavor(module(), String.t(), map(), URI.t(), keyword()) ::
          {:ok, [URI.t()], map()} | {:error, term()}
  def instantiate_for_flavor(flavor_class, uri_str, tmpl, workspace_uri, opts)
      when is_atom(flavor_class) and is_binary(uri_str) and is_map(tmpl) do
    agent_uri = Ezagent.URI.new!(uri_str)

    # #201 PR-2 — the speculative pre-spawn `AgentFlavorAttributes` write was
    # DELETED: the only flavor write is the spawn winner's post-ownership store
    # in `TemplateSpawn.complete_spawn_obligations` (from the content flavor).
    cond do
      opts == [] and agent_kind_alive?(agent_uri) ->
        {:ok, [agent_uri], %{fresh?: false}}

      true ->
        with {:ok, tmpl} <- ensure_config_home(agent_uri, tmpl) do
          spawn_for_headless(agent_uri, tmpl, workspace_uri, opts)
        end
    end
  end

  # F4 / #1460 — the headless SDK sidecar requires a config home
  # (`EZAGENT_CC_SDK_CONFIG_DIR`); a template content WITHOUT `config_dir`
  # used to flow through `create_agent_config_dir/2` as `{:ok, nil}` and crash
  # the sidecar on `String.to_charlist(nil)` (a FunctionClauseError, not a
  # validation error). The workspace create lane never hits this because
  # `file_flavor_template` always injects the per-agent target. Give the
  # template.instantiate lane the same guarantee: default a MISSING
  # `config_dir` to the canonical per-agent path and allocate it, so the
  # shared materialize path runs (derived config, sandbox skills, plugin
  # manifest, completion marker) exactly as in the create lane. A present but
  # malformed `config_dir` is left untouched so
  # `create_agent_config_dir/2`'s `{:error, {:invalid_config_dir, _}}` still
  # fails loud.
  @doc false
  @spec ensure_config_home(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def ensure_config_home(agent_uri, tmpl) do
    case Map.get(tmpl, "config_dir") do
      nil ->
        with {:ok, target} <-
               Ezagent.Sandbox.ConfigDir.allocate(
                 agent_uri,
                 Ezagent.Kind.Template.namespace_of(__MODULE__)
               ) do
          {:ok,
           tmpl
           |> Map.put("config_dir", target)
           |> Map.put("allocated_config_dir", target)}
        end

      _ ->
        {:ok, tmpl}
    end
  end

  # ---- Spawn path ---------------------------------------------------------

  defp spawn_for_headless(agent_uri, tmpl, _workspace_uri, opts) do
    claude_session_id = Map.get(tmpl, "claude_session_id") || new_session_id()

    with {:ok, started_or_adopted} <- ensure_agent_kind(agent_uri, claude_session_id, opts) do
      case started_or_adopted do
        :already_started ->
          _ = ensure_subprocess_alive(agent_uri, tmpl)
          {:ok, [agent_uri], %{fresh?: false}}

        {:started, false, _witness} ->
          # #201 PR-3 — REHYDRATING winner (`:started ∧ ¬created?`): a cold,
          # durably pre-existing agent. ZERO credential writes: NO grant-scoped
          # materialization; the Kind's own `Sandbox.post_init` self-heals the
          # subprocess from the DURABLE respawn state. No `:config_dir_path` in
          # meta → `record_sandbox_state` preserves the existing slice.
          {:ok, [agent_uri], %{fresh?: true, created?: false}}

        {:started, true, created_witness} ->
          # #201-cred (codex r2 NEW-HIGH-3) — thread the created-winner witness
          # into the cascade map (inside the helper, AFTER the sandbox-content
          # attach) so the deferred mint proves it is on this arm.
          case create_agent_config_dir_with_grant(agent_uri, tmpl, created_witness) do
            {:ok, config_dir, grant_ctx} ->
              tmpl_with_dir =
                tmpl
                |> put_agent_config_dir(config_dir)
                |> Map.put("claude_session_id", claude_session_id)

              case revalidate_grant_before_launch(grant_ctx) do
                :ok ->
                  case ensure_sdk_sidecar(agent_uri, tmpl_with_dir) do
                    :ok ->
                      Logger.info(
                        "cc-headless: agent #{URI.to_string(agent_uri)} " <>
                          "spawned with SDK sidecar"
                      )

                      {:ok, [agent_uri],
                       %{
                         fresh?: true,
                         # #201 PR-1 — core-issued logical-create verdict from
                         # the spawn receipt, passed through for the chokepoint's
                         # create-only write gates.
                         created?: true,
                         # #201-cred — the deferred-mint receipt for the
                         # chokepoint's rollback (nil = no grant minted).
                         grant_incarnation_id:
                           Ezagent.Credential.HomeRuntime.grant_ctx_incarnation(grant_ctx),
                         config_dir_path: config_dir,
                         respawn_template_data: tmpl_with_dir
                       }}

                    {:error, reason} ->
                      rollback_runtime(agent_uri)
                      compensate_and_report(agent_uri, grant_ctx, reason)
                  end

                {:error, reason} ->
                  rollback_runtime(agent_uri)
                  compensate_and_report(agent_uri, grant_ctx, reason)
              end

            {:error, reason} ->
              rollback_runtime(agent_uri)
              handle_spawn_failure(agent_uri, reason)
          end
      end
    end
  end

  defp put_agent_config_dir(tmpl, dir),
    do: Ezagent.Credential.HomeRuntime.put_agent_config_dir(tmpl, dir)

  defp create_agent_config_dir_with_grant(agent_uri, tmpl, created_witness) do
    with {:ok, tmpl} <-
           Ezagent.PluginCc.Template.CcAgent.attach_role_sandbox_content(tmpl, agent_uri) do
      # #201-cred (codex r2 NEW-HIGH-3) — inject the created-winner witness into
      # the cascade map AFTER the attach so the deferred mint can prove this arm.
      tmpl = Ezagent.Credential.HomeRuntime.put_cascade_created_witness(tmpl, created_witness)

      Ezagent.Credential.HomeRuntime.create_agent_config_dir_with_grant(
        agent_uri,
        tmpl,
        __MODULE__,
        config_home_opts()
      )
    end
  end

  defp revalidate_grant_before_launch(grant_ctx),
    do: Ezagent.Credential.HomeRuntime.revalidate_grant_before_launch(grant_ctx)

  # ---- ensure_subprocess_alive --------------------------------------------

  @impl Ezagent.Kind.Template
  def ensure_subprocess_alive(%URI{} = agent_uri, respawn_data) when is_map(respawn_data) do
    if EzagentPluginCc.SdkSidecar.alive?(agent_uri) do
      :ok
    else
      ensure_sdk_sidecar(agent_uri, respawn_data)
    end
  end

  def ensure_subprocess_alive(_, _), do: {:error, :invalid_args}

  # ---- Agent Kind ---------------------------------------------------------

  defp ensure_agent_kind(agent_uri, claude_session_id, opts) do
    init_args = %{
      uri: agent_uri,
      behaviors: Ezagent.Entity.Agent.cc_headless_behaviors(),
      claude_session_id: claude_session_id
    }

    # derivation-edge: template-post-obligation TemplateSpawn records fresh workers
    # #201 PR-1 — the spawn receipt surfaces BOTH the atomic winner verdict
    # (`:started` / `:already_started`) and the core logical-create verdict
    # (`created?`), which the TemplateSpawn chokepoint gates create-only
    # writes on.
    case Ezagent.Kind.spawn_receipt(Ezagent.Entity.Agent, init_args, opts) do
      {:ok, :started, _pid, %{created?: created?} = receipt} ->
        {:ok, {:started, created?, Map.get(receipt, :created_witness)}}

      {:ok, :already_started, _pid, _receipt} ->
        {:ok, :already_started}

      {:error, reason} ->
        {:error, {:agent_spawn_failed, reason}}
    end
  end

  defp agent_kind_alive?(agent_uri) do
    Ezagent.LocalRuntime.kind_alive?(agent_uri)
  end

  # ---- Failure handling ---------------------------------------------------

  # #201-cred (codex r2 HIGH-2) — post-mint spawn failure: CONFIRM-compensate
  # exactly the minted grant incarnation, then the config-dir teardown (the
  # shared HomeRuntime path).
  defp compensate_and_report(agent_uri, grant_ctx, reason) do
    Ezagent.Credential.HomeRuntime.compensate_spawn_failure(
      agent_uri,
      grant_ctx,
      reason,
      __MODULE__,
      "cc-headless.agent"
    )
  end

  defp handle_spawn_failure(agent_uri, reason) do
    Ezagent.PluginCc.Template.CcAgent.handle_spawn_failure(agent_uri, reason)
  end

  defp config_home_opts,
    do: [stage_error_tag: :config_dir_materialize_failed, chmod_error: :tagged]

  defp ensure_sdk_sidecar(agent_uri, tmpl) do
    if EzagentPluginCc.SdkSidecar.alive?(agent_uri) do
      :ok
    else
      case EzagentPluginCc.SdkSidecar.start(agent_uri, sdk_sidecar_params(agent_uri, tmpl)) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, {:cc_headless_sdk_sidecar_start_failed, reason}}
      end
    end
  end

  # Public (`@doc false`) so the cc-custom-backend test can assert the provider
  # env (`cmd_env`) threaded into the sidecar without starting a real sidecar.
  @doc false
  def sdk_sidecar_params(agent_uri, tmpl) do
    config_dir =
      Ezagent.Credential.HomeRuntime.resolve_config_home(agent_uri, tmpl, __MODULE__) ||
        Map.get(tmpl, "agent_config_dir") ||
        Map.get(tmpl, "config_dir")

    plugins = plugins_from_config_dir(config_dir)

    %{
      cwd: Map.fetch!(tmpl, "cwd"),
      config_dir: config_dir,
      session_id: Map.get(tmpl, "claude_session_id") || new_session_id(),
      # PTY parity (live e2e 2026-07-17): the PTY flavor launches `claude` with
      # `--dangerously-skip-permissions` (SpawnPlan argv); headless ran
      # `permission_mode=default`, and since a headless sidecar has NOBODY to
      # answer a prompt, every skill-reference Read / outside-cwd Bash / Write
      # hung on approval — the kanban-assistant could not execute its own
      # skill's CLI. `bypassPermissions` is the SDK equivalent of the PTY flag.
      #
      # Scope of the argument (codex review of PR #1452): this is a BEHAVIOR
      # PARITY claim with the PTY flavor, not a full-boundary claim. CapBAC
      # bounds what the agent can DISPATCH through the ezagent CLI (token +
      # caps on every action); it does NOT bound Bash/Read/Write/network on
      # the shared host — neither does the PTY flavor today. Tightening both
      # flavors behind per-agent OS isolation (or a role-gated bypass) is a
      # platform decision tracked in the task-A return's open decisions.
      # An explicit template value still overrides.
      permission_mode: Map.get(tmpl, "permission_mode", "bypassPermissions"),
      model: Map.get(tmpl, "model"),
      effort: Map.get(tmpl, "effort") || Map.get(tmpl, "claude_effort"),
      cli_path: Map.get(tmpl, "claude_cli_path"),
      system_prompt: system_prompt_from(tmpl),
      allowed_tools: ensure_skill_tool(Map.get(tmpl, "allowed_tools"), plugins != []),
      disallowed_tools: Map.get(tmpl, "disallowed_tools"),
      mcp_servers: Map.get(tmpl, "mcp_servers"),
      # Provider/backend env (anthropic | custom-backend profile), ORTHOGONAL
      # to the headless transport. anthropic → %{} (unchanged). A catalog
      # profile → its env block; the sidecar exports it as `EZAGENT_CC_SDK_ENV`
      # and the Python worker applies it as the Claude Code SDK subprocess
      # `env=`, so a headless custom-backend agent talks to the vendor endpoint
      # exactly like the pty path. The custom-backend instantiate already
      # fail-fasts on a missing profile API key.
      #
      # ALSO carries the CLI-identity credential for ROLE-agents (#1323 落 main /
      # Phase 3 ③ T7d parity): the SAME `SpawnPlan.maybe_put_cli_identity_env/3`
      # seam the PTY flavor uses, so a headless role-agent (e.g. the
      # kanban-assistant) can drive the ezagent CLI as itself from its Bash
      # tool (`EZAGENT_USER_TOKEN` → `EzagentCli.Exec`). Role-less agents get
      # provider env only — no behavior change.
      cmd_env: cmd_env(agent_uri, tmpl),
      uv_path: Map.get(tmpl, "uv_path"),
      python_path: Map.get(tmpl, "python_path"),
      sdk_worker_path: Map.get(tmpl, "sdk_worker_path"),
      plugins: plugins
    }
  end

  defp cmd_env(agent_uri, tmpl) do
    tmpl
    |> provider_cmd_env()
    |> Ezagent.PluginCc.Template.SpawnPlan.maybe_put_cli_identity_env(agent_uri, tmpl)
  end

  defp provider_cmd_env(tmpl) do
    case Ezagent.PluginCc.Provider.provider_env(tmpl) do
      {:ok, env} ->
        env

      # Unreachable when the flavor's instantiate/3 gates correctly
      # (`CcHeadlessCustomAgent`'s `Provider.ensure_api_key/2` fail-fast runs
      # before this) — this raise is the defense line for a template that
      # bypassed those gates. Fail loud so the misconfiguration is visible; no
      # silent fallback to the default anthropic path (precedent:
      # CcAgent.reject_stale_config_dir_data_key!/1).
      {:error, reason} ->
        raise ArgumentError,
              "cc-headless: provider " <>
                inspect(Ezagent.PluginCc.Provider.provider_of(tmpl)) <>
                " failed closed — " <>
                inspect(reason) <>
                ". Refusing to silently fall back to the default anthropic path; " <>
                "the flavor's instantiate/3 should have gated this before spawn " <>
                "(fail loud so the misconfiguration is visible, no silent fallback)."
    end
  end

  # Persona: resolve the system prompt from the template. Explicit
  # `system_prompt` key takes precedence (operator override — including
  # explicit empty string); fallback reads `sandbox_content.prompt`
  # (recipe persona, the §2 R1 mapping).
  defp system_prompt_from(tmpl) do
    if Map.has_key?(tmpl, "system_prompt") do
      Map.get(tmpl, "system_prompt")
    else
      get_in(tmpl, ["sandbox_content", :prompt])
    end
  end

  # Compute the SDK-side plugins list from the per-agent config_dir.
  # When the config_dir carries `.claude-plugin/plugin.json` (materialized by
  # HomeRuntime), the agent is its own plugin bundle — skills at
  # `<config_dir>/skills/<ref>/` are discoverable via the SDK's plugin path,
  # bypassing `setting_sources=[]`.
  defp plugins_from_config_dir(nil), do: []

  defp plugins_from_config_dir(config_dir) when is_binary(config_dir) do
    if File.exists?(Path.join(config_dir, ".claude-plugin/plugin.json")) do
      [%{"type" => "local", "path" => config_dir}]
    else
      []
    end
  end

  # The SDK auto-adds `Skill` to allowed_tools when `skills` is explicitly set,
  # but NOT when skills arrive via `plugins`. When the caller explicitly passes
  # an allowed_tools list AND plugins are configured, ensure `Skill` is present
  # so the agent can invoke plugin-loaded skills. When allowed_tools is nil,
  # the SDK's default tool set applies — don't override it.
  defp ensure_skill_tool(nil, _has_plugins?), do: nil

  defp ensure_skill_tool(tools, true = _has_plugins?) when is_list(tools) do
    if "Skill" not in tools, do: tools ++ ["Skill"], else: tools
  end

  defp ensure_skill_tool(tools, _has_plugins?), do: tools

  defp rollback_runtime(agent_uri) do
    _ = EzagentPluginCc.SdkSidecar.stop(agent_uri)
    _ = Ezagent.Kind.terminate!(agent_uri)
    :ok
  end

  defp new_session_id do
    "ezagent-cc-headless-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  # ---- Validation helpers (delegates/duplicates CcAgent patterns) ----------

  defp check_class(%{"class" => "cc_headless.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_cwd(%{"cwd" => cwd}) when is_binary(cwd) and cwd != "", do: :ok
  defp check_cwd(_), do: {:error, :missing_cwd}

  defp check_agent_uri(tmpl), do: Ezagent.Kind.Template.check_agent_uri(tmpl)

  defp check_optional_config_dir(tmpl) do
    case Map.fetch(tmpl, "config_dir") do
      :error -> :ok
      {:ok, value} when is_binary(value) and value != "" -> :ok
      {:ok, bad} -> {:error, {:invalid_config_dir, bad}}
    end
  end

  # Reject the stale config_dir data key to catch test regressions.
  defp reject_stale_config_dir_data_key!(tmpl) do
    Ezagent.PluginCc.Template.CcAgent.reject_stale_config_dir_data_key!(tmpl)
  end
end
