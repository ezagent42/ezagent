defmodule Ezagent.DomainGit.TestSupport.GitCapAuthorityLoader do
  @moduledoc """
  Test-support holder-cap loader for the git-domain dispatch suite.

  It models two classes of CURRENT principal for #195's principal gate
  (`Ezagent.Cap.Authorize.principal_current?`, which admits a holder whose
  independently-loaded held-cap set is non-empty):

    * the system admin — the all-authority genesis holder; and
    * any workspace agent grantee — the git task-worker principals these
      fixtures dispatch as are modeled as "current via durable held caps"
      (the lead's ruling: an agent is current via caps, NOT via a live Kind).

  Returning a non-empty set here is a CURRENCY signal only — the presented
  candidate caps (never this set) still decide authorization at the target
  gate, so a wrong-receiver / retargeted / unsigned candidate is still dropped
  and the dispatch is denied. This loader never satisfies the target gate.
  """

  @behaviour Ezagent.Cap.AuthorityLoader

  alias Ezagent.Capability

  @impl true
  def read_held_caps(actor) do
    cond do
      actor == Ezagent.URI.user(:system, :admin) ->
        MapSet.new([Capability.admin_genesis_cap()])

      agent_grantee?(actor) ->
        # A held-cap marker that makes the agent grantee a CURRENT principal.
        # Non-empty is all the principal gate reads; the concrete presented
        # cap (bound to a specific target/receiver) is what authorizes.
        MapSet.new([Capability.admin_genesis_cap()])

      true ->
        MapSet.new()
    end
  end

  @impl true
  def principal_fenced?(_actor), do: false

  defp agent_grantee?(%URI{} = actor), do: Ezagent.URI.type?(actor, :agent)
  defp agent_grantee?(_actor), do: false
end
