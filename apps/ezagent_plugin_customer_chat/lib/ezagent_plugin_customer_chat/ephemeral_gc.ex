defmodule EzagentPluginCustomerChat.EphemeralGc do
  @moduledoc """
  One-time cleanup of accumulated EPHEMERAL customer-chat agents.

  Per-conversation cc agents (`cc_cust_*`) and per-session orchestrators
  (`cc_orchestrator-*`) used to register permanent `session_templates`
  entries + leave `kind_snapshots` rows that the boot loader replayed,
  spawning every one's claude PTY at boot (a "boot storm"). The runtime
  fix stops NEW accumulation; this module clears what already accumulated.

  Run with the server STOPPED (it mutates the DB directly via Store +
  Repo; a running Workspace Kind would hold a stale in-memory slice).
  Idempotent: running twice is a no-op the second time.

  Scope: removes `cc.agent.cc_cust_*` template registrations and deletes
  `cc_cust_*` agent snapshot rows. Orchestrator/session snapshot cleanup
  is intentionally out of scope (deferred to "Approach B").
  Preserves provisioned agents (e.g. `cc_cs_main`).
  """
  import Ecto.Query, only: [from: 2]

  @template_prefix "cc.agent.cc_cust_"

  # Only the per-conversation cc REPLY agent snapshots are orphaned by
  # the template deregistration and unambiguously safe to delete (their
  # names are anchored to the ephemeral `cc_cust_` prefix). The per-session
  # orchestrator + session snapshots belong to a separate restoration path
  # that is intentionally OUT OF SCOPE here (deferred to "Approach B" — see
  # docs/notes/2026-05-30-ephemeral-agents-allen-note.md); deleting them is
  # neutral for the boot storm (the session restorer recreates the
  # orchestrator regardless) and `session://%` would dangerously also wipe
  # the legitimate `session://default/system/main` and other tenants.
  @snapshot_like ["entity://agent/%/cc_cust_%"]

  @doc """
  Pure: given a workspace's `session_templates` map, return the keys that
  are ephemeral per-conversation cc agents (safe to drop).
  """
  @spec ephemeral_keys(map()) :: [String.t()]
  def ephemeral_keys(templates) when is_map(templates) do
    templates
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, @template_prefix))
  end

  @doc """
  Strip ephemeral template registrations from every workspace and delete
  orphaned ephemeral snapshot rows. Returns `{templates_removed, snapshots_removed}`.

  `templates_removed` is the count of template KEYS dropped (across all
  workspaces); `snapshots_removed` is the count of `cc_cust_*` snapshot
  rows deleted.
  """
  @spec run() :: {non_neg_integer(), non_neg_integer()}
  def run do
    {clean_templates(), clean_snapshots()}
  end

  defp clean_templates do
    Ezagent.Workspace.Store.list_all()
    |> Enum.reduce(0, fn ws, acc ->
      keys = ephemeral_keys(ws.session_templates)

      if keys == [] do
        acc
      else
        kept = Map.drop(ws.session_templates, keys)
        {:ok, _} = Ezagent.Workspace.Store.update_templates(ws.name, kept)
        acc + length(keys)
      end
    end)
  end

  defp clean_snapshots do
    Enum.reduce(@snapshot_like, 0, fn pattern, acc ->
      {count, _} =
        EzagentCore.Repo.delete_all(
          from(k in Ezagent.Ecto.KindSnapshot, where: like(k.uri, ^pattern))
        )

      acc + count
    end)
  end
end
