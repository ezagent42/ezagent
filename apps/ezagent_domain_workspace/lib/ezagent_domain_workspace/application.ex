defmodule EzagentDomainWorkspace.Application do
  @moduledoc """
  Workspace domain OTP application — Phase 6 PR 2.

  Owns:
  - `Ezagent.Behavior.Workspace` registration on `Ezagent.Entity.Workspace`
  - `Ezagent.Workspace.Supervisor` DynamicSupervisor for `workspace://*` Kinds
  - `Ezagent.Workspace.Loader.load_all/0` invocation (deferred to last
    boot site — see notes)

  ## load_all timing

  Loader needs every plugin's spawn fn already registered (e.g.
  `agent`, `session`, `user`, `pty` schemes). Those registrations
  happen at each plugin's Application.start. The umbrella's child app
  start order is alphabetical, so ezagent_domain_workspace starts before
  most plugins.

  Solution: domain_workspace does NOT call load_all here. Instead it
  exposes `EzagentDomainWorkspace.boot_complete/0` which the LAST app to
  boot (currently ezagent_domain_chat, post-PR-3 ezagent_plugin_liveview)
  invokes after all spawn fns are registered. PR 3+ will move this
  call site to an explicit "registry-ready" gate.
  """

  use Application

  alias Ezagent.CapabilityRegistry
  alias Ezagent.Behavior.Workspace, as: WB
  alias Ezagent.Entity.Workspace, as: WK

  @impl true
  def start(_type, _args) do
    :ok = register_workspace_behavior()

    children = [
      {DynamicSupervisor, name: Ezagent.Workspace.Supervisor, strategy: :one_for_one}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)

    # PR-CC-2b (SPEC caps-cleanup-v1 §4.3) — seed the workspace-loader
    # system principal owned by this Application. Idempotent;
    # test-env skip.
    :ok = seed_workspace_system_principals()

    result
  end

  # PR-CC-2b (SPEC caps-cleanup-v1 §4.3) — Operating context (§4.1):
  # `system://workspace-loader` is used by `Ezagent.Workspace.Loader`
  # when re-spawning persisted workspaces at boot.
  defp seed_workspace_system_principals do
    if test_env?() do
      :ok
    else
      ensure_principal_logged("system://workspace-loader")
    end
  end

  # PR-CC-2b (codex round-1 HIGH-1 fix) — wrap ensure/1 in try/catch
  # so EXITs from absent supervisors don't kill workspace boot.
  defp ensure_principal_logged(uri_str) do
    try do
      case Ezagent.SystemPrincipal.ensure(URI.parse(uri_str)) do
        :ok ->
          :ok

        {:error, reason} ->
          log_seed_failure(uri_str, reason)
      end
    rescue
      e -> log_seed_failure(uri_str, e)
    catch
      kind, reason -> log_seed_failure(uri_str, {kind, reason})
    end
  end

  defp log_seed_failure(uri_str, reason) do
    require Logger

    Logger.warning(
      "EzagentDomainWorkspace seed: ensure(#{uri_str}) failed " <>
        "(#{inspect(reason)}); idempotent retry on next boot."
    )

    :ok
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end

  defp register_workspace_behavior do
    Enum.each(WB.actions(), fn action ->
      :ok = CapabilityRegistry.register(WK, action, WB)
    end)

    # PR #146 (SPEC v2 §5.7) — workspace-scoped routing rule mutations
    # dispatch to `workspace://<name>?action=routing.<action>` against
    # the Workspace Kind. CapBAC scopes naturally to the workspace
    # instance.
    alias Ezagent.Behavior.Routing, as: RB

    Enum.each(RB.actions(), fn action ->
      :ok = CapabilityRegistry.register(WK, action, RB)
    end)

    :ok
  end

  @doc """
  Called by the last-booting app once all spawn fns are registered.
  Idempotent — multiple callers OK (Loader handles "already spawned").
  """
  def boot_complete do
    _ = Ezagent.Workspace.Loader.load_all()
    :ok
  end
end
