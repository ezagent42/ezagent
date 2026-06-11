defmodule Ezagent.PluginCc.Template.SpawnPlan do
  @moduledoc false
  # BUILD-ONLY (#701 chokepoint hardening). This module assembles cc PTY
  # launch params + the claude command; it does NOT launch. The actual
  # `Ezagent.Domain.Pty.start/2` launch lives behind the grant-gated
  # private `CcAgent.Spawn.ensure_pty_server/3`, so a cc PTY can never be
  # started without first passing the create/respawn credential-grant gate
  # (codex PR-3T review). No public function here both builds cc launch
  # params AND starts a PTY.

  require Logger

  alias Ezagent.PluginCc.Template.CcAgent

  @doc false
  @spec build_pty_params(URI.t(), String.t(), map(), atom()) :: {:ok, map()} | {:error, term()}
  def build_pty_params(%URI{} = agent_uri, cwd, tmpl, compile_env)
      when is_binary(cwd) and is_map(tmpl) do
    build_pty_params_for_env(agent_uri, cwd, tmpl, compile_env)
  end

  @doc false
  @spec build_pty_params_for_env(URI.t(), String.t(), map(), atom()) ::
          {:ok, map()} | {:error, term()}
  def build_pty_params_for_env(_agent_uri, cwd, _tmpl, :test) do
    {:ok, %{cwd: cwd, test_mode: true}}
  end

  def build_pty_params_for_env(%URI{} = agent_uri, cwd, tmpl, _env)
      when is_binary(cwd) and is_map(tmpl) do
    with {:ok, {argv, cmd_env}} <- build_claude_cmd(agent_uri, cwd, tmpl) do
      {:ok,
       %{
         cwd: cwd,
         cmd_override: argv,
         cmd_env: cmd_env,
         auth_observers: credential_auth_observers()
       }}
    end
  end

  @doc false
  @spec build_claude_cmd(URI.t(), String.t(), map()) ::
          {:ok, {[String.t()], map()}} | {:error, :claude_not_found}
  def build_claude_cmd(%URI{} = agent_uri, agent_cwd, tmpl)
      when is_binary(agent_cwd) and is_map(tmpl) do
    with {:ok, claude_path} <- resolve_claude_executable(agent_uri) do
      config_home = CcAgent.resolve_config_home(agent_uri, tmpl)

      {:ok, _global_mcp_path, agent_token} =
        EzagentPluginCc.McpConfigWriter.write_with_token!(
          agent_uri: URI.to_string(agent_uri),
          agent_cwd: agent_cwd,
          config_dir: config_home
        )

      per_agent_mcp_path =
        if is_binary(config_home) and config_home != "",
          do: Path.join(config_home, ".mcp.json"),
          else: Path.join(agent_cwd, ".mcp.json")

      settings_mcp_args =
        assemble_settings_mcp_args(mandatory_settings_path(), per_agent_mcp_path, tmpl)

      argv =
        [
          claude_path,
          "--effort",
          effort_for(tmpl)
        ] ++
          model_args(tmpl) ++
          [
            "--dangerously-skip-permissions",
            "--dangerously-load-development-channels",
            "server:esr-bridge"
          ] ++ settings_mcp_args

      base_env = %{
        "EZAGENT_AGENT_URI" => Ezagent.URI.stable_key(agent_uri),
        "EZAGENT_AGENT_TOKEN" => agent_token
      }

      cmd_env =
        base_env
        |> put_claude_config_dir(config_home, tmpl)
        |> maybe_put_orchestrator_role_env(tmpl)
        |> maybe_put_anthropic_base_url(tmpl)

      {:ok, {argv, cmd_env}}
    end
  end

  @doc false
  @spec resolve_claude_executable(URI.t()) :: {:ok, String.t()} | {:error, :claude_not_found}
  def resolve_claude_executable(%URI{} = agent_uri) do
    case System.find_executable("claude") do
      nil ->
        Logger.error(
          "cc.agent: `claude` executable not found on PATH for " <>
            "#{URI.to_string(agent_uri)} — cannot build the argv invocation. " <>
            "erlexec list-form exec runs execve(3) with no PATH search, so " <>
            "argv element 0 must be an absolute path. Install `claude` on the " <>
            "PATH of the process running `mix phx.server`."
        )

        {:error, :claude_not_found}

      claude_path ->
        {:ok, claude_path}
    end
  end

  @doc false
  @spec assemble_settings_mcp_args(String.t(), String.t(), map()) :: [String.t()]
  def assemble_settings_mcp_args(mandatory_settings_path, bridge_mcp_path, tmpl)
      when is_binary(mandatory_settings_path) and is_binary(bridge_mcp_path) and is_map(tmpl) do
    operator_settings =
      case Map.get(tmpl, "operator_settings_path") do
        p when is_binary(p) and p != "" -> ["--settings", p]
        _ -> []
      end

    operator_mcp =
      case Map.get(tmpl, "operator_mcp_config_path") do
        p when is_binary(p) and p != "" -> ["--mcp-config", p]
        _ -> []
      end

    operator_settings ++
      ["--settings", mandatory_settings_path] ++
      ["--mcp-config", bridge_mcp_path] ++
      operator_mcp
  end

  defp credential_auth_observers do
    CcAgent.auth_failure_signals()
    |> Enum.with_index()
    |> Enum.map(fn {sig, i} -> %{name: :"cc_auth_failure_#{i}", match: sig} end)
  end

  defp maybe_put_orchestrator_role_env(env, tmpl) when is_map(env) do
    if CcAgent.orchestrator_role?(tmpl) do
      Map.put(env, "EZAGENT_AGENT_ROLE", "orchestrator")
    else
      env
    end
  end

  # Reasoning effort, per-template (Allen 2026-06-10). A cc bot otherwise inherits
  # claude's `high` effort default → 1–4 min of server-side extended thinking PER
  # reply (measured on the socialware CS live run, #715; local CPU idle = it was
  # waiting, not computing). Latency-sensitive templates (CS bots) take the `low`
  # default (~26 s, no quality loss); a template needing deep reasoning sets
  # `"effort" => "high"` (or `"medium"`) in its `template_data`. Invalid/absent → low.
  @valid_efforts ~w(low medium high)
  defp effort_for(tmpl) when is_map(tmpl) do
    case Map.get(tmpl, "effort") do
      e when e in @valid_efforts -> e
      _ -> "low"
    end
  end

  # Per-template model + endpoint (Allen / autoservice-v2 §6.4, 2026-06-10). A cc
  # agent runs the `claude` CLI, which can target a non-default model and/or an
  # Anthropic-compatible endpoint: `--model <m>` selects the model, and the
  # `ANTHROPIC_BASE_URL` env points claude at a proxy (e.g. autoservice's "slow"
  # agent runs `deepseek-v4-flash` via `https://api.deepseek.com/anthropic`).
  # The cc plugin stays generic — it reads `model`/`endpoint` from the template
  # map; the autoservice content layer maps its (master-only) `agents.yaml` into
  # the template. Absent → the operator/account default model + endpoint (claude).
  defp model_args(tmpl) when is_map(tmpl) do
    case Map.get(tmpl, "model") do
      m when is_binary(m) and m != "" -> ["--model", m]
      _ -> []
    end
  end

  defp maybe_put_anthropic_base_url(env, tmpl) when is_map(env) do
    case Map.get(tmpl, "endpoint") do
      url when is_binary(url) and url != "" -> Map.put(env, "ANTHROPIC_BASE_URL", url)
      _ -> env
    end
  end

  defp put_claude_config_dir(base_env, config_home, tmpl) do
    # Cleanup-2: single cc-plugin definition lives on CcAgent; delegate
    # (was a byte-identical fork in this module).
    CcAgent.reject_stale_config_dir_data_key!(tmpl)

    cond do
      is_binary(config_home) and config_home != "" ->
        Map.put(base_env, CcAgent.credential_env_var(), config_home)

      Ezagent.Credential.HomeRuntime.config_dir_present_but_malformed?(tmpl) ->
        raise ArgumentError,
              "cc.agent: invalid config_dir #{inspect(Map.get(tmpl, "config_dir"))} — must " <>
                "be a non-empty string (or absent for no config home). No silent fallback " <>
                "to the operator home (feedback_let_it_crash_no_workarounds)."

      true ->
        base_env
    end
  end

  defp mandatory_settings_path do
    :code.priv_dir(:ezagent_plugin_cc)
    |> Path.join("claude-pty-settings.json")
  end
end
