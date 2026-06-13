defmodule EzagentDomainInstanceMessage.SessionCreator.Rollback do
  @moduledoc false

  alias Ezagent.Invocation
  alias Ezagent.Entity.Session

  require Logger

  @spec rollback_session(URI.t(), URI.t() | nil) :: :ok
  @spec rollback_session(URI.t(), URI.t() | nil, keyword()) :: :ok
  def rollback_session(session_uri, orchestrator_uri, opts \\ [])

  def rollback_session(%URI{} = session_uri, orchestrator_uri, opts) when is_list(opts) do
    owner_uri = Keyword.get(opts, :owner_uri)
    workspace_uri = Keyword.get(opts, :workspace_uri)

    Logger.warning(
      "EzagentDomainInstanceMessage.SessionCreator.create_session: rolling back freshly-created " <>
        "session=#{URI.to_string(session_uri)} after a 4-8 failure — " <>
        "reversing create's writes (MCP unregister + orchestrator " <>
        "lineage/bind/snapshot/Kind + granted caps + Session Kind/bind/" <>
        "snapshot) (SPEC 2026-05-31 §4 step 9, codex-review Q1)."
    )

    if match?(%URI{}, orchestrator_uri) do
      # PR-8 (transport #53) — route MCP unregister + live-join clear through
      # the session-owned port (no-op when cc is not loaded) instead of naming
      # the now-cc-resident `McpRegistry` / `LiveJoinRegistry`.
      safe(fn -> Ezagent.Session.OrchestratorReadinessPort.unregister(orchestrator_uri) end)

      if match?(%URI{}, owner_uri) and match?(%URI{}, workspace_uri) do
        safe(fn ->
          Session.revoke_orchestrator_scoped_caps(
            orchestrator_uri,
            session_uri,
            owner_uri,
            workspace_uri
          )
        end)
      end

      safe(fn -> Ezagent.Lifecycle.destroy(orchestrator_uri, :rollback) end)
      safe(fn -> Ezagent.WorkspaceRegistry.unbind(orchestrator_uri) end)
      forget_lineage(orchestrator_uri)
      safe(fn -> Ezagent.Session.OrchestratorReadinessPort.clear(orchestrator_uri) end)
    end

    if match?(%URI{}, owner_uri) and match?(%URI{}, workspace_uri) do
      safe(fn -> revoke_owner_orchestrator_admin_cap(session_uri, owner_uri, workspace_uri) end)
    end

    safe(fn -> delete_session_rule_rows(session_uri) end)
    safe(fn -> Ezagent.Lifecycle.destroy(session_uri, :rollback) end)
    safe(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    :ok
  end

  def compensate_spawned_members(spawned_uris) when is_list(spawned_uris) do
    Enum.each(spawned_uris, fn %URI{} = uri ->
      safe(fn -> Ezagent.Lifecycle.destroy(uri, :rollback) end)
      safe(fn -> Ezagent.WorkspaceRegistry.unbind(uri) end)
      forget_lineage(uri)
    end)

    :ok
  end

  defp delete_session_rule_rows(%URI{} = session_uri) do
    table = Ezagent.Routing.Resolver.default_routing_table()
    session_str = URI.to_string(session_uri)

    Ezagent.Routing.RuleStore.list(table)
    |> Enum.filter(fn row -> row.created_by == session_str end)
    |> Enum.each(fn row ->
      safe(fn -> Ezagent.Routing.RuleStore.delete(row.id, force: true) end)
    end)

    safe(fn -> Ezagent.Routing.RuleStore.load_into_registry(table) end)
    :ok
  end

  defp forget_lineage(%URI{} = uri) do
    if Code.ensure_loaded?(Ezagent.AgentLineage) and
         function_exported?(Ezagent.AgentLineage, :forget, 1) do
      safe(fn -> Ezagent.AgentLineage.forget(uri) end)
    end

    :ok
  end

  defp revoke_owner_orchestrator_admin_cap(
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri
       ) do
    cap = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.Behavior.OrchestratorAdmin,
      action: :restart,
      instance: session_uri,
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: nil
    }

    target = Ezagent.URI.with_action(owner_uri, :identity, :revoke_cap)

    _ =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{cap: cap},
        ctx: %{
          caller: owner_uri,
          caps:
            "template-materialize"
            |> Ezagent.SystemPrincipal.uri()
            |> Ezagent.SystemPrincipal.caps(),
          reply: {:caller_inbox, self()}
        }
      })

    :ok
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
