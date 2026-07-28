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
        grant_incarnation_id
      ) do
    undo_workers(workers)
    rollback_receipts(receipts, preserve_creation_receipts?)
    cleanup_config_dirs(workers, template_class)
    # #201 PR-2 — no flavor cleanup here: the only flavor write is the
    # post-ownership store in `complete_spawn_obligations`, which runs AFTER
    # every step this rollback compensates. Nothing to undo (and deleting
    # could clobber a pre-existing live owner's cache row).
    compensate_grant(instance_uri, grant_incarnation_id)
  end

  # #201-cred (codex r2 HIGH-2/3) — grant compensation on fresh-spawn
  # rollback:
  #   * the created-winner minted and returned its exact incarnation receipt
  #     (`:grant_incarnation_id` in the plugin's instantiate meta) → delete
  #     EXACTLY that incarnation, CONFIRMED (retried; failure PROPAGATES as
  #     `{:error, :grant_compensation_failed}` — never rescued-to-`:ok`, so a
  #     grant can never silently survive a failed cleanup);
  #   * no receipt → NOTHING is deleted. The former URI-wide
  #     `GrantRow.delete/1` fallback for `minted_grant == nil` is DELETED
  #     (codex r2 HIGH-3): it was ABA-unsafe — a concurrent `reapprove/1`
  #     landing between the worker/config cleanup and the grant step
  #     installed a NEW incarnation G2 that the URI-wide delete then wiped.
  #     Every credential writer MUST return its exact grant-incarnation
  #     receipt (`GrantMint` does, and the mint is now structurally deferred
  #     to the created-winner), so rollback requires — and only ever acts on —
  #     that receipt.
  defp compensate_grant(_instance_uri, nil), do: :ok

  defp compensate_grant(instance_uri, incarnation_id) when is_binary(incarnation_id) do
    Ezagent.Credential.GrantMint.compensate(URI.to_string(instance_uri), incarnation_id)
  end

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
