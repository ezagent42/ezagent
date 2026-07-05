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
         :ok <- check_agent_uri(tmpl),
         :ok <- check_cwd(tmpl),
         :ok <- check_optional_config_dir(tmpl),
         :ok <- reject_stale_config_dir_data_key!(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
    agent_uri = Ezagent.URI.new!(uri_str)

    with :ok <- Ezagent.AgentFlavorAttributes.put_from_template_class(agent_uri, __MODULE__) do
      cond do
        agent_kind_alive?(agent_uri) ->
          {:ok, [agent_uri], %{fresh?: false}}

        true ->
          spawn_for_headless(agent_uri, tmpl, workspace_uri)
      end
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

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
    Ezagent.Credential.HomeRuntime.create_agent_config_dir_with_grant(
      agent_uri,
      tmpl,
      __MODULE__,
      config_home_opts()
    )
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

  defp sdk_sidecar_params(agent_uri, tmpl) do
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
      uv_path: Map.get(tmpl, "uv_path"),
      python_path: Map.get(tmpl, "python_path"),
      sdk_worker_path: Map.get(tmpl, "sdk_worker_path")
    }
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
