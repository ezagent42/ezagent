defmodule Ezagent.Orchestrator.CodexOrchestratorSeed do
  @moduledoc """
  Seeds the `codex-orchestrator` AgentTemplate.

  This mirrors the cc orchestrator seed at the AgentTemplate level while keeping
  the execution path codex-native: flavor `"codex"`, role `"orchestrator"`, and
  the shared AgentBridge/SessionManager `run_tool` seam for orchestration tools.
  No cc PTY or cc MCP transport is used.
  """

  require Logger

  @template_name "codex-orchestrator"

  @doc "Seed the codex-orchestrator AgentTemplate. Idempotent."
  @spec seed() :: :ok
  def seed do
    uri = template_uri_struct()

    with {:ok, _pid} <- ensure_kind(uri),
         {:ok, sandbox} <- ensure_sandbox_files(),
         :ok <- write_template_slice(uri, sandbox) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "codex-orchestrator AgentTemplate seed: #{inspect(reason)} — " <>
            "codex socialware orchestration will be unavailable until configured"
        )

        :ok
    end
  end

  @doc "The codex-orchestrator AgentTemplate URI string."
  @spec template_uri() :: String.t()
  def template_uri, do: template_uri_struct() |> URI.to_string()

  @doc "Inspect the codex-orchestrator seed status."
  @spec seed_status() :: {:ok | :partial | :missing, map()}
  def seed_status do
    uri = template_uri_struct()

    # Live-only read of the template's `:template` slice (§2.2 `Kind.read/3`,
    # `spawn: :never`). The returned value is already normalized to the state
    # view, so match the flat `%{content: ...}` shape directly.
    case Ezagent.Kind.read(uri, :template, spawn: :never) do
      {:ok, %{content: %{flavor: "codex", role: "orchestrator"} = content}} ->
        {:ok, %{template_uri: template_uri(), template_content: content}}

      {:ok, %{content: content}} ->
        {:partial, %{template_uri: template_uri(), template_content: content || %{}}}

      _ ->
        {:missing, %{template_uri: template_uri()}}
    end
  rescue
    _ -> {:missing, %{template_uri: template_uri()}}
  end

  defp template_uri_struct, do: Ezagent.URI.template(:system, :agent, @template_name)

  defp ensure_kind(%URI{} = uri) do
    case Ezagent.LocalRuntime.ensure_started_detailed(uri) do
      {:ok, _started_or_already, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_sandbox_files do
    base = sandbox_base()
    config_dir = Path.join(base, ".codex")

    File.mkdir_p!(config_dir)
    File.write!(Path.join(base, "AGENTS.md"), Ezagent.Orchestrator.OrchestratorRecipe.persona())

    unless File.exists?(Path.join(config_dir, "config.toml")) do
      File.write!(Path.join(config_dir, "config.toml"), "approval_policy = \"never\"\n")
    end

    {:ok, %{project_cwd: base, config_dir: config_dir}}
  rescue
    e -> {:error, {:sandbox_write_failed, e}}
  end

  defp sandbox_base do
    cond do
      base = Application.get_env(:ezagent_plugin_codex, :codex_orchestrator_sandbox_base) ->
        base

      Code.ensure_loaded?(Mix) and Mix.env() == :test ->
        Path.join(System.tmp_dir!(), "ezagent-test-codex-orchestrator")

      true ->
        Path.join([System.user_home() || "/tmp", ".ezagent", "codex-orchestrator"])
    end
  end

  defp write_template_slice(%URI{} = uri, sandbox) do
    admin_uri = Ezagent.URI.user(:system, :admin)

    content = %{
      name: @template_name,
      description:
        "The Codex session orchestrator — a codex-native manager that composes " <>
          "and routes socialware teams through the shared orchestrator tools.",
      flavor: "codex",
      project_cwd: sandbox.project_cwd,
      config_dir: sandbox.config_dir,
      bridge_ws_url: default_bridge_ws_url(),
      approval_policy: "never",
      sandbox: "workspace-write",
      role: "orchestrator",
      default_caps: [],
      created_by: nil,
      created_at: DateTime.utc_now()
    }

    target = Ezagent.URI.with_action(uri, :template, :write)

    requested =
      Ezagent.Capability.cap(
        :agent_template,
        Ezagent.ActionSet.Template,
        :write,
        Ezagent.URI.instance(target),
        Ezagent.Capability.workspace_of(target)
      )

    with {:ok, signed_cap} <- Ezagent.Cap.issue({:admin, admin_uri}, admin_uri, requested) do
      case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: %{content: content},
             ctx: %{
               caller: admin_uri,
               authenticated_principal: admin_uri,
               caps: MapSet.new([signed_cap]),
               reply: {:caller_inbox, self()}
             },
             origin: :trusted_internal
           }) do
        {:ok, %{content: _}} -> :ok
        {:error, _} = err -> err
        other -> {:error, {:unexpected_template_write_result, other}}
      end
    end
  end

  defp default_bridge_ws_url do
    Application.get_env(
      :ezagent_plugin_codex,
      :bridge_ws_url,
      "ws://127.0.0.1:10042/agent_bridge/websocket"
    )
  end
end
