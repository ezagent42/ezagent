defmodule Ezagent.PluginCodex.Template.CodexRemoteAgent do
  @moduledoc """
  Codex Remote agent Template Class — headless codex (no PTY/TUI).

  Like `codex.agent` but omits the PTY/TUI sidecar. Starts only the
  Codex app-server + Python bridge sidecar, which together provide the
  full AgentBridge delivery path for headless/remote operation.
  """

  @behaviour Ezagent.Kind.Template

  require Logger

  @compile_env Mix.env()
  @thread_id_wait_ms 15_000

  @impl Ezagent.Kind.Template
  def template_name, do: "codex_remote.agent"

  @impl Ezagent.Kind.Template
  def config_dir_namespace, do: "codex-remote"

  # Credential adapter — delegates to CodexAgent (same CODEX_HOME, auth.json, config.toml).
  @behaviour Ezagent.Agent.CredentialAdapter

  @impl Ezagent.Agent.CredentialAdapter
  def credential_env_var, do: Ezagent.PluginCodex.Template.CodexAgent.credential_env_var()

  @impl Ezagent.Agent.CredentialAdapter
  def credential_relpaths, do: Ezagent.PluginCodex.Template.CodexAgent.credential_relpaths()

  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: Ezagent.PluginCodex.Template.CodexAgent.secret_relpaths()

  @impl Ezagent.Agent.CredentialAdapter
  def auth_failure_signals, do: Ezagent.PluginCodex.Template.CodexAgent.auth_failure_signals()

  @impl Ezagent.Agent.CredentialAdapter
  def refresh_test_credentials(source, home, opts \\ []) do
    Ezagent.PluginCodex.Template.CodexAgent.refresh_test_credentials(source, home, opts)
  end

  # #160 — credential-status view. Same CODEX_HOME/auth.json as codex.
  @impl Ezagent.Agent.CredentialAdapter
  def credential_status(home, opts \\ []),
    do: Ezagent.PluginCodex.Template.CodexAgent.credential_status(home, opts)

  # template_data_extra — delegates to CodexAgent (same model/approval/sandbox fields).
  @impl Ezagent.Kind.Template
  def template_data_extra(content),
    do: Ezagent.PluginCodex.Template.CodexAgent.template_data_extra(content)

  @impl Ezagent.Kind.Template
  def compile(resolved, params) do
    Ezagent.Kind.Template.compile_codex_agent_data(
      resolved,
      params,
      &Ezagent.PluginCodex.Template.CodexAgent.template_data_extra/1
    )
  end

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_cwd(tmpl),
         :ok <- check_optional_config_dir(tmpl),
         :ok <- Ezagent.PluginCodex.Template.CodexAgent.ConfigSchema.validate_values(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
    agent_uri = Ezagent.URI.new!(uri_str)

    with :ok <- Ezagent.AgentFlavorAttributes.put_from_template_class(agent_uri, __MODULE__) do
      cond do
        fully_alive?(agent_uri) ->
          {:ok, [agent_uri], %{fresh?: false}}

        true ->
          spawn_for_codex_remote(agent_uri, tmpl, workspace_uri)
      end
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  # ---- Spawn path ---------------------------------------------------------

  defp spawn_for_codex_remote(agent_uri, tmpl, workspace_uri) do
    with {:ok, started_or_adopted} <- ensure_agent_kind(agent_uri) do
      case started_or_adopted do
        :already_started ->
          if owns_this_agent?(agent_uri, workspace_uri) do
            _ = ensure_subprocess_alive(agent_uri, tmpl)
          end

          {:ok, [agent_uri], %{fresh?: false}}

        :started ->
          case create_agent_config_dir_with_grant(agent_uri, tmpl) do
            {:ok, config_dir, grant_ctx} ->
              tmpl_with_dir = put_agent_config_dir(tmpl, config_dir)

              case revalidate_grant_before_launch(grant_ctx) do
                :ok ->
                  case ensure_remote_sidecars(agent_uri, tmpl_with_dir) do
                    {:ok, meta} ->
                      {:ok, [agent_uri],
                       meta
                       |> Map.put(:fresh?, true)
                       |> Map.put(:config_dir_path, config_dir)
                       |> Map.put(:respawn_template_data, tmpl_with_dir)}

                    {:error, reason} ->
                      rollback_remote_sidecars(agent_uri)
                      _ = Ezagent.Kind.terminate(agent_uri)
                      handle_spawn_failure(agent_uri, reason)
                  end

                {:error, reason} ->
                  _ = Ezagent.Kind.terminate(agent_uri)
                  handle_spawn_failure(agent_uri, reason)
              end

            {:error, reason} ->
              _ = Ezagent.Kind.terminate(agent_uri)
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

  # ---- Sidecars (AppServer + BridgeSidecar, NO PTY) -----------------------

  defp ensure_remote_sidecars(agent_uri, tmpl) do
    cwd = Map.fetch!(tmpl, "cwd")
    socket_path = app_server_socket_path(agent_uri, tmpl)
    thread_id_path = thread_id_path(agent_uri, tmpl)
    test_mode = Application.get_env(:ezagent_plugin_codex, :test_mode, @compile_env == :test)
    bridge_ws_url = Map.get(tmpl, "bridge_ws_url", default_bridge_ws_url())
    codex_path = Map.get(tmpl, "codex_path")

    with :ok <- ensure_app_server(agent_uri, cwd, socket_path, codex_path, test_mode, tmpl),
         :ok <- reset_thread_id_file_for_new_bridge(agent_uri, thread_id_path, test_mode),
         :ok <-
           ensure_bridge_sidecar(
             agent_uri,
             cwd,
             socket_path,
             thread_id_path,
             bridge_ws_url,
             tmpl,
             codex_path,
             test_mode
           ),
         {:ok, thread_id} <- ensure_bridge_thread_id(agent_uri, thread_id_path, test_mode) do
      {:ok,
       %{
         app_server_socket: socket_path,
         codex_thread_id: thread_id,
         codex_thread_id_file: thread_id_path,
         bridge_ws_url: bridge_ws_url
       }}
    end
  end

  defp ensure_app_server(agent_uri, cwd, socket_path, codex_path, test_mode, tmpl) do
    if EzagentPluginCodex.AppServer.alive?(agent_uri) do
      ensure_app_server_ready(agent_uri, socket_path, test_mode)
    else
      params =
        Ezagent.PluginCodex.Template.CodexAgent.build_app_server_params(
          cwd,
          socket_path,
          codex_path,
          test_mode,
          tmpl
        )

      case EzagentPluginCodex.AppServer.start(agent_uri, params) do
        {:ok, _pid} ->
          ensure_app_server_ready(agent_uri, socket_path, test_mode)

        {:error, {:already_started, _pid}} ->
          ensure_app_server_ready(agent_uri, socket_path, test_mode)

        {:error, reason} ->
          {:error, {:codex_app_server_start_failed, reason}}
      end
    end
  end

  # Identical app-server readiness wait as CodexAgent — delegate rather than copy.
  defdelegate ensure_app_server_ready(agent_uri, socket_path, test_mode),
    to: Ezagent.PluginCodex.Template.CodexAgent

  defp ensure_bridge_sidecar(
         agent_uri,
         cwd,
         socket_path,
         thread_id_path,
         bridge_ws_url,
         tmpl,
         codex_path,
         test_mode
       ) do
    restart_bridge_without_thread_file(agent_uri, thread_id_path, test_mode)

    if EzagentPluginCodex.BridgeSidecar.alive?(agent_uri) do
      :ok
    else
      params =
        Ezagent.PluginCodex.Template.CodexAgent.build_bridge_sidecar_params(
          cwd,
          socket_path,
          thread_id_path,
          bridge_ws_url,
          tmpl,
          codex_path,
          test_mode
        )
        |> Map.put(:bridge_topic, remote_bridge_topic(agent_uri))

      case EzagentPluginCodex.BridgeSidecar.start(agent_uri, params) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, {:codex_bridge_sidecar_start_failed, reason}}
      end
    end
  end

  defp restart_bridge_without_thread_file(_agent_uri, _thread_id_path, true), do: :ok

  defp restart_bridge_without_thread_file(agent_uri, thread_id_path, false) do
    if EzagentPluginCodex.BridgeSidecar.alive?(agent_uri) and not File.exists?(thread_id_path) do
      _ = EzagentPluginCodex.BridgeSidecar.stop(agent_uri)
    end

    :ok
  end

  # Rollback only AppServer + BridgeSidecar (no PTY to stop).
  defp rollback_remote_sidecars(agent_uri) do
    _ = EzagentPluginCodex.BridgeSidecar.stop(agent_uri)
    _ = EzagentPluginCodex.AppServer.stop(agent_uri)
    :ok
  end

  @doc false
  def remote_bridge_topic(%URI{} = agent_uri) do
    EzagentPluginCodex.CodexRemoteBridgeAdapter.channel_topic_prefix() <> URI.to_string(agent_uri)
  end

  # ---- ensure_subprocess_alive (respawn on cold restart) ------------------

  @impl Ezagent.Kind.Template
  def ensure_subprocess_alive(%URI{} = agent_uri, respawn_data) when is_map(respawn_data) do
    cond do
      remote_sidecars_alive?(agent_uri) ->
        :ok

      true ->
        with {:ok, respawn_data} <-
               Ezagent.Credential.CascadeRuntime.rehydrate_respawn_data(agent_uri, respawn_data) do
          cond do
            grant_revoked_for_restart?(agent_uri) ->
              {:error, {:credential_grant_revoked, agent_uri}}

            true ->
              case Map.fetch(respawn_data, "cwd") do
                {:ok, cwd} when is_binary(cwd) and cwd != "" ->
                  case ensure_remote_sidecars(agent_uri, respawn_data) do
                    {:ok, _meta} ->
                      Logger.info(
                        "codex_remote.agent.ensure_subprocess_alive: respawned sidecars for " <>
                          URI.to_string(agent_uri)
                      )

                      :ok

                    {:error, reason} ->
                      Logger.error(
                        "codex_remote.agent.ensure_subprocess_alive: failed for " <>
                          "#{URI.to_string(agent_uri)}: #{inspect(reason)}"
                      )

                      {:error, reason}
                  end

                _ ->
                  {:error, {:missing_cwd_in_respawn_data, agent_uri}}
              end
          end
        end
    end
  end

  def ensure_subprocess_alive(_, _), do: {:error, :invalid_args}

  # ---- Health checks ------------------------------------------------------

  defp fully_alive?(agent_uri) do
    agent_kind_alive?(agent_uri) and remote_sidecars_alive?(agent_uri)
  end

  defp remote_sidecars_alive?(agent_uri) do
    EzagentPluginCodex.AppServer.alive?(agent_uri) and
      EzagentPluginCodex.BridgeSidecar.alive?(agent_uri)
  end

  defp agent_kind_alive?(agent_uri) do
    Ezagent.LocalRuntime.kind_alive?(agent_uri)
  end

  # ---- Failure handling ---------------------------------------------------

  defp handle_spawn_failure(agent_uri, reason) do
    Ezagent.PluginCodex.Template.CodexAgent.handle_spawn_failure(agent_uri, reason)
  end

  defp grant_revoked_for_restart?(%URI{} = agent_uri),
    do: Ezagent.Credential.HomeRuntime.grant_revoked_for_restart?(agent_uri)

  defp config_home_opts,
    do: [stage_error_tag: :config_dir_materialize_failed, chmod_error: :tagged]

  # ---- Agent Kind + ownership ---------------------------------------------

  defp ensure_agent_kind(agent_uri) do
    case Ezagent.LocalRuntime.ensure_started_detailed(agent_uri) do
      {:ok, :started, _pid} -> {:ok, :started}
      {:ok, :already_started, _pid} -> {:ok, :already_started}
      {:error, reason} -> {:error, {:agent_spawn_failed, reason}}
    end
  end

  defp owns_this_agent?(%URI{} = agent_uri, %URI{} = workspace_uri) do
    case Ezagent.URI.workspace_name(agent_uri) do
      {:ok, workspace} -> workspace == workspace_uri.host
      :error -> false
    end
  end

  defp owns_this_agent?(_agent_uri, _workspace_uri), do: false

  # ---- Path helpers -------------------------------------------------------

  defp app_server_socket_path(agent_uri, tmpl) do
    Map.get(tmpl, "app_server_socket") ||
      Ezagent.PluginCodex.Template.CodexAgent.default_app_server_socket_path(agent_uri)
  end

  defp thread_id_path(agent_uri, tmpl) do
    Map.get(tmpl, "thread_id_file") ||
      Path.join(Path.dirname(app_server_socket_path(agent_uri, tmpl)), "bridge-thread-id")
  end

  defp default_bridge_ws_url do
    Application.get_env(
      :ezagent_plugin_codex,
      :bridge_ws_url,
      "ws://127.0.0.1:10042/agent_bridge/websocket"
    )
  end

  defp reset_thread_id_file_for_new_bridge(_agent_uri, _thread_id_path, true), do: :ok

  defp reset_thread_id_file_for_new_bridge(agent_uri, thread_id_path, false) do
    unless EzagentPluginCodex.BridgeSidecar.alive?(agent_uri) do
      _ = File.rm(thread_id_path)
    end

    :ok
  end

  defp ensure_bridge_thread_id(_agent_uri, _thread_id_path, true), do: {:ok, nil}

  defp ensure_bridge_thread_id(agent_uri, thread_id_path, false) do
    wait_for_thread_id(
      agent_uri,
      thread_id_path,
      System.monotonic_time(:millisecond) + @thread_id_wait_ms
    )
  end

  defp wait_for_thread_id(agent_uri, thread_id_path, deadline_ms) do
    case File.read(thread_id_path) do
      {:ok, body} ->
        case String.trim(body) do
          "" -> retry_thread_id(agent_uri, thread_id_path, deadline_ms)
          thread_id -> {:ok, thread_id}
        end

      {:error, :enoent} ->
        retry_thread_id(agent_uri, thread_id_path, deadline_ms)

      {:error, reason} ->
        {:error, {:codex_thread_id_file_read_failed, thread_id_path, reason}}
    end
  end

  defp retry_thread_id(agent_uri, thread_id_path, deadline_ms) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      {:error,
       {:codex_thread_id_file_timeout, thread_id_path,
        EzagentPluginCodex.BridgeSidecar.recent_output(agent_uri)}}
    else
      Process.sleep(100)
      wait_for_thread_id(agent_uri, thread_id_path, deadline_ms)
    end
  end

  # ---- Validation helpers -------------------------------------------------

  defp check_class(%{"class" => "codex_remote.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_cwd(%{"cwd" => cwd}) when is_binary(cwd) and cwd != "", do: :ok
  defp check_cwd(_), do: {:error, :missing_cwd}

  defp check_optional_config_dir(tmpl) do
    case Map.fetch(tmpl, "config_dir") do
      :error -> :ok
      {:ok, value} when is_binary(value) and value != "" -> :ok
      {:ok, bad} -> {:error, {:invalid_config_dir, bad}}
    end
  end

  defp check_agent_uri(tmpl), do: Ezagent.Kind.Template.check_agent_uri(tmpl)
end
