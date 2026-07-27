defmodule Ezagent.Entity.Agent.TemplateSpawn.Rollback do
  @moduledoc false

  alias Ezagent.Entity.Agent.SpawnObligations

  @doc false
  def fresh_spawn(
        workers,
        receipts,
        template_class,
        instance_uri,
        preserve_creation_receipts?,
        minted_grant,
        created?
      ) do
    undo_workers(workers)
    rollback_receipts(receipts, preserve_creation_receipts?)
    cleanup_config_dirs(workers, template_class)
    # #201 PR-2 — no flavor cleanup here: the only flavor write is the
    # post-ownership store in `complete_spawn_obligations`, which runs AFTER
    # every step this rollback compensates. Nothing to undo (and deleting
    # could clobber a pre-existing live owner's cache row).
    compensate_grant(instance_uri, minted_grant, created?)
    :ok
  end

  # #201 PR-3 (R4) — grant compensation on fresh-spawn rollback:
  #   * this attempt minted a grant → delete EXACTLY that incarnation
  #     (ABA-safe; a reinserted/reapproved row is never touched);
  #   * no cascade mint, but a GENUINE fresh create (`created?`) → legacy
  #     URI-delete: any row for this brand-new URI is this attempt's residue
  #     (e.g. a Template Class that inserts its own grant mid-instantiate);
  #   * `:started ∧ ¬created?` (rehydrating winner) → NEVER URI-delete: the
  #     row could be the pre-existing agent's original grant.
  defp compensate_grant(
         instance_uri,
         %Ezagent.Credential.GrantRow{incarnation_id: inc},
         _created?
       ) do
    _ = Ezagent.Credential.GrantRow.delete_incarnation(URI.to_string(instance_uri), inc)
    :ok
  end

  defp compensate_grant(instance_uri, nil, true) do
    _ = Ezagent.Credential.GrantRow.delete(URI.to_string(instance_uri))
    :ok
  end

  defp compensate_grant(_instance_uri, nil, false), do: :ok

  defp rollback_receipts(receipts, preserve_creation_receipts?) do
    Enum.each(receipts, fn
      {:agent_display_profile, :inserted, agent_uri} ->
        SpawnObligations.safe(fn ->
          Ezagent.Entity.Profile.rollback_agent_display_name(agent_uri, :inserted)
        end)

      {:creation_inventory, _attempt_id, _worker_uri, _root_uri, _workspace_uri}
      when preserve_creation_receipts? ->
        :ok

      {:creation_inventory, attempt_id, worker_uri, root_uri, workspace_uri} ->
        SpawnObligations.safe(fn ->
          Ezagent.Agent.CreationInventory.rollback_record(
            attempt_id,
            worker_uri,
            root_uri,
            workspace_uri
          )
        end)

      {:spawned_by_edge, _worker_uri, _root_uri} ->
        # Provenance is append-only audit history, including failed attempts.
        :ok

      {:lineage_fact, worker_uri, root_uri} ->
        SpawnObligations.safe(fn ->
          Ezagent.AgentLineage.rollback_lineage_fact(worker_uri, root_uri)
        end)
    end)
  end

  defp undo_workers(workers) do
    Enum.each(workers, fn worker_uri ->
      _ = Ezagent.Kind.terminate!(worker_uri)

      SpawnObligations.safe(fn ->
        Ezagent.WorkspaceRegistry.unbind(worker_uri)
      end)
    end)
  end

  defp cleanup_config_dirs(workers, template_class) do
    cond do
      not is_atom(template_class) ->
        :ok

      not function_exported?(template_class, :destroy_config_dir, 2) ->
        :ok

      true ->
        namespace = Ezagent.Kind.Template.namespace_of(template_class)

        Enum.each(workers, fn worker_uri ->
          dir = Ezagent.Sandbox.ConfigDir.path(worker_uri, namespace)
          _ = template_class.destroy_config_dir(worker_uri, dir)
        end)
    end
  end
end
