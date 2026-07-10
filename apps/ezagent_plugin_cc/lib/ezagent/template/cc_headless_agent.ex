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
  # with the deepseek provider shim (`CcHeadlessDeepseekAgent`) so its
  # `validate/1` reuses the exact rules while accepting its own
  # `"cc_headless_deepseek.agent"` class.
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
    instantiate_for_flavor(__MODULE__, uri_str, tmpl, workspace_uri)
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  # Flavor-parameterized instantiate body, shared with the deepseek provider
  # shim (`CcHeadlessDeepseekAgent`) so the STORED launch flavor is the caller's
  # flavor (`cc-headless` vs `cc-headless-deepseek`) while the SDK-sidecar spawn
  # path stays this single module. The provider dimension rides in `tmpl` as a
  # `"provider"` data field (read by `sdk_sidecar_params/2` → the sidecar's
  # `EZAGENT_CC_SDK_ENV` passthrough → the Python worker's SDK `env=`).
  @doc false
  @spec instantiate_for_flavor(module(), String.t(), map(), URI.t()) ::
          {:ok, [URI.t()], map()} | {:error, term()}
  def instantiate_for_flavor(flavor_class, uri_str, tmpl, workspace_uri)
      when is_atom(flavor_class) and is_binary(uri_str) and is_map(tmpl) do
    agent_uri = Ezagent.URI.new!(uri_str)

    with :ok <- Ezagent.AgentFlavorAttributes.put_from_template_class(agent_uri, flavor_class) do
      cond do
        agent_kind_alive?(agent_uri) ->
          {:ok, [agent_uri], %{fresh?: false}}

        true ->
          spawn_for_headless(agent_uri, tmpl, workspace_uri)
      end
    end
  end

  # ---- Spawn path ---------------------------------------------------------

  defp spawn_for_headless(agent_uri, tmpl, _workspace_uri) do
    claude_session_id = Map.get(tmpl, "claude_session_id") || new_session_id()

    with {:ok, started_or_adopted} <- ensure_agent_kind(agent_uri, claude_session_id) do
      case started_or_adopted do
        :already_started ->
          _ = ensure_subprocess_alive(agent_uri, tmpl)
          {:ok, [agent_uri], %{fresh?: false}}

        :started ->
          case create_agent_config_dir_with_grant(agent_uri, tmpl) do
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
                         config_dir_path: config_dir,
                         respawn_template_data: tmpl_with_dir
                       }}

                    {:error, reason} ->
                      rollback_runtime(agent_uri)
                      handle_spawn_failure(agent_uri, reason)
                  end

                {:error, reason} ->
                  rollback_runtime(agent_uri)
                  handle_spawn_failure(agent_uri, reason)
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

  defp create_agent_config_dir_with_grant(agent_uri, tmpl) do
    with {:ok, tmpl} <-
           Ezagent.PluginCc.Template.CcAgent.attach_role_sandbox_content(tmpl, agent_uri) do
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

  defp ensure_agent_kind(agent_uri, claude_session_id) do
    init_args = %{
      uri: agent_uri,
      behaviors: Ezagent.Entity.Agent.cc_headless_behaviors(),
      claude_session_id: claude_session_id
    }

    case Ezagent.Kind.spawn(Ezagent.Entity.Agent, init_args) do
      {:ok, _pid} -> {:ok, :started}
      {:error, {:already_started, _pid}} -> {:ok, :already_started}
      {:error, reason} -> {:error, {:agent_spawn_failed, reason}}
    end
  end

  defp agent_kind_alive?(agent_uri) do
    Ezagent.LocalRuntime.kind_alive?(agent_uri)
  end

  # ---- Failure handling ---------------------------------------------------

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

  # Public (`@doc false`) so the deepseek-backend test can assert the provider
  # env (`cmd_env`) threaded into the sidecar without starting a real sidecar.
  @doc false
  def sdk_sidecar_params(agent_uri, tmpl) do
    config_dir =
      Ezagent.Credential.HomeRuntime.resolve_config_home(agent_uri, tmpl, __MODULE__) ||
        Map.get(tmpl, "agent_config_dir") ||
        Map.get(tmpl, "config_dir")

    %{
      cwd: Map.fetch!(tmpl, "cwd"),
      config_dir: config_dir,
      session_id: Map.get(tmpl, "claude_session_id") || new_session_id(),
      permission_mode: Map.get(tmpl, "permission_mode", "default"),
      model: Map.get(tmpl, "model"),
      effort: Map.get(tmpl, "effort") || Map.get(tmpl, "claude_effort"),
      cli_path: Map.get(tmpl, "claude_cli_path"),
      system_prompt: Map.get(tmpl, "system_prompt"),
      allowed_tools: Map.get(tmpl, "allowed_tools"),
      disallowed_tools: Map.get(tmpl, "disallowed_tools"),
      mcp_servers: Map.get(tmpl, "mcp_servers"),
      # Provider/backend env (anthropic|deepseek), ORTHOGONAL to the headless
      # transport. anthropic → %{} (unchanged). deepseek → the 8-var DeepSeek
      # block; the sidecar exports it as `EZAGENT_CC_SDK_ENV` and the Python
      # worker applies it as the Claude Code SDK subprocess `env=`, so headless
      # deepseek talks to the DeepSeek endpoint exactly like the pty path. The
      # deepseek instantiate already fail-fasts on a missing DEEPSEEK_API_KEY.
      cmd_env: provider_cmd_env(tmpl),
      uv_path: Map.get(tmpl, "uv_path"),
      python_path: Map.get(tmpl, "python_path"),
      sdk_worker_path: Map.get(tmpl, "sdk_worker_path")
    }
  end

  defp provider_cmd_env(tmpl) do
    case Ezagent.PluginCc.Provider.provider_env(tmpl) do
      {:ok, env} -> env
      # Unreachable for deepseek (instantiate gates the key first); a bare {} is
      # a safe no-op for the sidecar's `maybe_json_env` (skips empty maps).
      {:error, _} -> %{}
    end
  end

  defp rollback_runtime(agent_uri) do
    _ = EzagentPluginCc.SdkSidecar.stop(agent_uri)
    _ = Ezagent.Kind.terminate(agent_uri)
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
