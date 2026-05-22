defmodule Ezagent.Orchestrator.CcOrchestratorSeed do
  @moduledoc """
  Seeds the `cc-orchestrator` AgentTemplate with a REAL `:template`
  slice (Phase 7 completion SPEC §2 "PR-5" — the cc-orchestrator
  AgentTemplate config).

  Pre-PR-5 `EzagentDomainChat.Application.seed_cc_orchestrator_template/0`
  only `SpawnRegistry.spawn`-ed an EMPTY AgentTemplate Kind — the
  `:template` slice was `%{content: nil}`, so the Generator could spawn
  an orchestrator process but it had no flavor, no sandbox, no MCP
  config, no system prompt. PR-5 makes the seed populate a real slice:

  - `flavor: "cc"` — the orchestrator is a `claude` PTY agent.
  - `claude_config_dir` — an isolated `CLAUDE_CONFIG_DIR` sandbox so the
    orchestrator's `claude` does not share the operator's `~/.claude`.
  - `settings_path` — a `settings.json` enabling the orchestration
    pattern (the mandatory plugin safety `--settings` still wins; this
    operator file layers non-conflicting keys — §1.5 (c)).
  - `mcp_config_path` — points at the ORCHESTRATOR MCP server config
    (the 7-tool surface, `Ezagent.Orchestrator.McpServer`) — additive
    to the trusted esr-bridge config (§1.5 (c)).
  - a system prompt teaching the orchestrator role (written into the
    sandbox `CLAUDE.md`).

  ## Idempotency

  The seed is boot-time + best-effort. It spawns the AgentTemplate Kind
  (or finds it alive), writes the sandbox files if absent, and dispatches
  `Ezagent.Behavior.Template` `:write` to populate the `:template`
  slice. AgentTemplate `:write` is a mutable replace (versionless URI),
  so re-running the seed is harmless.

  ## Why files on disk

  `claude_config_dir` / `settings_path` / `mcp_config_path` are file
  paths the cc Template Class threads to `claude` as `CLAUDE_CONFIG_DIR`
  env + `--settings` / `--mcp-config` flags. They must exist on disk for
  a live `claude` to use them. The seed writes dev-profile defaults
  under `~/.ezagent/cc-orchestrator/`; production multi-tenant
  deployments override per-template.
  """

  require Logger

  @template_uri "template://agent/default/cc-orchestrator"

  @doc """
  Seed the cc-orchestrator AgentTemplate. Idempotent; best-effort —
  logs and returns `:ok` on any failure so a boot does not abort.
  """
  @spec seed() :: :ok
  def seed do
    uri = URI.parse(@template_uri)

    with {:ok, _pid} <- ensure_kind(uri),
         {:ok, sandbox} <- ensure_sandbox_files(),
         :ok <- write_template_slice(uri, sandbox) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "cc-orchestrator AgentTemplate seed: #{inspect(reason)} — " <>
            "orchestrator-style SessionTemplate instantiation will use an " <>
            "unpopulated template until manually configured"
        )

        :ok
    end
  end

  @doc "The cc-orchestrator AgentTemplate URI string."
  @spec template_uri() :: String.t()
  def template_uri, do: @template_uri

  # --- internals ---------------------------------------------------------

  defp ensure_kind(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case Ezagent.SpawnRegistry.spawn(uri) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

  # Build the on-disk sandbox: a CLAUDE_CONFIG_DIR with a settings.json,
  # an mcp.json for the orchestrator tool surface, and a CLAUDE.md
  # carrying the orchestrator system prompt. Best-effort in :test (the
  # paths are recorded in the slice but the files are not required for
  # the deterministic test). Returns `{:ok, %{...paths}}`.
  defp ensure_sandbox_files do
    base = Path.join([System.user_home() || "/tmp", ".ezagent", "cc-orchestrator"])
    config_dir = Path.join(base, ".claude")
    settings_path = Path.join(config_dir, "settings.json")
    mcp_config_path = Path.join(base, "orchestrator.mcp.json")
    claude_md_path = Path.join(base, "CLAUDE.md")

    sandbox = %{
      working_directory: base,
      claude_config_dir: config_dir,
      settings_path: settings_path,
      mcp_config_path: mcp_config_path
    }

    if test_env?() do
      # In :test the slice records the paths but disk writes are skipped
      # — the deterministic e2e drives the tools directly, no live claude.
      {:ok, sandbox}
    else
      try do
        File.mkdir_p!(config_dir)
        unless File.exists?(settings_path), do: File.write!(settings_path, settings_json())
        unless File.exists?(mcp_config_path), do: File.write!(mcp_config_path, orchestrator_mcp_json())
        unless File.exists?(claude_md_path), do: File.write!(claude_md_path, system_prompt())
        {:ok, sandbox}
      rescue
        e -> {:error, {:sandbox_write_failed, e}}
      end
    end
  end

  # Dispatch `Ezagent.Behavior.Template` `:write` to populate the
  # AgentTemplate's `:template` slice — the canonical persistence path
  # (§1.7 (a)). AgentTemplate `:write` is a mutable replace, so the
  # re-seed on the next boot is idempotent.
  defp write_template_slice(%URI{} = uri, sandbox) do
    content = %{
      name: "cc-orchestrator",
      description:
        "The session orchestrator — an LLM-driven manager that composes " <>
          "and routes a team of worker agents via the 7 orchestration tools.",
      flavor: "cc",
      working_directory: sandbox.working_directory,
      claude_config_dir: sandbox.claude_config_dir,
      settings_path: sandbox.settings_path,
      mcp_config_path: sandbox.mcp_config_path,
      api_key_helper: nil,
      default_caps: [],
      created_by: nil,
      created_at: DateTime.utc_now()
    }

    target = URI.parse("#{URI.to_string(uri)}?action=template.write")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{content: content},
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps: Ezagent.Entity.User.admin_caps(),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{content: _}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_template_write_result, other}}
    end
  end

  # settings.json — enables the orchestrator pattern. The plugin-shipped
  # mandatory `--settings` (forcing `remoteControlAtStartup: false`) is
  # emitted LAST by `CcAgent.assemble_settings_mcp_args/3`, so anything
  # here that conflicts with a safety key loses. The keys here are
  # non-conflicting orchestration conveniences.
  defp settings_json do
    Jason.encode!(
      %{
        "includeCoAuthoredBy" => false,
        "env" => %{
          "EZAGENT_ROLE" => "orchestrator"
        }
      },
      pretty: true
    )
  end

  # orchestrator.mcp.json — the additional `--mcp-config` the cc
  # Template Class threads (additive to the trusted esr-bridge config).
  # It points `claude` at the orchestrator MCP server (the 7-tool
  # surface). The command runs a thin stdio bridge that forwards
  # `tools/call` to `Ezagent.Orchestrator.McpServer` over the existing
  # WS channel — the caller/cap/session context is bound ESR-side.
  defp orchestrator_mcp_json do
    Jason.encode!(
      %{
        "mcpServers" => %{
          "esr-orchestrator" => %{
            "command" => "uv",
            "args" => ["run", "--script", orchestrator_bridge_script_path()],
            "env" => %{
              "EZAGENT_ROLE" => "orchestrator"
            }
          }
        }
      },
      pretty: true
    )
  end

  # The orchestrator stdio bridge script path. Reuses the cc plugin's
  # python dir convention; the script is the orchestrator-tool analogue
  # of `ezagent_mcp_bridge.py`.
  defp orchestrator_bridge_script_path do
    Path.join([System.user_home() || "/tmp", ".ezagent", "cc-orchestrator", "orchestrator_bridge.py"])
  end

  # The orchestrator system prompt — written into the sandbox CLAUDE.md
  # so a live `claude` orchestrator reads it on startup.
  defp system_prompt do
    """
    # You are an ESR session orchestrator

    You manage a team of worker agents inside one chat session. You have
    7 orchestration tools (via the `esr-orchestrator` MCP server):

    - `add_agent_slot` — spawn a worker agent into a named slot.
    - `remove_agent_slot` — despawn a worker.
    - `update_agent_template` — swap a slot's AgentTemplate (rollback-safe).
    - `write_matcher` — add a routing rule so messages reach the right slots.
    - `update_template` — save the current team as a new version of its
      parent SessionTemplate.
    - `save_template_as` — save the current team as a NEW template family.
    - `list_templates` — discover the AgentTemplates / SessionTemplates
      available in your workspace.

    ## Rules

    - You act ONLY within your own session and workspace. Tools that
      target anything outside it will be denied — that is expected; do
      not retry with a different workspace.
    - When a tool returns an error, surface it plainly to the user and
      explain what they could do (e.g. "that template is outside your
      workspace").
    - Compose the team to fit the user's task; route messages with
      `write_matcher` so each worker sees what it needs.
    """
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end
end
