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

  # #21 PR-2b (④, TEST/E2E ONLY) — provision the full CODEX_HOME credential set
  # (auth.json + config.toml) from a durable `source` dir into the agent's `home`
  # CODEX_HOME, so the dockerized E2E runs without a human `codex login`. `source`
  # and `home` are CODEX_HOME DIRECTORIES (codex is dir-based, unlike cc's single
  # file). See `EzagentPluginCodex.CredentialRefresh`.
  @impl Ezagent.Agent.CredentialAdapter
  def refresh_test_credentials(source, home, opts \\ []) do
    EzagentPluginCodex.CredentialRefresh.provision(source, home, opts)
  end

  # SPEC 2026-06-01-flavor-generic-template-data (approach B): codex's
  # template_data fields, so an orchestrator-spawned codex worker carries
  # its model/approval/sandbox (pre-fix dropped by core's cc-only mapping).
  # `bridge_ws_url`/`codex_path` feed sidecar/app-server paths — emit them
  # ONLY as non-empty binaries (codex review MED) so a stray empty value
  # never reaches the runtime. nil values dropped by the caller.
  @impl Ezagent.Kind.Template
  def template_data_extra(content) when is_map(content) do
    %{
      "model" => content_field(content, :model),
      "approval_policy" => content_field(content, :approval_policy),
      "sandbox" => content_field(content, :sandbox)
    }
    |> maybe_put_binary(content, :bridge_ws_url, "bridge_ws_url")
    |> maybe_put_binary(content, :codex_path, "codex_path")
  end

  def template_data_extra(_), do: %{}

  defp maybe_put_binary(map, content, key, str_key) do
    case content_field(content, key) do
      v when is_binary(v) and v != "" -> Map.put(map, str_key, v)
      _ -> map
    end
  end

  defp content_field(content, key) when is_atom(key) do
    case Map.get(content, key) do
      nil -> Map.get(content, Atom.to_string(key))
      v -> v
    end
  end

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_cwd(tmpl),
         :ok <- check_optional_config_dir(tmpl),
         :ok <- check_optional_string(tmpl, "model"),
         :ok <- check_optional_string(tmpl, "approval_policy"),
         :ok <- check_optional_string(tmpl, "sandbox") do
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

    cond do
      fully_alive?(agent_uri) ->
        {:ok, [agent_uri], %{fresh?: false}}

      true ->
        spawn_for_codex(agent_uri, tmpl, workspace_uri)
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
          case create_agent_config_dir(agent_uri, tmpl) do
            {:ok, config_dir} ->
              tmpl_with_dir = put_agent_config_dir(tmpl, config_dir)

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
                  rollback_agent_config_dir(agent_uri)
                  {:error, reason}
              end

            {:error, reason} ->
              rollback_agent_config_dir(agent_uri)
              _ = Ezagent.Kind.terminate(agent_uri)
              {:error, reason}
          end
      end
    end
  end

  defp put_agent_config_dir(tmpl, nil), do: tmpl
  defp put_agent_config_dir(tmpl, dir), do: Map.put(tmpl, "agent_config_dir", dir)

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

  defp rollback_agent_config_dir(agent_uri) do
    _ = File.rm_rf(agent_config_dir(agent_uri))
    :ok
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
    cond do
      valid_dir?(Map.get(tmpl, "agent_config_dir")) ->
        Map.get(tmpl, "agent_config_dir")

      valid_dir?(Map.get(tmpl, "allocated_config_dir")) ->
        Map.get(tmpl, "allocated_config_dir")

      valid_dir?(Map.get(tmpl, "config_dir")) ->
        agent_config_dir(agent_uri)

      config_dir_present_but_malformed?(tmpl) ->
        raise ArgumentError,
              "codex.agent: invalid config_dir #{inspect(Map.get(tmpl, "config_dir"))} — " <>
                "must be a non-empty string or absent. No silent fallback to operator " <>
                "CODEX_HOME."

      true ->
        nil
    end
  end

  defp valid_dir?(dir) when is_binary(dir) and dir != "", do: true
  defp valid_dir?(_), do: false

  defp config_dir_present_but_malformed?(tmpl) do
    case Map.fetch(tmpl, "config_dir") do
      :error -> false
      {:ok, value} -> not valid_dir?(value)
    end
  end

  @doc false
  def agent_config_dir(%URI{} = agent_uri) do
    Ezagent.Sandbox.ConfigDir.path(agent_uri, Ezagent.Kind.Template.namespace_of(__MODULE__))
  end

  @doc false
  @spec create_agent_config_dir(URI.t(), map()) :: {:ok, String.t() | nil} | {:error, term()}
  def create_agent_config_dir(%URI{} = agent_uri, tmpl) when is_map(tmpl) do
    case Map.fetch(tmpl, "config_dir") do
      :error ->
        {:ok, nil}

      {:ok, ref} when is_binary(ref) and ref != "" ->
        case Map.fetch(tmpl, "allocated_config_dir") do
          {:ok, target} when is_binary(target) and target != "" ->
            materialize_config_dir(agent_uri, target, ref, tmpl)

          _ ->
            {:error, :config_dir_not_allocated}
        end

      {:ok, bad} ->
        {:error, {:invalid_config_dir, bad}}
    end
  end

  @config_complete_marker ".ezagent-config-complete"

  # #17 cascade PR-2 — dispatch on CASCADE inputs (see cc_agent.ex for the rationale).
  # NO cascade inputs → byte-for-byte the prior single-reference materialize. WITH
  # `tmpl["cascade"]` (PR-3 supplies it) → layer-merge (§D4) + secret-only copy (§D6)
  # under the TOCTOU-leased grant (§5.1) + atomic-replace (§7).
  defp materialize_config_dir(%URI{} = agent_uri, target, reference_dir, tmpl)
       when is_map(tmpl) do
    # #17 cascade PR-2 (§7 H3' (b)) — crash-mid-swap self-heal at materialize entry (see
    # cc_agent.ex for the rationale). Recover a leftover `<target>.bak-*` with a
    # missing/partial target before (re)materializing. Best-effort.
    _ = Ezagent.Agent.Materializer.recover_orphaned(target)

    case Map.get(tmpl, "cascade") do
      %{} = cascade -> materialize_cascade(agent_uri, target, cascade)
      _ -> materialize_single_reference(target, reference_dir)
    end
  end

  defp materialize_cascade(%URI{} = agent_uri, target, cascade) do
    marker = Path.join(target, @config_complete_marker)
    staging = "#{target}.staging-#{System.unique_integer([:positive])}"
    _ = File.rm_rf(staging)

    layer_dirs = Map.fetch!(cascade, :layer_dirs)
    source_dir_for = Map.fetch!(cascade, :source_dir_for)

    result =
      # #17 cascade PR-2 (§D4.2 H — codex HIGH) — NO whole-target overlay (see cc_agent.ex
      # for the full rationale). Overlaying the entire existing target resurrected
      # tombstoned files, overrode freshly-merged config, and kept stale credentials. The
      # layer merge (§D4) is the sole authority for the config tree; secrets come ONLY from
      # the grant-scoped source copy (§D6). No user-state preserved across re-materialize.
      with :ok <- Ezagent.Agent.Materializer.merge_layers(staging, layer_dirs),
           :ok <- File.chmod(staging, 0o700),
           :ok <- File.write(Path.join(staging, Path.basename(marker)), "ok\n") do
        Ezagent.Agent.Materializer.materialize_with_grant(%{
          agent_uri: URI.to_string(agent_uri),
          staging: staging,
          secret_relpaths: secret_relpaths(),
          source_dir_for: source_dir_for,
          commit: fn ->
            with :ok <- chmod_credential_files(staging),
                 :ok <- swap_into_place(staging, target) do
              {:ok, target}
            end
          end
        })
      end

    case result do
      {:ok, ^target} ->
        {:ok, target}

      {:error, reason} ->
        _ = File.rm_rf(staging)
        {:error, {:cascade_materialize_failed, reason}}
    end
  end

  defp materialize_single_reference(target, reference_dir) do
    marker = Path.join(target, @config_complete_marker)

    cond do
      not File.dir?(reference_dir) ->
        {:error, {:reference_dir_missing, reference_dir}}

      File.dir?(target) and File.exists?(marker) ->
        {:ok, target}

      File.dir?(target) and has_user_credentials?(target) ->
        stage_and_swap(reference_dir, target, marker, overlay: target)

      true ->
        stage_and_swap(reference_dir, target, marker)
    end
  end

  defp stage_and_swap(reference_dir, target, marker, opts \\ []) do
    staging = "#{target}.staging-#{System.unique_integer([:positive])}"
    marker_name = Path.basename(marker)
    _ = File.rm_rf(staging)

    with :ok <- File.mkdir_p(Path.dirname(target)),
         {:ok, _} <- File.cp_r(reference_dir, staging),
         :ok <- maybe_overlay(Keyword.get(opts, :overlay), staging),
         :ok <- File.chmod(staging, 0o700),
         :ok <- chmod_credential_files(staging),
         :ok <- File.write(Path.join(staging, marker_name), "ok\n"),
         :ok <- swap_into_place(staging, target) do
      {:ok, target}
    else
      {:error, reason} ->
        _ = File.rm_rf(staging)
        {:error, {:config_dir_materialize_failed, reason}}

      err ->
        _ = File.rm_rf(staging)
        {:error, {:config_dir_materialize_failed, err}}
    end
  end

  defp maybe_overlay(nil, _staging), do: :ok

  defp maybe_overlay(src, staging) when is_binary(src) do
    case File.cp_r(src, staging) do
      {:ok, _} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  # #17 cascade PR-2 (§7) — atomic-replace-with-rollback via the core Materializer:
  # move the current target aside to a sibling `.bak`, rename staging into place, drop
  # `.bak` on success / RESTORE it on failure. Replaces the prior `rm_rf(target)` THEN
  # `rename(staging, target)` which left NO config_dir on a crash between the two. A
  # failed swap leaves the PRIOR good config_dir intact (never empty / half-merged).
  defp swap_into_place(staging, target) do
    case Ezagent.Agent.Materializer.atomic_replace(staging, target) do
      {:ok, _target} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp chmod_credential_files(dir) do
    credential_relpaths()
    |> Enum.reduce_while(:ok, fn relpath, :ok ->
      path = Path.join(dir, relpath)

      if File.exists?(path) do
        case File.chmod(path, 0o600) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:chmod_failed, relpath, reason}}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp has_user_credentials?(dir) do
    Enum.any?(credential_relpaths(), fn relpath -> File.exists?(Path.join(dir, relpath)) end)
  end

  # #17 cascade PR-2 (§5.1) — true iff this agent has a credential grant that is now
  # REVOKED (no grant / active grant → false → proceed). Defensive: a DB read error must
  # not crash-loop a boot — treat as "not provably revoked" and let the materialize-time
  # TOCTOU gate be the loud authority.
  defp grant_revoked_for_restart?(%URI{} = agent_uri) do
    case Ezagent.Credential.GrantRow.get_for_agent(URI.to_string(agent_uri)) do
      %Ezagent.Credential.GrantRow{revoked_at: nil} -> false
      %Ezagent.Credential.GrantRow{} -> true
      nil -> false
    end
  rescue
    _ -> false
  end

  defp ensure_agent_kind(agent_uri) do
    case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
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

  def ensure_subprocess_alive(_, _), do: {:error, :invalid_args}

  defp agent_kind_alive?(agent_uri) do
    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} -> true
      :error -> false
    end
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

  defp check_optional_string(tmpl, key) do
    case Map.fetch(tmpl, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> :ok
      {:ok, bad} -> {:error, {:invalid_string_field, key, bad}}
    end
  end

  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    # PR-B unify-uri-query: the URI is an opaque identifier. This validator
    # checks only the structural entity-agent shape; flavor is stored in the
    # Template Class/content, never parsed from the URI name prefix.
    try do
      case Ezagent.URI.new!(uri_str) do
        %URI{scheme: "entity"} = uri ->
          if Ezagent.URI.type?(uri, :agent) do
            :ok
          else
            {:error, {:invalid_agent_uri, uri_str, "agent URI must be an entity agent URI"}}
          end

        %URI{} ->
          {:error, {:invalid_agent_uri, uri_str, "agent URI must be an entity agent URI"}}

        _ ->
          {:error, {:bad_agent_uri, uri_str}}
      end
    rescue
      ArgumentError -> {:error, {:bad_agent_uri, uri_str}}
    end
  end

  defp check_agent_uri(_), do: {:error, :missing_agent_uri}
end
