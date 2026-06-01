defmodule Mix.Tasks.Ezagent.CustomerChat.GcEphemeral do
  @shortdoc "Remove accumulated ephemeral customer-chat cc_cust_* agents (run with server STOPPED)"
  @moduledoc """
      mix ezagent.customer_chat.gc_ephemeral

  One-time cleanup of accumulated per-conversation cc agents that used to
  pile up in `workspaces.session_templates` + `kind_snapshots` and respawn
  at boot. Delegates to `EzagentPluginCustomerChat.EphemeralGc.run/0`.
  Run with the server STOPPED. Idempotent.

  NOTE: dev/PoC maintenance task (NOT a Category A audited operation —
  see the cli-gui-parity audit note on `ezagent.snapshot.clear`). The
  durable fix is the domain `ephemeral:` flag tracked for Allen in
  docs/notes/2026-05-30-ephemeral-agents-allen-note.md.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_workspace)

    {templates, snapshots} = EzagentPluginCustomerChat.EphemeralGc.run()

    Mix.shell().info(
      "✓ removed #{templates} ephemeral template registration(s), #{snapshots} snapshot row(s)"
    )
  end
end
