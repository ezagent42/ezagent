defmodule EzagentDomainWorkspace.TestSupport.SignedE2EAuthorityLoader do
  @moduledoc """
  Test-support holder-cap loader for the signed task-workspace e2e suite.

  #195 requires the dispatch's authenticated principal to be CURRENT — a
  holder whose independently-loaded held-cap set is non-empty
  (`Ezagent.Cap.Authorize.principal_current?`). The suite dispatches as a
  cold task-worker AGENT grantee that is later spawned FRESH by `AgentStart`;
  seeding a durable identity snapshot to establish currency would collide with
  that fresh spawn (`:snapshot_version_too_new`). So the lead's "current via
  held caps, NOT a live Kind" is modeled at the loader seam instead:

    * an agent grantee is reported as current (a non-empty marker set) WITHOUT
      reading its durable store — so no cold agent is lazy-spawned by the
      currency check; and
    * every other principal (users, the admin issuer) delegates to the real
      `Ezagent.Identity` loader, so a concurrent suite's user principals keep
      their genuine currency during the (async: false) swap window.

  The marker set is a CURRENCY signal only — the presented, receiver-bound
  task cap (never this set) still decides authorization at the target gate.
  """

  @behaviour Ezagent.Cap.AuthorityLoader

  alias Ezagent.Capability

  @impl true
  def read_held_caps(actor) do
    if agent?(actor) do
      MapSet.new([Capability.admin_genesis_cap()])
    else
      Ezagent.Identity.read_held_caps(actor)
    end
  end

  @impl true
  def principal_fenced?(actor), do: Ezagent.Identity.principal_fenced?(actor)

  defp agent?(%URI{} = actor), do: Ezagent.URI.type?(actor, :agent)
  defp agent?(_actor), do: false
end
