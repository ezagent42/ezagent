defmodule Ezagent.PluginCodex.Template.CodexAgent do
  @moduledoc """
  Codex agent Template Class.

  Instantiating `codex.agent` creates the shared `Ezagent.Entity.Agent`
  Kind, starts a per-agent Codex app-server sidecar, starts a
  user-visible Codex TUI in Domain.Pty, and starts a Python bridge
  sidecar that lets ezagent send turns into the same app-server thread.
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form

  require Logger

  @compile_env Mix.env()
  @thread_id_wait_ms 15_000

  @impl Ezagent.Kind.Template
  def template_name, do: "codex.agent"

  @impl Ezagent.Kind.Template
  def config_dir_namespace, do: "codex"

  # #17 PR-A — the codex credential adapter. Experiment-confirmed (2026-06-03):
  # codex isolates per-agent creds via CODEX_HOME (relocates config AND auth), so codex is
  # a first-class per-agent-file flavor symmetric to cc. See
  # [[reference_codex_codex_home_per_agent_auth]]. The CODEX_HOME allocation + auth.json
  # copy + env wiring lands in PR-A2; these are the pure declarations.
  @behaviour Ezagent.Agent.CredentialAdapter

  @impl Ezagent.Agent.CredentialAdapter
  def credential_env_var, do: "CODEX_HOME"

  @impl Ezagent.Agent.CredentialAdapter
  def credential_relpaths, do: ["auth.json", "config.toml"]

  # #17 cascade PR-0 (§D6, codex H4) — the SECRET subset, disjoint from config.
  # config.toml is configuration (joins the PR-2 layer merge), NOT a secret —
  # only auth.json is token material copied from the single resolved source.
  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: ["auth.json"]

  # codex's expiry/missing-auth signatures (confirm against a live expiry in PR-C).
  @impl Ezagent.Agent.CredentialAdapter
  def auth_failure_signals,
    do: [~r/Run codex login/, ~r/401 Unauthorized/, "no Codex credentials"]

  # #1201 A② — the node's HOST codex login home (`$CODEX_HOME` else `~/.codex`).
  # Consumed only through `CredentialAdapter.host_login_source_dir/1`, which
  # additionally requires a present `auth.json` before the dir is usable.
  @impl Ezagent.Agent.CredentialAdapter
  def host_login_dir,
    do: Ezagent.Credential.HomeRuntime.host_login_dir("CODEX_HOME", ".codex")

  # #21 PR-2b (④, TEST/E2E ONLY) — provision the full CODEX_HOME credential set
  # (auth.json + config.toml) from a durable `source` dir into the agent's `home`
  # CODEX_HOME, so the dockerized E2E runs without a human `codex login`. `source`
  # and `home` are CODEX_HOME DIRECTORIES (codex is dir-based, unlike cc's single
  # file). See `EzagentPluginCodex.CredentialRefresh`.
  @impl Ezagent.Agent.CredentialAdapter
  def refresh_test_credentials(source, home, opts \\ []) do
    EzagentPluginCodex.CredentialRefresh.provision(source, home, opts)
  end

  # #160 — credential-status view. codex has no readable expiry (`auth.json`
  # carries no `expiresAt`; the CLI self-refreshes), so the probe only reports
  # present/absent/unreadable and `expires_at` is always nil. Read-only, no network.
  @impl Ezagent.Agent.CredentialAdapter
  def credential_status(home, opts \\ []) do
    {status, detail} =
      case EzagentPluginCodex.CredentialFreshness.status(home, opts) do
        :authenticated -> {:authenticated, nil}
        :missing -> {:missing, "No `auth.json` — the agent has never logged in (`codex login`)"}
        :unknown -> {:unknown, nil}
      end

    %{status: status, detail: detail, expires_at: nil}
  end

  # SPEC 2026-06-01-flavor-generic-template-data (approach B): codex's
  # template_data fields, so an orchestrator-spawned codex worker carries
  # its model/approval/sandbox (pre-fix dropped by core's cc-only mapping).
  # `bridge_ws_url`/`codex_path` feed sidecar/app-server paths — emit them
  # ONLY as non-empty binaries; nil values dropped by the caller.
  @impl Ezagent.Kind.Template
  def template_data_extra(content) when is_map(content) do
    %{
      "model" => Ezagent.Kind.Template.content_field(content, :model),
      "approval_policy" => Ezagent.Kind.Template.content_field(content, :approval_policy),
      "sandbox" => Ezagent.Kind.Template.content_field(content, :sandbox),
      "role" => Ezagent.Kind.Template.content_field(content, :role)
    }
    |> maybe_put_binary(content, :bridge_ws_url, "bridge_ws_url")
    |> maybe_put_binary(content, :codex_path, "codex_path")
  end

  def template_data_extra(_), do: %{}

  @impl Ezagent.Kind.Template
  defdelegate config_schema, to: Ezagent.PluginCodex.Template.CodexAgent.ConfigSchema, as: :fields

  defp maybe_put_binary(map, content, key, str_key) do
    case Ezagent.Kind.Template.content_field(content, key) do
      v when is_binary(v) and v != "" -> Map.put(map, str_key, v)
      _ -> map
    end
  end

  @impl Ezagent.Kind.Template
  def compile(resolved, params),
    do: Ezagent.Kind.Template.compile_codex_agent_data(resolved, params, &template_data_extra/1)

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
    # SPEC 2026-05-27-uri-canonicalization §3 — boundary input routed
    # through the canonical chokepoint. Parity with the cc Template
    # `EzagentPluginCc.Template.CcAgent`.
    agent_uri = Ezagent.URI.new!(uri_str)

    with :ok <- Ezagent.AgentFlavorAttributes.put_from_template_class(agent_uri, __MODULE__) do
      cond do
        fully_alive?(agent_uri) ->
          {:ok, [agent_uri], %{fresh?: false}}

        true ->
          spawn_for_codex(agent_uri, tmpl, workspace_uri)
      end
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "agent_uri",
        type: :uri,
        label: "Agent URI",
        required: true,
        placeholder: "codex_builder"
      },
      %{
        name: "cwd",
        type: :path,
        label: "Working directory",
        required: true,
        placeholder: "/path/to/workspace"
      },
      %{
        name: "model",
        type: :text,
        label: "Model override",
        required: false,
        placeholder: "optional"
      },
      %{
        name: "approval_policy",
        type: :select,
        label: "Approval policy",
        required: false,
        options: ["", "never", "on-request", "untrusted"],
        default: ""
      },
      %{
        name: "sandbox",
        type: :select,
        label: "Sandbox",
        required: false,
        options: ["", "read-only", "workspace-write", "danger-full-access"],
        default: ""
      }
    ]
  end

  @impl Ezagent.UI.Form
  def form_to_args(params) when is_map(params) do
    params
    |> Map.drop(["tmpl_name"])
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
    |> Map.put("class", template_name())
  end

  defp spawn_for_codex(agent_uri, tmpl, workspace_uri) do
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

              # #17 cascade PR-2 (codex CRITICAL §5.1) — the config_dir is materialized but
              # the sidecars/PTY launch HERE (ensure_sidecars). Re-validate the grant
              # version IMMEDIATELY before launch; on :grant_changed ABORT + clear the
              # just-materialized config_dir so it is not left usable for the revoked grant.
              # No-grant agents skip this (nil ctx).
              case revalidate_grant_before_launch(grant_ctx) do
                :ok ->
                  case ensure_sidecars(agent_uri, tmpl_with_dir) do
                    {:ok, meta} ->
                      {:ok, [agent_uri],
                       meta
                       |> Map.put(:fresh?, true)
                       |> Map.put(:config_dir_path, config_dir)
                       |> Map.put(:respawn_template_data, tmpl_with_dir)}

                    {:error, reason} ->
                      rollback_sidecars(agent_uri)
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

  # #17 cascade PR-2 (codex CRITICAL §5.1) — normalize the 2-tuple (non-cascade) and
  # 3-tuple (cascade, carrying the grant ctx) returns of create_agent_config_dir/2.
  defp create_agent_config_dir_with_grant(agent_uri, tmpl) do
    Ezagent.Credential.HomeRuntime.create_agent_config_dir_with_grant(
      agent_uri,
      tmpl,
      __MODULE__,
      config_home_opts()
    )
  end

  # #17 cascade PR-2 (codex CRITICAL §5.1) — second grant re-validation immediately before
  # the sidecar/PTY launch. `nil` ctx → :ok. On :grant_changed the caller tears down + clears
  # the config_dir so nothing launches with (or leaves usable) a revoked grant's secret.
  defp revalidate_grant_before_launch(grant_ctx),
    do: Ezagent.Credential.HomeRuntime.revalidate_grant_before_launch(grant_ctx)

  defp ensure_sidecars(agent_uri, tmpl) do
    cwd = Map.fetch!(tmpl, "cwd")
    socket_path = app_server_socket_path(agent_uri, tmpl)
    thread_id_path = thread_id_path(agent_uri, tmpl)
    test_mode = Application.get_env(:ezagent_plugin_codex, :test_mode, @compile_env == :test)
    bridge_ws_url = Map.get(tmpl, "bridge_ws_url", default_bridge_ws_url())
    codex_path = Map.get(tmpl, "codex_path")

    # Bridge creates the Codex thread first; the PTY TUI resumes that
    # thread so operator input and AgentBridge turns share one context.
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
         {:ok, thread_id} <- ensure_bridge_thread_id(agent_uri, thread_id_path, test_mode),
         :ok <- ensure_pty(agent_uri, cwd, socket_path, thread_id, tmpl, codex_path, test_mode) do
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
      :ok
    else
      case EzagentPluginCodex.AppServer.start(
             agent_uri,
             build_app_server_params(cwd, socket_path, codex_path, test_mode, tmpl)
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, {:codex_app_server_start_failed, reason}}
      end
    end
  end

  defp ensure_pty(agent_uri, cwd, socket_path, thread_id, tmpl, codex_path, test_mode) do
    if Ezagent.Domain.Pty.alive?(agent_uri) do
      :ok
    else
      with {:ok, params} <- pty_params(cwd, socket_path, thread_id, tmpl, codex_path, test_mode) do
        case Ezagent.Domain.Pty.start(agent_uri, params) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:codex_tui_start_failed, reason}}
        end
      end
    end
  end

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
      case EzagentPluginCodex.BridgeSidecar.start(
             agent_uri,
             build_bridge_sidecar_params(
               cwd,
               socket_path,
               thread_id_path,
               bridge_ws_url,
               tmpl,
               codex_path,
               test_mode
             )
           ) do
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

  defp rollback_sidecars(agent_uri) do
    _ = EzagentPluginCodex.BridgeSidecar.stop(agent_uri)
    _ = Ezagent.Domain.Pty.stop(agent_uri)
    _ = EzagentPluginCodex.AppServer.stop(agent_uri)
    :ok
  end

  # codex H2 (FINDING 2) — handle a spawn failure AFTER the config_dir was materialized
  # (mirror of cc_agent.ex). Tear down the just-materialized grant-scoped secret dir, then
  # SURFACE a cleanup failure as BLOCKING: a grant-revoked-at-launch abort whose cleanup
  # fails leaves a usable revoked-grant credential dir in the canonical location — reporting
  # only the grant-change would silently leave it. Return a COMPOSITE
  # `{:grant_revoked_cleanup_failed, agent_uri, reason}` for that case; for any other failure
  # where cleanup also fails, attach the cleanup failure too.
  #
  # `@doc false` so the contract is directly unit-testable with an injected rm_rf failure.
  @doc false
  @spec handle_spawn_failure(URI.t(), term()) :: {:error, term()}
  def handle_spawn_failure(agent_uri, reason) do
    Ezagent.Credential.HomeRuntime.handle_spawn_failure(
      agent_uri,
      reason,
      __MODULE__,
      "codex.agent"
    )
  end

  defp pty_params(cwd, socket_path, thread_id, tmpl, codex_path, true) do
    build_pty_params_for_env(cwd, socket_path, thread_id, tmpl, codex_path, :test)
  end

  defp pty_params(cwd, socket_path, thread_id, tmpl, codex_path, false) do
    build_pty_params_for_env(cwd, socket_path, thread_id, tmpl, codex_path, :dev)
  end

  @doc false
  def build_pty_params_for_env(cwd, _socket_path, _thread_id, _tmpl, _codex_path, :test) do
    {:ok, %{cwd: cwd, test_mode: true}}
  end

  def build_pty_params_for_env(cwd, socket_path, thread_id, tmpl, codex_path, _env) do
    with {:ok, cmd} <- codex_tui_cmd(socket_path, cwd, thread_id, tmpl, codex_path) do
      # #17 PR-C (codex review P2) — wire codex's credential-adapter auth-failure signals
      # as emit-only PTY observers, same as cc, so an expired codex login surfaces
      # (telemetry + pty:auth_failed) instead of muting silently.
      {:ok,
       %{
         cwd: cwd,
         cmd_override: cmd,
         cmd_env: codex_home_env(tmpl),
         auth_observers: credential_auth_observers()
       }}
    end
  end

  # #17 PR-C — one named emit-only observer per declared codex auth-failure signal.
  defp credential_auth_observers do
    auth_failure_signals()
    |> Enum.with_index()
    |> Enum.map(fn {sig, i} -> %{name: :"codex_auth_failure_#{i}", match: sig} end)
  end

  defp codex_tui_cmd(socket_path, cwd, _thread_id, tmpl, codex_path) do
    with {:ok, codex} <- codex_executable(codex_path) do
      base = [codex, "resume", "--remote", "unix://#{socket_path}", "--cd", cwd]

      cmd =
        base
        |> maybe_append("--model", Map.get(tmpl, "model"))
        |> maybe_append("--ask-for-approval", Map.get(tmpl, "approval_policy"))
        |> maybe_append("--sandbox", Map.get(tmpl, "sandbox"))

      # codex 0.134.0: `resume --remote <addr> <SESSION_ID>` resolves the
      # positional SESSION_ID against the LOCAL rollout store (ignoring
      # --remote for the lookup) → "Failed to resume session from
      # ~/.codex/sessions/.../rollout-*.jsonl" → exit 256, because the thread
      # was created on the REMOTE app-server and has no local rollout. Verified
      # live 2026-06-03: `resume --remote <sock> --last` correctly attaches to
      # the remote app-server and resumes its most-recent thread. The
      # app-server is PER-AGENT (socket derived from agent_uri) and the bridge
      # sidecar just created the target thread before this TUI launches, so the
      # remote's most-recent thread IS the bridge thread. `thread_id` is still
      # created by the bridge (the TUI shares that thread); it is not passed
      # positionally anymore (that path resolves locally and fails).
      {:ok, cmd ++ ["--last"]}
    end
  end

  defp maybe_append(args, _flag, value) when value in [nil, ""], do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, value]

  defp codex_executable(path) when is_binary(path) and path != "", do: {:ok, path}

  defp codex_executable(_path) do
    case System.find_executable("codex") do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, :codex_not_found}
    end
  end

  @doc false
  def build_app_server_params(cwd, socket_path, codex_path, test_mode, tmpl) do
    %{
      cwd: cwd,
      socket_path: socket_path,
      codex_path: codex_path,
      test_mode: test_mode,
      cmd_env: codex_home_env(tmpl)
    }
  end

  @doc false
  def build_bridge_sidecar_params(
        cwd,
        socket_path,
        thread_id_path,
        bridge_ws_url,
        tmpl,
        codex_path,
        test_mode
      ) do
    %{
      cwd: cwd,
      app_server_socket: socket_path,
      thread_id_file: thread_id_path,
      bridge_ws_url: bridge_ws_url,
      codex_path: codex_path,
      model: Map.get(tmpl, "model"),
      approval_policy: Map.get(tmpl, "approval_policy"),
      sandbox: Map.get(tmpl, "sandbox"),
      test_mode: test_mode,
      cmd_env: codex_home_env(tmpl)
    }
  end

  @doc false
  def codex_home_env(%URI{} = agent_uri, tmpl) when is_map(tmpl) do
    case resolve_config_home(agent_uri, tmpl) do
      dir when is_binary(dir) and dir != "" -> %{"CODEX_HOME" => dir}
      _ -> %{}
    end
  end

  def codex_home_env(tmpl) when is_map(tmpl) do
    case Map.get(tmpl, "agent_uri") do
      uri_str when is_binary(uri_str) and uri_str != "" ->
        codex_home_env(Ezagent.URI.new!(uri_str), tmpl)

      _ ->
        case Map.get(tmpl, "agent_config_dir") || Map.get(tmpl, "allocated_config_dir") do
          dir when is_binary(dir) and dir != "" -> %{"CODEX_HOME" => dir}
          _ -> %{}
        end
    end
  end

  @doc false
  def resolve_config_home(%URI{} = agent_uri, tmpl) when is_map(tmpl) do
    Ezagent.Credential.HomeRuntime.resolve_config_home(agent_uri, tmpl, __MODULE__,
      on_malformed: {:raise, &invalid_config_dir_message/1}
    )
  end

  @doc false
  def agent_config_dir(%URI{} = agent_uri) do
    Ezagent.Credential.HomeRuntime.agent_config_dir(agent_uri, __MODULE__)
  end

  # Return: `{:ok, dir}` / `{:ok, nil}` on the non-cascade path (backward-compatible), OR
  # `{:ok, dir, {:grant, agent_uri_str, version}}` on the cascade path — the third element
  # carries the grant version validated at materialize so `spawn_for_codex/3` can
  # re-validate the grant IMMEDIATELY before the sidecar/PTY launch (codex CRITICAL §5.1).
  @doc false
  @spec create_agent_config_dir(URI.t(), map()) ::
          {:ok, String.t() | nil}
          | {:ok, String.t(), {:grant, String.t(), non_neg_integer()}}
          | {:error, term()}
  def create_agent_config_dir(%URI{} = agent_uri, tmpl) when is_map(tmpl) do
    Ezagent.Credential.HomeRuntime.create_agent_config_dir(
      agent_uri,
      tmpl,
      __MODULE__,
      config_home_opts()
    )
  end

  # #17 cascade PR-2 (§5.1) — true iff this agent has a credential grant that is now
  # REVOKED (no grant / active grant → false → proceed). Defensive: a DB read error must
  # not crash-loop a boot — treat as "not provably revoked" and let the materialize-time
  # TOCTOU gate be the loud authority.
  defp grant_revoked_for_restart?(%URI{} = agent_uri),
    do: Ezagent.Credential.HomeRuntime.grant_revoked_for_restart?(agent_uri)

  defp config_home_opts,
    do: [stage_error_tag: :config_dir_materialize_failed, chmod_error: :tagged]

  defp invalid_config_dir_message(value) do
    "codex.agent: invalid config_dir #{inspect(value)} — " <>
      "must be a non-empty string or absent. No silent fallback to operator " <>
      "CODEX_HOME."
  end

  defp ensure_agent_kind(agent_uri) do
    case Ezagent.LocalRuntime.ensure_started_detailed(agent_uri) do
      {:ok, :started, _pid} -> {:ok, :started}
      {:ok, :already_started, _pid} -> {:ok, :already_started}
      {:error, reason} -> {:error, {:agent_spawn_failed, reason}}
    end
  end

  defp fully_alive?(agent_uri) do
    agent_kind_alive?(agent_uri) and sidecars_alive?(agent_uri)
  end

  defp sidecars_alive?(agent_uri) do
    EzagentPluginCodex.AppServer.alive?(agent_uri) and
      Ezagent.Domain.Pty.alive?(agent_uri) and
      EzagentPluginCodex.BridgeSidecar.alive?(agent_uri)
  end

  @impl Ezagent.Kind.Template
  def ensure_subprocess_alive(%URI{} = agent_uri, respawn_data) when is_map(respawn_data) do
    cond do
      sidecars_alive?(agent_uri) ->
        :ok

      true ->
        with {:ok, respawn_data} <-
               Ezagent.Credential.CascadeRuntime.rehydrate_respawn_data(agent_uri, respawn_data) do
          cond do
            # #17 cascade PR-2 (§5.1) — a (re)start is a cascade boundary: an agent whose
            # credential grant was REVOKED must NOT come back up holding stale creds. No grant
            # / active grant → proceed. Full re-resolve-from-inputs re-materialize is FLAGGED.
            grant_revoked_for_restart?(agent_uri) ->
              {:error, {:credential_grant_revoked, agent_uri}}

            true ->
              case Map.fetch(respawn_data, "cwd") do
                {:ok, cwd} when is_binary(cwd) and cwd != "" ->
                  case ensure_sidecars(agent_uri, respawn_data) do
                    {:ok, _meta} ->
                      Logger.info(
                        "codex.agent.ensure_subprocess_alive: respawned sidecars for " <>
                          URI.to_string(agent_uri)
                      )

                      :ok

                    {:error, reason} ->
                      Logger.error(
                        "codex.agent.ensure_subprocess_alive: failed to respawn sidecars for " <>
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

  defp agent_kind_alive?(agent_uri) do
    Ezagent.LocalRuntime.kind_alive?(agent_uri)
  end

  defp owns_this_agent?(%URI{} = agent_uri, %URI{} = workspace_uri) do
    case Ezagent.URI.workspace_name(agent_uri) do
      {:ok, workspace} -> workspace == workspace_uri.host
      :error -> false
    end
  end

  defp owns_this_agent?(_agent_uri, _workspace_uri), do: false

  defp app_server_socket_path(agent_uri, tmpl) do
    Map.get(tmpl, "app_server_socket") || default_app_server_socket_path(agent_uri)
  end

  defp thread_id_path(agent_uri, tmpl) do
    Map.get(tmpl, "thread_id_file") ||
      Path.join(Path.dirname(app_server_socket_path(agent_uri, tmpl)), "bridge-thread-id")
  end

  # `@doc false` public so the SUN_LEN regression test can assert the
  # path length without spawning a real app-server.
  @doc false
  def default_app_server_socket_path(agent_uri) do
    # The socket dir MUST keep the full path under the unix-domain socket
    # limit (`SUN_LEN` ≈ 104 bytes on macOS). The previous slug embedded
    # the FULL sanitized agent URI, which for orchestrator-spawned workers
    # (`codex_worker-<slot>-<32hex>--<session>`) produced a ~135-byte path
    # → `codex app-server --listen unix://<path>` fails with
    # `Error: path must be shorter than SUN_LEN`, the app-server exits
    # status 1, the bridge can't connect, and the thread-id file is never
    # written (→ `:codex_thread_id_file_timeout` → spawn rollback). Use a
    # SHORT deterministic hash of the URI instead (~72-byte path). See
    # docs/superpowers/specs/2026-06-01-codex-socket-path-sunlen.md.
    slug = socket_dir_slug(agent_uri)
    Path.join([Ezagent.Home.path("codex"), slug, "app-server.sock"])
  end

  # 16 lower-hex chars (64 bits) of the URI's SHA-256 — deterministic
  # (respawn/adopt + the 4 path consumers always agree), collision-safe,
  # and short enough to stay well under SUN_LEN.
  defp socket_dir_slug(agent_uri) do
    agent_uri
    |> URI.to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
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

  defp check_class(%{"class" => "codex.agent"}), do: :ok
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

  # Cleanup-2: shared entity-agent-URI validator lives in core
  # (Ezagent.Kind.Template) — byte-identical across every flavor.
  defp check_agent_uri(tmpl), do: Ezagent.Kind.Template.check_agent_uri(tmpl)
end
