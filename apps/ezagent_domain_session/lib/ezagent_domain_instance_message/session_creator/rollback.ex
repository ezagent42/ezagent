defmodule EzagentDomainInstanceMessage.SessionCreator.Rollback do
  @moduledoc false

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
      # MCP context ownership stays behind the session-owned port (a no-op when
      # cc is absent). Generic live-join state belongs to the agent domain.
      safe(:orchestrator_context_unregister, fn ->
        Ezagent.Session.OrchestratorContextPort.unregister(orchestrator_uri)
      end)

      # Transport #53 Decision C (codex C-rC-P2) — stop the per-orchestrator
      # `SessionManager` GenServer (started at step-7 materialization). It is
      # independently supervised, so unregistering the transport alone would leak
      # it + leave a stale-bound executor a later recreate could reuse.
      safe(:session_manager_stop, fn -> Ezagent.Session.SessionManager.stop(orchestrator_uri) end)

      if match?(%URI{}, owner_uri) and match?(%URI{}, workspace_uri) do
        safe(:revoke_orchestrator_scoped_caps, fn ->
          Session.revoke_orchestrator_scoped_caps(
            orchestrator_uri,
            session_uri,
            owner_uri,
            workspace_uri
          )
        end)
      end

      retirement = retire_orchestrator(orchestrator_uri, session_uri, owner_uri, workspace_uri)

      if retirement_evidence_transferred?(retirement) do
        safe(:unbind_orchestrator, fn -> Ezagent.WorkspaceRegistry.unbind(orchestrator_uri) end)
        forget_lineage(orchestrator_uri)

        safe(:orchestrator_live_join_clear, fn ->
          Ezagent.Agent.LiveJoinRegistry.clear(orchestrator_uri)
        end)
      else
        Logger.error(
          "rollback preserved orchestrator evidence after retirement failed: #{inspect(retirement)}"
        )
      end
    end

    if match?(%URI{}, owner_uri) and match?(%URI{}, workspace_uri) do
      safe(:revoke_owner_orchestrator_admin_cap, fn ->
        revoke_owner_orchestrator_admin_cap(session_uri, owner_uri, workspace_uri)
      end)
    end

    safe(:delete_session_rule_rows, fn -> delete_session_rule_rows(session_uri) end)

    safe(:retract_session_installs, fn ->
      Ezagent.Socialware.Installation.retract_session_installs(
        session_uri,
        owner_uri || Ezagent.Entity.User.admin_uri()
      )
    end)

    safe(:destroy_session, fn -> Ezagent.Lifecycle.destroy(session_uri, :rollback) end)
    safe(:unbind_session, fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    :ok
  end

  def compensate_spawned_members(spawned_uris, context)
      when is_list(spawned_uris) and is_map(context) do
    Enum.each(spawned_uris, fn %URI{} = uri ->
      retirement = Ezagent.Domain.Agent.retire_spawned(uri, context)

      if retirement_evidence_transferred?(retirement) do
        safe(:unbind_spawned_member, fn -> Ezagent.WorkspaceRegistry.unbind(uri) end)
        forget_lineage(uri)
      end
    end)

    :ok
  end

  defp delete_session_rule_rows(%URI{} = session_uri) do
    table = Ezagent.Routing.Resolver.default_routing_table()
    session_str = URI.to_string(session_uri)

    Ezagent.Routing.RuleStore.list(table)
    |> Enum.filter(fn row -> row.created_by == session_str end)
    |> Enum.each(fn row ->
      safe(:delete_session_rule_row, fn ->
        Ezagent.Routing.RuleStore.delete(row.id, force: true)
      end)
    end)

    safe(:load_routing_registry, fn -> Ezagent.Routing.RuleStore.load_into_registry(table) end)
    :ok
  end

  defp forget_lineage(%URI{} = uri) do
    if Code.ensure_loaded?(Ezagent.AgentLineage) and
         function_exported?(Ezagent.AgentLineage, :forget, 1) do
      safe(:forget_agent_lineage, fn -> Ezagent.AgentLineage.forget(uri) end)
    end

    :ok
  end

  defp retire_orchestrator(
         %URI{} = orchestrator_uri,
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri
       ) do
    Ezagent.Domain.Agent.retire_spawned(orchestrator_uri, %{
      caller: owner_uri,
      caps: MapSet.new(),
      workspace_uri: workspace_uri,
      provenance_root: owner_uri,
      creation_attempt_id: "session-create:#{Ezagent.URI.stable_key(session_uri)}",
      created_agent_uris: [orchestrator_uri],
      reason: :rollback
    })
  end

  defp retire_orchestrator(_orchestrator_uri, _session_uri, _owner_uri, _workspace_uri),
    do: {:error, %{termination: :not_destroyed, reason: :missing_retirement_context}}

  defp retirement_evidence_transferred?({:ok, %{cleanup: :complete}}), do: true

  defp retirement_evidence_transferred?(
         {:partial, %{cleanup: :pending, obligation_id: obligation_id}}
       )
       when is_integer(obligation_id),
       do: true

  defp retirement_evidence_transferred?(_), do: false

  defp revoke_owner_orchestrator_admin_cap(
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri
       ) do
    cap = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.OrchestratorAdmin,
      action: :restart,
      instance: session_uri,
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: nil
    }

    # Grant chokepoint (SPEC 2026-06-17 §4 PR-2, site #13 — the revoke
    # inverse of the materializer grant, site #6). Same cap shape
    # (`session/OrchestratorAdmin/:restart/<session_uri>`), so the SAME
    # `{:rule, …}` tag: rule-bounded, configurer = owner. (Revoke has no
    # `granted_by` concern but routes through the chokepoint for the grep
    # gate + reaches dispatch via the rule branch.)
    _ =
      Ezagent.Identity.Grant.revoke_cap(
        owner_uri,
        cap,
        {:rule, :template_materialize, owner_uri}
      )

    :ok
  end

  defp safe(step, fun) do
    fun.()
  rescue
    e ->
      Logger.error("rollback step #{step} failed: #{Exception.message(e)}")
      :error
  catch
    kind, reason ->
      Logger.error("rollback step #{step} #{kind}: #{inspect(reason)}")
      :error
  end
end
