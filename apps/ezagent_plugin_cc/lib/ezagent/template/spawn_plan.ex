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
  alias Ezagent.PluginCc.Template.OrchestratorBootstrap

  # Phase 3 ③ T7d — the CLI-identity env a role-agent needs to act through the
  # ezagent CLI (`mix ezagent <verb>`) AS ITSELF. `EzagentCli.Exec` authenticates
  # every dispatching call against `entity_tokens` via these two vars (see
  # `EzagentCli.Exec.resolve_caller/2` → `Ezagent.Entity.authenticate/2`); without
  # them a `mix ezagent kanban.* / github.*` call fails CLOSED ("CLI calls require
  # authentication"). The bridge's `EZAGENT_AGENT_TOKEN` is a SEPARATE bridge-connect
  # token (`cc-channels.yaml`, verified by `AgentBridge.TokenStore`), NOT an entity
  # token, so it cannot stand in here.
  @cli_user_token_env "EZAGENT_USER_TOKEN"
  @cli_entity_uri_env "EZAGENT_ENTITY_URI"
  @cli_identity_token_label "cc-cli-identity"
  @dev_channels_flag "--dangerously-load-development-channels"
  @dev_channels_server "server:esr-bridge"
  # cc-PTY hardening 2026-07-10 (audit #2). On RESPAWN (crash/OOM/cold-restart)
  # the restarted `claude` must resume the SAME conversation, not start fresh —
  # otherwise every restart of a long session silently loses the whole context.
  # `--continue` resumes the most-recent conversation in the current directory;
  # because each cc agent has its OWN `cwd` AND its OWN `CLAUDE_CONFIG_DIR`, that
  # conversation is unambiguously THIS agent's. Verified empirically: on a first
  # spawn with no prior conversation `--continue` degrades gracefully to a fresh
  # session (it does not error), so it is safe on the respawn path even if the
  # very first spawn had crashed before persisting a transcript.
  @resume_flag "--continue"

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
          {:ok, {[String.t()], map()}}
          | {:error,
             :claude_not_found
             | :deepseek_api_key_missing
             | {:unsupported_claude_dev_channels, String.t()}}
  def build_claude_cmd(%URI{} = agent_uri, agent_cwd, tmpl)
      when is_binary(agent_cwd) and is_map(tmpl) do
    with {:ok, claude_path} <- resolve_claude_executable(agent_uri),
         :ok <- ensure_dev_channels_supported(claude_path),
         # Provider/backend dimension (anthropic|deepseek), ORTHOGONAL to
         # transport. anthropic → %{} (the normal cc env is UNCHANGED — no
         # DeepSeek vars leak in). deepseek → the 8-var block from
         # DEEPSEEK_API_KEY, or a fail-fast :deepseek_api_key_missing (the
         # deepseek instantiate already gates this before spawn; kept here as
         # defense so the raw builder never emits a half-configured deepseek
         # launch).
         {:ok, provider_env} <- Ezagent.PluginCc.Provider.provider_env(tmpl) do
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
          "--dangerously-skip-permissions",
          @dev_channels_flag,
          @dev_channels_server
        ] ++ settings_mcp_args

      base_env = %{
        "EZAGENT_AGENT_URI" => Ezagent.URI.stable_key(agent_uri),
        "EZAGENT_AGENT_TOKEN" => agent_token
      }

      cmd_env =
        base_env
        |> put_claude_config_dir(config_home, tmpl)
        |> maybe_put_orchestrator_recipe_env(tmpl)
        |> maybe_put_cli_identity_env(agent_uri, tmpl)
        # Provider env LAST so the DeepSeek block (ANTHROPIC_BASE_URL/
        # ANTHROPIC_AUTH_TOKEN/…) authoritatively points claude at the DeepSeek
        # endpoint. Empty for anthropic — the default cc path is unchanged.
        |> Map.merge(provider_env)
        # Bridge-topic override so a deepseek sidecar joins
        # `agent_bridge:cc-deepseek:<uri>` (matching its resolved flavor) instead
        # of the sidecar's `agent_bridge:cc:` default. Empty for anthropic.
        |> Map.merge(Ezagent.PluginCc.Provider.bridge_topic_env(tmpl, agent_uri))

      {:ok, {argv, cmd_env}}
    end
  end

  @doc """
  The `claude` resume flag (`--continue`). Public for the respawn-path caller
  and tests; see the `@resume_flag` rationale.
  """
  @spec resume_flag() :: String.t()
  def resume_flag, do: @resume_flag

  @doc false
  # cc-PTY hardening 2026-07-10 (audit #2). Insert `--continue` into an
  # already-built PTY params map so a respawned `claude` resumes its
  # conversation. Kept OUT of `build_claude_cmd/3` (whose 3-arity is pinned by a
  # large invariant-test surface) — the resume decision is a respawn-vs-fresh
  # concern owned by the gated launcher chain, not the argv builder. Idempotent
  # and shape-safe: a `:test` params map (no `:cmd_override`) or an
  # already-`--continue` argv is returned unchanged.
  @spec inject_resume_flag(map()) :: map()
  def inject_resume_flag(%{cmd_override: [claude_path | rest]} = params)
      when is_binary(claude_path) do
    if @resume_flag in rest or @resume_flag == claude_path do
      params
    else
      %{params | cmd_override: [claude_path, @resume_flag | rest]}
    end
  end

  def inject_resume_flag(params) when is_map(params), do: params

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
  @spec ensure_dev_channels_supported(String.t()) ::
          :ok | {:error, {:unsupported_claude_dev_channels, String.t()}}
  def ensure_dev_channels_supported(claude_path) when is_binary(claude_path) do
    case claude_dev_channel_probe(claude_path) do
      :accepted ->
        :ok

      {:rejected, output} ->
        Logger.error(
          "cc.agent: `claude` at #{claude_path} rejects #{@dev_channels_flag}; " <>
            "the cc bridge requires #{@dev_channels_flag} #{@dev_channels_server}. " <>
            "Install a Claude Code build that accepts development channels or use a non-cc flavor. " <>
            "probe_output=#{inspect(output)}"
        )

        {:error, {:unsupported_claude_dev_channels, claude_path}}

      {:unknown, reason} ->
        Logger.warning(
          "cc.agent: could not conclusively verify #{@dev_channels_flag} support for " <>
            "`claude` at #{claude_path}; continuing because the probe did not report an " <>
            "unknown flag. reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  @doc false
  @spec claude_dev_channels_supported?(String.t()) :: boolean()
  def claude_dev_channels_supported?(claude_path) when is_binary(claude_path) do
    case claude_dev_channel_probe(claude_path) do
      {:rejected, _output} -> false
      _ -> true
    end
  end

  defp claude_dev_channel_probe(claude_path) do
    probe_args = [@dev_channels_flag, @dev_channels_server, "--help"]

    case System.cmd(claude_path, probe_args, stderr_to_stdout: true) do
      {_output, 0} ->
        :accepted

      {output, status} when is_binary(output) ->
        if unknown_dev_channels_flag?(output) do
          {:rejected, output}
        else
          {:unknown, %{status: status, output: output}}
        end
    end
  rescue
    error in ErlangError -> {:unknown, Exception.message(error)}
  end

  defp unknown_dev_channels_flag?(output) when is_binary(output) do
    Regex.match?(
      ~r/(unknown|unrecognized|not recognized|invalid|unsupported|unexpected).{0,120}(option|flag|argument|arg)?.{0,120}--dangerously-load-development-channels|--dangerously-load-development-channels.{0,120}(unknown|unrecognized|not recognized|invalid|unsupported|unexpected)/i,
      output
    )
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

  @doc false
  # Phase 3 ③ T7d — inject the CLI-identity env (`EZAGENT_USER_TOKEN` +
  # `EZAGENT_ENTITY_URI`) for a ROLE-agent so its `claude` brain can drive the
  # ezagent CLI under its OWN identity + least-priv caps (every dispatch is
  # CapBAC-gated; the token is scoped to THIS agent's caps — no self-mint, no
  # admin fallback, exactly the threat model `TokenScopeCapbacTest` pins). A
  # role-less legacy cc agent (`role_name/1 == nil`) gets nothing.
  #
  # The gate is GENERIC over any role (机制 ≠ 业务): the same path serves
  # pm-coordinator / dev-together / orchestrator / any future cc role — it is the
  # cli+skill paradigm (act through the CLI as yourself), not a per-role branch.
  #
  # A fresh entity token is minted here at build-time and exported ONLY into the
  # process env (`cmd_env`) — the SAME ephemeral-credential pattern the bridge
  # token (`EZAGENT_AGENT_TOKEN`) already uses; it is never written to disk. A
  # mint failure is best-effort: the agent still spawns, but WITHOUT a CLI bearer
  # token, so `mix ezagent` calls under its identity fail CLOSED (no silent admin
  # fallback — `feedback_let_it_crash_no_workarounds`).
  @spec maybe_put_cli_identity_env(map(), URI.t(), map()) :: map()
  def maybe_put_cli_identity_env(env, %URI{} = agent_uri, tmpl)
      when is_map(env) and is_map(tmpl) do
    case OrchestratorBootstrap.role_name(tmpl) do
      nil -> env
      _role -> put_cli_identity_env(env, agent_uri)
    end
  end

  defp put_cli_identity_env(env, %URI{} = agent_uri) do
    case Ezagent.Entity.Token.mint(agent_uri, label: @cli_identity_token_label) do
      {token, _row} when is_binary(token) ->
        env
        |> Map.put(@cli_user_token_env, token)
        # canonical stable_key (== the key `Token.mint` persisted for this agent),
        # so `EzagentCli.Exec.resolve_caller/2`'s `Ezagent.URI.new!/1` round-trips
        # to the same `entity_tokens` row.
        |> Map.put(@cli_entity_uri_env, Ezagent.URI.stable_key(agent_uri))

      {:error, reason} ->
        Logger.warning(
          "cc.agent: CLI-identity token mint failed for #{URI.to_string(agent_uri)}: " <>
            "#{inspect(reason)} — the agent spawns WITHOUT a CLI bearer token, so " <>
            "`mix ezagent` calls under its identity fail CLOSED (no silent admin fallback)."
        )

        env
    end
  end

  defp maybe_put_orchestrator_recipe_env(env, tmpl) when is_map(env) do
    if CcAgent.orchestrator_recipe?(tmpl) do
      Map.put(env, "EZAGENT_AGENT_ROLE", "orchestrator")
    else
      env
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
