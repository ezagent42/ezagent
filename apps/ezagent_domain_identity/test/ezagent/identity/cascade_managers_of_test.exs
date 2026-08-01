defmodule Ezagent.Identity.CascadeManagersOfTest do
  @moduledoc """
  Membership-cap unification Phase B.2 (spec §10 / tests 15-17) — the bounded
  reverse-authority resolver `Ezagent.Identity.Cascade.managers_of/1`.

  Candidates are seeded as Users whose DURABLE identity caps are folded from
  their initial cap set on spawn (`activate/2` unions `caps_json` into the live
  `:identity` slice), then `managers_of/1` reads them LIVE (K5) with the
  `granted_by_entity?/1` provenance filter (K4).
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.Capability
  alias Ezagent.Identity.Cascade

  defp uniq, do: System.unique_integer([:positive])

  # A workspace-homed User seeded with `caps` folded into its durable identity
  # (initial caps → caps_json → `activate/2` union → live `:identity` slice).
  defp user_with_caps(ws_name, caps) do
    uri = URI.new!("entity://#{ws_name}/user/u-#{uniq()}")
    caps = if is_function(caps, 1), do: caps.(uri), else: caps
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", caps)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp manage_cap_over(x, granter, grantee) do
    cap = Ezagent.CreatorGrant.manage_cap(:agent, x, Capability.workspace_of(x), granter)
    {:ok, authority} = Ezagent.Cap.Authority.open(x, :agent)
    authority_signed_cap_as!(authority, granter, grantee, cap)
  end

  defp agent_uri(ws_name), do: URI.new!("entity://#{ws_name}/agent/x-#{uniq()}")

  test "managers_of(agent) returns the creator (holds Manage cap), not an unrelated user (15)" do
    x = agent_uri("team-alpha")

    creator =
      user_with_caps("team-alpha", fn creator ->
        [manage_cap_over(x, URI.new!("entity://team-alpha/user/root"), creator)]
      end)

    _unrelated = user_with_caps("team-alpha", [])

    assert Cascade.managers_of(x) == [creator]
  end

  test "a different-workspace user is NEVER returned (bounded scan) (15)" do
    x = agent_uri("team-alpha")
    # A team-beta user that DOES hold a Manage cap over the team-alpha agent —
    # still never scanned, because managers_of is bounded to X's workspace.
    _beta_mgr =
      user_with_caps("team-beta", fn manager ->
        [manage_cap_over(x, URI.new!("entity://team-beta/user/root"), manager)]
      end)

    assert Cascade.managers_of(x) == []
  end

  test "a system-granted stale Manage cap does NOT over-match (granted_by_entity? filter, 16)" do
    x = agent_uri("team-alpha")

    system_granted = %Capability{
      kind: :agent,
      behavior: Ezagent.ActionSet.Manage,
      action: :any,
      instance: x,
      workspace_uri: Capability.workspace_of(x),
      granted_by: URI.new!("system://genesis"),
      granted_at: DateTime.utc_now()
    }

    _stale = user_with_caps("team-alpha", [system_granted])
    assert Cascade.managers_of(x) == []
  end

  test "cascade uses LIVE caps: grant a Manage cap at runtime → new manager IS resolved (17)" do
    x = agent_uri("team-alpha")
    mgr = user_with_caps("team-alpha", [])

    # No authority yet.
    assert Cascade.managers_of(x) == []

    # Grant a Manage cap over X into the manager's LIVE identity at runtime.
    grant_live(mgr, manage_cap_over(x, mgr, mgr))
    wait_until(fn -> Cascade.managers_of(x) == [mgr] end)
  end

  defp grant_live(entity, cap) do
    Ezagent.IdentityCaps.grant(entity, cap)
  end

  defp wait_until(fun, retries \\ 200) do
    cond do
      fun.() ->
        :ok

      retries > 0 ->
        Process.sleep(10)
        wait_until(fun, retries - 1)

      true ->
        flunk("condition never became true")
    end
  end
end
