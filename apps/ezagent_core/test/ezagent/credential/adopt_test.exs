defmodule Ezagent.Credential.AdoptTest do
  @moduledoc """
  #17 cascade PR-0 (spec §5.2) — the one-time adoption migration routes through the SAME
  authorized, cap-checked, audited chokepoint (the :set_default_credential_source Behavior
  dispatch), refuses ambiguity, and is denied for non-operator caps (no side path).
  """

  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.Credential.{Adopt, UserDefaultSource}
  alias Ezagent.Users

  @ws "team-a"

  defp seed_agent(uri_str, owner, flavor) do
    {:ok, _} = Ezagent.SnapshotStore.write(uri_str, %{}, kind_type: :agent)
    uri = Ezagent.URI.new!(uri_str)
    :ok = Ezagent.AgentLineage.record(uri, owner)
    :ok = Ezagent.AgentFlavorAttributes.put(uri, flavor)
    uri_str
  end

  # System-principal elimination (#154, 2026-06-19) — the operator credential
  # adopt path now dispatches `:set_default_credential_source` under the real
  # admin entity carrying the INLINE per-action cap scoped to the OWNER (the
  # step-5.5 authorizer), replacing the eliminated `system://mix-task` wildcard.
  defp admin_uri, do: Ezagent.Entity.User.admin_uri()

  defp admin_caps(owner_str) do
    owner_uri = Ezagent.URI.new!(owner_str)

    target =
      Ezagent.URI.with_action(
        owner_uri,
        :user_default_credential_source,
        :set_default_credential_source
      )

    [
      signed_fixture_cap!(
        target,
        :user,
        Ezagent.ActionSet.UserDefaultCredentialSource,
        :set_default_credential_source,
        admin_uri()
      )
    ]
  end

  setup do
    suffix = System.unique_integer([:positive])
    owner_uri = Ezagent.URI.new!("entity://#{@ws}/user/alice#{suffix}")
    owner_str = URI.to_string(owner_uri)

    base = seed_agent("entity://#{@ws}/agent/alice-base-#{suffix}", owner_str, "cc")

    {:ok, _} = Users.create(owner_str, "pw-not-secret", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(owner_uri)

    {:ok, owner_str: owner_str, base: base, suffix: suffix}
  end

  test "adopts a single unambiguous existing source via the authorized dispatch", ctx do
    candidates = [ctx.base]

    assert {:ok, src} =
             Adopt.adopt(ctx.owner_str, @ws, "cc", candidates,
               caller: admin_uri(),
               caps: admin_caps(ctx.owner_str)
             )

    assert src == ctx.base
    assert UserDefaultSource.resolve(ctx.owner_str, @ws, "cc") == ctx.base
  end

  test "REFUSES when multiple candidates are ambiguous (no silent guess)", ctx do
    a1 = "entity://#{@ws}/agent/a1-#{ctx.suffix}"
    a2 = "entity://#{@ws}/agent/a2-#{ctx.suffix}"
    candidates = [a1, a2]

    assert {:error, {:ambiguous, ^candidates}} =
             Adopt.adopt(ctx.owner_str, @ws, "cc", candidates,
               caller: admin_uri(),
               caps: admin_caps(ctx.owner_str)
             )
  end

  test "adoption with non-operator caps is denied by the dispatch (no bypass)", ctx do
    candidates = [ctx.base]
    eve = Ezagent.URI.new!("entity://#{@ws}/user/eve")

    assert {:error, :missing_cap} =
             Adopt.adopt(ctx.owner_str, @ws, "cc", candidates,
               caller: eve,
               caps: MapSet.new()
             )

    assert UserDefaultSource.resolve(ctx.owner_str, @ws, "cc") == nil
  end

  test "empty candidate list returns :no_candidate", ctx do
    assert {:error, :no_candidate} =
             Adopt.adopt(ctx.owner_str, @ws, "cc", [],
               caller: admin_uri(),
               caps: admin_caps(ctx.owner_str)
             )
  end
end
