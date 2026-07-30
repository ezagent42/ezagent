defmodule Ezagent.Cap.AuthorityCheckedVerifyTest do
  use EzagentCore.DataCase, async: true

  import Ezagent.Test.CapHelper, only: [authority_signed_cap!: 3]

  alias Ezagent.Cap.Authority
  alias Ezagent.Capability

  test "distinguishes a stale artifact from an unreadable authority store" do
    target = unique_agent("checked-target")
    grantee = unique_user("checked-grantee")
    {:ok, generation_one} = Authority.open(target, :agent)
    artifact = authority_signed_cap!(generation_one, grantee, requested_cap(target))

    assert {:ok, true} =
             Authority.verify_against_current_checked(artifact, grantee, target)

    assert {:ok, _generation_two} = Authority.regenesis(target, :agent)

    assert {:ok, false} =
             Authority.verify_against_current_checked(artifact, grantee, target)

    parent = self()

    spawn(fn ->
      send(
        parent,
        {:checked_result, Authority.verify_against_current_checked(artifact, grantee, target)}
      )
    end)

    assert_receive {:checked_result, {:error, :authority_read_failed}}
  end

  test "filters stale artifacts before a caller deduplicates capability identities" do
    target = unique_agent("filter-target")
    grantee = unique_user("filter-grantee")
    {:ok, generation_one} = Authority.open(target, :agent)
    stale = authority_signed_cap!(generation_one, grantee, requested_cap(target))
    assert {:ok, generation_two} = Authority.regenesis(target, :agent)
    current = authority_signed_cap!(generation_two, grantee, requested_cap(target))

    assert Capability.identity_key(stale) == Capability.identity_key(current)

    assert {:ok, [^current]} =
             Authority.filter_current_artifacts_checked([stale, current], grantee)
  end

  defp requested_cap(target) do
    Capability.cap(
      :agent,
      Ezagent.Test.TestBehavior,
      :noop,
      target,
      Capability.workspace_of(target)
    )
  end

  defp unique_agent(suffix) do
    Ezagent.URI.agent("team-alpha", "#{suffix}-#{System.unique_integer([:positive])}")
  end

  defp unique_user(suffix) do
    Ezagent.URI.user("team-alpha", "#{suffix}-#{System.unique_integer([:positive])}")
  end
end
