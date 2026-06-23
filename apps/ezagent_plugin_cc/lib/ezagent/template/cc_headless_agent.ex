defmodule Ezagent.PluginCc.Template.CcHeadlessAgent do
  @moduledoc """
  CC Headless agent Template Class — headless claude (no PTY/TUI).

  Registers the `"cc-headless"` flavor with the same CredentialAdapter as
  `"cc"` (CLAUDE_CONFIG_DIR + .credentials.json). The spawn path currently
  uses a stub marker — actual headless subprocess integration
  (claude -p stdio or esr-bridge without PTY) requires further erlexec
  integration to bypass `Ezagent.Domain.Pty.start/2`.
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
  #
  # STUB — cc-headless subprocess integration (2026-06-23).
  #
  # The headless spawn path shares the same credential cascade
  # (create_agent_config_dir_with_grant → revalidate_grant_before_launch)
  # as cc, but skips the PTY/TUI launch. Two approaches remain:
  #
  #   3A: `claude -p` stdio pipe — requires verifying multi-turn support
  #       in current claude CLI. If `claude -p --input-format stream-json
  #       --output-format stream-json` works, use a plain Port with :stdin
  #       /:stdout (no erlexec :pty flag).
  #
  #   3B: `server:esr-bridge` without PTY — reuse the same argv as cc
  #       (from SpawnPlan.build_claude_cmd/3) but launch via erlexec
  #       WITHOUT the :pty flag. The bridge channel still connects via
  #       WebSocket. This requires bypassing Domain.Pty.start/2 and
  #       calling erlexec directly — a medium integration effort.
  #
  #   Until one of these is implemented, cc-headless agents will NOT have
  #   a running claude subprocess. The agent Kind spawns with a config_dir,
  #   but no LLM backend is active. This is a precise unsupported matrix
  #   entry.

  defp spawn_for_headless(agent_uri, tmpl, _workspace_uri) do
    with {:ok, started_or_adopted} <- ensure_agent_kind(agent_uri) do
      case started_or_adopted do
        :already_started ->
          {:ok, [agent_uri], %{fresh?: false}}

        :started ->
          case create_agent_config_dir_with_grant(agent_uri, tmpl) do
            {:ok, config_dir, grant_ctx} ->
              tmpl_with_dir = put_agent_config_dir(tmpl, config_dir)

              case revalidate_grant_before_launch(grant_ctx) do
                :ok ->
                  # STUB: headless subprocess launch goes here.
                  # For now we return success with fresh?: true but no
                  # active subprocess. The Agent Kind is alive with a
                  # config_dir; the credential cascade is complete.
                  _ =
                    Logger.info(
                      "cc-headless: agent #{URI.to_string(agent_uri)} " <>
                        "spawned (subprocess STUB — no claude backend active)"
                    )

                  {:ok, [agent_uri],
                   %{
                     fresh?: true,
                     config_dir_path: config_dir,
                     respawn_template_data: tmpl_with_dir
                   }}

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

  # ---- ensure_subprocess_alive --------------------------------------------

  @impl Ezagent.Kind.Template
  def ensure_subprocess_alive(%URI{} = agent_uri, _respawn_data) do
    # STUB — no subprocess to respawn. Returns :ok so cold-restart
    # doesn't crash. The Agent Kind alone is sufficient for now.
    Logger.info(
      "cc-headless: ensure_subprocess_alive stub for " <>
        URI.to_string(agent_uri)
    )

    :ok
  end

  def ensure_subprocess_alive(_, _), do: {:error, :invalid_args}

  # ---- Agent Kind ---------------------------------------------------------

  defp ensure_agent_kind(agent_uri) do
    case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
      {:ok, :started, _pid} -> {:ok, :started}
      {:ok, :already_started, _pid} -> {:ok, :already_started}
      {:error, reason} -> {:error, {:agent_spawn_failed, reason}}
    end
  end

  defp agent_kind_alive?(agent_uri) do
    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} -> true
      :error -> false
    end
  end

  # ---- Failure handling ---------------------------------------------------

  defp handle_spawn_failure(agent_uri, reason) do
    Ezagent.PluginCc.Template.CcAgent.handle_spawn_failure(agent_uri, reason)
  end

  defp config_home_opts,
    do: [stage_error_tag: :config_dir_materialize_failed, chmod_error: :tagged]

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
